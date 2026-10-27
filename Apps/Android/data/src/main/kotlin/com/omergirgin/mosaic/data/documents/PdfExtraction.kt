package com.omergirgin.mosaic.data.documents

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.omergirgin.mosaic.core.documents.DocumentIngestionException
import com.omergirgin.mosaic.core.documents.DocumentLimits
import com.omergirgin.mosaic.core.documents.DocumentText
import com.omergirgin.mosaic.core.documents.OcrTextAssembler
import com.omergirgin.mosaic.core.documents.OcrTextLine
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.io.StringWriter
import java.util.concurrent.Executor
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine

/** Embedded PDF text layer, one string per page, via PdfBox-Android. */
internal object PdfEmbeddedText {
  private const val PDFBOX_MEMORY_BYTES = 32L * 1_024 * 1_024

  /**
   * Returns null when PdfBox cannot parse the file (the caller then treats every page as blank
   * and lets PdfRenderer + OCR try). Password-protected files fail with the locked-PDF error.
   */
  fun read(context: Context, file: File, scratch: File, job: Job?, onPage: (page: Int, pages: Int) -> Unit): List<String>? {
    PDFBoxResourceLoader.init(context)
    val document = try {
      PDDocument.load(file, MemoryUsageSetting.setupMixed(PDFBOX_MEMORY_BYTES).setTempDir(scratch))
    } catch (_: InvalidPasswordException) {
      throw DocumentIngestionException.LockedPdf()
    } catch (_: IOException) {
      return null
    } catch (_: OutOfMemoryError) {
      return null
    } catch (error: RuntimeException) {
      if (error is CancellationException) throw error
      return null
    }
    return document.use {
      val pageCount = it.numberOfPages
      if (pageCount <= 0) return@use emptyList()
      val stripper = PerPageTextStripper(pageCount, job, onPage)
      try {
        stripper.writeText(it, stripper.sink)
      } catch (error: IOException) {
        return@use null
      } catch (_: OutOfMemoryError) {
        throw DocumentIngestionException.FileTooLarge()
      }
      stripper.pages.toList()
    }
  }

  /**
   * Captures each page's text in one pass. Pages without a content stream never reach
   * startPage/endPage and stay "" (blank, so they are planned for OCR).
   */
  private class PerPageTextStripper(
    pageCount: Int,
    private val job: Job?,
    private val onPage: (page: Int, pages: Int) -> Unit,
  ) : PDFTextStripper() {
    val sink = StringWriter()
    val pages = Array(pageCount) { "" }
    private var characterCount = 0

    init {
      setLineSeparator("\n")
    }

    override fun startPage(page: PDPage?) {
      job?.ensureActive()
      sink.buffer.setLength(0)
      onPage(currentPageNo, pages.size)
      super.startPage(page)
    }

    override fun endPage(page: PDPage?) {
      super.endPage(page)
      val index = currentPageNo - 1
      if (index in pages.indices) {
        val text = sink.toString()
        pages[index] = text
        characterCount += DocumentText.characterCount(text)
        if (characterCount > DocumentLimits.MAXIMUM_CHARACTERS) throw DocumentIngestionException.FileTooLarge()
      }
      sink.buffer.setLength(0)
    }
  }
}

/**
 * Renders PDF pages within the iOS pixel limits and recognizes them with ML Kit's bundled Latin
 * model, entirely on the device. The renderer and recognizer open lazily, only when a page
 * actually needs OCR. Not thread-safe; used sequentially by one import.
 */
internal class PdfPageRecognizer(private val file: File) : Closeable {
  private var descriptor: ParcelFileDescriptor? = null
  private var renderer: PdfRenderer? = null
  private var recognizer: TextRecognizer? = null

  fun pageCount(): Int = openRenderer().pageCount

  suspend fun recognize(pageIndex: Int): String =
    try {
      recognizeOrThrow(pageIndex)
    } catch (cancellation: CancellationException) {
      throw cancellation
    } catch (error: Exception) {
      // Type only: OCR errors never include page content, but keep the log content-free anyway.
      Log.w("TuringDocuments", "On-device OCR failed (${error.javaClass.name}).")
      throw error
    }

  private suspend fun recognizeOrThrow(pageIndex: Int): String {
    val bitmap = render(pageIndex)
    val client = recognizer ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS).also { recognizer = it }
    val result = client.process(InputImage.fromBitmap(bitmap, 0)).awaitResult()
    // Only recycle after ML Kit is done; a cancelled request may still be reading the pixels.
    val width = bitmap.width.toFloat()
    val height = bitmap.height.toFloat()
    bitmap.recycle()

    val lines = result.textBlocks.flatMap { it.lines }
    // Confidence is reported per line by the v2 model; if a build reports none, keep every line.
    val usesConfidence = lines.any { it.confidence > 0f }
    return OcrTextAssembler.assemble(
      lines.filter { !usesConfidence || it.confidence >= MINIMUM_CONFIDENCE }.map { line ->
        val box = line.boundingBox
        if (box == null) {
          OcrTextLine(line.text, 0f, 0f, 0f, 0f)
        } else {
          OcrTextLine(line.text, box.left / width, box.top / height, box.right / width, box.bottom / height)
        }
      }
    )
  }

  private fun openRenderer(): PdfRenderer {
    renderer?.let { return it }
    val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    return try {
      PdfRenderer(fd).also {
        descriptor = fd
        renderer = it
      }
    } catch (_: SecurityException) {
      fd.close()
      throw DocumentIngestionException.LockedPdf()
    } catch (_: IOException) {
      fd.close()
      throw DocumentIngestionException.Unreadable()
    }
  }

  private fun render(pageIndex: Int): Bitmap {
    val pdf = openRenderer()
    if (pageIndex !in 0 until pdf.pageCount) throw IOException("Page out of range.")
    pdf.openPage(pageIndex).use { page ->
      val width = page.width.toDouble()
      val height = page.height.toDouble()
      if (!(width > 0 && height > 0)) throw IOException("Empty page.")
      val pixelCapScale = sqrt(MAXIMUM_RENDERED_PIXELS / (width * height))
      val dimensionCapScale = MAXIMUM_PIXEL_DIMENSION / max(width, height)
      var scale = min(PREFERRED_SCALE, min(pixelCapScale, dimensionCapScale))
      repeat(3) {
        val bitmap = try {
          Bitmap.createBitmap(
            max(1, floor(width * scale).toInt()),
            max(1, floor(height * scale).toInt()),
            Bitmap.Config.ARGB_8888,
          )
        } catch (_: OutOfMemoryError) {
          null
        }
        if (bitmap != null) {
          // PdfRenderer draws onto transparent pixels; OCR needs an opaque white page.
          bitmap.eraseColor(Color.WHITE)
          page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
          return bitmap
        }
        scale /= 2
      }
      throw IOException("Not enough memory to render the page.")
    }
  }

  override fun close() {
    runCatching { recognizer?.close() }
    runCatching { renderer?.close() }
    runCatching { descriptor?.close() }
    recognizer = null
    renderer = null
    descriptor = null
  }

  private companion object {
    const val MAXIMUM_RENDERED_PIXELS = 12_000_000.0
    const val MAXIMUM_PIXEL_DIMENSION = 4_096.0
    const val PREFERRED_SCALE = 2.5
    const val MINIMUM_CONFIDENCE = 0.2f
  }
}

private val DirectExecutor = Executor { it.run() }

private suspend fun <T> Task<T>.awaitResult(): T = suspendCancellableCoroutine { continuation ->
  addOnCompleteListener(DirectExecutor) { task ->
    val error = task.exception
    when {
      error != null -> continuation.resumeWithException(error)
      task.isCanceled -> continuation.resumeWithException(IOException("Text recognition was cancelled."))
      else -> continuation.resume(task.result)
    }
  }
}
