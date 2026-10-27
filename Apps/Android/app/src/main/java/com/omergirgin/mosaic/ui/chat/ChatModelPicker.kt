package com.omergirgin.mosaic.ui.chat

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.data.model.ModelChoice
import com.omergirgin.mosaic.data.model.ModelOption

private fun ModelOption.key(section: String) = "$section/${choice.providerId}/${choice.modelId}"

private data class ProviderGroup(val providerId: String, val title: String, val options: List<ModelOption>)

private data class PickerSections(
  val favorites: List<ModelOption>,
  val recent: List<ModelOption>,
  val groups: List<ProviderGroup>,
) {
  val isEmpty: Boolean get() = favorites.isEmpty() && recent.isEmpty() && groups.isEmpty()
}

/**
 * Splits options into Favorites, Recently used (5) and per-provider groups of the rest, like the
 * iOS chooser. Pure and allocation-light so it can rerun per keystroke over thousands of models.
 */
private fun pickerSections(
  options: List<ModelOption>,
  recent: List<ModelChoice>,
  query: String,
  photosOnly: Boolean,
): PickerSections {
  val tokens = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
  val filtered = options.filter { option ->
    (!photosOnly || option.supportsImages) && tokens.all { token ->
      option.modelId.contains(token, ignoreCase = true) || option.providerName.contains(token, ignoreCase = true)
    }
  }
  val favorites = filtered.filter { it.isFavorite }
  val byChoice = filtered.associateBy { it.choice }
  val recentOptions = recent.asSequence()
    .mapNotNull { byChoice[it] }
    .filter { !it.isFavorite }
    .distinct()
    .take(5)
    .toList()
  val shown = (favorites + recentOptions).mapTo(HashSet()) { it.choice }
  val groups = filtered.asSequence()
    .filter { it.choice !in shown }
    .groupBy { it.choice.providerId }
    .map { (providerId, list) -> ProviderGroup(providerId, list.first().providerName, list) }
    .sortedBy { it.title.lowercase() }
  return PickerSections(favorites, recentOptions, groups)
}

/**
 * Full-screen, searchable chooser across every enabled model on every enabled connection.
 * Rendered in the activity window (not a dialog window) so system-bar styling and IME insets
 * behave exactly like the rest of the app.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ChatModelPicker(
  options: List<ModelOption>,
  recent: List<ModelChoice>,
  selected: ModelChoice?,
  onSelect: (ModelOption) -> Unit,
  onToggleFavorite: (ModelChoice) -> Unit,
  onManageModels: () -> Unit,
  onDismiss: () -> Unit,
) {
  BackHandler(onBack = onDismiss)
  var query by rememberSaveable { mutableStateOf("") }
  var photosOnly by rememberSaveable { mutableStateOf(false) }
  val sections = remember(options, recent, query, photosOnly) { pickerSections(options, recent, query, photosOnly) }
  val focusManager = LocalFocusManager.current

  Scaffold(
    topBar = {
      TopAppBar(
        title = { Text("Choose model") },
        navigationIcon = {
          IconButton(onClick = onDismiss) {
            Icon(Icons.Outlined.Close, contentDescription = "Close model chooser")
          }
        },
      )
    },
  ) { padding ->
    Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
      OutlinedTextField(
        value = query,
        onValueChange = { query = it },
        placeholder = { Text("Search models or providers") },
        leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
        trailingIcon = {
          if (query.isNotEmpty()) {
            IconButton(onClick = { query = "" }) {
              Icon(Icons.Outlined.Close, contentDescription = "Clear search")
            }
          }
        },
        singleLine = true,
        shape = RoundedCornerShape(28.dp),
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
        keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
      )
      Row(Modifier.padding(horizontal = 16.dp)) {
        FilterChip(
          selected = photosOnly,
          onClick = { photosOnly = !photosOnly },
          label = { Text("Supports photos") },
          leadingIcon = {
            Icon(
              if (photosOnly) Icons.Outlined.Check else Icons.Outlined.Image,
              contentDescription = null,
              modifier = Modifier.size(FilterChipDefaults.IconSize),
            )
          },
        )
      }

      LazyColumn(
        contentPadding = PaddingValues(bottom = 8.dp),
        modifier = Modifier.weight(1f),
      ) {
        if (sections.favorites.isNotEmpty()) {
          sectionHeader("favorites-header", "Favorites")
          items(sections.favorites, key = { it.key("fav") }, contentType = { "option" }) { option ->
            ModelRow(option, option.choice == selected, onSelect, onToggleFavorite)
          }
        }
        if (sections.recent.isNotEmpty()) {
          sectionHeader("recent-header", "Recently used")
          items(sections.recent, key = { it.key("recent") }, contentType = { "option" }) { option ->
            ModelRow(option, option.choice == selected, onSelect, onToggleFavorite)
          }
        }
        for (group in sections.groups) {
          stickyHeader(key = "provider/${group.providerId}", contentType = "providerHeader") {
            ProviderHeader(group)
          }
          items(group.options, key = { it.key("all") }, contentType = { "option" }) { option ->
            ModelRow(option, option.choice == selected, onSelect, onToggleFavorite)
          }
        }
        if (sections.isEmpty) {
          item(key = "empty") {
            Column(
              Modifier.fillMaxWidth().padding(32.dp),
              horizontalAlignment = Alignment.CenterHorizontally,
              verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
              Text(
                if (options.isEmpty()) "No enabled models" else "No matching models",
                style = MaterialTheme.typography.titleMedium,
              )
              Text(
                "Enable models in AI models & accounts, or adjust your search.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
              )
            }
          }
        }
      }

      HorizontalDivider()
      TextButton(
        onClick = onManageModels,
        modifier = Modifier
          .navigationBarsPadding()
          .padding(horizontal = 8.dp, vertical = 4.dp)
          .heightIn(min = 48.dp),
      ) {
        Icon(Icons.Outlined.Tune, contentDescription = null, modifier = Modifier.size(18.dp))
        Text("Manage AI models", modifier = Modifier.padding(start = 8.dp))
      }
    }
  }
}

private fun LazyListScope.sectionHeader(key: String, title: String) {
  item(key = key, contentType = "sectionHeader") {
    Text(
      title,
      style = MaterialTheme.typography.titleSmall,
      color = MaterialTheme.colorScheme.primary,
      modifier = Modifier
        .fillMaxWidth()
        .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp)
        .semantics { heading() },
    )
  }
}

@Composable
private fun ProviderHeader(group: ProviderGroup) {
  Surface(color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxWidth()) {
    Row(
      verticalAlignment = Alignment.CenterVertically,
      horizontalArrangement = Arrangement.spacedBy(10.dp),
      modifier = Modifier
        .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp)
        .semantics(mergeDescendants = true) { heading() },
    ) {
      DecorativeProviderLogo(kind = group.options.first().providerKind, size = 20.dp)
      Text(
        group.title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.weight(1f),
      )
      Text(
        if (group.options.size == 1) "1 model" else "${group.options.size} models",
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}

@Composable
private fun ModelRow(
  option: ModelOption,
  isSelected: Boolean,
  onSelect: (ModelOption) -> Unit,
  onToggleFavorite: (ModelChoice) -> Unit,
) {
  Row(
    verticalAlignment = Alignment.CenterVertically,
    modifier = Modifier
      .fillMaxWidth()
      .heightIn(min = 64.dp)
      .selectable(selected = isSelected, role = Role.RadioButton, onClick = { onSelect(option) })
      .padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp),
  ) {
    DecorativeProviderLogo(kind = option.providerKind, size = 28.dp)
    Column(
      Modifier.weight(1f).padding(start = 14.dp),
      verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
      Text(option.modelId, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
      Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
          option.providerName,
          style = MaterialTheme.typography.bodySmall,
          color = MaterialTheme.colorScheme.onSurfaceVariant,
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
          modifier = Modifier.weight(1f, fill = false),
        )
        if (option.supportsImages) {
          Icon(
            Icons.Outlined.Image,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(14.dp),
          )
          Text("Photos", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
      }
    }
    if (isSelected) {
      Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
        Icon(Icons.Outlined.Check, contentDescription = "Selected", tint = MaterialTheme.colorScheme.primary)
      }
    }
    IconToggleButton(checked = option.isFavorite, onCheckedChange = { onToggleFavorite(option.choice) }) {
      Icon(
        if (option.isFavorite) Icons.Filled.Star else Icons.Filled.StarBorder,
        contentDescription = if (option.isFavorite) "Remove ${option.modelId} from favorites" else "Add ${option.modelId} to favorites",
        tint = if (option.isFavorite) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
      )
    }
  }
}
