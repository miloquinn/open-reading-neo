import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/settings/sync/webdav_setup_page.dart';
import 'package:xxread/pages/settings/sync/webdav_sync_content_page.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';

void main() {
  setUpAll(() async {
    for (final entry in {
      'SyncPreview': const String.fromEnvironment('SYNC_PREVIEW_FONT'),
      'MaterialIcons': const String.fromEnvironment('SYNC_PREVIEW_ICON_FONT'),
    }.entries) {
      if (entry.value.isEmpty) continue;
      final bytes = await File(entry.value).readAsBytes();
      await (FontLoader(
        entry.key,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });

  testWidgets('WebDAV setup keeps connection actions clear and guarded', (
    tester,
  ) async {
    final controller = _SuccessfulConnectionController();
    addTearDown(controller.dispose);
    final previewKey = GlobalKey();
    await _setPhoneSurface(tester);
    await tester.pumpWidget(
      _testApp(
        controller,
        RepaintBoundary(key: previewKey, child: const WebDavSetupPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('webdav-connection-header')), findsOne);
    expect(find.byKey(const ValueKey('webdav-test-action')), findsOne);
    expect(find.byKey(const ValueKey('webdav-save-action')), findsOne);
    expect(
      tester.getSize(find.byKey(const ValueKey('webdav-test-action'))).width,
      greaterThan(320),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('webdav-save-action')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'WebDAV 地址'),
      'https://dav.example.test',
    );
    await tester.enterText(find.widgetWithText(TextFormField, '用户名'), 'niki');
    await tester.enterText(
      find.widgetWithText(TextFormField, '应用密码'),
      'app-password',
    );
    await tester.tap(find.byKey(const ValueKey('webdav-test-action')));
    await tester.pumpAndSettle();

    expect(find.text('连接与写入权限验证成功'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('webdav-save-action')),
          )
          .onPressed,
      isNotNull,
    );
    await _writePreview(tester, previewKey, 'webdav-setup-light.png');
  });

  testWidgets(
    'Other sync content contains data and preferences without duplicate progress or file controls',
    (tester) async {
      final store = SecureSyncConfigStore(
        secretStorage: _MemorySecrets(),
        preferences: _MemoryPreferences(),
      );
      final controller = _ScopeController(store);
      addTearDown(controller.dispose);
      final previewKey = GlobalKey();
      await _setPhoneSurface(tester);
      await tester.pumpWidget(
        _testApp(
          controller,
          RepaintBoundary(
            key: previewKey,
            child: const WebDavSyncContentPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('webdav-reading-data-section')),
        findsOne,
      );
      expect(
        find.byKey(const ValueKey('webdav-reading-preferences-section')),
        findsOne,
      );
      expect(
        find.byKey(const ValueKey('webdav-book-files-section')),
        findsNothing,
      );
      expect(find.text('数据与同步'), findsOneWidget);
      expect(find.text('阅读设置'), findsOneWidget);
      expect(find.text('书籍文件'), findsNothing);

      expect(find.widgetWithText(SwitchListTile, '阅读进度'), findsNothing);
      final progress = find.widgetWithText(SwitchListTile, '书签');
      await tester.tap(progress);
      await tester.pumpAndSettle();
      expect(controller.scope.bookmarks, isFalse);
      expect((await store.readScope()).bookmarks, isFalse);
      await _writePreview(tester, previewKey, 'webdav-content-light.png');
    },
  );

  testWidgets('secondary WebDAV pages support narrow dark large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final setupController = _SuccessfulConnectionController();
    addTearDown(setupController.dispose);
    final setupKey = GlobalKey();
    await tester.pumpWidget(
      _testApp(
        setupController,
        RepaintBoundary(key: setupKey, child: const WebDavSetupPage()),
        brightness: Brightness.dark,
        textScaler: const TextScaler.linear(1.6),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接信息'), findsOneWidget);
    expect(find.byKey(const ValueKey('webdav-test-action')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _writePreview(tester, setupKey, 'webdav-setup-dark-large-text.png');

    final store = SecureSyncConfigStore(
      secretStorage: _MemorySecrets(),
      preferences: _MemoryPreferences(),
    );
    final contentController = _ScopeController(store);
    addTearDown(contentController.dispose);
    final contentKey = GlobalKey();
    await tester.pumpWidget(
      _testApp(
        contentController,
        RepaintBoundary(key: contentKey, child: const WebDavSyncContentPage()),
        brightness: Brightness.dark,
        textScaler: const TextScaler.linear(1.6),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('数据与同步'), findsOneWidget);
    expect(find.text('阅读设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _writePreview(
      tester,
      contentKey,
      'webdav-content-dark-large-text.png',
    );
  });
}

Future<void> _setPhoneSurface(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

Widget _testApp(
  WebDavSyncController controller,
  Widget home, {
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return ChangeNotifierProvider<WebDavSyncController>.value(
    value: controller,
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorSchemeSeed: const Color(0xFF46658B),
        fontFamily: const String.fromEnvironment('SYNC_PREVIEW_FONT').isEmpty
            ? null
            : 'SyncPreview',
      ),
      locale: const Locale('zh'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: home,
    ),
  );
}

Future<void> _writePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  const previewDir = String.fromEnvironment('SYNC_PREVIEW_DIR');
  if (previewDir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(previewDir).create(recursive: true);
    await File('$previewDir/$name').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

class _SuccessfulConnectionController extends WebDavSyncController {
  @override
  Future<ConnectionTestResult> testConnection(
    WebDavSyncConfigDraft draft,
  ) async => const ConnectionTestResult(success: true);
}

class _ScopeController extends WebDavSyncController {
  _ScopeController(this.store) : super(configStore: store);

  final SecureSyncConfigStore store;
  WebDavSyncScope value = const WebDavSyncScope();

  @override
  bool get isConfigured => true;

  @override
  WebDavSyncScope get scope => value;

  @override
  Future<void> setScope(WebDavSyncScope scope) async {
    await store.saveScope(scope);
    value = scope;
    notifyListeners();
  }
}

class _MemoryPreferences implements SyncPreferences {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class _MemorySecrets implements SyncSecretStorage {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
