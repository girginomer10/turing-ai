package com.omergirgin.mosaic.data.recall

import com.omergirgin.mosaic.core.context.ContextPlanningException

/** A context plan together with the system prompt and recall it was planned with. */
internal class RecallPlanned<T>(val plan: T, val systemPrompt: String?, val recall: PreparedRecall)

/**
 * Plans a chat request with the recalled-context layer, keeping recall optional:
 * - if the plan cannot fit with recalled excerpts, it is replanned once without them;
 * - after planning (which may include a summary request), right before the chat request, the
 *   selected excerpts and the chat's project membership are revalidated. Stale excerpts are
 *   dropped from the system prompt; the plan stays valid because the prompt only gets smaller.
 * Both cases leave a receipt warning.
 *
 * [compose] builds the full system prompt for a given recall (use [PreparedRecall.appendTo] after
 * curated memory); [plan] runs the context planner for a system prompt.
 */
internal suspend fun <T> RecallCoordinator?.planWithRecall(
  prepared: PreparedRecall,
  compose: (PreparedRecall) -> String?,
  plan: suspend (systemPrompt: String?) -> T,
): RecallPlanned<T> {
  var recall = prepared
  var systemPrompt = compose(recall)
  val result = try {
    plan(systemPrompt)
  } catch (error: ContextPlanningException) {
    if (!recall.hasExcerpts) throw error
    recall = recall.withoutExcerpts(PreparedRecall.DID_NOT_FIT_WARNING)
    systemPrompt = compose(recall)
    plan(systemPrompt)
  }
  if (this != null && recall.hasExcerpts) {
    val current = revalidated(recall)
    if (current !== recall) {
      recall = current
      systemPrompt = compose(recall)
    }
  }
  return RecallPlanned(result, systemPrompt, recall)
}
