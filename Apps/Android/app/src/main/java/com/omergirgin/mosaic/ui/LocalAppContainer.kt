package com.omergirgin.mosaic.ui

import androidx.compose.runtime.staticCompositionLocalOf
import com.omergirgin.mosaic.data.api.AppContainer

/** Data-layer root for every screen. Provided once by MainActivity. */
val LocalAppContainer = staticCompositionLocalOf<AppContainer> {
  error("LocalAppContainer not provided")
}
