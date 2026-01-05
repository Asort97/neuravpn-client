import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class NeuralBackground extends StatefulWidget {
  const NeuralBackground({super.key});

  @override
  State<NeuralBackground> createState() => _NeuralBackgroundState();
}

class _NeuralBackgroundState extends State<NeuralBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ChangeNotifier _repaint = ChangeNotifier();
  final List<_Node> _nodes = [];
  Size _size = Size.zero;
  Duration _lastTick = Duration.zero;
  static const Duration _tickInterval = Duration(milliseconds: 33);
  static const int _nodeCount = 18;
  static const double _maxDistance = 160;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration elapsed) {
    if (_size == Size.zero) return;
    if (elapsed - _lastTick < _tickInterval) return;
    _lastTick = elapsed;
    for (final node in _nodes) {
      node.x += node.vx;
      node.y += node.vy;
      if (node.x < 0 || node.x > _size.width) {
        node.vx *= -1;
      }
      if (node.y < 0 || node.y > _size.height) {
        node.vy *= -1;
      }
    }
    _repaint.notifyListeners();
  }

  void _seedNodes(Size size) {
    _nodes
      ..clear()
      ..addAll(List.generate(_nodeCount, (index) {
        return _Node(
          x: math.Random().nextDouble() * size.width,
          y: math.Random().nextDouble() * size.height,
          vx: (math.Random().nextDouble() - 0.5) * 0.2,
          vy: (math.Random().nextDouble() - 0.5) * 0.2,
        );
      }));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final nextSize =
            Size(constraints.maxWidth, constraints.maxHeight);
        if (nextSize != _size) {
          _size = nextSize;
          _seedNodes(_size);
        }
        return RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _NeuralPainter(
              nodes: _nodes,
              repaint: _repaint,
            ),
          ),
        );
      },
    );
  }
}

class _NeuralPainter extends CustomPainter {
  const _NeuralPainter({required this.nodes, super.repaint});

  final List<_Node> nodes;

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;
    final nodePaint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      for (var j = i + 1; j < nodes.length; j++) {
        final other = nodes[j];
        final dx = node.x - other.x;
        final dy = node.y - other.y;
        final distance = math.sqrt(dx * dx + dy * dy);
        if (distance < _NeuralBackgroundState._maxDistance) {
          final opacity =
              (1 - distance / _NeuralBackgroundState._maxDistance) * 0.06;
          linePaint.color = Color.fromRGBO(239, 68, 68, opacity);
          canvas.drawLine(
            Offset(node.x, node.y),
            Offset(other.x, other.y),
            linePaint,
          );
        }
      }
    }

    for (final node in nodes) {
      nodePaint.color = const Color.fromRGBO(239, 68, 68, 0.18);
      canvas.drawCircle(Offset(node.x, node.y), 1.5, nodePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _NeuralPainter oldDelegate) => false;
}

class _Node {
  _Node({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
  });

  double x;
  double y;
  double vx;
  double vy;
}
