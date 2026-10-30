package com.cometchat.voip

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The ringer's way back into Dart.
 *
 * This package links **only** `cometchat_calls_sdk`, never the native Calls
 * SDK, so nothing here can connect, decline or hand a call to an
 * `IncomingCallListener` by itself. Dart does all of it, and this is the way
 * across.
 *
 * Which isolate answers depends on what is alive:
 *
 *  - the **app's**, whenever it is running. The plugin hands its channel over
 *    as soon as Dart says it is ready.
 *  - a **background** one this starts otherwise — a Decline tapped on a
 *    notification that outlived its process. `cometchat_calls_sdk` restores the
 *    Calls login from disk there, which is what lets the decline be sent as the
 *    right user.
 *
 * A request that arrives before either is ready is queued, not dropped: a cold
 * process is exactly when the ring matters most.
 */
internal object DartBridge {

    private const val PREFS = "cometchat_voip_bridge"
    private const val KEY_CALLBACK_HANDLE = "backgroundCallbackHandle"

    /** How long a caller may block waiting for Dart to come up and answer. */
    private const val READY_TIMEOUT_MS = 12_000L
    private const val CALL_TIMEOUT_MS = 15_000L

    private val main = Handler(Looper.getMainLooper())

    /** The channel of whichever isolate is serving, or null when none is. */
    @Volatile
    private var channel: MethodChannel? = null

    /** Held open for as long as the background isolate is serving. */
    @Volatile
    private var backgroundEngine: FlutterEngine? = null

    private val queue = ArrayDeque<Request>()
    private val lock = Any()

    private class Request(
        val method: String,
        val args: Map<String, Any?>,
        val onResult: (Any?) -> Unit
    )

    // ── Wiring, from the plugin ──

    /** Remembers the entry point to start when nothing is alive. */
    fun saveCallbackHandle(context: Context, handle: Long) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putLong(KEY_CALLBACK_HANDLE, handle).apply()
    }

    /// Whether `CometChatVoip.init` has registered the background entry point.
    /// Without it a Decline tapped on a notification that outlived its process
    /// has nothing to start, and waits for the app instead.
    fun hasCallbackHandle(context: Context): Boolean = callbackHandle(context) != 0L

    private fun callbackHandle(context: Context): Long =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_CALLBACK_HANDLE, 0L)

    /** Dart announcing it can serve requests. Flushes whatever was waiting. */
    fun onDartReady(channel: MethodChannel) {
        synchronized(lock) {
            this.channel = channel
            val waiting = ArrayList(queue)
            queue.clear()
            waiting
        }.forEach { send(it) }
    }

    /** The app's isolate going away. A later request starts a background one. */
    fun onDartGone(channel: MethodChannel) {
        synchronized(lock) {
            if (this.channel === channel) this.channel = null
        }
    }

    // ── Calling Dart ──

    /**
     * Invokes [method] in Dart, starting an isolate if none is serving.
     * [onResult] runs on the main thread, with null when nothing answered.
     */
    fun invoke(
        context: Context,
        method: String,
        args: Map<String, Any?> = emptyMap(),
        onResult: (Any?) -> Unit = {}
    ) {
        val request = Request(method, args, onResult)
        val live = synchronized(lock) {
            val existing = channel
            if (existing == null) queue.add(request)
            existing
        }
        if (live != null) {
            send(request)
        } else {
            ensureBackgroundEngine(context)
        }
    }

    /**
     * Invokes [method] and blocks for the reply.
     *
     * **Background threads only** — the reply arrives on the main thread, so
     * blocking that would deadlock. Returns null on a timeout, which every
     * caller reads as "could not tell", never as "no".
     */
    fun invokeBlocking(
        context: Context,
        method: String,
        args: Map<String, Any?> = emptyMap(),
        timeoutMs: Long = CALL_TIMEOUT_MS
    ): Any? {
        check(Looper.myLooper() != Looper.getMainLooper()) {
            "invokeBlocking would deadlock on the main thread"
        }
        val latch = CountDownLatch(1)
        var reply: Any? = null
        invoke(context, method, args) {
            reply = it
            latch.countDown()
        }
        if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
            Log.w("$method got no reply from Dart in ${timeoutMs}ms")
            return null
        }
        return reply
    }

    /**
     * Blocks until an isolate is serving, starting one if need be.
     *
     * Background threads only. False means Dart never came up, and the caller
     * carries on without it — a ring that cannot connect still rings.
     */
    fun awaitDart(context: Context, timeoutMs: Long = READY_TIMEOUT_MS): Boolean {
        if (channel != null) return true
        ensureBackgroundEngine(context)
        val deadline = System.currentTimeMillis() + timeoutMs
        while (channel == null && System.currentTimeMillis() < deadline) {
            Thread.sleep(100)
        }
        if (channel == null) {
            Log.w("Dart did not come up in ${timeoutMs}ms — the Calls SDK is out of reach")
            // Nothing is coming: fail what is waiting rather than leaking it,
            // so a decline reports failure instead of hanging for ever.
            synchronized(lock) {
                val stranded = ArrayList(queue)
                queue.clear()
                stranded
            }.forEach { main.post { it.onResult(null) } }
            return false
        }
        return true
    }

    private fun send(request: Request) {
        main.post {
            val live = channel
            if (live == null) {
                // Lost between the check and the post; queue it again.
                synchronized(lock) { queue.add(request) }
                return@post
            }
            live.invokeMethod(
                request.method,
                request.args,
                object : MethodChannel.Result {
                    override fun success(result: Any?) = request.onResult(result)

                    override fun error(code: String, message: String?, details: Any?) {
                        Log.w("${request.method} failed in Dart: $code $message")
                        request.onResult(null)
                    }

                    override fun notImplemented() {
                        Log.w("${request.method} is not implemented in Dart")
                        request.onResult(null)
                    }
                }
            )
        }
    }

    // ── The background isolate ──

    /**
     * Starts the headless isolate that serves requests when the app is gone.
     *
     * Needs the entry point `CometChatVoip.init` registered. Without it — an
     * install where init has never run — there is nothing to start, and the
     * request waits for the app instead.
     */
    private fun ensureBackgroundEngine(context: Context) {
        if (backgroundEngine != null) return
        val handle = callbackHandle(context)
        if (handle == 0L) {
            Log.w(
                "no background entry point registered, so the Calls SDK cannot be " +
                    "reached from here. Has CometChatVoip.init run since this install?"
            )
            return
        }

        main.post {
            if (backgroundEngine != null) return@post
            val callback = FlutterCallbackInformation.lookupCallbackInformation(handle)
            if (callback == null) {
                Log.e("the background entry point is gone — was it tree-shaken?")
                return@post
            }
            try {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(context.applicationContext)
                loader.ensureInitializationComplete(context.applicationContext, null)

                // The single-argument constructor registers the app's plugins
                // on this engine, which is what gives the isolate a native
                // side for the plugin channel. Without that the isolate comes
                // up, announces nothing, and the queued work strands.
                val engine = FlutterEngine(context.applicationContext)
                engine.dartExecutor.executeDartCallback(
                    DartExecutor.DartCallback(
                        context.applicationContext.assets,
                        loader.findAppBundlePath(),
                        callback
                    )
                )
                backgroundEngine = engine
                Log.d("started a background isolate to reach the Calls SDK")
            } catch (t: Throwable) {
                Log.e("could not start the background isolate: ${t.message}")
            }
        }
    }

    /**
     * Tears the background isolate down once nothing is ringing.
     *
     * Left running would hold a Dart VM alive for the life of the process,
     * which on a phone that took one call is pure cost.
     */
    fun releaseBackgroundEngine() {
        main.post {
            val engine = backgroundEngine ?: return@post
            backgroundEngine = null
            synchronized(lock) { channel = null }
            runCatching { engine.destroy() }
                .onFailure { Log.w("tearing down the background isolate threw: ${it.message}") }
        }
    }
}
