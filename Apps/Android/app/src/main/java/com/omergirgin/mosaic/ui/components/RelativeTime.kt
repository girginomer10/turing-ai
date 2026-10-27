package com.omergirgin.mosaic.ui.components

import android.text.format.DateUtils

/** "5 min. ago", "Yesterday", "Mar 3" — localized by the platform, matching iOS `.relative(.named)`. */
fun relativeTime(epochMillis: Long, now: Long = System.currentTimeMillis()): String {
  if (now - epochMillis in 0 until DateUtils.MINUTE_IN_MILLIS) return "Just now"
  return DateUtils.getRelativeTimeSpanString(
    epochMillis,
    now,
    DateUtils.MINUTE_IN_MILLIS,
    DateUtils.FORMAT_ABBREV_RELATIVE,
  ).toString()
}
