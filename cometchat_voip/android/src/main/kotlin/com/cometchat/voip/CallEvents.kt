package com.cometchat.voip

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * What the ringer tells Dart: calls answered, calls ended, and the app's own
 * ring screen asked for.
 *
 * Process-wide, because the ringer runs without any engine at all — in a
 * notification action or an alarm — and an app can have several engines, one
 * of them `firebase_messaging`'s background isolate. [emit] reaches every
 * listening engine; with none listening, events are held for the first that
 * does.
 *
 * **But "every engine" is not the same as "the right engine."** On a killed
 * app the call push starts the background isolate, which subscribes as soon as
 * it hands the push over — so it is a listening engine, and an event emitted
 * before the app's own engine is up is delivered there and *not* held. The
 * answer then runs in an isolate with no UI: the call is marked answered and
 * nothing joins. So the two events that happen exactly at launch — the answer
 * that opened the app, and the ring screen it was opened to draw — are sent
 * through [EngineEvents.send] to the engine that owns the activity instead,
 * which holds them until *that* engine's Dart listens.
 */
internal object CallEvents {

    /** Beyond this the oldest are dropped: a stale answer is worse than none. */
    private const val HELD_LIMIT = 8

    private val main = Handler(Looper.getMainLooper())
    private val sinks = LinkedHashSet<EventChannel.EventSink>()
    private val held = ArrayDeque<Map<String, Any?>>()

    fun answered(call: IncomingCall) = emit(answeredEvent(call))

    fun ended(call: IncomingCall, reason: CallEndReason) =
        emit(mapOf("event" to "ended", "call" to call.toMap(), "reason" to reason.wire))

    /** The user answered [call]. */
    fun answeredEvent(call: IncomingCall): Map<String, Any?> =
        mapOf("event" to "answered", "call" to call.toMap())

    /**
     * The app was opened to ring [call] itself, in
     * `CometChatCallMode.autoCustomScreen`. [endsActiveCall] is what the ring
     * says out loud: answering this one ends the call already live here.
     */
    fun ringScreenEvent(call: IncomingCall, endsActiveCall: Boolean): Map<String, Any?> =
        mapOf("event" to "ringScreen", "call" to call.toMap(), "endsActiveCall" to endsActiveCall)

    /**
     * One engine's end of the event channel.
     *
     * Created by the plugin, which Flutter instantiates once per engine, so
     * there is one of these per engine. It takes everything [emit] sends, as
     * the single shared handler used to, and adds [send] for an event meant
     * for this engine alone.
     */
    class EngineEvents : EventChannel.StreamHandler {

        private var sink: EventChannel.EventSink? = null

        /** Events for this engine, waiting for its Dart to subscribe. */
        private val mine = ArrayDeque<Map<String, Any?>>()

        /**
         * Sends [event] to this engine only, holding it until this engine's
         * Dart listens.
         *
         * The activity's engine is the app's by definition, which is what
         * makes this the right place to send an answer or a ring screen: on a
         * cold start its Dart is seconds behind the activity, and a
         * process-wide emit would be eaten by a background isolate that is
         * already listening.
         */
        fun send(event: Map<String, Any?>) {
            main.post {
                val target = synchronized(this) {
                    val attached = sink
                    if (attached == null) {
                        mine.addLast(event)
                        while (mine.size > HELD_LIMIT) mine.removeFirst()
                    }
                    attached
                }
                target?.success(event)
            }
        }

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            val attached = events ?: return
            main.post {
                // The process-wide backlog first: it was held before anything
                // listened, so it is the older of the two.
                val backlog = synchronized(CallEvents) {
                    sinks.add(attached)
                    held.toList().also { held.clear() }
                } + synchronized(this) {
                    sink = attached
                    mine.toList().also { mine.clear() }
                }
                backlog.forEach(attached::success)
            }
        }

        override fun onCancel(arguments: Any?) {
            val detached = synchronized(this) { sink.also { sink = null } } ?: return
            synchronized(CallEvents) { sinks.remove(detached) }
        }
    }

    private fun emit(event: Map<String, Any?>) {
        main.post {
            val targets = synchronized(this) {
                if (sinks.isEmpty()) {
                    held.addLast(event)
                    while (held.size > HELD_LIMIT) held.removeFirst()
                }
                sinks.toList()
            }
            targets.forEach { it.success(event) }
        }
    }
}
