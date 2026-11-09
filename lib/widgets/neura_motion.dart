import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Spring-based motion tokens. Durations and bounces match SwiftUI's
/// `spring(duration:bounce:)`, so the app moves like a native iOS app.
class NeuraMotion {
  const NeuraMotion._();

  /// Buttons, toggles, small state changes.
  static final SpringDescription snappy =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 320),
        bounce: 0.18,
      );

  /// Layout, cards, page-level content. No overshoot.
  static final SpringDescription smooth =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 450),
      );

  /// Celebratory feedback (connected, success).
  static final SpringDescription bouncy =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 520),
        bounce: 0.32,
      );

  /// UIKit sheet presentation curve.
  static const Curve sheet = Cubic(0.32, 0.72, 0, 1);

  /// Spring curves for widgets that only accept a [Curve].
  static const Curve snappyCurve = NeuraSpringCurve(bounce: 0.18);
  static const Curve smoothCurve = NeuraSpringCurve();
  static const Curve bouncyCurve = NeuraSpringCurve(bounce: 0.32);

  /// Time a [NeuraSpringCurve] animation needs, given the spring's perceptual
  /// duration.
  static Duration curveDuration(Duration perceptual) =>
      perceptual * NeuraSpringCurve.settleFactor;

  static bool reduceMotion(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// A spring expressed as a [Curve] for implicit animations and transitions.
///
/// The animation's duration maps to [settleFactor] perceptual durations, by
/// which point the spring is within 1% of rest, so the end snap is invisible.
class NeuraSpringCurve extends Curve {
  const NeuraSpringCurve({this.bounce = 0.0});

  final double bounce;

  static const double settleFactor = 1.2;

  @override
  double transformInternal(double t) {
    final spring = SpringDescription.withDurationAndBounce(
      duration: const Duration(seconds: 1),
      bounce: bounce,
    );
    return SpringSimulation(spring, 0, 1, 0).x(t * settleFactor);
  }
}

/// Animates [value] with a spring whenever it changes. A retarget keeps the
/// current velocity, so interrupted motion never jumps.
class NeuraSpringValue extends StatefulWidget {
  const NeuraSpringValue({
    super.key,
    required this.value,
    required this.builder,
    this.spring,
    this.child,
  });

  final double value;
  final SpringDescription? spring;
  final ValueWidgetBuilder<double> builder;
  final Widget? child;

  @override
  State<NeuraSpringValue> createState() => _NeuraSpringValueState();
}

class _NeuraSpringValueState extends State<NeuraSpringValue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
    value: widget.value,
  );

  @override
  void didUpdateWidget(NeuraSpringValue oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (NeuraMotion.reduceMotion(context)) {
      _controller.value = widget.value;
      return;
    }
    _controller.animateWith(
      SpringSimulation(
        widget.spring ?? NeuraMotion.snappy,
        _controller.value,
        widget.value,
        _controller.velocity,
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) =>
          widget.builder(context, _controller.value, child),
    );
  }
}

/// iOS-style press feedback: the child sinks and dims under the finger and
/// springs back on release. Use instead of ink ripples on mobile.
class NeuraPressable extends StatefulWidget {
  const NeuraPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.pressedOpacity = 0.82,
    this.haptic = NeuraHaptic.none,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;
  final double pressedOpacity;
  final NeuraHaptic haptic;
  final HitTestBehavior behavior;

  @override
  State<NeuraPressable> createState() => _NeuraPressableState();
}

class _NeuraPressableState extends State<NeuraPressable> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _enabled
          ? (_) {
              _setPressed(true);
              NeuraHaptics.play(widget.haptic);
            }
          : null,
      onTapUp: _enabled ? (_) => _setPressed(false) : null,
      onTapCancel: _enabled ? () => _setPressed(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: NeuraSpringValue(
        value: _pressed ? 1 : 0,
        child: widget.child,
        builder: (context, t, child) {
          final clamped = t.clamp(0.0, 1.0);
          return Opacity(
            opacity: 1 - (1 - widget.pressedOpacity) * clamped,
            child: Transform.scale(
              scale: 1 - (1 - widget.pressedScale) * t,
              child: child,
            ),
          );
        },
      ),
    );
  }
}

enum NeuraHaptic {
  none,
  selection,
  light,
  medium,
  heavy,
  soft,
  rigid,
  success,
  warning,
  error,
}

/// Haptics with iOS-native generators (UIImpact/UISelection/UINotification)
/// through the `neuravpn/haptics` channel, and [HapticFeedback] elsewhere.
class NeuraHaptics {
  const NeuraHaptics._();

  static const MethodChannel _channel = MethodChannel('neuravpn/haptics');

  @visibleForTesting
  static TargetPlatform? debugPlatformOverride;

  static bool _nativeUnavailable = false;

  static TargetPlatform get _platform =>
      debugPlatformOverride ?? defaultTargetPlatform;

  static void selection() => play(NeuraHaptic.selection);
  static void light() => play(NeuraHaptic.light);
  static void medium() => play(NeuraHaptic.medium);
  static void success() => play(NeuraHaptic.success);
  static void warning() => play(NeuraHaptic.warning);
  static void error() => play(NeuraHaptic.error);

  static void play(NeuraHaptic haptic) {
    if (haptic == NeuraHaptic.none) return;
    switch (_platform) {
      case TargetPlatform.iOS:
        unawaited(_playIos(haptic));
      case TargetPlatform.android:
        unawaited(_playFallback(haptic));
      default:
        return;
    }
  }

  static Future<void> _playIos(NeuraHaptic haptic) async {
    if (_nativeUnavailable) return _playFallback(haptic);
    try {
      switch (haptic) {
        case NeuraHaptic.selection:
          await _channel.invokeMethod<void>('selection');
        case NeuraHaptic.success:
        case NeuraHaptic.warning:
        case NeuraHaptic.error:
          await _channel.invokeMethod<void>('notification', {
            'type': haptic.name,
          });
        case NeuraHaptic.none:
          return;
        default:
          await _channel.invokeMethod<void>('impact', {'style': haptic.name});
      }
    } on MissingPluginException {
      _nativeUnavailable = true;
      await _playFallback(haptic);
    } on PlatformException {
      await _playFallback(haptic);
    }
  }

  static Future<void> _playFallback(NeuraHaptic haptic) {
    return switch (haptic) {
      NeuraHaptic.none => Future<void>.value(),
      NeuraHaptic.selection => HapticFeedback.selectionClick(),
      NeuraHaptic.light || NeuraHaptic.soft => HapticFeedback.lightImpact(),
      NeuraHaptic.medium ||
      NeuraHaptic.rigid ||
      NeuraHaptic.success => HapticFeedback.mediumImpact(),
      NeuraHaptic.heavy ||
      NeuraHaptic.warning ||
      NeuraHaptic.error => HapticFeedback.heavyImpact(),
    };
  }
}
