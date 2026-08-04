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

class AvatarImageInfo {
  const AvatarImageInfo({required this.width, required this.height});

  final int width;
  final int height;
}

class AvatarImageProcessor {
  const AvatarImageProcessor();

  static const maxDimension = 512;
  static const maxInputBytes = 25 * 1024 * 1024;
  static const maxPixels = 20 * 1000 * 1000;
  static const maxOutputBytes = 2 * 1024 * 1024;

  Future<AvatarImageInfo> inspect(Uint8List sourceBytes) async {
    _validateInput(sourceBytes);
    ui.Codec? codec;
    ui.Image? source;
    try {
      codec = await ui.instantiateImageCodec(sourceBytes);
      final frame = await codec.getNextFrame();
      source = frame.image;
      _validateDimensions(source);
      return AvatarImageInfo(width: source.width, height: source.height);
    } on AvatarProcessingException {
      rethrow;
    } catch (_) {
      throw const AvatarProcessingException('头像文件无法读取');
    } finally {
      source?.dispose();
      codec?.dispose();
    }
  }

  Future<AvatarUploadData> compress(Uint8List sourceBytes) async {
    return cropAndCompress(sourceBytes);
  }

  Future<AvatarUploadData> cropAndCompress(
    Uint8List sourceBytes, {
    ui.Rect? sourceRect,
  }) async {
    _validateInput(sourceBytes);

    ui.Codec? codec;
    ui.Image? source;
    ui.Image? resized;
    ui.Picture? picture;
    try {
      codec = await ui.instantiateImageCodec(sourceBytes);
      final frame = await codec.getNextFrame();
      source = frame.image;
      _validateDimensions(source);

      final imageBounds = ui.Rect.fromLTWH(
        0,
        0,
        source.width.toDouble(),
        source.height.toDouble(),
      );
      final crop = sourceRect == null
          ? imageBounds
          : sourceRect.intersect(imageBounds);
      if (crop.isEmpty || crop.width < 1 || crop.height < 1) {
        throw const AvatarProcessingException('头像裁剪区域无效');
      }
      final longestSide = crop.width > crop.height ? crop.width : crop.height;
      final outputScale = longestSide > maxDimension
          ? maxDimension / longestSide
          : 1.0;
      final targetWidth = (crop.width * outputScale).round().clamp(
        1,
        maxDimension,
      );
      final targetHeight = (crop.height * outputScale).round().clamp(
        1,
        maxDimension,
      );

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        source,
        crop,
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

  void _validateInput(Uint8List sourceBytes) {
    if (sourceBytes.isEmpty) {
      throw const AvatarProcessingException('头像文件为空');
    }
    if (sourceBytes.length > maxInputBytes) {
      throw const AvatarProcessingException('头像原图不能超过 25 MiB');
    }
  }

  void _validateDimensions(ui.Image source) {
    if (source.width <= 0 ||
        source.height <= 0 ||
        source.width * source.height > maxPixels) {
      throw const AvatarProcessingException('头像尺寸过大');
    }
  }
}
