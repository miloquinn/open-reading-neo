import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/core/display_refresh_rate_controller.dart';

Future<AppSettingsNotifier> _loadNotifier(
  DisplayRefreshRateController controller,
) async {
  final notifier = AppSettingsNotifier(
    displayRefreshRateController: controller,
  );
  if (notifier.isInitialized) return notifier;

  final initialized = Completer<void>();
  void listener() {
    if (notifier.isInitialized && !initialized.isCompleted) {
      initialized.complete();
    }
  }

  notifier.addListener(listener);
  listener();
  await initialized.future;
  notifier.removeListener(listener);
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/display_refresh_rate');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('power saving mode defaults off and persists changes', () async {
    final notifier = await _loadNotifier(
      DisplayRefreshRateController(channel: channel),
    );
    addTearDown(notifier.dispose);

    expect(notifier.powerSavingMode, isFalse);

    await notifier.setPowerSavingMode(true);

    final prefs = await SharedPreferences.getInstance();
    expect(notifier.powerSavingMode, isTrue);
    expect(prefs.getBool(DisplayRefreshRateController.preferenceKey), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setPowerSavingMode');
    expect(calls.single.arguments, {'enabled': true});
  });

  test('power saving mode restores from preferences', () async {
    SharedPreferences.setMockInitialValues({
      DisplayRefreshRateController.preferenceKey: true,
    });

    final notifier = await _loadNotifier(
      DisplayRefreshRateController(channel: channel),
    );
    addTearDown(notifier.dispose);

    expect(notifier.powerSavingMode, isTrue);
  });
}
