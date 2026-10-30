package com.cometchat.push_notifications

import java.util.concurrent.ConcurrentHashMap

/**
 * What has been posted, and what it said.
 *
 * Two jobs. It accumulates the recent lines of each conversation so a second
 * message expands the existing notification into a thread rather than stacking
 * a new one beside it, the way a messaging app behaves. And it remembers which
 * notification ids this package posted, so clearing "all" of them clears only
 * ours — an integrator's unrelated notifications are not this package's to
 * cancel.
 *
 * Process-lifetime only. A killed process loses the accumulated lines and the
 * next message starts a fresh thread, which is the right trade: persisting
 * message text to disk to make a notification prettier is not worth it.
 */
internal object NotificationStore {

    private const val MAX_LINES_PER_CONVERSATION = 6

    /**
     * How many conversations keep their accumulated lines.
     *
     * Without a cap this map grows for the life of the process, one entry per
     * conversation that has ever notified. Losing the oldest costs a thread
     * that the user almost certainly dismissed long ago.
     */
    private const val MAX_CONVERSATIONS = 50

    private val lines = ConcurrentHashMap<String, MutableList<String>>()
    private val recency = java.util.concurrent.ConcurrentLinkedQueue<String>()
    private val postedIds = ConcurrentHashMap.newKeySet<Int>()

    /** Appends [line] to [conversationKey] and returns the lines to display. */
    fun addLine(conversationKey: String, line: String): List<String> {
        if (lines.putIfAbsent(conversationKey, mutableListOf()) == null) {
            recency.add(conversationKey)
            evictOldest()
        }
        val bucket = lines[conversationKey] ?: mutableListOf()
        synchronized(bucket) {
            bucket.add(line)
            while (bucket.size > MAX_LINES_PER_CONVERSATION) bucket.removeAt(0)
            return bucket.toList()
        }
    }

    private fun evictOldest() {
        while (lines.size > MAX_CONVERSATIONS) {
            val oldest = recency.poll() ?: return
            lines.remove(oldest)
        }
    }

    /** Records that [id] belongs to this package. */
    fun rememberPosted(id: Int) {
        postedIds.add(id)
    }

    /** Forgets [conversationKey]'s lines, so its next message starts over. */
    fun clearConversation(conversationKey: String) {
        lines.remove(conversationKey)
        recency.remove(conversationKey)
    }

    /** Every id this package has posted, and forgets them all. */
    fun takeAllPostedIds(): Set<Int> {
        val snapshot = postedIds.toSet()
        postedIds.clear()
        lines.clear()
        recency.clear()
        return snapshot
    }

    /** Drops [id] from the posted set. */
    fun forgetPosted(id: Int) {
        postedIds.remove(id)
    }
}
