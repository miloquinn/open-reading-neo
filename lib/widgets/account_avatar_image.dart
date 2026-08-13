import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/account/account_avatar_cache.dart';
import 'image_decode_retry_controller.dart';

class AccountAvatarImage extends StatefulWidget {
  const AccountAvatarImage({
    super.key,
    required this.url,
    required this.fallback,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    this.cache,
  });

  final Uri url;
  final Widget fallback;
  final double width;
  final double height;
  final BoxFit fit;
  final AccountAvatarCache? cache;

  @override
  State<AccountAvatarImage> createState() => _AccountAvatarImageState();
}

class _AccountAvatarImageState extends State<AccountAvatarImage> {
  late Future<Uint8List> _bytes;
  final _decodeRetry = ImageDecodeRetryController();

  AccountAvatarCache get _cache => widget.cache ?? AccountAvatarCache.instance;

  @override
  void initState() {
    super.initState();
    _bytes = _cache.load(widget.url);
  }

  @override
  void didUpdateWidget(covariant AccountAvatarImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.cache != widget.cache) {
      _decodeRetry.reset();
      _bytes = _cache.load(widget.url);
    }
  }

  void _retryAfterDecodeFailure() {
    _decodeRetry.schedule(
      isMounted: () => mounted,
      evict: () => _cache.evict(widget.url),
      reload: () => setState(() {
        _bytes = _cache.load(widget.url);
      }),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      if (bytes == null) return widget.fallback;
      return Image.memory(
        bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        cacheWidth: (widget.width * MediaQuery.devicePixelRatioOf(context))
            .round(),
        cacheHeight: (widget.height * MediaQuery.devicePixelRatioOf(context))
            .round(),
        errorBuilder: (_, _, _) {
          _retryAfterDecodeFailure();
          return widget.fallback;
        },
      );
    },
  );
}
