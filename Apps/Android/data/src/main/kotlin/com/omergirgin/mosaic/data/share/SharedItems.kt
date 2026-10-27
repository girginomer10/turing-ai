package com.omergirgin.mosaic.data.share

import android.net.Uri
import java.io.File
import kotlinx.coroutines.flow.Flow

/*
 * Shared items (iOS `SharedInbox` + `SharedInboxView`): content handed to Turing AI through the
 * system share sheet is copied into app-private storage right away (content URIs expire) and
 * waits here until the person opens it as a new draft. Nothing is ever sent automatically. The
 * queue is local files only, outside the database and backups, like the iOS app-group inbox.
 */

enum class SharedFileKind { IMAGE, PDF, TEXT }

/** A copied file. [file] is app-private and readable until the item is removed. */
data class SharedFile(val file: File, val displayName: String, val kind: SharedFileKind)

/**
 * A web address shared without its page. Browsers and most apps share only the link, so the
 * model receives the address, never the page text.
 */
data class SharedLink(val url: String, val title: String?)

data class SharedItem(
  val id: String,
  val createdAt: Long,
  /** Optional question typed in the share screen (iOS `prompt`). */
  val note: String,
  /** Shared text short enough for the composer; longer text arrives as a text file instead. */
  val text: String?,
  val link: SharedLink?,
  val files: List<SharedFile>,
) {
  /** Text for the new draft: the question, then the shared text or link (all editable before sending). */
  val draftText: String
    get() = listOfNotNull(
      note.trim().takeIf { it.isNotEmpty() },
      text?.trim()?.takeIf { it.isNotEmpty() },
      link?.let { link ->
        listOfNotNull(
          link.title?.let { "Page title: $it" },
          "Shared link (page text was not provided): ${link.url}",
        ).joinToString("\n")
      },
    ).joinToString("\n\n")

  /** iOS titles the draft after its first file. */
  val draftTitle: String
    get() = (files.firstOrNull()?.displayName ?: link?.title ?: "Shared items").take(160)
}

/** One readable stream from a share intent. */
data class IncomingStream(val uri: Uri, val mimeType: String?)

/** What a share intent carried, before anything is copied. */
data class IncomingShare(val text: String?, val subject: String?, val streams: List<IncomingStream>)

/** Thrown with a user-facing message when shared content cannot be accepted or prepared. */
class SharedItemException(message: String) : Exception(message)

interface SharedItemsRepository {
  /** Queued items, oldest first. */
  fun observeItems(): Flow<List<SharedItem>>

  /**
   * Copies everything [incoming] refers to into a private staging folder. Must run while the
   * share grant is alive (the receiving activity). The result is not queued until [commit].
   */
  suspend fun stage(incoming: IncomingShare): SharedItem

  /** Queues a staged item with the optional question [note]. */
  suspend fun commit(stagedId: String, note: String)

  /** Deletes a staged item that was never queued (share cancelled). */
  suspend fun discard(stagedId: String)

  /** Removes a queued item and its copied files. */
  suspend fun delete(id: String)

  /**
   * Creates the draft chat for item [id] (or reuses it after an interrupted earlier attempt),
   * stores the draft text, and removes the item from the queue. Returns the conversation ID.
   * Attachments are prepared by the caller beforehand and handed to the composer directly.
   */
  suspend fun createDraft(id: String): String
}
