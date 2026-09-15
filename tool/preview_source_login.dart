// flutter test tool/preview_source_login.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_login_ui.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/source_login_page.dart';
import 'package:xxread/utils/app_themes.dart';

class _PreviewClient extends BookSourceClient {
  @override
  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource source,
  ) async => [
    const SourceLoginField(name: '账号', type: 'text'),
    const SourceLoginField(name: '密码', type: 'password'),
    for (final name in [
      '登录书源',
      '注册书源',
      '退出登录',
      '用户后台',
      '书源设置中心',
      '检测登录',
      '打赏享福利',
      '更新书源',
      '番茄登录',
      '清空设置',
      '设置检测',
      '永久发布页',
      '清除设备',
      '切换服务器',
      '检测当前服务器',
      '使用教程',
      '发现页兼容',
    ])
      SourceLoginField(name: name, type: 'button', action: 'preview()'),
    const SourceLoginField(name: '自定义搜索源（多个用英文逗号分割）', type: 'text'),
    const SourceLoginField(name: '自定义服务器（可不填）', type: 'text'),
  ];
}

void main() {
  testWidgets('preview generic source login', (tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      final font = await File(
        '/System/Library/Fonts/Hiragino Sans GB.ttc',
      ).readAsBytes();
      await (FontLoader(
        'LoginPreview',
      )..addFont(Future.value(ByteData.sublistView(font)))).load();
      final root = Platform.resolvedExecutable.split('/bin/cache').first;
      final icons = await File(
        '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 20);
    addTearDown(tester.view.reset);
    final client = _PreviewClient();
    addTearDown(client.close);
    final source = ReadingSourceConfig.fromJson({
      'bookSourceName': '大灰狼聚合 · VIP 完全版',
      'bookSourceUrl': 'https://example.test',
      'loginUrl': 'function login() {}',
    }).toRegisteredSource();
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey(dark),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            useMaterial3: true,
            fontFamily: 'LoginPreview',
            colorScheme: ColorScheme.fromSeed(
              seedColor: AppThemes.defaultAccentColor,
              brightness: dark ? Brightness.dark : Brightness.light,
            ),
          ),
          builder: (context, child) =>
              RepaintBoundary(key: const Key('preview'), child: child!),
          home: SourceLoginPage(source: source, client: client),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const Key('preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('.omx/source-login-previews')
          ..createSync(recursive: true);
        await File(
          '${output.path}/${dark ? 'dark' : 'light'}.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
