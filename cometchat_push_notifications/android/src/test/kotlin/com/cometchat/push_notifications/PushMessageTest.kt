package com.cometchat.push_notifications

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [PushMessage.conversationKey] decides every notification id, so getting it
 * wrong either splits one conversation across notifications or collapses two
 * conversations into one.
 */
internal class PushMessageTest {

    private fun message(
        sender: String = "alex",
        receiver: String = "cameron",
        receiverType: String = "user",
        messageId: String = "42"
    ) = PushMessage(
        title = "Alex",
        body = "hello",
        sender = sender,
        senderName = "Alex Okonjo",
        senderAvatar = null,
        receiver = receiver,
        receiverType = receiverType,
        messageId = messageId
    )

    @Test
    fun `a 1-to-1 message is keyed by its sender, not its recipient`() {
        // The recipient is always the logged-in user, so keying on it would put
        // every conversation into one notification.
        assertEquals("alex", message().conversationKey)
    }

    @Test
    fun `a group message is keyed by the group`() {
        assertEquals(
            "engineering",
            message(receiver = "engineering", receiverType = "group").conversationKey
        )
    }

    @Test
    fun `receiverType is matched without regard to case`() {
        assertTrue(message(receiverType = "GROUP").isGroup)
        assertTrue(message(receiverType = "Group").isGroup)
        assertFalse(message(receiverType = "user").isGroup)
    }

    @Test
    fun `a message with no identifiable conversation falls back to its id`() {
        // Better a notification of its own than every such message collapsing
        // onto the same empty-string key.
        assertEquals("42", message(sender = "", receiver = "").conversationKey)
    }

    @Test
    fun `fromMap defaults missing strings to empty rather than crashing`() {
        val parsed = PushMessage.fromMap(mapOf("sender" to "alex"))

        assertEquals("alex", parsed.sender)
        assertEquals("", parsed.body)
        assertEquals(null, parsed.senderAvatar)
    }
}
