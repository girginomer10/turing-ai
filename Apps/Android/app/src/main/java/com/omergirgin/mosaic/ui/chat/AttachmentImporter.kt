package com.omergirgin.mosaic.ui.chat

import android.content.ContentResolver
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.util.Base64
import androidx.core.graphics.createBitmap
import androidx.core.graphics.scale
import androidx.exifinterface.media.ExifInterface
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class AttachmentImportException(message: String) : Exception(message)

/**
 * Turns picked content into chat [Attachment]s, mirroring iOS `ChatAttachmentStore`:
 * photos become JPEG at most 1024 px on the long edge and 1 MiB, re-encoded from pixels so
 * EXIF (location, camera) metadata never leaves the device; text files are read as UTF-8 with
 * the same 800,000-byte cap.
 */
object AttachmentImporter {
  const val MAX_ATTACHMENTS = 4
  private const val MAX_PHOTO_SOURCE_BYTES = 30L * 1024 * 1024
  private const val MAX_EDGE = 1024
  private const val MAX_JPEG_BYTES = 1_048_576
  private const val MAX_TEXT_BYTES = 800_000
  private const val MAX_NAME_LENGTH = 200

  suspend fun photo(context: Context, uri: Uri): Attachment = withContext(Dispatchers.IO) {
    val resolver = context.contentResolver
    val size = querySize(resolver, uri)
    if (size != null && size > MAX_PHOTO_SOURCE_BYTES) {
      throw AttachmentImportException("Choose a photo smaller than 30 MB.")
    }
    val decoded = try {
      decodeBounded(resolver, uri)
    } catch (e: OutOfMemoryError) {
      null
    } catch (e: Exception) {
      null
    } ?: throw AttachmentImportException("This photo could not be opened.")
    val jpeg = try {
      encodeJpeg(decoded)
    } finally {
      decoded.recycle()
    }
    Attachment(
      id = UUID.randomUUID().toString(),
      kind = AttachmentKind.IMAGE,
      fileName = jpegFileName(displayName(resolver, uri)),
      mimeType = "image/jpeg",
      imageBase64 = Base64.encodeToString(jpeg, Base64.NO_WRAP),
    )
  }

  suspend fun textFile(context: Context, uri: Uri): Attachment = withContext(Dispatchers.IO) {
    val resolver = context.contentResolver
    val name = (displayName(resolver, uri) ?: "Document.txt").take(MAX_NAME_LENGTH)
    val size = querySize(resolver, uri)
    if (size != null && size > MAX_TEXT_BYTES) throw tooLong()
    val bytes = resolver.openInputStream(uri)?.use { readAtMost(it, MAX_TEXT_BYTES + 1) }
      ?: throw AttachmentImportException("This file could not be opened.")
    if (bytes.size > MAX_TEXT_BYTES) throw tooLong()
    var text = decodeUtf8(bytes)
      ?: throw AttachmentImportException("“$name” isn't UTF-8 text. Choose a plain text or Markdown file.")
    if (text.startsWith('\uFEFF')) text = text.substring(1)
    // A NUL almost always means a binary file that happens to decode; sending it wastes tokens.
    if (text.indexOf('\u0000') >= 0) {
      throw AttachmentImportException("“$name” looks like a binary file. Choose a plain text or Markdown file.")
    }
    if (text.isBlank()) throw AttachmentImportException("“$name” is empty.")
    val mime = resolver.getType(uri)?.takeIf { it.startsWith("text/") } ?: if (name.endsWith(".md", true) || name.endsWith(".markdown", true)) "text/markdown" else "text/plain"
    Attachment(
      id = UUID.randomUUID().toString(),
      kind = AttachmentKind.TEXT,
      fileName = name,
      mimeType = mime,
      extractedText = text,
    )
  }

  private fun tooLong() = AttachmentImportException(
    "This file is too long for a chat attachment (800 KB of text at most). Shorten it or split it into parts."
  )

  /** Decodes with the long edge already at most [MAX_EDGE] px and orientation applied. */
  private fun decodeBounded(resolver: ContentResolver, uri: Uri): Bitmap? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      val source = ImageDecoder.createSource(resolver, uri)
      // ImageDecoder applies EXIF orientation itself and decodes HEIF/AVIF/WebP as well.
      return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
        val width = info.size.width
        val height = info.size.height
        val scale = MAX_EDGE.toFloat() / max(width, height)
        if (scale < 1f) {
          decoder.setTargetSize(
            max(1, (width * scale).roundToInt()),
            max(1, (height * scale).roundToInt()),
          )
        }
        // Software pixels: hardware bitmaps cannot be drawn into a Canvas for alpha flattening.
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
      }
    }

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) } ?: return null
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_EDGE) sample *= 2
    val options = BitmapFactory.Options().apply { inSampleSize = sample }
    val sampled = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
    val rotation = resolver.openInputStream(uri)?.use { exifRotation(it) } ?: 0

    val scale = minOf(1f, MAX_EDGE.toFloat() / max(sampled.width, sampled.height))
    if (scale == 1f && rotation == 0) return sampled
    val matrix = Matrix().apply {
      postScale(scale, scale)
      if (rotation != 0) postRotate(rotation.toFloat())
    }
    val transformed = Bitmap.createBitmap(sampled, 0, 0, sampled.width, sampled.height, matrix, true)
    if (transformed !== sampled) sampled.recycle()
    return transformed
  }

  private fun exifRotation(stream: InputStream): Int =
    when (ExifInterface(stream).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
      ExifInterface.ORIENTATION_ROTATE_90, ExifInterface.ORIENTATION_TRANSPOSE -> 90
      ExifInterface.ORIENTATION_ROTATE_180 -> 180
      ExifInterface.ORIENTATION_ROTATE_270, ExifInterface.ORIENTATION_TRANSVERSE -> 270
      else -> 0
    }

  private fun encodeJpeg(source: Bitmap): ByteArray {
    // JPEG has no alpha channel; flatten onto white so transparent PNGs don't turn black.
    var current = if (source.hasAlpha()) {
      createBitmap(source.width, source.height).also {
        Canvas(it).apply {
          drawColor(Color.WHITE)
          drawBitmap(source, 0f, 0f, null)
        }
      }
    } else {
      source
    }
    try {
      repeat(4) {
        for (quality in intArrayOf(85, 75, 65, 55)) {
          val out = ByteArrayOutputStream()
          current.compress(Bitmap.CompressFormat.JPEG, quality, out)
          if (out.size() <= MAX_JPEG_BYTES) return out.toByteArray()
        }
        // Noisy images can exceed 1 MiB even at 1024 px; shrink and try again.
        val smaller = current.scale(
          max(1, (current.width * 0.8f).roundToInt()),
          max(1, (current.height * 0.8f).roundToInt()),
        )
        if (current !== source) current.recycle()
        current = smaller
      }
    } finally {
      if (current !== source) current.recycle()
    }
    throw AttachmentImportException("This photo is too large. Choose a smaller image.")
  }

  private fun decodeUtf8(bytes: ByteArray): String? = try {
    Charsets.UTF_8.newDecoder()
      .onMalformedInput(CodingErrorAction.REPORT)
      .onUnmappableCharacter(CodingErrorAction.REPORT)
      .decode(ByteBuffer.wrap(bytes))
      .toString()
  } catch (e: CharacterCodingException) {
    null
  }

  private fun readAtMost(stream: InputStream, limit: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    while (out.size() < limit) {
      val read = stream.read(buffer, 0, minOf(buffer.size, limit - out.size()))
      if (read < 0) break
      out.write(buffer, 0, read)
    }
    return out.toByteArray()
  }

  private fun displayName(resolver: ContentResolver, uri: Uri): String? = runCatching {
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) cursor.getString(0) else null
    }
  }.getOrNull()?.takeIf { it.isNotBlank() }

  private fun querySize(resolver: ContentResolver, uri: Uri): Long? = runCatching {
    resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
      if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
    }
  }.getOrNull()

  private fun jpegFileName(original: String?): String {
    val base = original?.substringBeforeLast('.')?.takeIf { it.isNotBlank() } ?: "Photo"
    return "${base.take(MAX_NAME_LENGTH - 4)}.jpg"
  }
}
