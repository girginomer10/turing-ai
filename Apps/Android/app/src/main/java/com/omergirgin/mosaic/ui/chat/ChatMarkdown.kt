package com.omergirgin.mosaic.ui.chat

import android.content.ClipData
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.mikepenz.markdown.compose.components.markdownComponents
import com.mikepenz.markdown.compose.elements.MarkdownCodeBlock
import com.mikepenz.markdown.compose.elements.MarkdownCodeFence
import com.mikepenz.markdown.m3.Markdown
import com.mikepenz.markdown.m3.markdownColor
import com.mikepenz.markdown.m3.markdownTypography
import com.mikepenz.markdown.model.rememberMarkdownState
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Above this size the first parse happens off the main thread instead of during composition. */
private const val IMMEDIATE_PARSE_LIMIT = 12_000

/**
 * Assistant Markdown. Code blocks get a header with the language and a Copy button and scroll
 * horizontally instead of wrapping, so copied code keeps its exact layout.
 */
@Composable
fun ChatMarkdown(content: String, modifier: Modifier = Modifier) {
  // retainState keeps the previous render while a streamed update re-parses, so rows don't
  // collapse to empty and make the transcript jump. Short messages parse synchronously so a row
  // recycled back into view has its final height on the first frame.
  val state = rememberMarkdownState(
    content = content,
    retainState = true,
    immediate = content.length <= IMMEDIATE_PARSE_LIMIT,
  )
  val components = remember {
    markdownComponents(
      codeFence = { model ->
        MarkdownCodeFence(model.content, model.node, model.typography.code) { code, language, style ->
          CodeBlock(code = code, language = language, style = style)
        }
      },
      codeBlock = { model ->
        MarkdownCodeBlock(model.content, model.node, model.typography.code) { code, language, style ->
          CodeBlock(code = code, language = language, style = style)
        }
      },
    )
  }
  val colors = MaterialTheme.colorScheme
  val type = MaterialTheme.typography
  Markdown(
    markdownState = state,
    colors = markdownColor(
      text = colors.onSurface,
      codeBackground = colors.surfaceContainerHigh,
      inlineCodeBackground = colors.surfaceContainerHigh,
      dividerColor = colors.outlineVariant,
      tableBackground = colors.surfaceContainerLow,
    ),
    typography = markdownTypography(
      h1 = type.headlineSmall,
      h2 = type.titleLarge,
      h3 = type.titleMedium,
      h4 = type.titleSmall,
      h5 = type.titleSmall,
      h6 = type.titleSmall,
      text = type.bodyLarge,
      paragraph = type.bodyLarge,
      ordered = type.bodyLarge,
      bullet = type.bodyLarge,
      list = type.bodyLarge,
      quote = type.bodyLarge.copy(color = colors.onSurfaceVariant),
      code = type.bodyMedium.copy(fontFamily = FontFamily.Monospace),
      inlineCode = type.bodyLarge.copy(fontFamily = FontFamily.Monospace),
    ),
    components = components,
    modifier = modifier,
  )
}

@Composable
private fun CodeBlock(code: String, language: String?, style: TextStyle) {
  val clipboard = LocalClipboard.current
  val scope = rememberCoroutineScope()
  var copied by remember { mutableStateOf(false) }
  LaunchedEffect(copied) {
    if (copied) {
      delay(1_500)
      copied = false
    }
  }
  Surface(
    color = MaterialTheme.colorScheme.surfaceContainerHigh,
    shape = RoundedCornerShape(12.dp),
    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
  ) {
    Column {
      Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(start = 12.dp)) {
        Text(
          text = language?.takeIf { it.isNotBlank() } ?: "Code",
          style = MaterialTheme.typography.labelMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
          modifier = Modifier.weight(1f),
        )
        IconButton(onClick = {
          scope.launch {
            clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Code", code)))
            copied = true
          }
        }) {
          Icon(
            imageVector = if (copied) Icons.Outlined.Check else Icons.Outlined.ContentCopy,
            contentDescription = "Copy code",
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
      }
      Text(
        text = code.trimEnd('\n'),
        style = style.copy(color = MaterialTheme.colorScheme.onSurface),
        softWrap = false,
        modifier = Modifier
          .horizontalScroll(rememberScrollState())
          .padding(start = 12.dp, end = 12.dp, bottom = 12.dp),
      )
    }
  }
}
