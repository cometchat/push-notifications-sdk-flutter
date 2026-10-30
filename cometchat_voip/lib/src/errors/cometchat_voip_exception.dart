/// Why a `CometChatVoip` call failed.
enum CometChatVoipErrorCode {
  /// `CometChatVoip.init` has not run.
  notInitialized,

  /// Nobody is logged in to the Calls SDK, and no auth token was configured,
  /// so there is no user to register a push token against.
  notLoggedIn,

  /// There is no push token to register yet. This package holds no native
  /// code, so the app is what obtains the token — the PushKit VoIP token on
  /// iOS, the FCM token on Android — and passes it in.
  noPushToken,

  /// The push token endpoint refused the request.
  tokenRegistrationFailed,

  /// The push token endpoint could not be reached.
  networkError,

  /// The call is not supported on this platform.
  unsupportedPlatform,

  /// The Calls SDK refused the call.
  callsSdkError,

  /// The native ringer reported an error.
  pluginError,
}

/// Thrown by `CometChatVoip` when an operation cannot complete.
class CometChatVoipException implements Exception {
  /// What went wrong.
  final CometChatVoipErrorCode code;

  /// A description of the failure, fit for a log.
  final String message;

  /// The error this one wraps, if any.
  final Object? cause;

  /// Creates a [CometChatVoipException].
  const CometChatVoipException({
    required this.code,
    required this.message,
    this.cause,
  });

  @override
  String toString() => 'CometChatVoipException(${code.name}): $message';
}
