import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Hidden "clear chat history" confirmation, opened by pressing Tab.
///
/// Deliberately undiscoverable, like the Tab bypass on the holding page: it
/// is a maintenance shortcut for us, not a user-facing feature. Y confirms,
/// any other key cancels — so a stray keypress can only ever cancel.
///
/// Everything it clears is on-device. Conversation logs already written to
/// the worker's D1 database stay put; this never deletes anything
/// server-side.
///
/// Returns true only if the user pressed Y.
Future<bool> showClearHistoryPrompt(
  BuildContext context, {
  required String message,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _ClearHistoryDialog(message: message),
  );
  return confirmed ?? false;
}

class _ClearHistoryDialog extends StatefulWidget {
  final String message;

  const _ClearHistoryDialog({required this.message});

  @override
  State<_ClearHistoryDialog> createState() => _ClearHistoryDialogState();
}

class _ClearHistoryDialogState extends State<_ClearHistoryDialog> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Y confirms; every other key cancels, so there is no way to destroy
    // history by mashing keys.
    final confirmed = event.logicalKey == LogicalKeyboardKey.keyY;
    Navigator.of(context).pop(confirmed);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKey,
      autofocus: true,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(
          widget.message,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        content: const Text(
          'Press Y to confirm. Any other key cancels.\n\n'
          'This clears the copy stored on this device only.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Clear', style: TextStyle(color: theme.primaryColor)),
          ),
        ],
      ),
    );
  }
}
