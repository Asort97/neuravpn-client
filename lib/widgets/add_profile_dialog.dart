import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/subscription_manager.dart';
import 'neura_ui.dart';

class AddProfileDialog extends StatefulWidget {
  const AddProfileDialog({super.key});

  @override
  State<AddProfileDialog> createState() => _AddProfileDialogState();
}

class _AddProfileDialogState extends State<AddProfileDialog> {
  late TextEditingController _inputController;
  late FocusNode _inputFocus;
  String _detectedType = '\u041e\u043f\u0440\u0435\u0434\u0435\u043b\u0435\u043d\u0438\u0435...';
  bool _isValidating = false;
  bool _canPaste = false;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();
    _inputController.addListener(_detectType);
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
        _detectedType = '\u0412\u0432\u0435\u0434\u0438\u0442\u0435 URL \u0438\u043b\u0438 VLESS \u043a\u043b\u044e\u0447';
        _isValidating = false;
      });
      return;
    }

    if (input.startsWith('vless://')) {
      setState(() {
        _detectedType = '\u042d\u0442\u043e VLESS \u043a\u043b\u044e\u0447';
        _isValidating = false;
      });
      return;
    }

    final manager = SubscriptionService();
    if (manager.isValidSubscriptionUrl(input)) {
      setState(() {
        _detectedType = '\u042d\u0442\u043e \u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0430 URL';
        _isValidating = false;
      });
    } else {
      setState(() {
        _detectedType = '\u041d\u0435\u0432\u0435\u0440\u043d\u044b\u0439 \u0444\u043e\u0440\u043c\u0430\u0442';
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
    if (text.isEmpty) return;
    _inputController.text = text;
  }

  bool get _isVless => _inputController.text.trim().startsWith('vless://');
  bool get _isValidInput => _inputController.text.isNotEmpty &&
      (_isVless ||
          SubscriptionService().isValidSubscriptionUrl(_inputController.text.trim()));
  bool get _isComplete => _isValidInput && !_isValidating;

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
                  Navigator.pop(
                    context,
                    {
                      'input': input,
                      'name': '',
                      'isVless': _isVless,
                    },
                  );
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
              labelText: 'URL \u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0438 \u0438\u043b\u0438 VLESS \u043a\u043b\u044e\u0447',
              hintText: 'vless://... \u0438\u043b\u0438 https://...',
              helperText: _detectedType,
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
            _isVless
                ? '\u0422\u0438\u043f: VLESS \u043a\u043b\u044e\u0447'
                : '\u0422\u0438\u043f: \u043f\u043e\u0434\u043f\u0438\u0441\u043a\u0430',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.55),
            ),
          ),
          const SizedBox(height: 16),
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
