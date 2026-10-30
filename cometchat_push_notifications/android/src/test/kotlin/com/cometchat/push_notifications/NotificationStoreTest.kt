package com.cometchat.push_notifications

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The store decides what a notification says and what "clear all" clears, and
 * it lives for the whole process — so both its accumulation and its forgetting
 * are worth pinning down.
 */
internal class NotificationStoreTest {

    @AfterTest
    fun reset() {
        NotificationStore.takeAllPostedIds()
    }

    @Test
    fun `lines accumulate per conversation, newest last`() {
        NotificationStore.addLine("alex", "first")
        val lines = NotificationStore.addLine("alex", "second")

        assertEquals(listOf("first", "second"), lines)
    }

    @Test
    fun `conversations do not bleed into each other`() {
        NotificationStore.addLine("alex", "to alex")

        assertEquals(listOf("to cameron"), NotificationStore.addLine("cameron", "to cameron"))
    }

    @Test
    fun `only the most recent lines are kept`() {
        repeat(10) { NotificationStore.addLine("alex", "message $it") }

        val lines = NotificationStore.addLine("alex", "latest")
        assertEquals(6, lines.size)
        assertEquals("latest", lines.last())
    }

    @Test
    fun `clearing a conversation starts its next message over`() {
        NotificationStore.addLine("alex", "first")
        NotificationStore.clearConversation("alex")

        assertEquals(listOf("second"), NotificationStore.addLine("alex", "second"))
    }

    @Test
    fun `the conversation map is capped rather than growing forever`() {
        // One entry per conversation that ever notified would leak for the life
        // of the process.
        repeat(120) { NotificationStore.addLine("conversation $it", "hello") }

        // The most recent conversation still accumulates; an early one does not.
        assertEquals(2, NotificationStore.addLine("conversation 119", "again").size)
        assertEquals(1, NotificationStore.addLine("conversation 0", "again").size)
    }

    @Test
    fun `taking the posted ids returns them once and forgets them`() {
        NotificationStore.rememberPosted(7)
        NotificationStore.rememberPosted(8)

        assertEquals(setOf(7, 8), NotificationStore.takeAllPostedIds())
        assertTrue(NotificationStore.takeAllPostedIds().isEmpty())
    }

    @Test
    fun `a forgotten id is not returned again`() {
        NotificationStore.rememberPosted(7)
        NotificationStore.forgetPosted(7)

        assertTrue(NotificationStore.takeAllPostedIds().isEmpty())
    }
}
