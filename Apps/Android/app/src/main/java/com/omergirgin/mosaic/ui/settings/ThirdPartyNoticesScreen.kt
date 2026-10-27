package com.omergirgin.mosaic.ui.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val NOTICES_ASSET = "ThirdPartyNotices.txt"

private sealed interface NoticesState {
  data object Loading : NoticesState
  data class Loaded(val paragraphs: List<String>) : NoticesState
  data object Failed : NoticesState
}

/**
 * License texts are hard-wrapped near 72 columns, which reads raggedly on a phone. Long lines are
 * joined into flowing prose; short lines (names, URLs, copyright lines) keep their own line.
 */
private fun reflow(paragraph: String): String {
  val lines = paragraph.lines().map { it.trim() }.filter { it.isNotEmpty() }
  val text = StringBuilder()
  lines.forEachIndexed { index, line ->
    if (index > 0) {
      val previous = lines[index - 1]
      val startsEntryLine = line.startsWith("Copyright ") || line.startsWith("Licensed under")
      text.append(if (previous.length >= 50 && !previous.startsWith("http") && !startsEntryLine) ' ' else '\n')
    }
    text.append(line)
  }
  return text.toString()
}

@Composable
internal fun ThirdPartyNoticesScreen(onBack: () -> Unit) {
  val context = LocalContext.current
  val state by produceState<NoticesState>(NoticesState.Loading, context) {
    value = withContext(Dispatchers.IO) {
      runCatching {
        val text = context.assets.open(NOTICES_ASSET).bufferedReader().use { it.readText() }
        // Paragraph items keep the long license text lazy instead of one giant Text node.
        NoticesState.Loaded(text.split(Regex("\\n\\s*\\n")).filter { it.isNotBlank() }.map(::reflow))
      }.getOrElse { NoticesState.Failed }
    }
  }

  SettingsScaffold(title = "Third-party notices", onBack = onBack) { padding ->
    when (val current = state) {
      NoticesState.Loading -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
        CircularProgressIndicator()
      }
      NoticesState.Failed -> Box(Modifier.fillMaxSize().padding(padding)) {
        StatusLine("The notices couldn't be loaded. Reinstalling the app restores them.", StatusTone.ERROR)
      }
      is NoticesState.Loaded -> LazyColumn(
        modifier = Modifier.fillMaxSize().padding(padding),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
      ) {
        itemsIndexed(current.paragraphs) { _, paragraph ->
          Text(
            paragraph,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
          )
        }
      }
    }
  }
}
