package com.cometchat.voip

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Delivers a decline even if the process dies the instant after the tap.
 *
 * A process the system started only to show a notification is exactly the one
 * that gets killed mid-request, and then the caller keeps ringing a phone that
 * already said no. WorkManager persists the decline before anything else and
 * survives process death, a reboot and a network outage.
 */
internal object DeclineQueue {

    private const val KEY_SESSION_ID = "sessionId"
    private const val KEY_STATUS = "status"

    /** One unique name per session, so a double-tapped Decline enqueues once. */
    private fun workName(sessionId: String) = "cometchat-voip-decline-$sessionId"

    fun enqueue(context: Context, sessionId: String, status: String) {
        val request = OneTimeWorkRequestBuilder<DeclineWorker>()
            .setInputData(
                Data.Builder()
                    .putString(KEY_SESSION_ID, sessionId)
                    .putString(KEY_STATUS, status)
                    .build()
            )
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 10, TimeUnit.SECONDS)
            .build()
        try {
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(workName(sessionId), ExistingWorkPolicy.KEEP, request)
            Log.d("queued $status for $sessionId")
        } catch (t: Throwable) {
            Log.e("could not queue the decline for $sessionId: ${t.message}")
        }
    }

    /** Runs on WorkManager's thread, so blocking until the reply is the point. */
    internal class DeclineWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

        override fun doWork(): Result {
            val sessionId = inputData.getString(KEY_SESSION_ID) ?: return Result.failure()
            val status = inputData.getString(KEY_STATUS) ?: CallsConstants.CALL_STATUS_REJECTED
            val config = VoipConfig.restore(applicationContext) ?: return Result.failure()
            // The backoff has run well past the ring window by then: the
            // caller's own timeout has ended the call, and there is nothing
            // left to decline.
            if (runAttemptCount >= CallsConstants.DECLINE_MAX_ATTEMPTS) {
                Log.w("giving up on the decline for $sessionId")
                return Result.failure()
            }

            if (!CallsSdk.ensureInitialised(applicationContext, config)) return Result.retry()

            // After a cold start the login comes back asynchronously; endCall needs it.
            val deadline = System.currentTimeMillis() + CallsConstants.DECLINE_POLL_BUDGET_MS
            while (!CallsSdk.isLoggedIn(applicationContext) && System.currentTimeMillis() < deadline) {
                Thread.sleep(CallsConstants.DECLINE_POLL_INTERVAL_MS)
            }
            if (!CallsSdk.isLoggedIn(applicationContext)) {
                Log.w("not logged in yet — retrying the decline for $sessionId")
                return Result.retry()
            }

            val latch = CountDownLatch(1)
            var ok = false
            CallsSdk.endCall(applicationContext, sessionId, status) {
                ok = it
                latch.countDown()
            }
            latch.await(30, TimeUnit.SECONDS)

            return if (ok) {
                Log.d("$status delivered for $sessionId")
                Result.success()
            } else {
                Result.retry()
            }
        }
    }
}
