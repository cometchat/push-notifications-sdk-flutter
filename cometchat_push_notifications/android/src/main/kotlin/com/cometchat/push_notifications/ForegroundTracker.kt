package com.cometchat.push_notifications

import android.app.Activity
import android.app.Application
import android.os.Bundle

/**
 * Whether the app is on screen.
 *
 * Needed for `showInAppNotifications`: a push that arrives while the user is
 * looking at the app is usually already visible in the conversation, and a
 * banner over it is noise.
 *
 * Counts started activities rather than asking the system, because
 * `getRunningAppProcesses` has been unreliable for this since Android 5 and
 * reports the whole process, not whether a screen is actually up.
 */
internal object ForegroundTracker : Application.ActivityLifecycleCallbacks {

    @Volatile
    private var startedActivities = 0

    private var registered = false

    /** Starts tracking. Safe to call more than once. */
    fun register(application: Application) {
        if (registered) return
        registered = true
        application.registerActivityLifecycleCallbacks(this)
    }

    /**
     * Whether any activity is started.
     *
     * Defaults to false before the first activity starts, so a push that wakes
     * a dead app is treated as background — which it is.
     */
    fun isInForeground(): Boolean = startedActivities > 0

    override fun onActivityStarted(activity: Activity) {
        startedActivities++
    }

    override fun onActivityStopped(activity: Activity) {
        // A configuration change stops and starts, so this can briefly reach
        // zero while the app is still on screen. The cost is one suppressed
        // notification during a rotation, against the complexity of tracking
        // whether a restart is pending.
        if (startedActivities > 0) startedActivities--
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
