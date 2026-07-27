/// Error codes for CometChat notification operations.
enum CometChatErrorCode {
  /// Plugin was not initialized before use.
  notInitialized,

  /// Push payload is malformed or missing required fields.
  invalidPayload,

  /// Token registration with CometChat servers failed.
  tokenRegistrationFailed,

  /// Operation is not supported on the current platform.
  unsupportedPlatform,

  /// The underlying notification_voip_plugin returned an error.
  pluginError,

  /// Permission was denied by the user.
  permissionDenied,

  /// A call operation failed.
  callOperationFailed,
}

/// Exception thrown by the CometChat notifications plugin.
class CometChatNotificationException implements Exception {
  /// The error code identifying the type of failure.
  final CometChatErrorCode code;

  /// A human-readable description of the error.
  final String message;

  /// The underlying cause of the error, if any.
  final Object? cause;

  /// Creates a [CometChatNotificationException].
  const CometChatNotificationException({
    required this.code,
    required this.message,
    this.cause,
  });

  @override
  String toString() => 'CometChatNotificationException(${code.name}): $message';
}
