import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens extracted verbatim from the official ZCode Web Remote Control
/// bundle (`theme-zai-dark` / `:root` light). The official page uses a Tailwind
/// neutral gray scale with a sky-blue brand accent. Values below are the
/// official oklch scale resolved to sRGB.
class ZColors {
  ZColors._();

  // Tailwind neutral scale (oklch L, chroma 0 → resolved to gray).
  static const neutral50 = Color(0xFFFAFAFA);
  static const neutral100 = Color(0xFFF5F5F5);
  static const neutral200 = Color(0xFFE5E5E5);
  static const neutral300 = Color(0xFFD4D4D4);
  static const neutral400 = Color(0xFFA3A3A3);
  static const neutral500 = Color(0xFF737373);
  static const neutral600 = Color(0xFF525252);
  static const neutral700 = Color(0xFF404040);
  static const neutral800 = Color(0xFF262626);
  static const neutral900 = Color(0xFF171717);
  static const neutral950 = Color(0xFF0A0A0A);

  // Official surfaces.
  static const darkBackground = Color(0xFF161616);
  static const darkCard = Color(0xFF2B2B2B);
  /// Official dual-pane left column (--workspace-sidebar-panel-width area).
  static const darkSidebar = Color(0xFF1E1E1E);
  static const darkSecondary = Color(0xFF363636);
  static const lightBackground = Color(0xFFF8F8F8);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightSidebar = Color(0xFFF0F0F0);
  static const lightSecondary = Color(0xFFE6E6E6);

  // Brand sky accent (official --color-brand / --color-accent).
  static const sky400 = Color(0xFF38BDF8);
  static const sky500 = Color(0xFF0EA5E9);
  static const sky600 = Color(0xFF0284C7);
  static const sky50 = Color(0xFFF0F9FF);
  static const sky950 = Color(0xFF082F49);

  // Status.
  static const danger = Color(0xFFFF5C5C); // dark destructive
  static const dangerLight = Color(0xFFE03131); // light destructive
  static const success = Color(0xFF34D399); // emerald-400
  static const warning = Color(0xFFFBBF24); // amber-400

  // Official mobile status pills (measured on the official 390px list).
  static const pillSuccessBg = Color(0xFF46BF72); // 已完成 pill surface
  static const pillRunningBg = Color(0xFF001D3D); // 运行中 pill surface
}

/// Theme-aware text colors mirroring the official foreground tokens.
class ZInk {
  ZInk._();

  static Color solid(BuildContext c) =>
      _dark(c) ? ZColors.neutral200 : ZColors.neutral700;
  static Color soft(BuildContext c) =>
      _dark(c) ? ZColors.neutral300 : ZColors.neutral600;
  static Color muted(BuildContext c) =>
      _dark(c) ? ZColors.neutral400 : ZColors.neutral500;
  static Color faint(BuildContext c) => _dark(c)
      ? ZColors.neutral200.withValues(alpha: 0.60)
      : ZColors.neutral700.withValues(alpha: 0.60);
  static Color ghost(BuildContext c) => _dark(c)
      ? ZColors.neutral200.withValues(alpha: 0.30)
      : ZColors.neutral700.withValues(alpha: 0.40);

  /// Sub-surface tone (tiles inside a card: reasoning, tool calls, queue).
  static Color tile(BuildContext c) =>
      _dark(c) ? ZColors.darkSecondary : ZColors.lightSecondary;

  /// Card / panel surface (chat composer, user bubbles, sheets).
  static Color card(BuildContext c) =>
      _dark(c) ? ZColors.darkCard : ZColors.lightCard;

  /// Full-bleed page surface (scrim overlays, kicked-offline mask).
  static Color surface(BuildContext c) =>
      _dark(c) ? ZColors.darkBackground : ZColors.lightBackground;

  /// 1px hairline borders around tiles.
  static Color hairline(BuildContext c) => _dark(c)
      ? const Color(0x14FFFFFF)
      : const Color(0x140D0D0D);

  /// Inline-code pill background (assistant markdown `code`).
  static Color codeInlineBg(BuildContext c) =>
      _dark(c) ? ZColors.neutral800 : ZColors.neutral200;

  /// Fenced code-block background.
  static Color codeBlockBg(BuildContext c) =>
      _dark(c) ? ZColors.neutral950 : ZColors.neutral100;

  static Color codeText(BuildContext c) =>
      _dark(c) ? ZColors.neutral200 : ZColors.neutral700;

  static bool _dark(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark;
}

/// Light/dark mode, persisted. Defaults to dark like the official page.
class ThemeController extends ChangeNotifier {
  static const _key = 'zlinker_theme_mode';
  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_key)) {
      case 'light':
        _mode = ThemeMode.light;
        break;
      case 'system':
        _mode = ThemeMode.system;
        break;
      default:
        _mode = ThemeMode.dark;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      _ => 'dark',
    });
  }

  void cycle() {
    setMode(switch (_mode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.system,
      ThemeMode.system => ThemeMode.dark,
    });
  }
}

ThemeData buildDarkTheme() {
  const scheme = ColorScheme.dark(
    primary: ZColors.neutral50,
    onPrimary: ZColors.neutral950,
    secondary: ZColors.darkSecondary,
    onSecondary: ZColors.neutral50,
    surface: ZColors.darkBackground,
    onSurface: ZColors.neutral200,
    error: ZColors.danger,
    onError: ZColors.neutral950,
    surfaceContainerHighest: ZColors.darkCard,
    outline: Color(0x1AFFFFFF),
  );
  return _base(scheme, ZColors.darkBackground, ZColors.darkCard,
      const Color(0x1AFFFFFF), ZColors.neutral200);
}

ThemeData buildLightTheme() {
  const scheme = ColorScheme.light(
    primary: ZColors.neutral950,
    onPrimary: ZColors.neutral50,
    secondary: ZColors.lightSecondary,
    onSecondary: ZColors.neutral950,
    surface: ZColors.lightBackground,
    onSurface: ZColors.neutral700,
    error: ZColors.dangerLight,
    onError: ZColors.neutral50,
    surfaceContainerHighest: ZColors.lightCard,
    outline: Color(0x1A0D0D0D),
  );
  return _base(scheme, ZColors.lightBackground, ZColors.lightCard,
      const Color(0x1A0D0D0D), ZColors.neutral700);
}

ThemeData _base(ColorScheme scheme, Color background, Color card,
    Color border, Color foreground) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
          color: foreground, fontSize: 17, fontWeight: FontWeight.w600),
      iconTheme: IconThemeData(color: foreground),
    ),
    // card/dialog visuals ride the CardTheme/DialogTheme widgets in
    // ZLinkerApp.builder — the ThemeData param type differs across SDKs
    // (CardTheme vs CardThemeData), the widget form does not.
    dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.primary,
      contentTextStyle: TextStyle(color: scheme.onPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: card,
      hintStyle: TextStyle(color: foreground.withValues(alpha: 0.4)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: ZColors.sky500)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: foreground,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: foreground,
      iconColor: foreground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}


/// Card visuals for [ZLinkerApp]'s builder-wrapped CardTheme widget
/// (stable across SDKs, unlike ThemeData.cardTheme's param type).
CardThemeData zCardTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return CardThemeData(
    color: dark ? ZColors.darkCard : ZColors.lightCard,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12), // official --radius-xl
      side: BorderSide(
          color: dark ? const Color(0x14FFFFFF) : const Color(0x140D0D0D)),
    ),
  );
}

/// Dialog visuals for the builder-wrapped DialogTheme widget.
DialogThemeData zDialogTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return DialogThemeData(
    backgroundColor: dark ? ZColors.darkCard : ZColors.lightCard,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  );
}
