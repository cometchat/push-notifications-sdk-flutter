package com.cometchat.voip

import android.app.PendingIntent

/** Immutable, and updated in place when one for the same intent exists. */
internal fun pendingIntentFlags(): Int =
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
