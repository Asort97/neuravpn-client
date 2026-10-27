import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/qr_import.dart';
import 'neura_ui.dart';

class SubscriptionQrScanner extends StatefulWidget {
  const SubscriptionQrScanner({super.key});

  @override
  State<SubscriptionQrScanner> createState() => _SubscriptionQrScannerState();
}

class _SubscriptionQrScannerState extends State<SubscriptionQrScanner>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 600,
  );
  Future<void> _cameraWork = Future.value();
  bool _foreground = true;
  bool _finished = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCamera());
  }

  // Serialize start/stop, including lifecycle events during permission prompts.
  Future<void> _syncCamera() {
    _cameraWork = _cameraWork.then((_) async {
      if (!mounted) return;
      try {
        if (_foreground && !_finished) {
          await _controller.start();
          if (!_foreground || _finished || !mounted) {
            await _controller.stop();
          }
        } else {
          await _controller.stop();
        }
      } catch (_) {
        if (mounted && !_finished) {
          setState(() => _message = 'Не удалось включить камеру');
        }
      }
    });
    return _cameraWork;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // A permission dialog can make the app inactive while start is pending.
    if (_controller.value.isStarting) return;
    if (_controller.value.hasCameraPermission || _foreground) {
      unawaited(_syncCamera());
    }
  }

  Future<void> _detect(BarcodeCapture capture) async {
    if (!mounted ||
        _finished ||
        !_foreground ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final input = parseQrImport(barcode.rawValue);
      if (input == null) continue;
      _finished = true;
      unawaited(HapticFeedback.lightImpact());
      await _syncCamera();
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(input);
      }
      return;
    }
    if (capture.barcodes.isNotEmpty && _message == null) {
      setState(
        () => _message =
            'Этот QR не содержит подписку или ключ VLESS / Hysteria 2',
      );
    }
  }

  Future<void> _openSettings() async {
    try {
      await const MethodChannel(
        'happycat.vpn/native',
      ).invokeMethod<bool>('openAppSettings');
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Разрешите камеру в настройках приложения');
      }
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
    } catch (_) {
      if (mounted) setState(() => _message = 'Фонарик недоступен');
    }
  }

  @override
  void dispose() {
    _finished = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseCamera());
    super.dispose();
  }

  Future<void> _releaseCamera() async {
    await _cameraWork;
    try {
      await _controller.dispose();
    } catch (_) {
      // The native camera may already be gone when Android destroys the view.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NeuraUi.black,
      appBar: AppBar(
        backgroundColor: NeuraUi.black,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Закрыть сканер',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('QR подписки', style: TextStyle(fontSize: 18)),
        actions: [
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, state, _) => IconButton(
              tooltip: state.torchState == TorchState.on
                  ? 'Выключить фонарик'
                  : 'Включить фонарик',
              onPressed:
                  state.isRunning && state.torchState != TorchState.unavailable
                  ? _toggleTorch
                  : null,
              color: state.torchState == TorchState.on
                  ? NeuraUi.red
                  : Colors.white,
              icon: Icon(
                state.torchState == TorchState.on
                    ? Icons.flash_on_rounded
                    : Icons.flash_off_rounded,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = math.max(
              1.0,
              math.min(
                300.0,
                math.min(constraints.maxWidth - 48, constraints.maxHeight - 48),
              ),
            );
            final window = Rect.fromCenter(
              center: Offset(
                constraints.maxWidth / 2,
                constraints.maxHeight / 2,
              ),
              width: side,
              height: side,
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _detect,
                  scanWindow: window,
                  errorBuilder: (_, _) =>
                      const ColoredBox(color: NeuraUi.black),
                  placeholderBuilder: (_) => const Center(
                    child: CircularProgressIndicator(color: NeuraUi.red),
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: _controller,
                  builder: (context, state, _) {
                    final error = state.error;
                    if (error != null) {
                      final denied =
                          error.errorCode ==
                          MobileScannerErrorCode.permissionDenied;
                      return Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                denied
                                    ? Icons.no_photography_outlined
                                    : Icons.camera_alt_outlined,
                                color: NeuraUi.red,
                                size: 40,
                              ),
                              const SizedBox(height: 20),
                              Text(
                                denied
                                    ? 'Нет доступа к камере'
                                    : 'Камера недоступна',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                denied
                                    ? 'Разрешите доступ к камере в настройках NeuraVPN'
                                    : 'Закройте другие приложения, использующие камеру',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 24),
                              if (denied && Platform.isAndroid)
                                FilledButton.icon(
                                  onPressed: _openSettings,
                                  icon: const Icon(Icons.settings_outlined),
                                  label: const Text('Настройки'),
                                ),
                              TextButton.icon(
                                onPressed: _syncCamera,
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Повторить'),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return IgnorePointer(
                      child: CustomPaint(painter: _ScanFramePainter(window)),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _message ?? 'Подписка, VLESS или Hysteria 2',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _message == null ? Colors.white60 : NeuraUi.red,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScanFramePainter extends CustomPainter {
  const _ScanFramePainter(this.window);
  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = RRect.fromRectAndRadius(window, const Radius.circular(8));
    final mask = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(frame);
    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.62),
    );
    canvas.drawRRect(
      frame,
      Paint()
        ..color = NeuraUi.red
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_ScanFramePainter oldDelegate) =>
      oldDelegate.window != window;
}
