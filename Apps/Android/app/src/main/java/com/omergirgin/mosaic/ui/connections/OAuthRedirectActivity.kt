package com.omergirgin.mosaic.ui.connections

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import com.omergirgin.mosaic.MainActivity
import com.omergirgin.mosaic.TuringApplication
import com.omergirgin.mosaic.core.connections.ConnectorId

/**
 * Receives `com.omergirgin.turing:/oauth/<provider>` redirects from the Custom Tab. It only hands the
 * exact URI to the pending sign-in, which validates scheme, path, single state and code (and
 * ignores the callback when no sign-in is pending), then returns to the app. Nothing is logged.
 */
class OAuthRedirectActivity : Activity() {
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val uri = intent?.data
    if (savedInstanceState == null && uri != null && uri.scheme == ConnectorId.REDIRECT_SCHEME) {
      (application as TuringApplication).container.connections.handleRedirect(uri.toString())
    }
    // Bring the existing task (and its connection screen) back instead of opening a new one.
    startActivity(
      Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    )
    finish()
  }
}
