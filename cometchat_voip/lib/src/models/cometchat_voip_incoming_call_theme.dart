import 'dart:ui' show Color;

/// Which colour set the ring screen uses.
enum CometChatVoipIncomingCallThemeMode {
  /// Follows the phone's light or dark setting at the moment it rings.
  ///
  /// The phone's setting, not the app's: an app with its own light/dark
  /// toggle passes [light] or [dark] instead, and sets the theme again when
  /// the user toggles.
  system('system'),

  /// Always the light set.
  light('light'),

  /// Always the dark set.
  dark('dark');

  const CometChatVoipIncomingCallThemeMode(this.wireName);

  /// The name in the saved form.
  final String wireName;

  /// The mode named [wire], or [system] for one this version does not know.
  static CometChatVoipIncomingCallThemeMode fromWire(String? wire) {
    for (final mode in values) {
      if (mode.wireName == wire?.toLowerCase()) return mode;
    }
    return system;
  }
}

/// One set of ring screen colours, light or dark.
///
/// Every colour is optional. One left out comes from the
/// `cometchat_voip_call_*` Android resource, except in a light set, which
/// fills its gaps with built-in light colours: the resources are dark (the
/// screen's default look), and a light set taking one of them would put, say,
/// a light-grey name on a white page.
class CometChatVoipIncomingCallColors {
  /// Creates a colour set.
  const CometChatVoipIncomingCallColors({
    this.background,
    this.callerName,
    this.subtitle,
    this.avatarBackground,
    this.avatarText,
    this.acceptButton,
    this.acceptIcon,
    this.acceptLabel,
    this.declineButton,
    this.declineIcon,
    this.declineLabel,
  });

  /// The page, and the system bars over it.
  final Color? background;

  /// The caller's name.
  final Color? callerName;

  /// The line under the name: the call type, or "Answering ends your current
  /// call".
  final Color? subtitle;

  /// The circle behind the initials, on the screen and in the notifications'
  /// avatar.
  final Color? avatarBackground;

  /// The initials, on the screen and in the notifications' avatar.
  final Color? avatarText;

  /// The Answer button; also the ring and connecting notifications' accent and
  /// their Answer colour.
  final Color? acceptButton;

  /// The glyph on the Answer button.
  final Color? acceptIcon;

  /// "Answer" under the button.
  final Color? acceptLabel;

  /// The Decline button; also the missed-call notification's accent and the
  /// Decline colour.
  final Color? declineButton;

  /// The glyph on the Decline button.
  final Color? declineIcon;

  /// "Decline" under the button.
  final Color? declineLabel;

  /// The saved form: each colour that is set, as `#AARRGGBB`. Colours left
  /// out are not written.
  Map<String, String> toMap() => {
    for (final MapEntry(:key, :value) in {
      'background': background,
      'callerName': callerName,
      'subtitle': subtitle,
      'avatarBackground': avatarBackground,
      'avatarText': avatarText,
      'acceptButton': acceptButton,
      'acceptIcon': acceptIcon,
      'acceptLabel': acceptLabel,
      'declineButton': declineButton,
      'declineIcon': declineIcon,
      'declineLabel': declineLabel,
    }.entries)
      if (value != null) key: _hex(value),
  };

  /// Reads the saved form. `#RRGGBB` is taken as opaque; a value that does not
  /// parse, and a key this version does not know, are ignored.
  factory CometChatVoipIncomingCallColors.fromMap(Map<Object?, Object?> map) {
    Color? read(String key) => _parse(map[key]);
    return CometChatVoipIncomingCallColors(
      background: read('background'),
      callerName: read('callerName'),
      subtitle: read('subtitle'),
      avatarBackground: read('avatarBackground'),
      avatarText: read('avatarText'),
      acceptButton: read('acceptButton'),
      acceptIcon: read('acceptIcon'),
      acceptLabel: read('acceptLabel'),
      declineButton: read('declineButton'),
      declineIcon: read('declineIcon'),
      declineLabel: read('declineLabel'),
    );
  }

  static String _hex(Color color) =>
      '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static Color? _parse(Object? value) {
    if (value is! String) return null;
    var hex = value.trim();
    if (!hex.startsWith('#')) return null;
    hex = hex.substring(1);
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;
    final argb = int.tryParse(hex, radix: 16);
    return argb == null ? null : Color(argb);
  }
}

/// The colours of the ring screen `cometchat_voip` draws in
/// [CometChatCallMode.auto] on Android, and of its ring, connecting and
/// missed-call notifications.
///
/// Set it on [CometChatVoipConfig.incomingCallTheme] or, at any time, with
/// `CometChatVoip.setIncomingCallTheme`. It is saved natively, so a push that
/// starts a killed app rings in it. Ignored on iOS, where CallKit draws the
/// ring and cannot be styled.
///
/// The same shape and saved form as the Android Push SDK's
/// `CometChatPNIncomingCallTheme`.
class CometChatVoipIncomingCallTheme {
  /// Creates a theme.
  const CometChatVoipIncomingCallTheme({
    this.mode = CometChatVoipIncomingCallThemeMode.system,
    this.light,
    this.dark,
  });

  /// Which set is used.
  final CometChatVoipIncomingCallThemeMode mode;

  /// The colours in light mode.
  final CometChatVoipIncomingCallColors? light;

  /// The colours in dark mode. Left out, dark mode uses the resources (dark by
  /// default), never the light set.
  final CometChatVoipIncomingCallColors? dark;

  /// The saved form: `{"v":1,"mode":"system","light":{…},"dark":{…}}`.
  Map<String, Object?> toMap() => {
    'v': 1,
    'mode': mode.wireName,
    if (light != null) 'light': light!.toMap(),
    if (dark != null) 'dark': dark!.toMap(),
  };

  /// Reads the saved form, or returns null for one without a version.
  static CometChatVoipIncomingCallTheme? fromMap(Map<Object?, Object?> map) {
    if (map['v'] == null) return null;
    final light = map['light'];
    final dark = map['dark'];
    return CometChatVoipIncomingCallTheme(
      mode: CometChatVoipIncomingCallThemeMode.fromWire(map['mode'] as String?),
      light: light is Map
          ? CometChatVoipIncomingCallColors.fromMap(light)
          : null,
      dark: dark is Map ? CometChatVoipIncomingCallColors.fromMap(dark) : null,
    );
  }
}
