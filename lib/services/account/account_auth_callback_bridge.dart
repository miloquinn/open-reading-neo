import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AccountAuthCallbackBridge {
  AccountAuthCallbackBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'com.niki.xxread/account_auth';
  final MethodChannel _channel;
  final _callbacks = StreamController<Uri>.broadcast();

  Stream<Uri> get callbacks => _callbacks.stream;

  Future<void> initialize() async {
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.linux) return;
    try {
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onAuthCallback') _add(call.arguments);
      });
      _add(await _channel.invokeMethod<String>('getInitialAuthCallback'));
    } on MissingPluginException {
      // Desktop/web/test hosts may not provide the native callback bridge.
    } on PlatformException {
      // A missing bridge must not block the normal polling fallback.
    }
  }

  void _add(Object? value) {
    if (value is! String) return;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'xxread' || uri.host != 'auth') return;
    _callbacks.add(uri);
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _callbacks.close();
  }
}
