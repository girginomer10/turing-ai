package com.omergirgin.mosaic.core.connections

import java.net.URI
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

/** Text layer of a PDF: one entry per read page (null = no selectable text), plus the page count. */
class PdfPages(val pages: List<String?>, val totalPages: Int)

/** Platform PDF text extraction (PdfBox on Android). Returns null when the file can't be parsed or is locked. */
fun interface PdfTextReader {
  fun read(bytes: ByteArray, maximumPages: Int): PdfPages?
}

/** Bounded UTF-8 and selectable-PDF extraction for small files (iOS `ConnectorFileText`). */
object ConnectorFileText {
  val READABLE_EXTENSIONS = setOf("txt", "md", "csv", "json", "log", "pdf")

  fun extension(name: String): String = name.substringAfterLast('/').substringAfterLast('.', "").lowercase()

  fun extract(data: ByteArray, name: String, pdf: PdfTextReader?): JsonElement {
    if (data.size > 2_000_000) throw ConnectorException(ConnectorException.Kind.TOO_LARGE)
    val ext = extension(name)
    if (ext == "pdf") {
      val document = pdf?.read(data, 20) ?: throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
      if (document.totalPages <= 0) throw ConnectorException(ConnectorException.Kind.INVALID_RESPONSE)
      val text = StringBuilder()
      for ((index, page) in document.pages.withIndex()) {
        text.append("\nPage ").append(index + 1).append('\n')
          .append(page?.takeIf { it.isNotBlank() } ?: "[No selectable text; OCR was not performed.]")
        if (ConnectorText.utf8Size(text.toString()) > 30_000) break
      }
      return jsonObject(
        "name" to JsonPrimitive(name),
        "text" to JsonPrimitive(ConnectorText.bounded(text.toString(), 30_000)),
        "notice" to JsonPrimitive(
          "Selectable PDF text from at most the first 20 pages, capped at 30KB. Images, scans, tables and " +
            "remaining pages may be omitted; no OCR was performed."
        ),
        "total_pages" to JsonPrimitive(document.totalPages),
      )
    }
    if (ext !in READABLE_EXTENSIONS) throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    val text = ConnectorJson.utf8(data) ?: throw ConnectorException(ConnectorException.Kind.INVALID_ARGUMENTS)
    return jsonObject(
      "name" to JsonPrimitive(name),
      "text" to JsonPrimitive(ConnectorText.bounded(text, 30_000)),
      "truncated" to JsonPrimitive(ConnectorText.utf8Size(text) > 30_000),
    )
  }

  /** Unsigned Microsoft download hosts (known storage suffixes only). Bearer tokens are never sent there. */
  fun microsoftDownloadHost(url: String): String? {
    val uri = runCatching { URI(url) }.getOrNull() ?: return null
    val host = uri.host?.lowercase() ?: return null
    if (uri.scheme != "https" || uri.rawUserInfo != null || uri.rawFragment != null || (uri.port != -1 && uri.port != 443)) {
      return null
    }
    val suffixes = listOf("sharepoint.com", "sharepoint-df.com", "1drv.com", "storage.live.com")
    return host.takeIf { candidate -> suffixes.any { candidate.endsWith(".$it") } }
  }

  /** Dropbox-API-Arg must be ASCII: non-ASCII characters are JSON \\u escapes. */
  fun asciiHeader(json: JsonElement): String {
    val encoded = json.encoded
    val output = StringBuilder(encoded.length)
    for (char in encoded) {
      if (char.code < 128) output.append(char) else output.append("\\u%04x".format(char.code))
    }
    return output.toString()
  }
}
