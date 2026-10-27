package com.omergirgin.mosaic.data.backup

import android.net.Uri
import java.io.File
import kotlinx.coroutines.flow.StateFlow

/** What a backup contains (or a restore would bring back). */
data class BackupContents(
  val conversations: Int = 0,
  val messages: Int = 0,
  val attachments: Int = 0,
  val pinnedMemories: Int = 0,
  val learnedTopics: Int = 0,
  val documents: Int = 0,
  val projects: Int = 0,
  val providers: Int = 0,
  val automations: Int = 0,
  val embeddingProfiles: Int = 0,
)

/** Long-running step for progress UI. [total] is 0 when the size is not known yet. */
data class BackupProgress(val stage: Stage, val completed: Long = 0, val total: Long = 0) {
  enum class Stage { READING_LIBRARY, VERIFYING, COPYING_FILE, VALIDATING, RESTORING, CLEANING_UP }
}

/** A verified backup waiting in app-private storage until the user picks a destination. */
class PreparedBackup internal constructor(
  internal val file: File,
  val suggestedFileName: String,
  val byteCount: Long,
  val contents: BackupContents,
  /** What was intentionally left out and why (user-facing sentences). */
  val notes: List<String>,
  val verified: Boolean,
)

/** A fully validated backup staged in memory/app storage; nothing in the library has changed yet. */
class RestorePreview internal constructor(
  internal val plan: RestorePlan,
  val backupCreatedAtMillis: Long,
  val byteCount: Long,
  val contents: BackupContents,
  /** Data in the file that Android does not restore, and other consequences (user-facing). */
  val notes: List<String>,
)

data class RestoreResult(val contents: BackupContents, val notes: List<String>, val searchIndexCleared: Boolean)

/**
 * Portable `.mosaicbackup` export and restore, file-compatible with the iOS app. Export never
 * contains API keys, the rebuildable vector cache or app-local preferences. Restore validates the
 * whole file before anything changes, then replaces the library in one transaction: providers get
 * new local IDs and stay disabled without keys, and automations stay paused.
 */
interface LibraryBackupRepository {
  /** Why a backup or restore cannot start right now (active reply, running automation), or null. */
  suspend fun busyReason(): String?

  /** Snapshots the library into a verified file in app-private storage. Cancellable. */
  suspend fun prepareExport(onProgress: (BackupProgress) -> Unit): PreparedBackup

  /** Copies a prepared backup to a user-chosen document (SAF), then deletes the private copy. */
  suspend fun saveExport(prepared: PreparedBackup, destination: Uri)

  fun discardExport(prepared: PreparedBackup)

  /** Copies, checks and stages [source]; the live library is untouched. Cancellable. */
  suspend fun prepareRestore(source: Uri, onProgress: (BackupProgress) -> Unit): RestorePreview

  /** Replaces the library with [preview] in one transaction. Not cancellable once it starts. */
  suspend fun applyRestore(preview: RestorePreview, onProgress: (BackupProgress) -> Unit): RestoreResult

  fun discardRestore(preview: RestorePreview)

  /** Last successful backup/restore message for this process (iOS "Last result"). */
  val lastResult: StateFlow<String?>

  fun suggestedFileName(nowMillis: Long = System.currentTimeMillis()): String
}
