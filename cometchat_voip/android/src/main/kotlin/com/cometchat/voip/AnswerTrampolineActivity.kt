package com.cometchat.voip

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle

/**
 * Every Answer lands here, never on the app directly.
 *
 * 1. **Records the answer** through the same funnel as every other answer:
 *    stops the ring, cancels the expiry, keeps the process alive. Opening the
 *    app straight from the action meant no package code ran on Answer, and the
 *    expiry alarm then posted a missed call in the middle of the call.
 * 2. **Asks for the microphone**, and the camera for a video call, when they
 *    are missing. A call answered from a notification is often the first time
 *    the app has run since install, and only an activity can ask; without this
 *    the callee joins muted.
 * 3. **Opens the app** whatever the user chose — the caller is waiting, and a
 *    denied permission never fails the call — and tells Dart.
 *
 * On a locked device the permission dialog cannot show over the keyguard, so
 * the user is asked to unlock first; if they do not, the app opens without
 * asking. Translucent and not `noHistory`: it has to outlive the dialog to hear
 * the result.
 */
internal class AnswerTrampolineActivity : Activity() {

    private var call: IncomingCall? = null
    private var asking = false
    private var handedOff = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val current = CallBundles.getCall(intent)
        if (current == null) {
            finish()
            return
        }
        call = current

        // Recreated while the dialog was up: the answer is recorded, the result is coming.
        if (savedInstanceState?.getBoolean(STATE_ASKING) == true) {
            asking = true
            return
        }

        if (RingController.answer(this, current.sessionId) == null) {
            // Nothing was ringing: the call ended as the user tapped.
            finish()
            return
        }

        val missing = if (VoipConfig.restore(this)?.requestCallPermissions != false) {
            missingPermissions(this, current)
        } else {
            emptyArray()
        }
        if (missing.isEmpty()) {
            handOff()
            return
        }
        asking = true
        if (Manifest.permission.RECORD_AUDIO in missing) RingReadiness.recordMicrophoneAsked(this)
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (keyguard != null && keyguard.isKeyguardLocked) {
            keyguard.requestDismissKeyguard(this, object : KeyguardManager.KeyguardDismissCallback() {
                override fun onDismissSucceeded() = requestPermissions(missing, REQUEST_CALL_PERMISSIONS)
                override fun onDismissCancelled() = handOff()
                override fun onDismissError() = handOff()
            })
        } else {
            requestPermissions(missing, REQUEST_CALL_PERMISSIONS)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CALL_PERMISSIONS) handOff()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_ASKING, asking && !handedOff)
    }

    private fun handOff() {
        if (handedOff) return
        handedOff = true
        val answered = call
        if (answered != null) {
            CallEvents.answered(answered)
            IncomingCallNotifier.launchIntent(this)?.let { launch ->
                runCatching {
                    startActivity(
                        CallBundles.putCall(launch, answered)
                            .putExtra(CallBundles.EXTRA_ANSWERED, true)
                            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    )
                }.onFailure { Log.e("could not open the app for the answered call: ${it.message}") }
            }
        }
        finish()
    }

    companion object {
        private const val STATE_ASKING = "com.cometchat.voip.ASKING_PERMISSIONS"
        private const val REQUEST_CALL_PERMISSIONS = 4201

        fun intent(context: Context, call: IncomingCall): Intent =
            Intent(context, AnswerTrampolineActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .setData(CallBundles.sessionUri(CallBundles.KIND_ANSWER, call.sessionId))
                .also { CallBundles.putCall(it, call) }

        /** What the call needs and lacks: the microphone always, the camera for video. */
        fun missingPermissions(context: Context, call: IncomingCall): Array<String> =
            buildList {
                add(Manifest.permission.RECORD_AUDIO)
                if (call.isVideo) add(Manifest.permission.CAMERA)
            }.filter { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }.toTypedArray()
    }
}
