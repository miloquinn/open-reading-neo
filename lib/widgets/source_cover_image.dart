import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../book_sources/caching/source_cover_cache.dart';
import 'image_decode_retry_controller.dart';

class SourceCoverImage extends StatefulWidget {
  const SourceCoverImage({
    super.key,
    required this.url,
    required this.fallback,
    this.cache,
    this.headers = const {},
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.cacheHeight,
    this.alignment = Alignment.center,
  });

  final Uri url;
  final Widget fallback;
  final SourceCoverCache? cache;
  final Map<String, String> headers;
  final double? width;
  final double? height;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final AlignmentGeometry alignment;

  @override
  State<SourceCoverImage> createState() => _SourceCoverImageState();
}

class _SourceCoverImageState extends State<SourceCoverImage> {
  late Future<Uint8List> _bytes;
  final _decodeRetry = ImageDecodeRetryController();

  SourceCoverCache get _cache => widget.cache ?? SourceCoverCache.instance;

  @override
  void initState() {
    super.initState();
    _bytes = _cache.load(widget.url, headers: widget.headers);
  }

  @override
  void didUpdateWidget(covariant SourceCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.cache != widget.cache ||
        !mapEquals(oldWidget.headers, widget.headers)) {
      _decodeRetry.reset();
      _bytes = _cache.load(widget.url, headers: widget.headers);
    }
  }

  void _retryAfterDecodeFailure() {
    _decodeRetry.schedule(
      isMounted: () => mounted,
      evict: () => _cache.evict(widget.url, headers: widget.headers),
      reload: () => setState(() {
        _bytes = _cache.load(widget.url, headers: widget.headers);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return widget.fallback;
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          alignment: widget.alignment,
          cacheWidth: widget.cacheWidth,
          cacheHeight: widget.cacheHeight,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) {
            _retryAfterDecodeFailure();
            return widget.fallback;
          },
        );
      },
    );
  }
}
