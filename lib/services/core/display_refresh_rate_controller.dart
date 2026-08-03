// 文件说明：控制移动端窗口刷新率策略，并持久化省电模式偏好。

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DisplayRefreshRateController {
  DisplayRefreshRateController({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const String preferenceKey = 'power_saving_mode_v1';
  static const String _channelName = 'com.niki.xxread/fullscreen';

  final MethodChannel _channel;

  static Future<void> applySavedPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(preferenceKey) ?? false;
    await DisplayRefreshRateController().apply(enabled);
  }

  Future<void> apply(bool powerSavingMode) async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setPowerSavingMode', {
        'enabled': powerSavingMode,
      });
    } on PlatformException {
      // 部分设备或旧平台实现不支持动态切换刷新率，保留用户偏好即可。
    } on MissingPluginException {
      // 单元测试或未接入原生实现的平台没有对应通道。
    }
  }
}
