import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/home/widgets/home_tablet_top_backdrop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fades real backdrop blur and leaves a fully clear tail', (
    tester,
  ) async {
    final blurred = await _renderBackdrop(tester, blurEnabled: true);
    final unblurred = await _renderBackdrop(tester, blurEnabled: false);

    final topRatio = _contrastRatio(blurred, unblurred, y: 9);
    final middleRatio = _contrastRatio(blurred, unblurred, y: 43);
    final lowerRatio = _contrastRatio(blurred, unblurred, y: 75);

    expect(topRatio, lessThan(middleRatio));
    expect(middleRatio, lessThan(lowerRatio));
    expect(topRatio, lessThan(0.45));
    expect(lowerRatio, greaterThan(0.65));

    for (final point in const [
      Offset(3, 88),
      Offset(9, 88),
      Offset(33, 94),
      Offset(81, 99),
    ]) {
      expect(
        blurred.pixel(point.dx.toInt(), point.dy.toInt()),
        unblurred.pixel(point.dx.toInt(), point.dy.toInt()),
        reason: 'The bottom 16dp must contain neither blur nor tint at $point.',
      );
      expect(
        blurred.pixel(point.dx.toInt(), point.dy.toInt()),
        _checkerColorAt(point.dx.toInt(), point.dy.toInt()),
        reason:
            'The clear tail must preserve the exact backdrop pixel at $point.',
      );
    }
  });

  testWidgets('disabled blur keeps the tint but omits the backdrop filter', (
    tester,
  ) async {
    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      _TestScene(boundaryKey: boundaryKey, blurEnabled: false),
    );
    await tester.pump();

    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(HomeTabletTopBackdrop), findsOneWidget);
    expect(
      tester
          .widget<IgnorePointer>(
            find.descendant(
              of: find.byType(HomeTabletTopBackdrop),
              matching: find.byType(IgnorePointer),
            ),
          )
          .ignoring,
      isTrue,
    );

    final pixels = (await tester.runAsync(() => _capture(boundaryKey)))!;

    expect(pixels.pixel(3, 4), isNot(_checkerColorAt(3, 4)));
    expect(pixels.pixel(3, 90), _checkerColorAt(3, 90));
    expect(pixels.pixel(9, 90), _checkerColorAt(9, 90));
  });
}

const _sceneSize = Size(108, 116);
const _backdropHeight = 100.0;
const _checkerCellSize = 6;
const _dark = Color(0xFF101010);
const _light = Color(0xFFF0F0F0);

Future<_PixelBuffer> _renderBackdrop(
  WidgetTester tester, {
  required bool blurEnabled,
}) async {
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    _TestScene(boundaryKey: boundaryKey, blurEnabled: blurEnabled),
  );
  await tester.pump();
  return (await tester.runAsync(() => _capture(boundaryKey)))!;
}

Future<_PixelBuffer> _capture(GlobalKey boundaryKey) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return _PixelBuffer(
    data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    _sceneSize.width.toInt(),
  );
}

double _contrastRatio(
  _PixelBuffer blurred,
  _PixelBuffer unblurred, {
  required int y,
}) {
  final blurredContrast = _contrast(blurred.pixel(3, y), blurred.pixel(9, y));
  final unblurredContrast = _contrast(
    unblurred.pixel(3, y),
    unblurred.pixel(9, y),
  );
  return blurredContrast / unblurredContrast;
}

double _contrast(Color first, Color second) {
  final red = (first.r - second.r).abs();
  final green = (first.g - second.g).abs();
  final blue = (first.b - second.b).abs();
  return (red + green + blue) / 3;
}

Color _checkerColorAt(int x, int y) {
  final isLight = (x ~/ _checkerCellSize + y ~/ _checkerCellSize).isEven;
  return isLight ? _light : _dark;
}

class _TestScene extends StatelessWidget {
  const _TestScene({required this.boundaryKey, required this.blurEnabled});

  final GlobalKey boundaryKey;
  final bool blurEnabled;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          surface: Colors.white,
        ),
      ),
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: boundaryKey,
            child: SizedBox.fromSize(
              size: _sceneSize,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const CustomPaint(painter: _CheckerPainter()),
                  Align(
                    alignment: Alignment.topCenter,
                    child: HomeTabletTopBackdrop(
                      height: _backdropHeight,
                      controlsBottom: 60,
                      blurEnabled: blurEnabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (var y = 0; y < size.height; y += _checkerCellSize) {
      for (var x = 0; x < size.width; x += _checkerCellSize) {
        paint.color = _checkerColorAt(x, y);
        canvas.drawRect(
          Rect.fromLTWH(
            x.toDouble(),
            y.toDouble(),
            _checkerCellSize.toDouble(),
            _checkerCellSize.toDouble(),
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CheckerPainter oldDelegate) => false;
}

class _PixelBuffer {
  _PixelBuffer(this.bytes, this.width);

  final Uint8List bytes;
  final int width;

  Color pixel(int x, int y) {
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      bytes[offset + 3],
      bytes[offset],
      bytes[offset + 1],
      bytes[offset + 2],
    );
  }
}
