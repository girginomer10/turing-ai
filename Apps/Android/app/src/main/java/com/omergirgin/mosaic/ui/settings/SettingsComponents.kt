package com.omergirgin.mosaic.ui.settings

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import com.omergirgin.mosaic.ui.components.relativeTime
import java.text.NumberFormat
import java.util.Locale

/** Minimum touch target used throughout the settings area (Material accessibility baseline). */
internal val MinTouchTarget = 48.dp

/** Standard settings screen frame: pinned top app bar with a back arrow. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsScaffold(
  title: String,
  onBack: () -> Unit,
  modifier: Modifier = Modifier,
  backEnabled: Boolean = true,
  actions: @Composable RowScope.() -> Unit = {},
  floatingActionButton: @Composable () -> Unit = {},
  snackbarHostState: SnackbarHostState? = null,
  content: @Composable (PaddingValues) -> Unit,
) {
  val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
  Scaffold(
    modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
    topBar = {
      TopAppBar(
        title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = {
          IconButton(onClick = onBack, enabled = backEnabled) {
            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
          }
        },
        actions = actions,
        scrollBehavior = scrollBehavior,
      )
    },
    floatingActionButton = floatingActionButton,
    snackbarHost = { snackbarHostState?.let { SnackbarHost(it) } },
    content = content,
  )
}

@Composable
internal fun SectionHeader(text: String, modifier: Modifier = Modifier) {
  Text(
    text = text,
    style = MaterialTheme.typography.titleSmall,
    color = MaterialTheme.colorScheme.primary,
    modifier = modifier
      .fillMaxWidth()
      .padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 8.dp)
      .semantics { heading() },
  )
}

@Composable
internal fun SectionFooter(text: String, modifier: Modifier = Modifier) {
  Text(
    text = text,
    style = MaterialTheme.typography.bodySmall,
    color = MaterialTheme.colorScheme.onSurfaceVariant,
    modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
  )
}

/** Body paragraph inside a settings list, aligned with list content. */
@Composable
internal fun SettingsParagraph(
  text: String,
  modifier: Modifier = Modifier,
  color: Color = MaterialTheme.colorScheme.onSurface,
) {
  Text(
    text = text,
    style = MaterialTheme.typography.bodyMedium,
    color = color,
    modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
  )
}

@Composable
internal fun SettingsLinkRow(
  title: String,
  onClick: () -> Unit,
  modifier: Modifier = Modifier,
  subtitle: String? = null,
  icon: ImageVector? = null,
  enabled: Boolean = true,
  showChevron: Boolean = true,
) {
  ListItem(
    headlineContent = { Text(title) },
    supportingContent = subtitle?.let { { Text(it) } },
    leadingContent = icon?.let { { Icon(it, contentDescription = null) } },
    trailingContent = if (showChevron) {
      { Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null) }
    } else null,
    modifier = modifier
      .fillMaxWidth()
      .heightIn(min = 56.dp)
      .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
  )
}

/** Opens an official page in the browser. The trailing icon tells users they leave the app. */
@Composable
internal fun ExternalLinkRow(title: String, url: String, modifier: Modifier = Modifier) {
  val context = LocalContext.current
  ListItem(
    headlineContent = { Text(title, color = MaterialTheme.colorScheme.primary) },
    trailingContent = { Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = "Opens in browser") },
    modifier = modifier
      .fillMaxWidth()
      .heightIn(min = MinTouchTarget)
      .clickable(role = Role.Button) { openExternalUrl(context, url) },
  )
}

@Composable
internal fun SettingsSwitchRow(
  title: String,
  checked: Boolean,
  onCheckedChange: (Boolean) -> Unit,
  modifier: Modifier = Modifier,
  subtitle: String? = null,
  enabled: Boolean = true,
) {
  ListItem(
    headlineContent = { Text(title) },
    supportingContent = subtitle?.let { { Text(it) } },
    // The whole row toggles; the Switch itself is decorative so TalkBack reads one control.
    trailingContent = { Switch(checked = checked, onCheckedChange = null, enabled = enabled) },
    modifier = modifier
      .fillMaxWidth()
      .heightIn(min = 56.dp)
      .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange),
  )
}

internal enum class StatusTone { SUCCESS, ERROR, WARNING, NEUTRAL }

/** Status is always spelled out in text; color and icon only reinforce it. */
@Composable
internal fun StatusLine(text: String, tone: StatusTone, modifier: Modifier = Modifier) {
  val (icon, color) = when (tone) {
    StatusTone.SUCCESS -> Icons.Filled.CheckCircle to successColor()
    StatusTone.ERROR -> Icons.Filled.Error to MaterialTheme.colorScheme.error
    StatusTone.WARNING -> Icons.Filled.Warning to warningColor()
    StatusTone.NEUTRAL -> Icons.Outlined.Info to MaterialTheme.colorScheme.onSurfaceVariant
  }
  Row(
    modifier = modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
    verticalAlignment = Alignment.Top,
  ) {
    Icon(icon, contentDescription = null, tint = color, modifier = Modifier.padding(top = 1.dp).size(18.dp))
    Spacer(Modifier.width(8.dp))
    Text(
      text,
      style = MaterialTheme.typography.bodySmall,
      color = if (tone == StatusTone.NEUTRAL) MaterialTheme.colorScheme.onSurfaceVariant else color,
    )
  }
}

@Composable
internal fun successColor(): Color =
  if (MaterialTheme.colorScheme.background.luminanceIsDark()) Color(0xFF7DDA8C) else Color(0xFF1B7F37)

@Composable
internal fun warningColor(): Color =
  if (MaterialTheme.colorScheme.background.luminanceIsDark()) Color(0xFFFFB866) else Color(0xFF9A5B00)

private fun Color.luminanceIsDark(): Boolean = (0.299f * red + 0.587f * green + 0.114f * blue) < 0.5f

@Composable
internal fun ConfirmDialog(
  title: String,
  message: String,
  confirmLabel: String,
  onConfirm: () -> Unit,
  onDismiss: () -> Unit,
  destructive: Boolean = true,
  dismissLabel: String = "Cancel",
) {
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text(title) },
    text = { Text(message) },
    confirmButton = {
      TextButton(
        onClick = onConfirm,
        colors = if (destructive) {
          ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)
        } else ButtonDefaults.textButtonColors(),
      ) { Text(confirmLabel) }
    },
    dismissButton = { TextButton(onClick = onDismiss) { Text(dismissLabel) } },
  )
}

@Composable
internal fun MessageDialog(title: String, message: String, onDismiss: () -> Unit) {
  AlertDialog(
    onDismissRequest = onDismiss,
    title = { Text(title) },
    text = { Text(message) },
    confirmButton = { TextButton(onClick = onDismiss) { Text("OK") } },
  )
}

@Composable
internal fun DiscardChangesDialog(message: String, onDiscard: () -> Unit, onKeepEditing: () -> Unit) {
  ConfirmDialog(
    title = "Discard changes?",
    message = message,
    confirmLabel = "Discard",
    dismissLabel = "Keep editing",
    onConfirm = onDiscard,
    onDismiss = onKeepEditing,
  )
}

/** Centered empty state with optional actions, used when a library has no rows yet. */
@Composable
internal fun EmptyState(
  title: String,
  message: String,
  modifier: Modifier = Modifier,
  icon: ImageVector? = null,
  header: (@Composable () -> Unit)? = null,
  actions: @Composable () -> Unit = {},
) {
  Box(modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
    Column(
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.spacedBy(12.dp),
      modifier = Modifier.widthIn(max = 480.dp),
    ) {
      header?.invoke()
      if (header == null && icon != null) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
      }
      Text(
        title,
        style = MaterialTheme.typography.titleLarge,
        textAlign = TextAlign.Center,
        modifier = Modifier.semantics { heading() },
      )
      Text(
        message,
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
      )
      Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.padding(top = 4.dp),
      ) { actions() }
    }
  }
}

internal val ListItemTransparentColors
  @Composable get() = ListItemDefaults.colors(containerColor = Color.Transparent)

/** Opens [url] in the user's browser; reports instead of crashing when no browser exists. */
internal fun openExternalUrl(context: Context, url: String) {
  val intent = Intent(Intent.ACTION_VIEW, url.toUri()).addCategory(Intent.CATEGORY_BROWSABLE)
  if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
  try {
    context.startActivity(intent)
  } catch (_: ActivityNotFoundException) {
    Toast.makeText(context, "No browser is available to open this link.", Toast.LENGTH_LONG).show()
  }
}

internal fun formatCount(value: Long): String = NumberFormat.getIntegerInstance().format(value)

internal fun formatCount(value: Int): String = formatCount(value.toLong())

/** Same relative-date wording as the chat history list. */
internal fun formatRelativeTime(millis: Long): String = relativeTime(millis)

internal fun utf8Size(value: String): Int = value.toByteArray(Charsets.UTF_8).size

/** USD with 2–4 decimals, matching the iOS estimate presentation; tiny non-zero values stay visible. */
internal fun formatUsd(amount: Double): String {
  if (amount > 0 && amount < 0.0001) return "< $0.0001"
  val format = NumberFormat.getCurrencyInstance(Locale.US).apply {
    minimumFractionDigits = 2
    maximumFractionDigits = 4
  }
  return format.format(amount)
}

internal fun pluralize(count: Int, singular: String, plural: String = singular + "s"): String =
  "${formatCount(count)} ${if (count == 1) singular else plural}"
