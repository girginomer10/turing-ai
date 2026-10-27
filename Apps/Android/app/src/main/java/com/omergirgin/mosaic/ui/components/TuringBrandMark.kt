package com.omergirgin.mosaic.ui.components

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.omergirgin.mosaic.R

/** The Turing AI mark. Decorative: callers pair it with visible text, so it has no label. */
@Composable
fun TuringBrandMark(modifier: Modifier = Modifier, size: Dp = 48.dp) {
  Image(
    painter = painterResource(R.drawable.turing_mark),
    contentDescription = null,
    modifier = modifier.size(size).clip(RoundedCornerShape(size * 0.22f)),
  )
}
