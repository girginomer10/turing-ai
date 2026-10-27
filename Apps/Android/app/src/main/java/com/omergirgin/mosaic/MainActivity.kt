package com.omergirgin.mosaic

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.CompositionLocalProvider
import com.omergirgin.mosaic.ui.LocalAppContainer
import com.omergirgin.mosaic.ui.root.TuringRoot
import com.omergirgin.mosaic.ui.share.SharedItemsLaunchRequests
import com.omergirgin.mosaic.ui.tasks.AutomationLaunchRequests
import com.omergirgin.mosaic.ui.theme.TuringTheme

class MainActivity : ComponentActivity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    // Edge-to-edge before super.onCreate so the first frame already draws behind the system bars;
    // each screen applies its own insets.
    enableEdgeToEdge()
    super.onCreate(savedInstanceState)
    // A tapped scheduled-prompt notification opens its result chat; never replayed on recreation.
    if (savedInstanceState == null) AutomationLaunchRequests.handle(intent)
    // "Save and open Turing AI" from the share screen opens Shared items (also never replayed).
    if (savedInstanceState == null) SharedItemsLaunchRequests.handle(intent)
    val container = (application as TuringApplication).container
    setContent {
      CompositionLocalProvider(LocalAppContainer provides container) {
        TuringTheme { TuringRoot() }
      }
    }
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    AutomationLaunchRequests.handle(intent)
    SharedItemsLaunchRequests.handle(intent)
  }
}
