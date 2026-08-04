import 'dart:typed_data';
import 'dart:ui' as ui;

class AvatarProcessingException implements Exception {
  const AvatarProcessingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AvatarUploadData {
  const AvatarUploadData({
    required this.bytes,
    this.filename = 'avatar.png',
    this.contentType = 'image/png',
  });

  final Uint8List bytes;
  final String filename;
  final String contentType;
}

class AvatarImageProcessor {
  const AvatarImageProcessor();

  static const maxDimension = 512;
  static const maxInputBytes = 25 * 1024 * 1024;
  static const maxPixels = 20 * 1000 * 1000;
  static const maxOutputBytes = 2 * 1024 * 1024;

  Future<AvatarUploadData> compress(Uint8List sourceBytes) async {
    if (sourceBytes.isEmpty) {
      throw const AvatarProcessingException('头像文件为空');
    }
    if (sourceBytes.length > maxInputBytes) {
      throw const AvatarProcessingException('头像原图不能超过 25 MiB');
    }

    ui.Codec? codec;
    ui.Image? source;
    ui.Image? resized;
    ui.Picture? picture;
    try {
      codec = await ui.instantiateImageCodec(sourceBytes);
      final frame = await codec.getNextFrame();
      source = frame.image;
      if (source.width <= 0 ||
          source.height <= 0 ||
          source.width * source.height > maxPixels) {
        throw const AvatarProcessingException('头像尺寸过大');
      }

      final scale = source.width >= source.height
          ? maxDimension / source.width
          : maxDimension / source.height;
      final boundedScale = scale < 1 ? scale : 1.0;
      final targetWidth = (source.width * boundedScale).round().clamp(
        1,
        maxDimension,
      );
      final targetHeight = (source.height * boundedScale).round().clamp(
        1,
        maxDimension,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        ui.Rect.fromLTWH(
          0,
          0,
          source.width.toDouble(),
          source.height.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      picture = recorder.endRecording();
      resized = await picture.toImage(targetWidth, targetHeight);
      final encoded = await resized.toByteData(format: ui.ImageByteFormat.png);
      if (encoded == null) {
        throw const AvatarProcessingException('头像压缩失败');
      }
      final bytes = encoded.buffer.asUint8List(
        encoded.offsetInBytes,
        encoded.lengthInBytes,
      );
      if (bytes.length > maxOutputBytes) {
        throw const AvatarProcessingException('头像压缩后仍然过大');
      }
      return AvatarUploadData(bytes: Uint8List.fromList(bytes));
    } on AvatarProcessingException {
      rethrow;
    } catch (_) {
      throw const AvatarProcessingException('头像文件无法读取');
    } finally {
      resized?.dispose();
      picture?.dispose();
      source?.dispose();
      codec?.dispose();
    }
  }
}
