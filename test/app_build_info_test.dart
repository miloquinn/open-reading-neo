import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:xxread/services/core/app_build_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.niki.xxread/app_update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PackageInfo info;

  setUp(() {
    info = PackageInfo(
      appName: 'Origo',
      packageName: 'com.niki.xxread',
      version: '2.6.7',
      buildNumber: '260910001',
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'Android reads the canonical release build from the native channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getReleaseBuildNumber');
        return '260907001';
      });

      expect(await readAppReleaseBuildNumber(info), '260907001');
    },
  );

  test(
    'Android keeps the release build unknown when the native method is absent',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(await readAppReleaseBuildNumber(info), '');
    },
  );

  test(
    'Android keeps invalid or failed native release reads unknown',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final value in ['0', '-1', 'not-a-build', null]) {
        messenger.setMockMethodCallHandler(channel, (_) async => value);
        expect(await readAppReleaseBuildNumber(info), '');
      }
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'unavailable'),
      );
      expect(await readAppReleaseBuildNumber(info), '');
    },
  );

  test(
    'iOS returns PackageInfo without invoking the Android channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var invoked = false;
      messenger.setMockMethodCallHandler(channel, (_) async {
        invoked = true;
        return '260907001';
      });

      expect(await readAppReleaseBuildNumber(info), '260910001');
      expect(invoked, isFalse);
    },
  );
}
