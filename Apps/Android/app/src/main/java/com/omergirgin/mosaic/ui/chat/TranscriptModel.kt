package com.omergirgin.mosaic.ui.chat

import com.omergirgin.mosaic.core.chat.ChatRole
import com.omergirgin.mosaic.data.model.Message

/** Messages of one conversation, tagged with the conversation they belong to. */
data class TranscriptState(
  val conversationId: String?,
  val messages: List<Message>,
  val loaded: Boolean,
)

/** One visual row of the transcript. */
sealed interface TranscriptItem {
  val key: String

  data class User(val message: Message) : TranscriptItem {
    override val key: String get() = message.id
  }

  /**
   * An assistant answer and its retries. Retries are auditable rows that point at the attempt
   * they replace; the transcript shows one attempt at a time (newest by default).
   */
  data class Assistant(val rootId: String, val attempts: List<Message>) : TranscriptItem {
    override val key: String get() = rootId
  }
}

/**
 * Collapses retry chains (`retryOfMessageId`) into one [TranscriptItem.Assistant] placed where the
 * first attempt was. Handles both chained (A3 → A2 → A1) and flat (A3 → A1) retry links, and
 * tolerates links to deleted messages. System rows are never shown.
 */
fun buildTranscript(messages: List<Message>): List<TranscriptItem> {
  val ordered = messages.filter { it.role != ChatRole.SYSTEM }.sortedBy { it.createdAt }
  val byId = ordered.associateBy { it.id }

  fun rootOf(message: Message): String {
    var current = message
    val seen = HashSet<String>()
    while (true) {
      if (!seen.add(current.id)) return current.id
      val parent = current.retryOfMessageId?.let(byId::get) ?: return current.id
      if (parent.role != ChatRole.ASSISTANT) return current.id
      current = parent
    }
  }

  val groups = LinkedHashMap<String, MutableList<Message>>()
  val order = ArrayList<Any>(ordered.size) // Message (user) or String (assistant group root)
  for (message in ordered) {
    if (message.role == ChatRole.ASSISTANT) {
      val root = rootOf(message)
      val group = groups[root]
      if (group == null) {
        groups[root] = mutableListOf(message)
        order += root
      } else {
        group += message
      }
    } else {
      order += message
    }
  }
  return order.map { entry ->
    when (entry) {
      is Message -> TranscriptItem.User(entry)
      else -> {
        val root = entry as String
        TranscriptItem.Assistant(root, groups.getValue(root))
      }
    }
  }
}
