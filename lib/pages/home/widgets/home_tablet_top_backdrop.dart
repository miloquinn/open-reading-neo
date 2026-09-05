import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../utils/glass_config.dart';

/// A top-edge backdrop whose blur fades continuously into the page content.
///
/// The last [_clearTail] logical pixels are fully transparent, so callers can
/// place this over scrolling content without leaving a visible horizontal edge.
class HomeTabletTopBackdrop extends StatelessWidget {
  const HomeTabletTopBackdrop({
    super.key,
    required this.height,
    required this.controlsBottom,
    this.blurEnabled = true,
  }) : assert(height >= 0);

  final double height;
  /// Keep the controls legible even when accessibility text makes them taller.
  final double controlsBottom;
  final bool blurEnabled;

  static const double _clearTail = 16;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final clearStart = height <= 0
        ? 0.0
        : ((height - _clearTail) / height).clamp(0.0, 1.0);
    final fadeStart = height <= 0
        ? 0.0
        : (controlsBottom / height).clamp(0.0, clearStart);
    final shouldBlur =
        blurEnabled &&
        !GlassEffectConfig.shouldDisableBlur &&
        GlassEffectConfig.appBarBlur > 0;

    return IgnorePointer(
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (shouldBlur)
              ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: GlassEffectConfig.appBarBlur,
                    sigmaY: GlassEffectConfig.appBarBlur,
                    tileMode: TileMode.clamp,
                  ),
                  blendMode: BlendMode.srcOver,
                  child: CustomPaint(
                    painter: _ProgressiveBlurEraser(
                      fadeStart: fadeStart,
                      clearStart: clearStart,
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surface.withValues(alpha: 0.92),
                    surface.withValues(alpha: 0.82),
                    surface.withValues(alpha: 0),
                    surface.withValues(alpha: 0),
                  ],
                  stops: [0, fadeStart, clearStart, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressiveBlurEraser extends CustomPainter {
  const _ProgressiveBlurEraser({
    required this.fadeStart,
    required this.clearStart,
  });

  final double fadeStart;
  final double clearStart;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // Paint inside BackdropFilter's layer: erase the filtered image gradually
    // to reveal the original page. An outer ShaderMask would isolate the layer
    // before the filter reads its backdrop and can lose the page behind it.
    final paint = Paint()
      ..blendMode = BlendMode.dstOut
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, size.height),
        const [
          Colors.transparent,
          Color(0x1FFFFFFF),
          Colors.white,
          Colors.white,
        ],
        [0, fadeStart, clearStart, 1],
      );

    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _ProgressiveBlurEraser oldDelegate) {
    return fadeStart != oldDelegate.fadeStart ||
        clearStart != oldDelegate.clearStart;
  }
}
