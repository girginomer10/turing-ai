package com.omergirgin.mosaic.core.backup

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.DigestOutputStream
import java.security.MessageDigest

/*
 * Envelope layout (Swift JSONEncoder, `.sortedKeys` + `.withoutEscapingSlashes`):
 *
 *   {"checksumSHA256":"<hex>","credentialsIncluded":false,"formatIdentifier":"...",
 *    "formatVersion":1,"minimumReaderVersion":1,"semanticVectorsIncluded":false,"snapshot":{...}}
 *
 * The checksum is SHA-256 of the same object without its first member (iOS `IntegrityBody`).
 * Because "checksumSHA256" always sorts first, the body bytes are "{" followed by everything
 * after `"checksumSHA256":"<hex>",`, so both sides can hash the exact bytes in a stream.
 */

private const val CHECKSUM_PREFIX = "{\"checksumSHA256\":\""
private const val HEADER_LENGTH = 19 + 64 + 2

/** Counts bytes written through it (record and envelope size limits). */
private class CountingOutputStream(private val target: OutputStream?) : OutputStream() {
  var count = 0L
    private set

  override fun write(b: Int) {
    count++
    target?.write(b)
  }

  override fun write(b: ByteArray, off: Int, len: Int) {
    count += len
    target?.write(b, off, len)
  }

  override fun flush() {
    target?.flush()
  }

  override fun close() {
    target?.close()
  }
}

/** Decoded envelope plus the facts the restore summary shows. */
class PortableBackupFile(val snapshot: PortableSnapshot, val checksum: String, val byteCount: Long)

/**
 * Reads and fully validates a `.mosaicbackup` file without materializing it as one string: the
 * checksum is verified over the raw bytes first, then records are decoded one at a time.
 * [checkCancelled] is called between records so a long validation can be stopped.
 */
class PortableBackupReader(
  private val limits: PortableBackupLimits = PortableBackupLimits.DEFAULT,
  private val checkCancelled: () -> Unit = {},
) {
  fun read(file: File, blobs: PortableBlobSink? = null, onRecord: (Long) -> Unit = {}): PortableBackupFile {
    val size = file.length()
    if (size > limits.maximumTotalBytes) throw PortableBackupException.tooLarge()
    if (size < HEADER_LENGTH) throw PortableBackupException.malformed()
    val checksum = verifyChecksum(file)
    val snapshot = try {
      BufferedInputStream(FileInputStream(file), 64 * 1_024).use { input ->
        decode(PortableJsonReader(input, maximumStringChars = limits.maximumRecordBytes + 1_024), checksum, blobs, onRecord)
      }
    } catch (error: PortableBackupException) {
      throw error
    } catch (error: PortableValueTooLargeException) {
      throw PortableBackupException.recordTooLarge("backup")
    } catch (error: PortableJsonSyntaxException) {
      throw PortableBackupException.malformed()
    } catch (error: ClassCastException) {
      throw PortableBackupException.malformed()
    }
    PortableBackupValidator.validate(snapshot, limits)
    return PortableBackupFile(snapshot, checksum, size)
  }

  private fun verifyChecksum(file: File): String {
    BufferedInputStream(FileInputStream(file), 64 * 1_024).use { input ->
      val header = ByteArray(HEADER_LENGTH)
      var read = 0
      while (read < header.size) {
        val count = input.read(header, read, header.size - read)
        if (count < 0) throw PortableBackupException.malformed()
        read += count
      }
      val text = String(header, Charsets.US_ASCII)
      val checksum = text.substring(CHECKSUM_PREFIX.length, CHECKSUM_PREFIX.length + 64)
      if (!text.startsWith(CHECKSUM_PREFIX) || !text.endsWith("\",") || checksum.any { it !in "0123456789abcdef" }) {
        throw PortableBackupException.malformed()
      }
      val digest = MessageDigest.getInstance("SHA-256")
      digest.update('{'.code.toByte())
      val buffer = ByteArray(64 * 1_024)
      while (true) {
        checkCancelled()
        val count = input.read(buffer)
        if (count < 0) break
        digest.update(buffer, 0, count)
      }
      val actual = digest.digest().joinToString("") { "%02x".format(it) }
      if (actual != checksum) throw PortableBackupException.checksumMismatch()
      return checksum
    }
  }

  private fun decode(
    reader: PortableJsonReader,
    expectedChecksum: String,
    blobs: PortableBlobSink?,
    onRecord: (Long) -> Unit,
  ): PortableSnapshot {
    var checksum: String? = null
    var credentials: Boolean? = null
    var formatIdentifier: String? = null
    var formatVersion: Int? = null
    var minimumReader: Int? = null
    var vectors: Boolean? = null
    var snapshot: PortableSnapshot? = null
    reader.beginObject()
    while (reader.hasNext()) {
      when (reader.nextName()) {
        "checksumSHA256" -> checksum = (reader.readValue() as PJString).value
        "credentialsIncluded" -> credentials = (reader.readValue() as PJBool).value
        "formatIdentifier" -> formatIdentifier = (reader.readValue() as PJString).value
        "formatVersion" -> formatVersion = (reader.readValue() as PJNumber).literal.toIntOrNull() ?: throw PortableBackupException.malformed()
        "minimumReaderVersion" -> minimumReader =
          (reader.readValue() as PJNumber).literal.toIntOrNull() ?: throw PortableBackupException.malformed()
        "semanticVectorsIncluded" -> vectors = (reader.readValue() as PJBool).value
        "snapshot" -> {
          if (snapshot != null) throw PortableBackupException.malformed()
          // Sorted keys put every header field before the snapshot; check them before decoding it.
          checkHeader(formatIdentifier, formatVersion, minimumReader, credentials, vectors)
          snapshot = decodeSnapshot(reader, blobs, onRecord)
        }
        else -> throw PortableBackupException.malformed()
      }
    }
    reader.endObject()
    reader.finish()
    checkHeader(formatIdentifier, formatVersion, minimumReader, credentials, vectors)
    if (checksum != expectedChecksum) throw PortableBackupException.malformed()
    return snapshot ?: throw PortableBackupException.malformed()
  }

  private fun checkHeader(identifier: String?, version: Int?, minimumReader: Int?, credentials: Boolean?, vectors: Boolean?) {
    if (identifier == null || version == null || minimumReader == null || credentials == null || vectors == null) {
      throw PortableBackupException.malformed()
    }
    if (identifier != PortableBackupFormat.FORMAT_IDENTIFIER) throw PortableBackupException.unsupportedFormat()
    if (version > PortableBackupFormat.FORMAT_VERSION || version < 1) throw PortableBackupException.unsupportedVersion(version)
    if (minimumReader > PortableBackupFormat.READER_VERSION) throw PortableBackupException.readerTooOld(minimumReader)
    if (credentials || vectors) throw PortableBackupException.malformed()
  }

  private fun decodeSnapshot(reader: PortableJsonReader, blobs: PortableBlobSink?, onRecord: (Long) -> Unit): PortableSnapshot {
    var backupId: String? = null
    var createdAt: PortableDate? = null
    var schema: String? = null
    val conversations = ArrayList<PortableConversation>()
    val messages = ArrayList<PortableMessage>()
    val memories = ArrayList<PortableMemory>()
    val tasks = ArrayList<PortableScheduledTask>()
    val providers = ArrayList<PortableProviderConfiguration>()
    val profiles = ArrayList<PortableEmbeddingProfile>()
    val documents = ArrayList<PortableImportedDocument>()
    val chunks = ArrayList<PortableDocumentChunk>()
    val events = ArrayList<PortableRequestContextEvent>()
    val artifacts = ArrayList<PortableCompactionArtifact>()
    val heads = ArrayList<PortableCompactionHead>()
    val progress = ArrayList<PortableBackfillProgress>()
    val extensions = PortableExtensions.Builder(blobs)
    val seen = HashSet<String>()
    var records = 0L

    fun <T> collection(type: String, decode: (PJ) -> T, consume: (T) -> Unit) {
      reader.beginArray()
      while (reader.hasNext()) {
        checkCancelled()
        val value = reader.readValue()
        val bytes = CountingOutputStream(null).also { SwiftJsonWriter(it, withoutEscapingSlashes = true).write(value) }.count
        if (bytes > limits.maximumRecordBytes) throw PortableBackupException.recordTooLarge(type)
        records++
        if (records > limits.maximumRecordCount) throw PortableBackupException.tooManyRecords()
        consume(decode(value))
        onRecord(records)
      }
      reader.endArray()
    }

    reader.beginObject()
    while (reader.hasNext()) {
      val key = reader.nextName()
      if (!seen.add(key)) throw PortableBackupException.malformed()
      when (key) {
        "backupID" -> backupId = PortableIds.fromPortable((reader.readValue() as PJString).value) ?: throw PortableBackupException.malformed()
        "createdAt" -> createdAt = PortableDate.fromLiteral((reader.readValue() as PJNumber).literal) ?: throw PortableBackupException.malformed()
        "sourceSchemaVersion" -> schema = (reader.readValue() as PJString).value
        "conversations" -> collection("conversation", PortableConversation::from) { conversations += it }
        "messages" -> collection("message", PortableMessage::from) { messages += it }
        "memories" -> collection("memory", PortableMemory::from) { memories += it }
        "scheduledTasks" -> collection("scheduled_task", PortableScheduledTask::from) { tasks += it }
        "providerConfigurations" -> collection("provider_configuration", PortableProviderConfiguration::from) { providers += it }
        "embeddingProfiles" -> collection("embedding_profile", PortableEmbeddingProfile::from) { profiles += it }
        "importedDocuments" -> collection("imported_document", PortableImportedDocument::from) { documents += it }
        "documentChunks" -> collection("document_chunk", PortableDocumentChunk::from) { chunks += it }
        "requestContextEvents" -> collection("request_context_event", PortableRequestContextEvent::from) { events += it }
        "compactionArtifacts" -> collection("compaction_artifact", PortableCompactionArtifact::from) { artifacts += it }
        "conversationCompactionHeads" -> collection("conversation_compaction_head", PortableCompactionHead::from) { heads += it }
        "normalizedBackfillProgress" -> collection("normalized_backfill_progress", PortableBackfillProgress::from) { progress += it }
        // Each payload is decoded immediately; the opaque envelope is not retained.
        "extensionRecords" -> collection("extension_record", PortableExtensionRecord::from) { extensions.add(it) }
        else -> throw PortableBackupException.malformed()
      }
    }
    reader.endObject()
    // Every snapshot member is a non-optional Swift property, including empty collections.
    if (seen.size != SNAPSHOT_KEYS.size) throw PortableBackupException.malformed()
    return PortableSnapshot(
      backupID = backupId ?: throw PortableBackupException.malformed(),
      createdAt = createdAt ?: throw PortableBackupException.malformed(),
      sourceSchemaVersion = schema ?: throw PortableBackupException.malformed(),
      conversations = conversations, messages = messages, memories = memories, scheduledTasks = tasks,
      providerConfigurations = providers, embeddingProfiles = profiles, importedDocuments = documents,
      documentChunks = chunks, requestContextEvents = events, compactionArtifacts = artifacts,
      conversationCompactionHeads = heads, normalizedBackfillProgress = progress, extensions = extensions.build(),
    )
  }

  companion object {
    /** Snapshot members in Swift `.sortedKeys` order. */
    val SNAPSHOT_KEYS = listOf(
      "backupID", "compactionArtifacts", "conversationCompactionHeads", "conversations", "createdAt", "documentChunks",
      "embeddingProfiles", "extensionRecords", "importedDocuments", "memories", "messages", "normalizedBackfillProgress",
      "providerConfigurations", "requestContextEvents", "scheduledTasks", "sourceSchemaVersion",
    )
  }
}

/**
 * Streams a snapshot into [bodyFile] while hashing it, then [finish] writes the final envelope.
 * Callers emit members in [PortableBackupReader.SNAPSHOT_KEYS] order; every record is size-checked
 * before it is written, and the running envelope size is bounded like iOS capture.
 */
class PortableBackupWriter(
  private val bodyFile: File,
  backupId: String,
  private val limits: PortableBackupLimits = PortableBackupLimits.DEFAULT,
) : Closeable {
  private val digest = MessageDigest.getInstance("SHA-256")
  private val counter = CountingOutputStream(BufferedOutputStream(FileOutputStream(bodyFile), 64 * 1_024))
  private val raw = DigestOutputStream(counter, digest)
  private val writer = SwiftJsonWriter(raw, withoutEscapingSlashes = true)
  private var nextKey = 0
  private var firstInCollection = true
  private var openCollection: String? = null
  var recordCount = 0L
    private set

  init {
    writer.writeAscii(
      "{\"credentialsIncluded\":false,\"formatIdentifier\":\"${PortableBackupFormat.FORMAT_IDENTIFIER}\"," +
        "\"formatVersion\":${PortableBackupFormat.FORMAT_VERSION},\"minimumReaderVersion\":${PortableBackupFormat.READER_VERSION}," +
        "\"semanticVectorsIncluded\":false,\"snapshot\":{"
    )
    member("backupID")
    writer.writeString(PortableIds.toPortable(backupId))
  }

  private fun member(key: String) {
    check(openCollection == null) { "A collection is still open." }
    val index = PortableBackupReader.SNAPSHOT_KEYS.indexOf(key)
    check(index >= nextKey) { "Snapshot members must be written in sorted order." }
    nextKey = index + 1
    if (index > 0) writer.writeAscii(",")
    writer.writeString(key)
    writer.writeAscii(":")
  }

  fun createdAt(date: PortableDate) {
    member("createdAt")
    writer.writeAscii(date.literal)
  }

  fun beginCollection(key: String) {
    member(key)
    writer.writeAscii("[")
    openCollection = key
    firstInCollection = true
  }

  /** Encodes and appends one record; throws when it exceeds a configured limit. */
  fun record(recordType: String, value: PJ) {
    val bytes = SwiftJsonWriter.encode(value, withoutEscapingSlashes = true)
    if (bytes.size > limits.maximumRecordBytes) throw PortableBackupException.recordTooLarge(recordType)
    recordCount++
    if (recordCount > limits.maximumRecordCount) throw PortableBackupException.tooManyRecords()
    if (!firstInCollection) writer.writeAscii(",")
    firstInCollection = false
    writer.writeRaw(bytes)
    if (counter.count + HEADER_LENGTH > limits.maximumTotalBytes) throw PortableBackupException.tooLarge()
  }

  fun endCollection() {
    writer.writeAscii("]")
    openCollection = null
  }

  /** Completes the body, then writes the checksummed envelope to [destination]; returns its checksum. */
  fun finish(destination: File): String {
    member("sourceSchemaVersion")
    writer.writeString(PortableBackupFormat.SOURCE_SCHEMA_VERSION)
    writer.writeAscii("}}")
    writer.flush()
    raw.flush()
    raw.close()
    if (counter.count + HEADER_LENGTH > limits.maximumTotalBytes) throw PortableBackupException.tooLarge()
    val checksum = digest.digest().joinToString("") { "%02x".format(it) }
    BufferedOutputStream(FileOutputStream(destination), 64 * 1_024).use { out ->
      out.write("$CHECKSUM_PREFIX$checksum\",".toByteArray(Charsets.US_ASCII))
      BufferedInputStream(FileInputStream(bodyFile), 64 * 1_024).use { input ->
        input.skipNBytesCompat(1)
        input.copyTo(out, 64 * 1_024)
      }
    }
    return checksum
  }

  override fun close() {
    runCatching { raw.close() }
  }
}

private fun InputStream.skipNBytesCompat(count: Long) {
  var remaining = count
  while (remaining > 0) {
    val skipped = skip(remaining)
    if (skipped <= 0) {
      if (read() < 0) return
      remaining--
    } else {
      remaining -= skipped
    }
  }
}
