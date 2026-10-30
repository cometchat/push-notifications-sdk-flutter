package com.cometchat.voip

import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.content.Intent
import android.os.Bundle
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import androidx.core.graphics.ColorUtils
import androidx.core.view.WindowCompat

/**
 * The full-screen ring screen, launched over the keyguard when the device is
 * locked.
 *
 * Native, not Flutter: it has to appear within the second the phone starts
 * ringing, on a process that may have been created for this push, and starting
 * a Flutter engine for it would take longer than that. Everything it draws is
 * self-contained — no host theme, no image loading — because anything that can
 * fail here fails while the phone is ringing.
 */
internal class IncomingCallActivity : Activity() {

    private var call: IncomingCall? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showOverKeyguard(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        val current = CallBundles.getCall(intent)
        if (current == null || !CallStore.isRinging(this, current.sessionId)) {
            // Opened from a stale notification, or after the ring ended.
            finish()
            return
        }
        setContentView(R.layout.cometchat_voip_activity_incoming_call)
        bind(current)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        CallBundles.getCall(intent)?.let(::bind)
    }

    override fun onDestroy() {
        call?.sessionId?.let(RingSurfaces::unregister)
        super.onDestroy()
    }

    private fun bind(next: IncomingCall) {
        call?.sessionId?.takeIf { it != next.sessionId }?.let(RingSurfaces::unregister)
        call = next
        // Here rather than in onCreate: a second ring reuses this screen
        // (singleTop) and comes through onNewIntent.
        applyTheme()
        // Close when the ring ends anywhere else: cancelled, answered on another
        // device, expired.
        RingSurfaces.register(next.sessionId) { runOnUiThread { finish() } }

        findViewById<TextView>(R.id.cometchat_voip_initials).text = next.initials
        findViewById<TextView>(R.id.cometchat_voip_caller_name).text = next.callerName
        findViewById<TextView>(R.id.cometchat_voip_call_type).text =
            if (RingController.liveSession(this, next.sessionId) != null) {
                // Answering leaves the live call: the Calls SDK holds one
                // session at a time, and this is the last place to say so.
                getString(R.string.cometchat_voip_answer_ends_current_call)
            } else {
                getString(
                    R.string.cometchat_voip_incoming_call_text,
                    IncomingCallNotifier.callTypeLabel(this, next)
                )
            }

        findViewById<ImageButton>(R.id.cometchat_voip_answer).setOnClickListener {
            // The same route as the notification's Answer, permissions and all.
            startActivity(AnswerTrampolineActivity.intent(this, next))
            finish()
        }
        findViewById<ImageButton>(R.id.cometchat_voip_decline).setOnClickListener {
            RingController.decline(this, next.sessionId)
            finish()
        }
    }

    /**
     * Colours the screen from [IncomingCallTheme]. With no theme set this
     * resolves to the layout's own resources, so the screen looks as it always
     * has. Views are looked up null-safely: an app may have replaced the layout.
     */
    @Suppress("DEPRECATION")
    private fun applyTheme() {
        val colors = IncomingCallTheme.resolve(this)
        window.setBackgroundDrawable(ColorDrawable(colors.background))
        findViewById<ViewGroup>(android.R.id.content)?.getChildAt(0)?.setBackgroundColor(colors.background)
        // The system bars follow the page, with dark icons on a light page.
        window.statusBarColor = colors.background
        window.navigationBarColor = colors.background
        val lightPage = ColorUtils.calculateLuminance(colors.background) > 0.5
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = lightPage
            isAppearanceLightNavigationBars = lightPage
        }

        findViewById<TextView>(R.id.cometchat_voip_initials)?.apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(colors.avatarBackground)
            }
            setTextColor(colors.avatarText)
        }
        findViewById<TextView>(R.id.cometchat_voip_caller_name)?.setTextColor(colors.callerName)
        findViewById<TextView>(R.id.cometchat_voip_call_type)?.setTextColor(colors.subtitle)
        findViewById<ImageButton>(R.id.cometchat_voip_answer)?.style(colors.acceptButton, colors.acceptIcon)
        findViewById<ImageButton>(R.id.cometchat_voip_decline)?.style(colors.declineButton, colors.declineIcon)
        findViewById<TextView>(R.id.cometchat_voip_answer_label)?.setTextColor(colors.acceptLabel)
        findViewById<TextView>(R.id.cometchat_voip_decline_label)?.setTextColor(colors.declineLabel)
    }

    /** A round button in [fill], its glyph in [icon], and a ripple of the glyph's colour. */
    private fun ImageButton.style(fill: Int, icon: Int) {
        val oval = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(fill)
        }
        // 40% of the glyph colour: today's #66FFFFFF when the glyph is white.
        background = RippleDrawable(ColorStateList.valueOf(ColorUtils.setAlphaComponent(icon, 0x66)), oval, null)
        imageTintList = ColorStateList.valueOf(icon)
    }

    companion object {
        fun intent(context: Context, call: IncomingCall): Intent =
            Intent(context, IncomingCallActivity::class.java)
                .addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
                .setData(CallBundles.sessionUri(CallBundles.KIND_FULL_SCREEN, call.sessionId))
                .also { CallBundles.putCall(it, call) }
    }
}

/** Lets [activity] show over the keyguard and turn the screen on, or stop doing so. */
@Suppress("DEPRECATION")
internal fun showOverKeyguard(activity: Activity, show: Boolean = true) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
        activity.setShowWhenLocked(show)
        activity.setTurnScreenOn(show)
    } else {
        val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        if (show) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
    }
}
