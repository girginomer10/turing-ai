package com.omergirgin.mosaic.ui.chat

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Link
import androidx.compose.material.icons.outlined.PhotoLibrary
import androidx.compose.material.icons.outlined.UploadFile
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.model.Attachment

/** Everything the composer renders; computed by the conversation screen from view-model state. */
data class ComposerState(
  val text: String,
  val attachments: List<Attachment>,
  val importingCount: Int,
  val generating: Boolean,
  val modelReady: Boolean,
  /** The chat is loaded but its model is missing or disabled: offer the chooser below the field. */
  val showChooseModel: Boolean,
  val canAddAttachments: Boolean,
  /** Web search can be toggled (supported by the model, or on and must be switchable off). */
  val webSearchToggleVisible: Boolean,
  val webSearchEnabled: Boolean,
  val webSearchSupported: Boolean,
  val photosUnsupported: Boolean,
  /** Progress of a document being extracted (e.g. OCR pages); null = generic "Preparing". */
  val importProgress: String? = null,
  /** Gemini Live dictation is running in this chat: the field is read-only and Send is hidden. */
  val dictating: Boolean = false,
  /** Some connected service is enabled for this chat ("Connections · On" in the + menu). */
  val connectionsActive: Boolean = false,
) {
  val canSend: Boolean
    get() = !generating && !dictating && modelReady && importingCount == 0 && !photosUnsupported &&
      (text.isNotBlank() || attachments.isNotEmpty())
}

/**
 * Full-width multiline field that grows up to [maxTextHeight] and then scrolls; Enter inserts a
 * newline and sending is explicit (arrow button, or Ctrl/⌘+Enter on a hardware keyboard). Controls
 * sit below the text as on iOS.
 */
@Composable
fun Composer(
  state: ComposerState,
  maxTextHeight: Dp,
  onTextChange: (String) -> Unit,
  onAddPhotos: () -> Unit,
  /** PDF, Markdown or plain-text file, extracted on-device. */
  onAddFile: () -> Unit,
  onToggleWebSearch: (Boolean) -> Unit,
  onRemoveAttachment: (String) -> Unit,
  onSend: () -> Unit,
  onStop: () -> Unit,
  onChooseModel: () -> Unit,
  modifier: Modifier = Modifier,
  /** Stops attachments that are still being prepared (long PDFs/OCR). */
  onCancelImport: (() -> Unit)? = null,
  /** Microphone control placed beside Send (ui/voice). */
  voiceControl: (@Composable () -> Unit)? = null,
  /** Dictation status line under the field (ui/voice). */
  voiceStatus: (@Composable () -> Unit)? = null,
  /** Per-chat connection access (+ → Connections); hidden when null (e.g. Temporary Chat). */
  onOpenConnections: (() -> Unit)? = null,
) {
  var menuOpen by remember { mutableStateOf(false) }
  val colors = MaterialTheme.colorScheme

  Surface(color = colors.surface, modifier = modifier) {
    Column(
      // navigationBars first so the IME padding only adds what the keyboard covers beyond them.
      modifier = Modifier
        .navigationBarsPadding()
        .imePadding()
        .padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 8.dp),
      horizontalAlignment = Alignment.CenterHorizontally,
    ) {
      Surface(
        shape = RoundedCornerShape(24.dp),
        color = colors.surfaceContainerHigh,
        modifier = Modifier.widthIn(max = 860.dp).fillMaxWidth(),
      ) {
        Column(Modifier.padding(start = 6.dp, end = 6.dp, top = 6.dp, bottom = 4.dp)) {
          if (state.attachments.isNotEmpty() || state.importingCount > 0) {
            LazyRow(
              horizontalArrangement = Arrangement.spacedBy(8.dp),
              contentPadding = PaddingValues(horizontal = 4.dp),
              modifier = Modifier.fillMaxWidth().padding(bottom = 4.dp),
            ) {
              items(state.attachments, key = { it.id }) { attachment ->
                PendingAttachmentChip(attachment, onRemove = { onRemoveAttachment(attachment.id) }, enabled = true)
              }
              if (state.importingCount > 0) {
                item(key = "preparing") { PreparingAttachmentChip(state.importProgress, onCancelImport) }
              }
            }
          }
          if (state.photosUnsupported) {
            ComposerNotice("The selected model doesn't accept photos. Choose a photo-capable model or remove them.", warning = true)
          }
          if (state.webSearchEnabled) {
            ComposerNotice(
              if (state.webSearchSupported) "Web search on · provider search fees may apply"
              else "Web search isn't available for this model. Turn it off or choose a supported model.",
              warning = !state.webSearchSupported,
            )
          }

          BasicTextField(
            value = state.text,
            onValueChange = onTextChange,
            readOnly = state.dictating,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = colors.onSurface),
            cursorBrush = SolidColor(colors.primary),
            keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
            minLines = 1,
            modifier = Modifier
              .fillMaxWidth()
              .heightIn(min = 44.dp, max = maxTextHeight)
              .padding(horizontal = 10.dp, vertical = 8.dp)
              .semantics { contentDescription = "Message" }
              .onPreviewKeyEvent { event ->
                // Plain Enter stays a newline; Ctrl/⌘+Enter sends from a hardware keyboard.
                if (event.type == KeyEventType.KeyDown && event.key == Key.Enter &&
                  (event.isCtrlPressed || event.isMetaPressed)
                ) {
                  if (state.canSend) onSend()
                  true
                } else {
                  false
                }
              },
            decorationBox = { inner ->
              Box {
                if (state.text.isEmpty()) {
                  Text(
                    "Message Turing AI",
                    style = MaterialTheme.typography.bodyLarge,
                    color = colors.onSurfaceVariant,
                  )
                }
                inner()
              }
            },
          )

          Row(verticalAlignment = Alignment.CenterVertically) {
            Box {
              IconButton(onClick = { menuOpen = true }, enabled = !state.generating && !state.dictating) {
                Icon(Icons.Filled.Add, contentDescription = "Add attachments and tools")
              }
              DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                  text = { Text("Add photos") },
                  leadingIcon = { Icon(Icons.Outlined.PhotoLibrary, contentDescription = null) },
                  enabled = state.canAddAttachments,
                  onClick = {
                    menuOpen = false
                    onAddPhotos()
                  },
                )
                DropdownMenuItem(
                  text = { Text("Add PDF or text file") },
                  leadingIcon = { Icon(Icons.Outlined.UploadFile, contentDescription = null) },
                  enabled = state.canAddAttachments,
                  onClick = {
                    menuOpen = false
                    onAddFile()
                  },
                )
                if (!state.canAddAttachments && state.attachments.size + state.importingCount >= AttachmentImporter.MAX_ATTACHMENTS) {
                  Text(
                    "A message can contain four attachments.",
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                  )
                }
                if (state.webSearchToggleVisible) {
                  DropdownMenuItem(
                    text = { Text("Web search") },
                    leadingIcon = { Icon(Icons.Outlined.Language, contentDescription = null) },
                    trailingIcon = { Checkbox(checked = state.webSearchEnabled, onCheckedChange = null) },
                    onClick = {
                      menuOpen = false
                      onToggleWebSearch(!state.webSearchEnabled)
                    },
                  )
                }
                if (onOpenConnections != null) {
                  DropdownMenuItem(
                    text = { Text(if (state.connectionsActive) "Connections · On" else "Connections") },
                    leadingIcon = { Icon(Icons.Outlined.Link, contentDescription = null) },
                    onClick = {
                      menuOpen = false
                      onOpenConnections()
                    },
                  )
                }
              }
            }
            Spacer(Modifier.weight(1f))
            if (state.generating) {
              FilledTonalIconButton(onClick = onStop) {
                Icon(Icons.Filled.Stop, contentDescription = "Stop response")
              }
            } else {
              voiceControl?.invoke()
              // While dictating, the microphone control stands in for Send (iOS parity).
              if (!state.dictating) {
                FilledIconButton(onClick = onSend, enabled = state.canSend) {
                  Icon(Icons.Filled.ArrowUpward, contentDescription = "Send message")
                }
              }
            }
          }
        }
      }
      voiceStatus?.invoke()
      if (state.showChooseModel && !state.generating) {
        TextButton(onClick = onChooseModel, modifier = Modifier.heightIn(min = 48.dp)) {
          Text("Choose an enabled model")
        }
      }
    }
  }
}

@Composable
private fun ComposerNotice(text: String, warning: Boolean) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(6.dp),
    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
  ) {
    if (warning) {
      Icon(
        Icons.Outlined.Warning,
        contentDescription = null,
        tint = MaterialTheme.colorScheme.error,
        modifier = Modifier.size(16.dp),
      )
    }
    Text(
      text,
      style = MaterialTheme.typography.labelMedium,
      color = if (warning) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
    )
  }
}
