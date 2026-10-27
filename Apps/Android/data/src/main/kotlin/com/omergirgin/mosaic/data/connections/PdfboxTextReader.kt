package com.omergirgin.mosaic.data.connections

import android.content.Context
import com.omergirgin.mosaic.core.connections.PdfPages
import com.omergirgin.mosaic.core.connections.PdfTextReader
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper

/** Selectable text of a small connected file's first pages (no OCR, unlike document import). */
internal class PdfboxTextReader(context: Context) : PdfTextReader {
  private val context = context.applicationContext

  override fun read(bytes: ByteArray, maximumPages: Int): PdfPages? {
    PDFBoxResourceLoader.init(context)
    val document = try {
      PDDocument.load(bytes, "", null, null, MemoryUsageSetting.setupMainMemoryOnly(16L * 1_024 * 1_024))
    } catch (_: Exception) {
      return null
    } catch (_: OutOfMemoryError) {
      return null
    }
    return document.use {
      if (it.isEncrypted) return@use null
      val total = it.numberOfPages
      val stripper = PDFTextStripper()
      val pages = (1..minOf(total, maximumPages)).map { page ->
        stripper.startPage = page
        stripper.endPage = page
        runCatching { stripper.getText(it).trim().ifEmpty { null } }.getOrNull()
      }
      PdfPages(pages, total)
    }
  }
}
