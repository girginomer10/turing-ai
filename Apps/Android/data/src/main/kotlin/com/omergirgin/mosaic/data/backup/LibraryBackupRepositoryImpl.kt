package com.omergirgin.mosaic.data.backup

import android.content.Context
import android.net.Uri
import android.util.Log
import com.omergirgin.mosaic.core.backup.PortableBackupException
import com.omergirgin.mosaic.core.backup.PortableBackupFormat
import com.omergirgin.mosaic.core.backup.PortableBackupLimits
import com.omergirgin.mosaic.core.backup.PortableBackupReader
import com.omergirgin.mosaic.core.backup.PortableBlob
import com.omergirgin.mosaic.core.backup.PortableBlobSink
import com.omergirgin.mosaic.core.backup.PortableIds
import com.omergirgin.mosaic.core.retrieval.RetrievalSourceKind
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.index.SemanticVectorStore
import com.omergirgin.mosaic.data.security.SecretStore
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/** Spills attachment bytes to app-private files while a backup is staged or verified. */
private class FileBlobSink(private val directory: File) : PortableBlobSink {
  override fun store(recordId: String, bytes: ByteArray): PortableBlob {
    directory.mkdirs()
    val file = File(directory, "${PortableIds.deterministicLocal("blob:$recordId")}.bin")
    file.writeBytes(bytes)
    return PortableBlob(bytes.size) { file.readBytes() }
  }
}

internal class LibraryBackupRepositoryImpl(
  context: Context,
  private val db: MosaicDatabase,
  private val secrets: SecretStore,
  private val vectors: SemanticVectorStore,
  /** Returns a user-facing reason while provider work or an automation is running. */
  private val busyCheck: suspend () -> String?,
  /** Reschedules background work for the replaced library (paused automations). */
  private val afterRestore: suspend () -> Unit,
  private val limits: PortableBackupLimits = PortableBackupLimits.DEFAULT,
) : LibraryBackupRepository {
  private val appContext = context.applicationContext
  private val operation = Mutex()
  private val _lastResult = MutableStateFlow<String?>(null)
  override val lastResult: StateFlow<String?> = _lastResult.asStateFlow()

  private val workDir: File
    get() = File(appContext.cacheDir, "portable-backup").apply { mkdirs() }

  override suspend fun busyReason(): String? = busyCheck()

  override fun suggestedFileName(nowMillis: Long): String {
    val stamp = SimpleDateFormat("yyyy-MM-dd-HHmm", Locale.US).format(Date(nowMillis))
    return "Turing AI-Backup-$stamp.${PortableBackupFormat.FILE_EXTENSION}"
  }

  /** One backup/restore step at a time; a second request fails instead of queuing silently. */
  private suspend fun <T> exclusive(block: suspend () -> T): T {
    if (!operation.tryLock()) throw IllegalStateException("Another backup or restore is already running.")
    try {
      return block()
    } finally {
      operation.unlock()
    }
  }

  private suspend fun requireIdle() {
    busyCheck()?.let { throw IllegalStateException(it) }
  }

  override suspend fun prepareExport(onProgress: (BackupProgress) -> Unit): PreparedBackup = withContext(Dispatchers.IO) {
    exclusive {
      requireIdle()
      cleanStaleFiles()
      val file = File(workDir, "export-${PortableIds.random()}.${PortableBackupFormat.FILE_EXTENSION}")
      try {
        val outcome = BackupExporter(db, workDir, limits).export(file, onProgress)
        onProgress(BackupProgress(BackupProgress.Stage.VERIFYING))
        val verified = verifyReadable(file)
        PreparedBackup(file, suggestedFileName(), file.length(), outcome.contents, outcome.notes, verified)
      } catch (error: Throwable) {
        file.delete()
        throw describe(error, exporting = true)
      }
    }
  }

  /**
   * Read-back check (iOS staging verification): the exact file is decoded and validated with the
   * restore rules. Skipped only when the file is too large to hold on this device.
   */
  private suspend fun verifyReadable(file: File): Boolean {
    if (file.length() > memoryBudget()) return false
    val blobs = File(workDir, "verify-${PortableIds.random()}")
    val context = coroutineContext
    try {
      PortableBackupReader(limits) { context.ensureActive() }.read(file, FileBlobSink(blobs))
      return true
    } catch (error: PortableBackupException) {
      throw IllegalStateException("Turing AI could not verify the backup it created (${error.message}) Nothing was saved.")
    } finally {
      blobs.deleteRecursively()
    }
  }

  override suspend fun saveExport(prepared: PreparedBackup, destination: Uri) = withContext(Dispatchers.IO + NonCancellable) {
    try {
      val output = appContext.contentResolver.openOutputStream(destination, "wt")
        ?: throw IllegalStateException("The selected location cannot be written.")
      output.use { out -> prepared.file.inputStream().use { it.copyTo(out, 64 * 1_024) } }
      _lastResult.value = "Portable backup saved."
    } catch (error: SecurityException) {
      throw IllegalStateException("Turing AI does not have permission to write to the selected location.")
    } catch (error: IOException) {
      throw IllegalStateException("The backup could not be written to the selected location.")
    } finally {
      prepared.file.delete()
    }
  }

  override fun discardExport(prepared: PreparedBackup) {
    prepared.file.delete()
  }

  override suspend fun prepareRestore(source: Uri, onProgress: (BackupProgress) -> Unit): RestorePreview =
    withContext(Dispatchers.IO) {
      exclusive {
        cleanStaleFiles()
        val copy = File(workDir, "restore-${PortableIds.random()}.${PortableBackupFormat.FILE_EXTENSION}")
        val staging = File(workDir, "staging-${PortableIds.random()}")
        try {
          onProgress(BackupProgress(BackupProgress.Stage.COPYING_FILE))
          copyBounded(source, copy)
          if (copy.length() > memoryBudget()) {
            throw IllegalStateException(
              "This backup is too large to restore on this device in one operation. Free up memory or restore it on a device with more memory."
            )
          }
          val context = coroutineContext
          onProgress(BackupProgress(BackupProgress.Stage.VALIDATING))
          val decoded = PortableBackupReader(limits) { context.ensureActive() }
            .read(copy, FileBlobSink(staging)) { count ->
              if (count % 256 == 0L) onProgress(BackupProgress(BackupProgress.Stage.VALIDATING, count))
            }
          coroutineContext.ensureActive()
          val mapper = RestoreMapper(decoded.snapshot, staging)
          val plan = mapper.map()
          RestorePreview(plan, decoded.snapshot.createdAt.epochMillis, decoded.byteCount, mapper.contents(plan), mapper.notes)
        } catch (error: Throwable) {
          staging.deleteRecursively()
          throw describe(error, exporting = false)
        } finally {
          copy.delete()
        }
      }
    }

  override suspend fun applyRestore(preview: RestorePreview, onProgress: (BackupProgress) -> Unit): RestoreResult =
    // Past this point cancellation is ignored: the transaction either commits or rolls back.
    withContext(Dispatchers.IO + NonCancellable) {
      exclusive {
        requireIdle()
        val dao = db.backup()
        val previousProviders = dao.providers().map { it.id }
        val previousProfiles = dao.embeddingProfiles().map { it.id }
        val plan = preview.plan
        try {
          plan.replace(db) { done ->
            if (done % 256 == 0L) onProgress(BackupProgress(BackupProgress.Stage.RESTORING, done, plan.rowCount))
          }
        } catch (error: Throwable) {
          Log.w(TAG, "Library restore rolled back (${error.javaClass.simpleName}).")
          throw IllegalStateException("Turing AI could not replace the local library. Nothing was changed.")
        }
        onProgress(BackupProgress(BackupProgress.Stage.CLEANING_UP))
        // Keys of replaced connections can never be reused: restored providers have new IDs.
        for (id in previousProviders) runCatching { secrets.remove(id) }
        val indexCleared = clearSearchIndex(previousProfiles + plan.profiles.map { it.id })
        runCatching { afterRestore() }.onFailure { Log.w(TAG, "Rescheduling after restore failed (${it.javaClass.simpleName}).") }
        plan.discard()
        val message = if (indexCleared) {
          "Library restored. Review and re-enable providers, re-enter their keys, and review paused automations before using them."
        } else {
          "Library restored with providers disabled and automations paused. The rebuildable search cache could not be cleared and will be revalidated before use."
        }
        _lastResult.value = message
        RestoreResult(preview.contents, preview.notes, indexCleared)
      }
    }

  override fun discardRestore(preview: RestorePreview) {
    preview.plan.discard()
  }

  /** Deletes every cached vector: per known profile, then any remaining rows of each source kind. */
  private suspend fun clearSearchIndex(profileIds: List<String>): Boolean = runCatching {
    profileIds.distinct().forEach { vectors.deleteProfile(it) }
    for (kind in RetrievalSourceKind.entries) {
      while (true) {
        val page = vectors.metadataPage(kind.rawValue, "", SemanticVectorStore.MAXIMUM_PAGE_SIZE)
        if (page.isEmpty()) break
        vectors.delete(page.map { it.cacheKey })
      }
    }
  }.onFailure { Log.w(TAG, "Search index clear failed (${it.javaClass.simpleName}).") }.isSuccess

  private suspend fun copyBounded(source: Uri, target: File) {
    val input = try {
      appContext.contentResolver.openInputStream(source)
    } catch (error: SecurityException) {
      null
    } ?: throw IllegalStateException("Turing AI could not open the selected file.")
    input.use { stream ->
      FileOutputStream(target).use { out ->
        val buffer = ByteArray(64 * 1_024)
        var total = 0L
        while (true) {
          coroutineContext.ensureActive()
          val count = stream.read(buffer)
          if (count < 0) break
          total += count
          if (total > limits.maximumTotalBytes) throw PortableBackupException.tooLarge()
          out.write(buffer, 0, count)
        }
      }
    }
  }

  /** Rough peak-memory guard: decoded text roughly doubles in memory (UTF-16) plus row objects. */
  private fun memoryBudget(): Long = Runtime.getRuntime().maxMemory() / 3

  private fun cleanStaleFiles() {
    val cutoff = System.currentTimeMillis() - STALE_AFTER_MILLIS
    workDir.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
  }

  private fun describe(error: Throwable, exporting: Boolean): Throwable = when (error) {
    is CancellationException -> error
    is PortableBackupException -> error
    is IllegalStateException -> error
    is OutOfMemoryError -> IllegalStateException(
      if (exporting) "This library is too large to back up on this device in one operation."
      else "This backup is too large to restore on this device in one operation."
    )
    is IOException -> IllegalStateException(
      if (exporting) "Turing AI could not write the backup file." else "Turing AI could not read the selected file."
    )
    else -> {
      Log.w(TAG, "Backup operation failed (${error.javaClass.simpleName}).")
      IllegalStateException(if (exporting) "Turing AI could not create the backup." else "The selected file is not a valid Turing AI backup.")
    }
  }

  private companion object {
    const val TAG = "TuringBackup"
    const val STALE_AFTER_MILLIS = 6L * 60 * 60 * 1_000
  }
}
