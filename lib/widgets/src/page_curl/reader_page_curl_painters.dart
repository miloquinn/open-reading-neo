part of '../../reader_shader_page_curl.dart';

/// Amount of mirrored front-page ink visible through the phone curl's back.
///
/// The remaining 64% comes from the active reader theme's paper color. Tablet
/// spreads provide a real reverse-page snapshot and do not use this value.
const double readerPhonePageCurlBackInkOpacity = 0.36;

class _ReaderClassicFoldPainter extends CustomPainter {
  const _ReaderClassicFoldPainter({
    required this.shader,
    required this.sourcePage,
    required this.backPage,
    required this.paperColor,
    required this.geometry,
    required this.bindingEdge,
    required this.bindingOverflow,
  });

  final ui.FragmentShader shader;
  final ui.Image sourcePage;
  final ui.Image? backPage;
  final Color paperColor;
  final ReaderPageTurnGeometry geometry;
  final ReaderPageBindingEdge bindingEdge;
  final double bindingOverflow;

  @override
  void paint(Canvas canvas, Size size) {
    var index = 0;
    shader
      ..setFloat(index++, size.width)
      ..setFloat(index++, size.height)
      ..setFloat(index++, geometry.canonicalLineA.dx)
      ..setFloat(index++, geometry.canonicalLineA.dy)
      ..setFloat(index++, geometry.canonicalLineB.dx)
      ..setFloat(index++, geometry.canonicalLineB.dy)
      ..setFloat(index++, bindingEdge == ReaderPageBindingEdge.right ? 1 : 0)
      ..setFloat(index++, backPage == null ? 0 : 1)
      ..setFloat(index++, paperColor.r)
      ..setFloat(index++, paperColor.g)
      ..setFloat(index++, paperColor.b)
      ..setFloat(index++, readerPhonePageCurlBackInkOpacity)
      ..setImageSampler(0, sourcePage)
      ..setImageSampler(1, backPage ?? sourcePage);
    final paintBounds = bindingEdge == ReaderPageBindingEdge.left
        ? Rect.fromLTRB(-bindingOverflow, 0, size.width, size.height)
        : Rect.fromLTRB(0, 0, size.width + bindingOverflow, size.height);
    canvas.drawRect(paintBounds, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant _ReaderClassicFoldPainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.bindingEdge != bindingEdge ||
      oldDelegate.bindingOverflow != bindingOverflow ||
      oldDelegate.paperColor != paperColor ||
      !identical(oldDelegate.sourcePage, sourcePage) ||
      !identical(oldDelegate.backPage, backPage);
}

class _ReaderFallbackTurnPainter extends CustomPainter {
  const _ReaderFallbackTurnPainter({
    required this.sourcePage,
    required this.backPage,
    required this.geometry,
    required this.bindingOverflow,
  });

  final ui.Image sourcePage;
  final ui.Image? backPage;
  final ReaderPageTurnGeometry geometry;
  final double bindingOverflow;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final turnExtent = bindingOverflow > 0 ? bindingOverflow : size.width;
    final canonicalOffset = switch (geometry.motion) {
      ReaderPageTurnMotion.outgoing => -turnExtent * geometry.progress,
      ReaderPageTurnMotion.incoming => -turnExtent * (1 - geometry.progress),
    };
    final offset = geometry.bindingOnRight ? -canonicalOffset : canonicalOffset;
    canvas.translate(offset, 0);
    final visiblePage = backPage != null && geometry.progress >= 0.5
        ? backPage!
        : sourcePage;
    _drawPageImage(canvas, visiblePage, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReaderFallbackTurnPainter oldDelegate) =>
      oldDelegate.geometry != geometry ||
      oldDelegate.bindingOverflow != bindingOverflow ||
      !identical(oldDelegate.sourcePage, sourcePage) ||
      !identical(oldDelegate.backPage, backPage);
}

void _drawPageImage(Canvas canvas, ui.Image image, Size size) {
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    Offset.zero & size,
    Paint()..filterQuality = FilterQuality.medium,
  );
}
