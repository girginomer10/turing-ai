package com.omergirgin.mosaic.data.connections

import com.omergirgin.mosaic.core.chat.ProviderClientFactory
import com.omergirgin.mosaic.core.chat.ProviderConnection
import com.omergirgin.mosaic.core.chat.WebSource
import com.omergirgin.mosaic.core.connections.ConnectionActionReceipt
import com.omergirgin.mosaic.core.connections.ConnectorException
import com.omergirgin.mosaic.core.connections.ConnectorExecutor
import com.omergirgin.mosaic.core.connections.ConnectorId
import com.omergirgin.mosaic.core.connections.ConnectorResearch
import com.omergirgin.mosaic.core.connections.ConnectorResearchHooks
import com.omergirgin.mosaic.core.connections.ConnectorSelection
import com.omergirgin.mosaic.core.connections.ConnectorText
import com.omergirgin.mosaic.core.connections.encoded
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.db.UsageRecordEntity
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.internal.newId
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Untrusted evidence to append to the answer request, and the sources to show with the answer. */
internal class ConnectorChatContext(val prompt: String?, val sources: List<WebSource>)

/**
 * Chat-time connector research for one assistant attempt (the iOS `ConversationView` connector
 * block). Uses the chat's own access (or the device defaults), binds the run to that exact
 * selection, records every planner request as separate "Connected tools" usage, persists action
 * receipts before reviewed requests are sent, and stores the answer's connection activity.
 */
internal class ConnectorChatHook(private val repository: ConnectionsRepositoryImpl, private val db: MosaicDatabase) {

  /**
   * Returns null when this chat has no connection access. Failures that should fail the reply
   * (selection changed mid-request, planner limits) are thrown as IllegalStateException with a
   * presentable message; cancellation propagates unchanged.
   */
  suspend fun prepare(
    conversationId: String,
    assistantId: String,
    question: String,
    connection: ProviderConnection,
    availableInputTokens: Int,
  ): ConnectorChatContext? {
    val requested = repository.preferences.effective(conversationId)
    if (requested.bindings.isEmpty() || question.isBlank()) return null
    val (usable, unavailable) = usableBindings(requested)
    val unavailableNotice = unavailable.takeIf { it.isNotEmpty() }?.let { services ->
      services.joinToString(", ") { it.title } + (if (services.size == 1) " is" else " are") +
        " no longer connected with the account chosen for this chat. Turn it on again from + → Connections."
    }
    if (usable.bindings.isEmpty()) {
      recordActivity(conversationId, assistantId, unavailableNotice, emptyList(), emptyList())
      return ConnectorChatContext(
        "Connected services were selected for this chat but are no longer available on this device (disconnected, " +
          "reconnected with another account, or permission removed). No connected data was read for this message.",
        emptyList(),
      )
    }
    val maximumBytes = minOf(8_000, availableInputTokens / 4)
    if (maximumBytes < 1_024) {
      val notice = "The selected model's context is too small to include connected service results."
      recordActivity(conversationId, assistantId, notice, emptyList(), emptyList())
      return ConnectorChatContext("$notice No connected data was read for this message.", emptyList())
    }

    val executor = ConnectorExecutor(usable, repository.store, repository.transport, repository.device, repository.pdf)
    var usage: UsageRecordEntity? = null
    val insertedReceipts = HashSet<String>()
    val hooks = ConnectorResearchHooks(
      validate = {
        if (repository.preferences.effective(conversationId) != requested) {
          throw ConnectorException(ConnectorException.Kind.CHANGED)
        }
      },
      onStart = {
        // Every intermediate request gets its own record before it is sent (unknown usage stays null).
        val record = UsageRecordEntity(
          id = newId(),
          providerId = connection.id,
          providerKind = connection.provider.rawId,
          providerName = connection.displayName,
          modelId = connection.modelId,
          destinationHost = connection.destinationHost,
          category = USAGE_CATEGORY,
          inputTokens = null,
          outputTokens = null,
          conversationId = conversationId,
          messageId = assistantId,
          createdAt = MonotonicClock.now(),
        )
        usage = record
        db.connections().upsertUsage(record)
      },
      onUsage = { tokens ->
        val current = usage
        if (current != null) {
          val updated = current.copy(
            inputTokens = tokens.inputTokens ?: current.inputTokens,
            outputTokens = tokens.outputTokens ?: current.outputTokens,
          )
          usage = updated
          db.connections().upsertUsage(updated)
        }
      },
      onProgress = { repository.setProgress(assistantId, it) },
      approve = { tool, call -> repository.approvals.request(conversationId, tool, call) },
      onAction = { receipt -> persist(receipt, conversationId, assistantId, insertedReceipts) },
    )
    try {
      val context = ConnectorResearch.run(
        question = question,
        selection = usable,
        client = ProviderClientFactory.make(connection),
        maximumBytes = maximumBytes,
        inputBudget = availableInputTokens,
        executor = executor,
        hooks = hooks,
      )
      val notice = listOfNotNull(context.notice, unavailableNotice).joinToString(" ").ifEmpty { null }
      if (context.prompt.isNotEmpty() || notice != null || context.sources.isNotEmpty()) {
        recordActivity(conversationId, assistantId, notice, context.usedServices, context.sources)
      }
      return ConnectorChatContext(context.prompt.ifEmpty { null }, context.sources)
    } catch (error: CancellationException) {
      throw error
    } catch (error: ConnectorException) {
      withContext(NonCancellable) { recordActivity(conversationId, assistantId, error.message, emptyList(), emptyList()) }
      throw IllegalStateException(error.message)
    } finally {
      repository.setProgress(assistantId, null)
    }
  }

  /** Bindings whose generation is still stored (and whose permission is still granted). */
  private suspend fun usableBindings(selection: ConnectorSelection): Pair<ConnectorSelection, List<ConnectorId>> {
    val usable = LinkedHashMap<ConnectorId, String>()
    val unavailable = ArrayList<ConnectorId>()
    for ((service, generation) in selection.bindings) {
      val live = repository.store.generation(service) == generation &&
        (!service.isDevice || repository.device.isAuthorized(service))
      if (live) usable[service] = generation else unavailable += service
    }
    return ConnectorSelection(usable) to unavailable
  }

  /** Receipts are written before the reviewed request leaves the device, then updated in place. */
  private suspend fun persist(receipt: ConnectionActionReceipt, conversationId: String, assistantId: String, inserted: MutableSet<String>) =
    withContext(NonCancellable) {
      val now = MonotonicClock.now()
      if (inserted.add(receipt.id)) {
        db.connections().insertReceipt(
          ConnectionActionReceiptEntity(
            id = receipt.id,
            messageId = assistantId,
            conversationId = conversationId,
            service = receipt.service.rawId,
            tool = receipt.tool,
            argumentsJson = ConnectorText.bounded(receipt.arguments.encoded, 32_768),
            outcome = receipt.outcome.name,
            summary = ConnectorText.bounded(receipt.summary, 1_000),
            createdAt = now,
            updatedAt = now,
          )
        )
      } else {
        check(db.connections().updateReceipt(receipt.id, receipt.outcome.name, ConnectorText.bounded(receipt.summary, 1_000), now) == 1)
      }
    }

  private suspend fun recordActivity(
    conversationId: String,
    assistantId: String,
    notice: String?,
    services: List<ConnectorId>,
    sources: List<WebSource>,
  ) {
    runCatching {
      db.connections().upsertActivity(
        ConnectionActivityEntity(
          messageId = assistantId,
          conversationId = conversationId,
          notice = notice?.let { ConnectorText.bounded(it, 1_500) },
          servicesJson = JsonArray(services.map { JsonPrimitive(it.rawId) }).encoded,
          sourcesJson = JsonArray(
            sources.take(100).map {
              JsonObject(mapOf("title" to (it.title?.let(::JsonPrimitive) ?: JsonNull), "url" to JsonPrimitive(it.url)))
            }
          ).encoded,
          createdAt = MonotonicClock.now(),
        )
      )
    }
  }

  companion object {
    const val USAGE_CATEGORY = "Connected tools"
  }
}
