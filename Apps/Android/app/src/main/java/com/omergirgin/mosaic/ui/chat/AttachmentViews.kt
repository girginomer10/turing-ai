package com.omergirgin.mosaic.ui.chat

import android.graphics.BitmapFactory
import android.util.Base64
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.omergirgin.mosaic.data.model.Attachment
import com.omergirgin.mosaic.data.model.AttachmentKind
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Long text is shown up to this length in the inspector; the full text was still sent. */
private const val PREVIEW_TEXT_LIMIT = 50_000

/**
 * Decoded thumbnails keyed by attachment id and size, so scrolling the transcript doesn't decode
 * the same base64 JPEG again. Bounded by count (each entry is at most ~1024 px).
 */
private object AttachmentBitmapCache {
  val cache = LruCache<String, ImageBitmap>(32)
}

@Composable
private fun rememberAttachmentBitmap(attachment: Attachment, maxEdge: Dp): ImageBitmap? {
  val maxEdgePx = with(LocalDensity.current) { maxEdge.roundToPx() }
  val cacheKey = "${attachment.id}@$maxEdgePx"
  val bitmap by produceState(AttachmentBitmapCache.cache.get(cacheKey), cacheKey) {
    if (value != null) return@produceState
    val base64 = attachment.imageBase64 ?: return@produceState
    value = withContext(Dispatchers.Default) {
      runCatching {
        val bytes = Base64.decode(base64, Base64.DEFAULT)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxEdgePx) sample *= 2
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
          ?.asImageBitmap()
      }.getOrNull()
    }?.also { AttachmentBitmapCache.cache.put(cacheKey, it) }
  }
  return bitmap
}

/** Attachments of a sent user message. Tapping one opens the inspector. */
@Composable
fun SentAttachments(attachments: List<Attachment>, onOpen: (Attachment) -> Unit, modifier: Modifier = Modifier) {
  Column(modifier, verticalArrangement = Arrangement.spacedBy(6.dp), horizontalAlignment = Alignment.End) {
    for (attachment in attachments) {
      when (attachment.kind) {
        AttachmentKind.IMAGE -> {
          val bitmap = rememberAttachmentBitmap(attachment, 180.dp)
          Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier
              .size(width = 180.dp, height = 135.dp)
              .clip(RoundedCornerShape(16.dp))
              .background(MaterialTheme.colorScheme.surfaceContainerHigh)
              .clickable(onClickLabel = "Open photo", role = Role.Image) { onOpen(attachment) },
          ) {
            if (bitmap != null) {
              Image(
                bitmap = bitmap,
                contentDescription = "Photo: ${attachment.fileName}",
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
              )
            } else {
              Icon(Icons.Outlined.Image, contentDescription = "Photo: ${attachment.fileName}")
            }
          }
        }
        AttachmentKind.TEXT, AttachmentKind.PDF -> Surface(
          shape = RoundedCornerShape(14.dp),
          color = MaterialTheme.colorScheme.surfaceContainerHigh,
          modifier = Modifier
            .widthIn(max = 260.dp)
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClickLabel = "Show the text that was sent") { onOpen(attachment) },
        ) {
          Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.heightIn(min = 48.dp).padding(horizontal = 12.dp, vertical = 8.dp),
          ) {
            Icon(
              if (attachment.kind == AttachmentKind.PDF) Icons.Outlined.PictureAsPdf else Icons.Outlined.Description,
              contentDescription = if (attachment.kind == AttachmentKind.PDF) "PDF" else "Text file",
            )
            Text(
              attachment.fileName,
              style = MaterialTheme.typography.bodyMedium,
              maxLines = 1,
              overflow = TextOverflow.Ellipsis,
            )
          }
        }
      }
    }
  }
}

/** Inspector for a sent attachment: the normalized photo, or the exact extracted text. */
@Composable
fun AttachmentPreviewDialog(attachment: Attachment, onDismiss: () -> Unit) {
  when (attachment.kind) {
    AttachmentKind.IMAGE -> Dialog(
      onDismissRequest = onDismiss,
      properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
      Surface(shape = RoundedCornerShape(20.dp), modifier = Modifier.padding(16.dp)) {
        Column(horizontalAlignment = Alignment.End) {
          IconButton(onClick = onDismiss) {
            Icon(Icons.Outlined.Close, contentDescription = "Close photo")
          }
          val bitmap = rememberAttachmentBitmap(attachment, 1024.dp)
          Box(Modifier.fillMaxWidth().heightIn(min = 200.dp), contentAlignment = Alignment.Center) {
            if (bitmap != null) {
              Image(
                bitmap = bitmap,
                contentDescription = "Photo: ${attachment.fileName}",
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
              )
            } else {
              CircularProgressIndicator()
            }
          }
        }
      }
    }
    AttachmentKind.TEXT, AttachmentKind.PDF -> {
      val text = attachment.extractedText.orEmpty()
      AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(attachment.fileName, maxLines = 2, overflow = TextOverflow.Ellipsis) },
        text = {
          Column(Modifier.heightIn(max = 480.dp).verticalScroll(rememberScrollState())) {
            Text(
              if (attachment.kind == AttachmentKind.PDF) "Text extracted on this device and sent with the message."
              else "Text sent with the message.",
              style = MaterialTheme.typography.labelMedium,
              color = MaterialTheme.colorScheme.onSurfaceVariant,
              modifier = Modifier.padding(bottom = 8.dp),
            )
            if (text.length > PREVIEW_TEXT_LIMIT) {
              Text(
                "Showing the first 50,000 characters. The whole file was attached.",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(bottom = 8.dp),
              )
            }
            SelectionContainer {
              Text(
                text.take(PREVIEW_TEXT_LIMIT).ifEmpty { "No text was extracted from this file." },
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
              )
            }
          }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
      )
    }
  }
}

/** Unsent attachment in the composer with a 48 dp remove button. */
@Composable
fun PendingAttachmentChip(attachment: Attachment, onRemove: () -> Unit, enabled: Boolean) {
  Surface(
    shape = RoundedCornerShape(14.dp),
    color = MaterialTheme.colorScheme.surfaceContainerHighest,
  ) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 6.dp)) {
      if (attachment.kind == AttachmentKind.IMAGE) {
        val bitmap = rememberAttachmentBitmap(attachment, 36.dp)
        Box(
          contentAlignment = Alignment.Center,
          modifier = Modifier.size(36.dp).clip(RoundedCornerShape(8.dp)),
        ) {
          if (bitmap != null) {
            Image(bitmap = bitmap, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
          } else {
            Icon(Icons.Outlined.Image, contentDescription = null)
          }
        }
      } else {
        Icon(
          if (attachment.kind == AttachmentKind.PDF) Icons.Outlined.PictureAsPdf else Icons.Outlined.Description,
          contentDescription = null,
          modifier = Modifier.padding(start = 4.dp),
        )
      }
      Text(
        attachment.fileName,
        style = MaterialTheme.typography.labelLarge,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.widthIn(max = 160.dp).padding(start = 8.dp),
      )
      IconButton(onClick = onRemove, enabled = enabled) {
        Icon(Icons.Outlined.Close, contentDescription = "Remove ${attachment.fileName}")
      }
    }
  }
}

/**
 * Placeholder chip while a picked file is being normalized or its text extracted. [label] shows
 * extraction progress (e.g. OCR page counts); [onCancel] adds a 48 dp stop button.
 */
@Composable
fun PreparingAttachmentChip(label: String? = null, onCancel: (() -> Unit)? = null) {
  Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(8.dp),
      modifier = Modifier
        .heightIn(min = 48.dp)
        .padding(start = 12.dp, end = if (onCancel == null) 12.dp else 0.dp)
        .semantics(mergeDescendants = true) {},
    ) {
      CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
      Text(
        label ?: "Preparing attachment…",
        style = MaterialTheme.typography.labelLarge,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.widthIn(max = 240.dp),
      )
      if (onCancel != null) {
        IconButton(onClick = onCancel) {
          Icon(Icons.Outlined.Close, contentDescription = "Cancel preparing attachment")
        }
      }
    }
  }
}
