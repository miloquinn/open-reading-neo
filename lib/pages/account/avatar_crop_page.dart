import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/account/account.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';

class AvatarCropPage extends StatefulWidget {
  const AvatarCropPage({
    super.key,
    required this.bytes,
    required this.imageInfo,
  });

  final Uint8List bytes;
  final AvatarImageInfo imageInfo;

  @override
  State<AvatarCropPage> createState() => _AvatarCropPageState();
}

class _AvatarCropPageState extends State<AvatarCropPage> {
  double _zoom = 1;
  Offset _offset = Offset.zero;
  double _startZoom = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocalPoint = Offset.zero;
  double _viewportSize = 0;

  void _startGesture(ScaleStartDetails details) {
    _startZoom = _zoom;
    _startOffset = _offset;
    _startFocalPoint = details.localFocalPoint;
  }

  void _updateGesture(ScaleUpdateDetails details) {
    if (_viewportSize <= 0) return;
    final nextZoom = (_startZoom * details.scale).clamp(1.0, 5.0);
    final center = Offset(_viewportSize / 2, _viewportSize / 2);
    final focal = details.localFocalPoint;
    final ratio = nextZoom / _startZoom;
    final zoomAdjusted =
        focal - center - (focal - center - _startOffset) * ratio;
    final translated = zoomAdjusted + (focal - _startFocalPoint);
    setState(() {
      _zoom = nextZoom;
      _offset = _clampOffset(translated, nextZoom);
    });
  }

  Offset _clampOffset(Offset offset, double zoom) {
    final size = _baseImageSize(_viewportSize);
    final maxX = math.max(0.0, (size.width * zoom - _viewportSize) / 2);
    final maxY = math.max(0.0, (size.height * zoom - _viewportSize) / 2);
    return Offset(offset.dx.clamp(-maxX, maxX), offset.dy.clamp(-maxY, maxY));
  }

  Size _baseImageSize(double viewport) {
    final width = widget.imageInfo.width.toDouble();
    final height = widget.imageInfo.height.toDouble();
    final coverScale = math.max(viewport / width, viewport / height);
    return Size(width * coverScale, height * coverScale);
  }

  ui.Rect _sourceCropRect() {
    final sourceWidth = widget.imageInfo.width.toDouble();
    final sourceHeight = widget.imageInfo.height.toDouble();
    final baseSize = _baseImageSize(_viewportSize);
    final pixelsPerSourcePixel = baseSize.width / sourceWidth * _zoom;
    final cropSize = _viewportSize / pixelsPerSourcePixel;
    final centerX = sourceWidth / 2 - _offset.dx / pixelsPerSourcePixel;
    final centerY = sourceHeight / 2 - _offset.dy / pixelsPerSourcePixel;
    return ui.Rect.fromCenter(
      center: Offset(centerX, centerY),
      width: cropSize,
      height: cropSize,
    );
  }

  void _confirm() {
    Navigator.of(context).pop(_sourceCropRect());
  }

  @override
  Widget build(BuildContext context) => FloatingSubpageScaffold(
    title: context.l10n.accountAvatarCropTitle,
    actions: [
      FloatingSubpageAction(
        key: const ValueKey('avatar-crop-confirm'),
        tooltip: context.l10n.confirm,
        onPressed: _confirm,
        icon: Icons.check_rounded,
      ),
    ],
    body: LayoutBuilder(
      builder: (context, constraints) {
        final viewport = math
            .min(constraints.maxWidth - 40, constraints.maxHeight - 140)
            .clamp(160.0, 560.0);
        _viewportSize = viewport;
        final imageSize = _baseImageSize(viewport);
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                context.l10n.accountAvatarCropHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(
              child: SizedBox.square(
                dimension: viewport,
                child: GestureDetector(
                  key: const ValueKey('avatar-crop-gesture'),
                  onScaleStart: _startGesture,
                  onScaleUpdate: _updateGesture,
                  child: ClipOval(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: Transform.translate(
                              offset: _offset,
                              child: Transform.scale(
                                scale: _zoom,
                                child: SizedBox(
                                  width: imageSize.width,
                                  height: imageSize.height,
                                  child: Image.memory(
                                    widget.bytes,
                                    fit: BoxFit.fill,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
