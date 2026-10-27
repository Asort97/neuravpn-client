import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/subscription_manager.dart';
import 'neura_ui.dart';
import '../vless/proxy_parser.dart';

class AddProfileDialog extends StatefulWidget {
  const AddProfileDialog({super.key, this.initialInput = '', this.onScanQr});

  final String initialInput;
  final Future<String?> Function()? onScanQr;

  @override
  State<AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<AddProfileDialog> {
  late TextEditingController _inputController;
  late FocusNode _inputFocus;
  String _detectedType =
      '\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u0438\u0435...';
  bool _isValidating = false;
  bool _canPaste = false;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.initialInput);
    _inputController.addListener(_detectType);
    if (widget.initialInput.isNotEmpty) _detectType();
    _inputFocus = FocusNode()..addListener(_handleFocusChange);
    _updateClipboardAvailability();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _inputFocus
      ..removeListener(_handleFocusChange)
      ..dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (_inputFocus.hasFocus) {
      _updateClipboardAvailability();
    }
  }

  void _detectType() {
    setState(() => _isValidating = true);

    final input = _inputController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _detectedType =
            '\u0412\u0432\u0435\u0434\u0438\u0442\u0435 URL \u0438\u043b\u0438 VLESS / Hysteria 2';
        _isValidating = false;
      });
      return;
    }

    if (isProxyUri(input)) {
      setState(() {
        _detectedType = isSecureProxyUri(input)
            ? parseProxyUri(input)!.protocolLabel
            : proxyImportError(input);
        _isValidating = false;
      });
      return;
    }

    final manager = SubscriptionService();
    if (manager.isValidSubscriptionUrl(input)) {
      setState(() {
        _detectedType =
            '\u042d\u0442\u043e \u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0430 URL';
        _isValidating = false;
      });
    } else {
      setState(() {
        _detectedType =
            '\u041d\u0435\u0432\u0435\u0440\u043d\u044b\u0439 \u0444\u043e\u0440\u043c\u0430\u0442';
        _isValidating = false;
      });
    }
  }

  Future<void> _updateClipboardAvailability() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    setState(() => _canPaste = text.isNotEmpty);
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted || text.isEmpty) return;
    _inputController.text = text;
  }

  Future<void> _scanQr() async {
    if (_scanning || widget.onScanQr == null) return;
    _inputFocus.unfocus();
    setState(() => _scanning = true);
    try {
      final input = await widget.onScanQr!();
      if (mounted && input != null) _inputController.text = input;
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  bool get _isProfile => isProxyUri(_inputController.text.trim());
  bool get _isValidInput =>
      _inputController.text.isNotEmpty &&
      (isSecureProxyUri(_inputController.text.trim()) ||
          SubscriptionService().isValidSubscriptionUrl(
            _inputController.text.trim(),
          ));
  bool get _isComplete => _isValidInput && !_isValidating && !_scanning;

  @override
  Widget build(BuildContext context) {
    return NeuraOverlayDialog(
      title: const Text(
        '\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c \u043f\u0440\u043e\u0444\u0438\u043b\u044c/\u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0443',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('\u041e\u0442\u043c\u0435\u043d\u0430'),
        ),
        FilledButton(
          onPressed: _isComplete
              ? () {
                  final input = _inputController.text.trim();
                  Navigator.pop(context, {
                    'input': input,
                    'name': '',
                    'isProfile': _isProfile,
                  });
                }
              : null,
          child: const Text('\u0414\u043e\u0431\u0430\u0432\u0438\u0442\u044c'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _inputController,
            focusNode: _inputFocus,
            maxLines: 1,
            style: const TextStyle(color: Colors.white),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Подписка или ключ',
              hintText: 'https://..., vless://..., hy2://...',
              helperText: _detectedType,
              helperMaxLines: 5,
              helperStyle: TextStyle(
                color: _isValidating
                    ? Colors.white.withOpacity(0.6)
                    : (_isValidInput ? NeuraUi.success : NeuraUi.danger),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isProfile
                ? _detectedType
                : '\u0422\u0438\u043f: \u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0430',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.55),
            ),
          ),
          const SizedBox(height: 16),
          if (widget.onScanQr != null) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _scanning ? null : _scanQr,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                label: const Text('Сканировать QR'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _canPaste ? _pasteFromClipboard : null,
              icon: const Icon(Icons.content_paste, size: 18),
              label: const Text(
                '\u0412\u0441\u0442\u0430\u0432\u0438\u0442\u044c \u0438\u0437 \u0431\u0443\u0444\u0435\u0440\u0430',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
