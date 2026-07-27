import 'package:flutter/foundation.dart' show kIsWeb;

/// Utility for platform capability checks.
class PlatformGuard {
  PlatformGuard._();

  /// Returns `true` if the current platform supports VoIP calls.
  ///
  /// VoIP is supported on Android and iOS but not on web.
  static bool get isVoipSupported => !kIsWeb;

  /// Throws [UnsupportedError] if VoIP is not supported on the current
  /// platform.
  ///
  /// Call this at the start of any VoIP-only method to guard against
  /// unsupported platforms.
  static void ensureVoipSupported() {
    if (!isVoipSupported) {
      throw UnsupportedError('VoIP calls are not supported on web.');
    }
  }
}
