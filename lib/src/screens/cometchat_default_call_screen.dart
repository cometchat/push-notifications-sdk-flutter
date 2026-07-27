import 'package:flutter/material.dart';

import '../models/cometchat_call_details.dart';

/// Default incoming call screen shown when no custom screen builder is
/// provided.
///
/// Displays the caller's name and call type at the top, the caller's
/// avatar in the middle, and Accept / Decline action buttons at the
/// bottom.
///
/// To override this screen, provide a
/// [CometChatNotificationConfig.customCallScreenBuilder].
class CometChatDefaultCallScreen extends StatelessWidget {
  /// The call details for the incoming call.
  final CometChatCallDetails callDetails;

  /// Callback invoked when the user taps the Accept button.
  final VoidCallback onAccept;

  /// Callback invoked when the user taps the Decline button.
  final VoidCallback onDecline;

  /// Creates a [CometChatDefaultCallScreen].
  const CometChatDefaultCallScreen({
    super.key,
    required this.callDetails,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final callLabel = callDetails.isVideo
        ? 'Incoming Video call'
        : 'Incoming Voice call';
    final avatar = callDetails.callerAvatar;
    final initials = _initials(callDetails.callerName);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F4F4),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 64),
            Text(
              callDetails.callerName.isEmpty
                  ? 'Unknown Caller'
                  : callDetails.callerName,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  callDetails.isVideo
                      ? Icons.videocam_outlined
                      : Icons.call_outlined,
                  size: 16,
                  color: Colors.grey.shade600,
                ),
                const SizedBox(width: 6),
                Text(
                  callLabel,
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 48),
            CircleAvatar(
              radius: 64,
              backgroundColor: const Color(0xFF9B8CFF),
              backgroundImage: (avatar != null && avatar.isNotEmpty)
                  ? NetworkImage(avatar)
                  : null,
              child: (avatar == null || avatar.isEmpty)
                  ? Text(
                      initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  : null,
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CallActionButton(
                    icon: Icons.call_end,
                    color: const Color(0xFFEF5350),
                    onPressed: onDecline,
                    heroTag: 'decline',
                  ),
                  _CallActionButton(
                    icon: Icons.call,
                    color: const Color(0xFF22C55E),
                    onPressed: onAccept,
                    heroTag: 'accept',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Returns the first letters of the caller's name for avatar fallback.
  String _initials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

/// A circular call action button with a colored background and icon.
class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;
  final String heroTag;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.onPressed,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: FloatingActionButton(
        heroTag: heroTag,
        backgroundColor: color,
        elevation: 0,
        onPressed: onPressed,
        child: Icon(icon, color: Colors.white, size: 28),
      ),
    );
  }
}
