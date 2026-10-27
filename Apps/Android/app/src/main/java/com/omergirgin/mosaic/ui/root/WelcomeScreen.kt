package com.omergirgin.mosaic.ui.root

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.outlined.CardGiftcard
import androidx.compose.material3.Button
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.ui.components.TuringBrandMark

/**
 * Provider-free welcome (iOS `WelcomeView` + simple setup copy): explains choosing a service,
 * adding its API key and saving before chatting, with the optional free-options guide.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WelcomeScreen(
  snackbarHostState: SnackbarHostState,
  onOpenHistory: (() -> Unit)?,
  onAddService: () -> Unit,
  onExploreFreeOptions: () -> Unit,
) {
  Scaffold(
    topBar = {
      CenterAlignedTopAppBar(
        title = { Text("Turing AI") },
        navigationIcon = {
          if (onOpenHistory != null) {
            IconButton(onClick = onOpenHistory) {
              Icon(Icons.Filled.Menu, contentDescription = "Open chat history and settings")
            }
          }
        },
      )
    },
    snackbarHost = { SnackbarHost(snackbarHostState) },
  ) { padding ->
    Column(
      horizontalAlignment = Alignment.CenterHorizontally,
      verticalArrangement = Arrangement.spacedBy(20.dp),
      modifier = Modifier
        .fillMaxSize()
        .padding(padding)
        .verticalScroll(rememberScrollState())
        .padding(horizontal = 24.dp, vertical = 32.dp),
    ) {
      Spacer(Modifier.height(16.dp))
      TuringBrandMark(size = 56.dp)
      Text(
        "How can I help?",
        style = MaterialTheme.typography.headlineMedium,
        fontWeight = FontWeight.Bold,
        textAlign = TextAlign.Center,
        modifier = Modifier.semantics { heading() },
      )
      Text(
        "Connect an AI service to start chatting with your favorite models.",
        style = MaterialTheme.typography.bodyLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        textAlign = TextAlign.Center,
        modifier = Modifier.widthIn(max = 420.dp),
      )

      Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = MaterialTheme.shapes.large,
        modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth(),
      ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
          Text(
            "Start chatting",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
          )
          SetupStep(1, "Choose your AI service.")
          SetupStep(2, "Add its API key.")
          SetupStep(3, "Save, then choose a model in your chat.")
          Text(
            "Your key stays encrypted on this device. Messages go directly to the service you choose, " +
              "which bills you for API use. A chat subscription may not include API access.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
          )
        }
      }

      Button(
        onClick = onAddService,
        modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth().heightIn(min = 48.dp),
      ) {
        Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(8.dp))
        Text("Add an AI service")
      }
      OutlinedButton(
        onClick = onExploreFreeOptions,
        modifier = Modifier.widthIn(max = 420.dp).fillMaxWidth().heightIn(min = 48.dp),
      ) {
        Icon(Icons.Outlined.CardGiftcard, contentDescription = null, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(8.dp))
        Text("Explore free options")
      }
    }
  }
}

@Composable
private fun SetupStep(number: Int, text: String) {
  Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    Box(
      contentAlignment = Alignment.Center,
      modifier = Modifier.size(28.dp).background(MaterialTheme.colorScheme.primaryContainer, CircleShape),
    ) {
      Text(
        number.toString(),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onPrimaryContainer,
      )
    }
    Text(text, style = MaterialTheme.typography.bodyLarge)
  }
}
