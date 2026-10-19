import 'package:flutter/material.dart';

/// 配色沿用原 Android 版的微信绿体系，只是补了暗色模式。
class Palette {
  Palette._();

  static const Color green = Color(0xFF07C160);
  static const Color greenDark = Color(0xFF05974A);
  static const Color greenSoft = Color(0xFFE7F8EF);
  static const Color bg = Color(0xFFF5F6F7);
  static const Color card = Color(0xFFFFFFFF);
  static const Color line = Color(0xFFECEDEE);
  static const Color text = Color(0xFF181818);
  static const Color textDim = Color(0xFF8A8F99);
  static const Color blue = Color(0xFF2E7CF6);
  static const Color amber = Color(0xFFE8A33D);
  static const Color red = Color(0xFFE1493C);

  static const Color darkBg = Color(0xFF141516);
  static const Color darkCard = Color(0xFF1E2021);
  static const Color darkLine = Color(0xFF2C2F31);
  static const Color darkText = Color(0xFFEDEDED);
  static const Color darkTextDim = Color(0xFF8D9399);
}

/// 间距/圆角这类常量集中放，避免各页面各写一套。
class Dimens {
  Dimens._();

  static const double pagePadding = 16;
  static const double cardRadius = 14;
  static const double gap = 12;
  static const double gapSmall = 8;

  /// 桌面端内容最大宽度（手机上无影响）。
  static const double maxContentWidth = 1180;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Palette.green,
    brightness: brightness,
    surface: dark ? Palette.darkCard : Palette.card,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? Palette.darkBg : Palette.bg,
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme().apply(
      bodyColor: dark ? Palette.darkText : Palette.text,
      displayColor: dark ? Palette.darkText : Palette.text,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF262A2C) : const Color(0xFFF1F3F4),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Palette.green, width: 1.2),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: dark ? Palette.darkLine : Palette.line,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? const Color(0xFF2E3133) : const Color(0xFF2C3033),
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark ? Palette.darkCard : Palette.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

/// 金额文本样式（等宽数字，避免列表里跳动）。
TextStyle amountStyle(BuildContext context,
    {double size = 20, Color? color, FontWeight weight = FontWeight.w700}) {
  return TextStyle(
    fontSize: size,
    fontWeight: weight,
    color: color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Palette.darkText
            : Palette.text),
    fontFeatures: const [FontFeature.tabularFigures()],
    letterSpacing: -0.2,
  );
}
