import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Adds keyboard and mouse-wheel page turning to a reader surface.
///
/// Pointer scrolling is opt-in so vertically scrolling readers can keep their
/// native pixel scrolling while still using the keyboard callbacks below.
class ReaderDesktopInput extends StatefulWidget {
  const ReaderDesktopInput({
    super.key,
    required this.child,
    required this.onNext,
    required this.onPrevious,
    this.enabled = true,
    this.turnPageOnPointerScroll = true,
  });

  final Widget child;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final bool enabled;
  final bool turnPageOnPointerScroll;

  @override
  State<ReaderDesktopInput> createState() => _ReaderDesktopInputState();
}

class _ReaderDesktopInputState extends State<ReaderDesktopInput> {
  static const double _pointerTurnThreshold = 24;
  static const Duration _pointerIdleDelay = Duration(milliseconds: 180);

  final FocusNode _focusNode = FocusNode(debugLabel: 'reader-desktop-input');
  Timer? _pointerIdleTimer;
  double _pointerScrollAccumulator = 0;
  bool _pointerGestureLocked = false;

  @override
  void dispose() {
    _pointerIdleTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (!widget.enabled || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final shiftPressed = keyboard.isShiftPressed;
    final hasSystemModifier =
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed;
    if (key == LogicalKeyboardKey.space) {
      if (hasSystemModifier) return KeyEventResult.ignored;
      if (shiftPressed) {
        widget.onPrevious();
      } else {
        widget.onNext();
      }
      return KeyEventResult.handled;
    }
    if (shiftPressed || hasSystemModifier) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      widget.onPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      widget.onNext();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (!widget.enabled ||
        !widget.turnPageOnPointerScroll ||
        event is! PointerScrollEvent) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      _resolvePointerScroll,
    );
  }

  void _resolvePointerScroll(PointerSignalEvent signal) {
    final event = signal as PointerScrollEvent;
    final delta = event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;

    _pointerIdleTimer?.cancel();
    _pointerIdleTimer = Timer(_pointerIdleDelay, () {
      _pointerScrollAccumulator = 0;
      _pointerGestureLocked = false;
    });
    if (_pointerGestureLocked) return;

    _pointerScrollAccumulator += delta;
    if (_pointerScrollAccumulator.abs() < _pointerTurnThreshold) return;

    final turnsForward = _pointerScrollAccumulator > 0;
    _pointerScrollAccumulator = 0;
    _pointerGestureLocked = true;
    if (turnsForward) {
      widget.onNext();
    } else {
      widget.onPrevious();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (widget.enabled) _focusNode.requestFocus();
        },
        onPointerSignal: _handlePointerSignal,
        child: widget.child,
      ),
    );
  }
}
