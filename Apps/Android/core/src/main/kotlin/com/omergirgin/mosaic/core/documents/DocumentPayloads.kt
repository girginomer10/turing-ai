package com.omergirgin.mosaic.core.documents

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** Builds commit-ready payloads from extracted text (the pure half of iOS `DocumentIngestor`). */
object DocumentPayloads {
  const val PDF_MIME_TYPE = "application/pdf"

  /** File name without extension; the full name when that would be blank. */
  fun displayTitle(fileName: String): String {
    val base = if (fileName.contains('.')) fileName.substringBeforeLast('.') else fileName
    return DocumentText.trim(base).ifEmpty { fileName }
  }

  /**
   * Strict text decoding: UTF-8 (optional BOM) or BOM-marked UTF-16. Malformed input and NUL
   * bytes are rejected instead of being imported as garbage.
   */
  fun decodeText(bytes: ByteArray): String {
    val text = when {
      bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte() ->
        strictDecode(bytes, 3, Charsets.UTF_8)
      bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() ->
        strictDecode(bytes, 2, Charsets.UTF_16BE)
      bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() ->
        strictDecode(bytes, 2, Charsets.UTF_16LE)
      else -> strictDecode(bytes, 0, Charsets.UTF_8)
    } ?: throw DocumentIngestionException.NotUtf8Text()
    // A NUL almost always means a binary file that happens to decode.
    if (text.indexOf('\u0000') >= 0) throw DocumentIngestionException.UnsupportedType()
    return text
  }

  fun textPayload(
    fileName: String,
    mimeType: String,
    text: String,
    sourceByteCount: Long,
    checkCancellation: () -> Unit = {},
  ): ImportedDocumentPayload {
    val trimmed = DocumentText.trim(text)
    if (trimmed.isEmpty()) throw DocumentIngestionException.NoExtractableText(isPdf = false)
    val characterCount = DocumentText.characterCount(trimmed)
    if (characterCount > DocumentLimits.MAXIMUM_CHARACTERS) throw DocumentIngestionException.FileTooLarge()
    checkCancellation()
    val chunks = DocumentTextChunker().chunks(listOf(DocumentSection(null, trimmed)), checkCancellation = checkCancellation)
    checkCancellation()
    return ImportedDocumentPayload(
      title = displayTitle(fileName),
      sourceFilename = fileName,
      mimeType = mimeType,
      contentFingerprint = DocumentText.fingerprint(trimmed),
      characterCount = characterCount,
      pageCount = null,
      chunks = chunks,
      sourceByteCount = sourceByteCount,
    )
  }

  fun pdfPayload(
    fileName: String,
    extraction: PdfExtractedText,
    pageCount: Int,
    sourceByteCount: Long,
    checkCancellation: () -> Unit = {},
  ): ImportedDocumentPayload {
    checkCancellation()
    val chunks = DocumentTextChunker().chunks(extraction.sections, extraction.ocrPageNumbers, checkCancellation)
    checkCancellation()
    return ImportedDocumentPayload(
      title = displayTitle(fileName),
      sourceFilename = fileName,
      mimeType = PDF_MIME_TYPE,
      contentFingerprint = DocumentText.fingerprint(extraction.joinedText),
      characterCount = extraction.characterCount,
      pageCount = pageCount,
      chunks = chunks,
      ocrPageCount = extraction.ocrPageCount,
      ocrFallbackPageCount = extraction.ocrFallbackPageCount,
      sourceByteCount = sourceByteCount,
    )
  }

  private fun strictDecode(bytes: ByteArray, offset: Int, charset: Charset): String? = try {
    charset.newDecoder()
      .onMalformedInput(CodingErrorAction.REPORT)
      .onUnmappableCharacter(CodingErrorAction.REPORT)
      .decode(ByteBuffer.wrap(bytes, offset, bytes.size - offset))
      .toString()
  } catch (_: CharacterCodingException) {
    null
  }
}
