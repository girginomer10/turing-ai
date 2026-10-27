package com.omergirgin.mosaic.ui.chat

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import com.omergirgin.mosaic.core.provider.ProviderKind
import com.omergirgin.mosaic.ui.components.ProviderLogo

/**
 * [ProviderLogo] announces the provider name; next to visible provider text that would be read
 * twice, so the chat UI hides the tile from accessibility where the name is already spoken.
 */
@Composable
internal fun DecorativeProviderLogo(kind: ProviderKind, size: Dp, modifier: Modifier = Modifier) {
  Box(modifier.clearAndSetSemantics {}) {
    ProviderLogo(kind = kind, size = size)
  }
}
