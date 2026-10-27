package com.omergirgin.mosaic.ui.chat.branching

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.AltRoute
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.omergirgin.mosaic.data.branching.ConversationAlternative
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.components.relativeTime
import kotlinx.coroutines.flow.catch

/**
 * Alternatives of the open chat (iOS `ConversationAlternativesView`): every conversation in its
 * branch group, oldest first, with the model each one uses and when it was created.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AlternativesSheet(conversationId: String, onOpen: (String) -> Unit, onDismiss: () -> Unit) {
  val container = LocalAppContainer.current
  val flow = remember(conversationId) {
    container.alternatives.observeAlternatives(conversationId).catch { emit(emptyList()) }
  }
  val alternatives by flow.collectAsStateWithLifecycle(initialValue = null)

  ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
    Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(bottom = 16.dp)) {
      Column(Modifier.padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text("Alternatives", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
        Text(
          "Each alternative is its own chat. The original conversation stays unchanged.",
          style = MaterialTheme.typography.bodyMedium,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
      }
      val list = alternatives
      when {
        list == null -> CircularProgressIndicator(Modifier.padding(24.dp).size(24.dp).align(Alignment.CenterHorizontally))
        list.isEmpty() -> Text(
          "Edit a message or ask another model to create an alternative.",
          style = MaterialTheme.typography.bodyLarge,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          modifier = Modifier.padding(horizontal = 24.dp, vertical = 20.dp),
        )
        else -> LazyColumn(Modifier.padding(top = 8.dp)) {
          items(list, key = { it.conversationId }) { alternative ->
            AlternativeRow(
              alternative = alternative,
              current = alternative.conversationId == conversationId,
              onClick = {
                onDismiss()
                if (alternative.conversationId != conversationId) onOpen(alternative.conversationId)
              },
            )
          }
        }
      }
    }
  }
}

@Composable
private fun AlternativeRow(alternative: ConversationAlternative, current: Boolean, onClick: () -> Unit) {
  val details = buildList {
    add(if (alternative.isOriginal) "Original" else "Alternative")
    val model = listOfNotNull(alternative.providerName, alternative.modelId).joinToString(" · ")
    add(model.ifEmpty { "No model selected" })
    add(relativeTime(alternative.createdAt))
    if (alternative.isArchived) add("Archived")
  }.joinToString(" · ")
  Row(
    verticalAlignment = Alignment.CenterVertically,
    horizontalArrangement = Arrangement.spacedBy(16.dp),
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 64.dp)
      .semantics { selected = current }
      .clickable(role = Role.Button, onClickLabel = if (current) "Close" else "Open alternative", onClick = onClick)
      .padding(horizontal = 24.dp, vertical = 10.dp),
  ) {
    Icon(Icons.AutoMirrored.Outlined.AltRoute, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
      Text(
        alternative.title,
        style = MaterialTheme.typography.bodyLarge,
        fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
      )
      Text(
        details,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
      )
    }
    if (current) Icon(Icons.Outlined.Check, contentDescription = "Open now")
  }
}
