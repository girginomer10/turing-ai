package com.omergirgin.mosaic.data.share

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import com.omergirgin.mosaic.core.context.utf8Length
import com.omergirgin.mosaic.data.db.ConversationEntity
import com.omergirgin.mosaic.data.db.MosaicDatabase
import com.omergirgin.mosaic.data.internal.MonotonicClock
import com.omergirgin.mosaic.data.repo.ProviderRepositoryImpl
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.URI
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * File-backed queue: `files/SharedItems/<id>/item.json` plus the copied files (`0.jpg`, ...).
 * A share is first copied into `<id>.pending` and only becomes visible when committed, so an
 * interrupted share never shows a half-copied item. Limits follow iOS: at most ten queued items,
 * four files per item, 30 MB per file and a 32,000-byte question.
 */
internal class SharedItemsRepositoryImpl(
  context: Context,
  private val db: MosaicDatabase,
  private val providers: ProviderRepositoryImpl,
) : SharedItemsRepository {
  private val appContext = context.applicationContext
  private val root = File(appContext.filesDir, ROOT_DIRECTORY)
  private val revision = MutableStateFlow(0L)
  private val lock = Mutex()
  private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

  override fun observeItems(): Flow<List<SharedItem>> =
    revision
      .map { lock.withLock { loadAll() } }
      .distinctUntilChanged()
      .flowOn(Dispatchers.IO)

  override suspend fun stage(incoming: IncomingShare): SharedItem = withContext(Dispatchers.IO) {
    lock.withLock {
      removeStaleStaging()
      if (committedDirectories().size >= MAX_QUEUED_ITEMS) {
        throw SharedItemException("Open Turing AI and clear Shared items before adding more.")
      }
    }
    val streams = incoming.streams.distinctBy { it.uri }
    if (streams.size > MAX_FILES) throw SharedItemException("Share up to four files at a time.")

    val id = UUID.randomUUID().toString()
    val staging = File(root, id + PENDING_SUFFIX)
    if (!staging.mkdirs()) throw SharedItemException("Turing AI couldn't save the shared items on this device.")
    try {
      val files = ArrayList<StoredFile>()
      var text: String? = null
      var link: StoredLink? = null
      val subject = incoming.subject?.trim()?.takeIf { it.isNotEmpty() }?.take(MAX_SUBJECT_LENGTH)
      val shared = incoming.text?.trim()?.takeIf { it.isNotEmpty() }
      if (shared != null) {
        val url = singleWebUrl(shared)
        if (url != null) {
          link = StoredLink(url, subject?.takeIf { it != url })
        } else {
          // Apps that share a note often put its title in the subject; keep it with the text.
          val combined = if (subject != null && !shared.contains(subject)) "$subject\n\n$shared" else shared
          val bytes = utf8Length(combined)
          when {
            bytes <= MAX_DRAFT_TEXT_BYTES -> text = combined
            bytes <= MAX_TEXT_FILE_BYTES -> {
              val storedName = "${files.size}.txt"
              File(staging, storedName).writeText(combined, Charsets.UTF_8)
              files += StoredFile(storedName, "Shared text.txt", SharedFileKind.TEXT.name)
            }
            else -> throw SharedItemException(
              "The shared text is longer than 800 KB, which is too long for a chat attachment."
            )
          }
        }
      }
      if (files.size + streams.size > MAX_FILES) throw SharedItemException("Share up to four files at a time.")
      for (stream in streams) {
        ensureActive()
        files += copyStream(stream, staging, files.size)
      }
      if (text == null && link == null && files.isEmpty()) {
        throw SharedItemException("Nothing that Turing AI can use was shared.")
      }
      val manifest = Manifest(id = id, createdAt = System.currentTimeMillis(), text = text, link = link, files = files)
      writeManifest(staging, manifest)
      manifest.toItem(staging)
    } catch (error: Throwable) {
      staging.deleteRecursively()
      throw error
    }
  }

  override suspend fun commit(stagedId: String, note: String) = withContext(Dispatchers.IO) {
    if (utf8Length(note) > MAX_NOTE_BYTES) throw SharedItemException("The question is too long. Shorten it to save.")
    requireUuid(stagedId)
    lock.withLock {
      val staging = File(root, stagedId + PENDING_SUFFIX)
      val manifest = readManifest(staging) ?: throw SharedItemException("These shared items are no longer available. Share them again.")
      writeManifest(staging, manifest.copy(prompt = note.trim()))
      if (!staging.renameTo(File(root, stagedId))) {
        throw SharedItemException("Turing AI couldn't save the shared items on this device.")
      }
    }
    revision.value += 1
  }

  override suspend fun discard(stagedId: String) {
    withContext(Dispatchers.IO) {
      requireUuid(stagedId)
      lock.withLock { File(root, stagedId + PENDING_SUFFIX).deleteRecursively() }
    }
  }

  override suspend fun delete(id: String) {
    withContext(Dispatchers.IO) {
      requireUuid(id)
      lock.withLock { File(root, id).deleteRecursively() }
    }
    revision.value += 1
  }

  override suspend fun createDraft(id: String): String {
    requireUuid(id)
    val item = withContext(Dispatchers.IO) { lock.withLock { readManifest(File(root, id))?.toItem(File(root, id)) } }
      ?: throw SharedItemException("This shared item is no longer available.")
    // The item's stable ID makes a retry after an interrupted earlier attempt idempotent (iOS).
    if (db.conversations().get(id) == null) {
      val choice = providers.defaultChoice(null, null)
      val now = MonotonicClock.now()
      db.conversations().insert(
        ConversationEntity(
          id = id,
          title = item.draftTitle,
          projectId = null,
          systemPrompt = null,
          modelProviderId = choice?.providerId,
          modelId = choice?.modelId,
          draft = item.draftText,
          isArchived = false,
          webSearchEnabled = false,
          createdAt = now,
          updatedAt = now,
        )
      )
    }
    delete(id)
    return id
  }

  // region files

  private fun copyStream(stream: IncomingStream, directory: File, index: Int): StoredFile {
    val uri = stream.uri
    val resolver = appContext.contentResolver
    // Only content shared by another app: a file:// URI or one of our own providers could point
    // at Turing AI's private files, which must never end up in a draft.
    if (uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority.isNullOrBlank() || isOwnProvider(uri)) {
      throw SharedItemException("This item can't be read. Share it again from the app that has it.")
    }
    val displayName = sanitizedName(queryDisplayName(resolver, uri))
    val wildcard = stream.mimeType == null || stream.mimeType.endsWith("/*")
    val mimeType = (if (wildcard) runCatching { resolver.getType(uri) }.getOrNull() else stream.mimeType)
      ?.lowercase(Locale.ROOT)
    val kind = kindOf(mimeType, displayName)
      ?: throw SharedItemException("“${displayName ?: "This item"}” isn't a photo, PDF, or text file.")
    val name = displayName ?: defaultName(kind)
    val size = querySize(resolver, uri)
    if (size != null && size > MAX_FILE_BYTES) throw tooLarge(name)
    val storedName = "$index.${extensionFor(kind, mimeType, name)}"
    val target = File(directory, storedName)
    try {
      val input = resolver.openInputStream(uri) ?: throw SharedItemException("“$name” couldn't be opened.")
      input.use { source -> target.outputStream().use { copyBounded(source, it, name) } }
    } catch (error: SecurityException) {
      throw SharedItemException("Turing AI wasn't allowed to read “$name”. Share it again.")
    } catch (error: IOException) {
      throw SharedItemException("“$name” couldn't be copied. Share it again.")
    }
    if (target.length() == 0L) throw SharedItemException("“$name” is empty.")
    return StoredFile(storedName, name, kind.name)
  }

  private fun copyBounded(input: InputStream, output: OutputStream, name: String) {
    val buffer = ByteArray(64 * 1024)
    var total = 0L
    while (true) {
      val read = input.read(buffer)
      if (read < 0) break
      total += read
      if (total > MAX_FILE_BYTES) throw tooLarge(name)
      output.write(buffer, 0, read)
    }
  }

  @Suppress("DEPRECATION")
  private fun isOwnProvider(uri: Uri): Boolean {
    val authority = uri.authority ?: return true
    val owner = runCatching { appContext.packageManager.resolveContentProvider(authority, 0)?.packageName }.getOrNull()
    return owner == appContext.packageName
  }

  private fun committedDirectories(): List<File> =
    root.listFiles()?.filter { it.isDirectory && isUuid(it.name) }.orEmpty()

  /** Staging folders left by a share that crashed or was killed mid-copy. */
  private fun removeStaleStaging() {
    val cutoff = System.currentTimeMillis() - STALE_STAGING_MILLIS
    root.listFiles()
      ?.filter { it.isDirectory && it.name.endsWith(PENDING_SUFFIX) && it.lastModified() < cutoff }
      ?.forEach { it.deleteRecursively() }
  }

  private fun loadAll(): List<SharedItem> {
    removeStaleStaging()
    return committedDirectories()
      .mapNotNull { directory -> readManifest(directory)?.takeIf { it.id == directory.name }?.toItem(directory) }
      .sortedWith(compareBy({ it.createdAt }, { it.id }))
  }

  private fun readManifest(directory: File): Manifest? {
    val file = File(directory, MANIFEST)
    if (!file.isFile || file.length() > MAX_MANIFEST_BYTES) return null
    val manifest = runCatching { json.decodeFromString(Manifest.serializer(), file.readText(Charsets.UTF_8)) }.getOrNull()
      ?: return null
    val valid = manifest.files.size <= MAX_FILES &&
      utf8Length(manifest.prompt) <= MAX_NOTE_BYTES &&
      manifest.files.all { stored ->
        STORED_NAME.matches(stored.storedName) &&
          stored.displayName.length <= MAX_NAME_LENGTH &&
          SharedFileKind.entries.any { it.name == stored.kind } &&
          File(directory, stored.storedName).isFile
      }
    return manifest.takeIf { valid }
  }

  private fun writeManifest(directory: File, manifest: Manifest) {
    val temporary = File(directory, "$MANIFEST.tmp")
    temporary.writeText(json.encodeToString(Manifest.serializer(), manifest), Charsets.UTF_8)
    if (!temporary.renameTo(File(directory, MANIFEST))) {
      temporary.delete()
      throw SharedItemException("Turing AI couldn't save the shared items on this device.")
    }
  }

  private fun Manifest.toItem(directory: File) = SharedItem(
    id = id,
    createdAt = createdAt,
    note = prompt,
    text = text,
    link = link?.let { SharedLink(it.url, it.title) },
    files = files.map { SharedFile(File(directory, it.storedName), it.displayName, SharedFileKind.valueOf(it.kind)) },
  )

  // endregion

  @Serializable
  private data class Manifest(
    val id: String,
    val createdAt: Long,
    /** iOS `SharedInboxItem.prompt`. */
    val prompt: String = "",
    val text: String? = null,
    val link: StoredLink? = null,
    val files: List<StoredFile> = emptyList(),
  )

  @Serializable
  private data class StoredLink(val url: String, val title: String? = null)

  /** iOS `SharedInboxItem.File` plus the kind decided when it was received. */
  @Serializable
  private data class StoredFile(val storedName: String, val displayName: String, val kind: String)

  private companion object {
    const val ROOT_DIRECTORY = "SharedItems"
    const val PENDING_SUFFIX = ".pending"
    const val MANIFEST = "item.json"
    const val MAX_QUEUED_ITEMS = 10
    const val MAX_FILES = 4
    const val MAX_FILE_BYTES = 30L * 1024 * 1024
    const val MAX_NOTE_BYTES = 32_000
    /** Longer shared text becomes a text attachment instead of filling the composer. */
    const val MAX_DRAFT_TEXT_BYTES = 32_000
    const val MAX_TEXT_FILE_BYTES = 800_000
    const val MAX_MANIFEST_BYTES = 256L * 1024
    const val MAX_NAME_LENGTH = 200
    const val MAX_SUBJECT_LENGTH = 500
    const val MAX_URL_BYTES = 8_192
    const val STALE_STAGING_MILLIS = 24L * 60 * 60 * 1000
    val STORED_NAME = Regex("[0-9]\\.[a-z0-9]{1,12}")
    val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "heic", "heif", "gif", "bmp", "avif")
    val TEXT_EXTENSIONS = setOf("txt", "md", "markdown", "text")

    fun requireUuid(id: String) {
      if (!isUuid(id)) throw SharedItemException("This shared item is no longer available.")
    }

    fun isUuid(value: String): Boolean = runCatching { UUID.fromString(value).toString() == value }.getOrDefault(false)

    fun tooLarge(name: String) = SharedItemException("“$name” is larger than 30 MB.")

    /** The whole text is one http(s) address: a link shared without its page. */
    fun singleWebUrl(text: String): String? {
      if (text.any { it.isWhitespace() } || utf8Length(text) > MAX_URL_BYTES) return null
      val uri = runCatching { URI(text) }.getOrNull() ?: return null
      val scheme = uri.scheme?.lowercase(Locale.ROOT)
      if ((scheme != "http" && scheme != "https") || uri.host.isNullOrBlank()) return null
      return text
    }

    fun kindOf(mimeType: String?, displayName: String?): SharedFileKind? {
      val extension = displayName?.substringAfterLast('.', "")?.lowercase(Locale.ROOT).orEmpty()
      return when {
        mimeType?.startsWith("image/") == true -> SharedFileKind.IMAGE
        mimeType == "application/pdf" -> SharedFileKind.PDF
        mimeType?.startsWith("text/") == true -> SharedFileKind.TEXT
        extension == "pdf" -> SharedFileKind.PDF
        extension in TEXT_EXTENSIONS -> SharedFileKind.TEXT
        extension in IMAGE_EXTENSIONS -> SharedFileKind.IMAGE
        else -> null
      }
    }

    /** Stored names use a known extension so the document reader recognizes the copied file. */
    fun extensionFor(kind: SharedFileKind, mimeType: String?, name: String): String {
      val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
      return when (kind) {
        SharedFileKind.PDF -> "pdf"
        SharedFileKind.TEXT -> if (extension == "md" || extension == "markdown" || mimeType == "text/markdown") "md" else "txt"
        SharedFileKind.IMAGE -> extension.takeIf { it in IMAGE_EXTENSIONS }
          ?: mimeType?.substringAfter("image/")?.filter { it.isLetterOrDigit() }?.take(12)?.ifEmpty { null }
          ?: "img"
      }
    }

    fun defaultName(kind: SharedFileKind): String = when (kind) {
      SharedFileKind.IMAGE -> "Photo.jpg"
      SharedFileKind.PDF -> "Document.pdf"
      SharedFileKind.TEXT -> "Text.txt"
    }

    /** Display only: path separators and control characters removed, length bounded. */
    fun sanitizedName(raw: String?): String? =
      raw?.substringAfterLast('/')
        ?.filterNot { it.isISOControl() || it == '\\' }
        ?.trim()
        ?.take(MAX_NAME_LENGTH)
        ?.takeIf { it.isNotEmpty() && it != "." && it != ".." }

    fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? = runCatching {
      resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getString(0) else null
      }
    }.getOrNull()

    fun querySize(resolver: ContentResolver, uri: Uri): Long? = runCatching {
      resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
      }
    }.getOrNull()
  }
}
