package com.omergirgin.mosaic.ui.share

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.share.SharedFile
import com.omergirgin.mosaic.data.share.SharedFileKind
import com.omergirgin.mosaic.data.share.SharedItem
import com.omergirgin.mosaic.data.share.SharedLink
import java.io.File
import kotlin.math.max
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What arrived: the question, shared text, link and files, each as it will appear in the draft. */
@Composable
internal fun SharedItemPreview(item: SharedItem, showNote: Boolean = true) {
  Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
    if (showNote && item.note.isNotBlank()) {
      LabeledText("Your question", item.note, maxLines = 4)
    }
    item.text?.let { LabeledText("Shared text", it, maxLines = 6) }
    item.link?.let { SharedLinkRow(it) }
    for (file in item.files) SharedFileRow(file)
  }
}

@Composable
private fun LabeledText(label: String, text: String, maxLines: Int) {
  Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.semantics(mergeDescendants = true) {}) {
    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    Text(text.trim(), style = MaterialTheme.typography.bodyMedium, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
  }
}

/** A link shared without its page: say plainly that the model receives only the address. */
@Composable
internal fun SharedLinkRow(link: SharedLink) {
  Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(12.dp),
      modifier = Modifier.semantics(mergeDescendants = true) {},
    ) {
      Icon(Icons.Outlined.Link, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
      Column(Modifier.weight(1f)) {
        link.title?.let { Text(it, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis) }
        Text(
          link.url,
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 2,
          overflow = TextOverflow.Ellipsis,
        )
      }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
      Icon(Icons.Outlined.Info, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
      Text(
        "Only the link was shared. The sharing app didn't include the page text, and Turing AI " +
          "doesn't open it, so the model receives just the address.",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

@Composable
private fun SharedFileRow(file: SharedFile) {
  val kindLabel = when (file.kind) {
    SharedFileKind.IMAGE -> "Photo"
    SharedFileKind.PDF -> "PDF"
    SharedFileKind.TEXT -> "Text file"
  }
  Row(
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(12.dp),
    modifier = Modifier
      .heightIn(min = 48.dp)
      .semantics(mergeDescendants = true) { contentDescription = "$kindLabel: ${file.displayName}" },
  ) {
    if (file.kind == SharedFileKind.IMAGE) {
      SharedThumbnail(file.file)
    } else {
      Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest, modifier = Modifier.size(56.dp)) {
        Box(contentAlignment = Alignment.Center) {
          Icon(
            if (file.kind == SharedFileKind.PDF) Icons.Outlined.PictureAsPdf else Icons.AutoMirrored.Outlined.InsertDriveFile,
            contentDescription = null,
          )
        }
      }
    }
    Column(Modifier.weight(1f)) {
      Text(file.displayName, style = MaterialTheme.typography.bodyMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
      Text(kindLabel, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
  }
}

@Composable
private fun SharedThumbnail(file: File) {
  val bitmap by produceState<ImageBitmap?>(null, file) {
    value = withContext(Dispatchers.IO) { runCatching { decodeThumbnail(file, 168) }.getOrNull()?.asImageBitmap() }
  }
  val image = bitmap
  if (image != null) {
    Image(
      bitmap = image,
      contentDescription = null,
      contentScale = ContentScale.Crop,
      modifier = Modifier.size(56.dp).clip(RoundedCornerShape(10.dp)),
    )
  } else {
    Surface(shape = RoundedCornerShape(10.dp), color = MaterialTheme.colorScheme.surfaceContainerHighest, modifier = Modifier.size(56.dp)) {
      Box(contentAlignment = Alignment.Center) { Icon(Icons.Outlined.Image, contentDescription = null) }
    }
  }
}

/** Small preview decoded from the private copy; the original stays untouched until the draft. */
private fun decodeThumbnail(file: File, maxEdge: Int): Bitmap? {
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
    return ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, info, _ ->
      val scale = maxEdge.toFloat() / max(info.size.width, info.size.height)
      if (scale < 1f) {
        decoder.setTargetSize(max(1, (info.size.width * scale).toInt()), max(1, (info.size.height * scale).toInt()))
      }
    }
  }
  val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
  BitmapFactory.decodeFile(file.path, bounds)
  var sample = 1
  while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxEdge) sample *= 2
  return BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
}
