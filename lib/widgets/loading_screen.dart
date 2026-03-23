import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'neura_ui.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<Animation<double>> _dotAnimations;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _dotAnimations = List.generate(3, (index) {
      final start = index * 0.18;
      final end = math.min(start + 0.65, 1.0);
      return CurvedAnimation(
        parent: _controller,
        curve: Interval(start, end, curve: Curves.easeInOutCubic),
      );
    });

    if (!_scheduled) {
      _scheduled = true;
      unawaited(Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) {
          widget.onComplete();
        }
      }));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: Center(
        child: NeuraReveal(
          child: NeuraGlassSurface(
            borderRadius: 28,
            blur: 26,
            glowColor: NeuraUi.red,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0.92, end: 1),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutBack,
                  builder: (context, scale, child) => Transform.scale(
                    scale: scale,
                    child: child,
                  ),
                  child: Image.asset(
                    'assets/images/11zon_cropped.png',
                    width: 64,
                    height: 64,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'neuravpn',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(_dotAnimations.length, (index) {
                    return AnimatedBuilder(
                      animation: _dotAnimations[index],
                      builder: (context, child) {
                        final value = _dotAnimations[index].value;
                        return Transform.scale(
                          scale: 0.7 + value * 0.6,
                          child: Opacity(
                            opacity: 0.3 + value * 0.7,
                            child: child,
                          ),
                        );
                      },
                      child: Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
