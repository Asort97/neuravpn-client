import 'dart:ui';

import 'package:flutter/material.dart';

class NeuraUi {
  static const Color black = Color(0xFF0A0A0A);
  static const Color card = Color(0xFF1A1A1A);
  static const Color surface = Color(0xFF2A2A2A);
  static const Color red = Color(0xFFEF4444);
  static const Color redSoft = Color(0xFFFF1E3C);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);
  static const Color neutral = Color(0xFFCBD5E1);

  static const Duration micro = Duration(milliseconds: 140);
  static const Duration fast = Duration(milliseconds: 220);
  static const Duration normal = Duration(milliseconds: 320);
  static const Duration slow = Duration(milliseconds: 520);

  static const Curve curve = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutQuart;

  static ThemeData buildTheme() {
    final baseScheme = ColorScheme.fromSeed(
      seedColor: redSoft,
      brightness: Brightness.dark,
    );
    final scheme = baseScheme.copyWith(
      primary: red,
      secondary: redSoft,
      error: danger,
      surface: card,
      surfaceContainerHighest: const Color(0xFF202126),
      onSurface: Colors.white,
      onPrimary: Colors.white,
    );

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF050608),
      splashFactory: InkSparkle.splashFactory,
      dialogTheme: const DialogThemeData(backgroundColor: Colors.transparent),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white.withOpacity(0.04),
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.75)),
        hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: red.withOpacity(0.85), width: 1.2),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: red,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          side: BorderSide(color: Colors.white.withOpacity(0.14)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: Colors.white.withOpacity(0.02),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white70,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: card.withOpacity(0.82),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}

enum NeuraToastTone { neutral, success, warning, error }

class NeuraGlassSurface extends StatelessWidget {
  const NeuraGlassSurface({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 24,
    this.blur = 26,
    this.fillColor,
    this.borderColor,
    this.glowColor,
    this.glowOpacity = 0.18,
    this.animate = false,
    this.expand = false,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double blur;
  final Color? fillColor;
  final Color? borderColor;
  final Color? glowColor;
  final double glowOpacity;
  final bool animate;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: fillColor ?? NeuraUi.card.withOpacity(0.72),
      border: Border.all(
        color: borderColor ?? Colors.white.withOpacity(0.08),
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withOpacity(0.28),
          blurRadius: 28,
          offset: const Offset(0, 12),
        ),
        if (glowColor != null)
          BoxShadow(
            color: glowColor!.withOpacity(glowOpacity),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
      ],
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Colors.white.withOpacity(0.055),
          Colors.white.withOpacity(0.015),
        ],
      ),
    );

    final content = RepaintBoundary(
      child: Container(
        width: expand ? double.infinity : null,
        margin: margin,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(borderRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
            child: AnimatedContainer(
              duration: animate ? NeuraUi.normal : Duration.zero,
              curve: NeuraUi.curve,
              width: expand ? double.infinity : null,
              padding: padding,
              decoration: decoration,
              child: child,
            ),
          ),
        ),
      ),
    );
    return content;
  }
}

class NeuraGlassPill extends StatelessWidget {
  const NeuraGlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.active = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return NeuraGlassSurface(
      borderRadius: 999,
      blur: 18,
      padding: padding,
      animate: true,
      expand: false,
      glowColor: active ? NeuraUi.red : null,
      fillColor: (active ? NeuraUi.red : Colors.white).withOpacity(
        active ? 0.18 : 0.035,
      ),
      borderColor: (active ? NeuraUi.red : Colors.white).withOpacity(
        active ? 0.32 : 0.10,
      ),
      child: child,
    );
  }
}

class NeuraReveal extends StatelessWidget {
  const NeuraReveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, 0.04),
  });

  final Widget child;
  final Duration delay;
  final Offset offset;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: NeuraUi.slow + delay,
      curve: NeuraUi.emphasized,
      builder: (context, value, _) {
        final t = Curves.easeOutCubic.transform(value.clamp(0.0, 1.0));
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(offset.dx * (1 - t) * 24, offset.dy * (1 - t) * 24),
            child: child,
          ),
        );
      },
    );
  }
}

class NeuraOverlayDialog extends StatelessWidget {
  const NeuraOverlayDialog({
    super.key,
    required this.title,
    required this.child,
    this.actions = const <Widget>[],
    this.width = 460,
  });

  final Widget title;
  final Widget child;
  final List<Widget> actions;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: NeuraGlassSurface(
            padding: const EdgeInsets.all(22),
            borderRadius: 28,
            blur: 28,
            fillColor: NeuraUi.card.withOpacity(0.84),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                DefaultTextStyle(
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                  child: title,
                ),
                const SizedBox(height: 14),
                child,
                if (actions.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions
                        .map(
                          (action) => Padding(
                            padding: const EdgeInsets.only(left: 10),
                            child: action,
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> showNeuraDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierDismissible: barrierDismissible,
    barrierColor: Colors.black.withOpacity(0.58),
    transitionDuration: NeuraUi.normal,
    pageBuilder: (context, _, __) => builder(context),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: NeuraUi.emphasized,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );
}

Future<T?> showNeuraBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.58),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
      ),
      child: NeuraReveal(
        child: NeuraGlassSurface(
          borderRadius: 30,
          blur: 28,
          fillColor: NeuraUi.card.withOpacity(0.86),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 54,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(child: builder(ctx)),
            ],
          ),
        ),
      ),
    ),
  );
}

SnackBar buildNeuraSnackBar(
  BuildContext context,
  String message, {
  NeuraToastTone tone = NeuraToastTone.neutral,
  IconData? icon,
}) {
  final toneColor = switch (tone) {
    NeuraToastTone.neutral => Colors.white,
    NeuraToastTone.success => NeuraUi.success,
    NeuraToastTone.warning => NeuraUi.warning,
    NeuraToastTone.error => NeuraUi.danger,
  };
  final toneIcon = icon ??
      switch (tone) {
        NeuraToastTone.neutral => Icons.notifications_active_outlined,
        NeuraToastTone.success => Icons.check_circle_outline,
        NeuraToastTone.warning => Icons.warning_amber_rounded,
        NeuraToastTone.error => Icons.error_outline,
      };
  return SnackBar(
    content: NeuraGlassSurface(
      borderRadius: 22,
      blur: 24,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      fillColor: NeuraUi.black.withOpacity(0.86),
      borderColor: toneColor.withOpacity(0.22),
      glowColor: toneColor,
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: toneColor.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(toneIcon, color: toneColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    ),
    backgroundColor: Colors.transparent,
    elevation: 0,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    duration: const Duration(seconds: 2),
  );
}

void showNeuraToast(
  BuildContext context,
  String message, {
  NeuraToastTone tone = NeuraToastTone.neutral,
  IconData? icon,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    buildNeuraSnackBar(context, message, tone: tone, icon: icon),
  );
}
