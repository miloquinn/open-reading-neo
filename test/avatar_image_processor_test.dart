import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/account/account.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('avatar processor resizes and re-encodes the selected image', () async {
    final source = await _png(width: 1200, height: 800);

    final upload = await const AvatarImageProcessor().compress(source);
    final codec = await ui.instantiateImageCodec(upload.bytes);
    final frame = await codec.getNextFrame();

    expect(upload.filename, 'avatar.png');
    expect(upload.contentType, 'image/png');
    expect(frame.image.width, 512);
    expect(frame.image.height, 341);
    expect(upload.bytes.length, lessThan(AvatarImageProcessor.maxOutputBytes));

    frame.image.dispose();
    codec.dispose();
  });

  test('avatar processor rejects corrupt input', () async {
    await expectLater(
      const AvatarImageProcessor().compress(Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<AvatarProcessingException>().having(
          (error) => error.message,
          'message',
          '头像文件无法读取',
        ),
      ),
    );
  });

  test(
    'avatar processor crops a square selection before compression',
    () async {
      final source = await _png(width: 1200, height: 800);

      final upload = await const AvatarImageProcessor().cropAndCompress(
        source,
        sourceRect: const ui.Rect.fromLTWH(200, 0, 800, 800),
      );
      final codec = await ui.instantiateImageCodec(upload.bytes);
      final frame = await codec.getNextFrame();

      expect(frame.image.width, 512);
      expect(frame.image.height, 512);
      expect(
        upload.bytes.length,
        lessThan(AvatarImageProcessor.maxOutputBytes),
      );

      frame.image.dispose();
      codec.dispose();
    },
  );
}

Future<Uint8List> _png({required int width, required int height}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xff2678c9),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  if (data == null) throw StateError('PNG encode failed');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}
