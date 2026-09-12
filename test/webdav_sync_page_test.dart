import 'dart:async';
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
import 'package:xxread/pages/settings/sync/txt_sync_details_page.dart';
import 'package:xxread/pages/settings/sync/webdav_sync_content_page.dart';
import 'package:xxread/pages/settings/sync/webdav_sync_page.dart';
import 'package:xxread/services/sync/secure_sync_config.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/book_content_sync_service.dart';
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
  testWidgets('续读首页在宽屏可操作且连接参数不占据首屏', (tester) async {
    final store = SecureSyncConfigStore(
      secretStorage: _MemorySecrets(),
      preferences: _MemoryPreferences(),
    );
    final controller = _ScopeController(store);
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1080, 980));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final previewKey = GlobalKey();
    await tester.pumpWidget(
      _testApp(
        controller,
        RepaintBoundary(key: previewKey, child: const WebDavSyncPage()),
      ),
    );
    await tester.pumpAndSettle();
    final resume = find.widgetWithText(SwitchListTile, '打开书籍自动接续');
    expect(tester.widget<SwitchListTile>(resume).value, isTrue);
    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(await store.readAutoResume(), isFalse);
    expect(tester.widget<SwitchListTile>(resume).value, isFalse);
    await tester.tap(resume);
    await tester.pumpAndSettle();
    expect(await store.readAutoResume(), isTrue);
    expect(find.text('跨设备续读'), findsOneWidget);
    expect(find.text('WebDAV 地址'), findsNothing);
    expect(tester.takeException(), isNull);
    const previewDir = String.fromEnvironment('SYNC_PREVIEW_DIR');
    if (previewDir.isNotEmpty) {
      await tester.runAsync(() async {
        final boundary =
            previewKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(previewDir).create(recursive: true);
        await File(
          '$previewDir/cloud-sync-wide.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
  testWidgets('未配置概览在窄屏展示安全的主操作', (tester) async {
    final controller = WebDavSyncController();
    addTearDown(controller.dispose);

    await tester.binding.setSurfaceSize(const Size(360, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_testApp(controller, const WebDavSyncPage()));
    await tester.pumpAndSettle();

    expect(find.text('云端同步'), findsWidgets);
    expect(find.text('尚未配置'), findsWidgets);
    expect(find.text('设置 WebDAV'), findsOneWidget);
    expect(find.text('跨设备续读'), findsOneWidget);
    expect(find.text('打开书籍自动接续'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文传输中禁用重复同步并显示进行状态', (tester) async {
    final controller = _PreviewController(transferring: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(_testApp(controller, const WebDavSyncPage()));
    await tester.pump();
    final button = tester.widget<FilledButton>(find.byType(FilledButton).first);
    expect(button.onPressed, isNull);
    expect(find.text('正在同步'), findsWidgets);
  });

  testWidgets('减少动态效果时保留同步文字且不循环旋转', (tester) async {
    final controller = _PreviewController(transferring: true);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _testApp(controller, const WebDavSyncPage(), disableAnimations: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('正在同步'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('概览摘要包含所有开启的数据范围', (tester) async {
    final controller = _PreviewController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(1080, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_testApp(controller, const WebDavSyncPage()));
    await tester.pumpAndSettle();
    final summary = find.textContaining('笔记与高亮');
    expect(summary, findsOneWidget);
    expect(find.textContaining('阅读器设置'), findsOneWidget);
    expect(find.textContaining('替换规则'), findsOneWidget);
  });

  for (final preview in [
    (
      name: 'mobile',
      size: const Size(390, 844),
      dark: false,
      scale: 1.0,
      failed: false,
    ),
    (
      name: 'desktop',
      size: const Size(1080, 900),
      dark: false,
      scale: 1.0,
      failed: false,
    ),
    (
      name: 'error',
      size: const Size(390, 844),
      dark: false,
      scale: 1.0,
      failed: true,
    ),
    (
      name: 'dark',
      size: const Size(390, 844),
      dark: true,
      scale: 1.0,
      failed: false,
    ),
    (
      name: 'large-text',
      size: const Size(360, 900),
      dark: false,
      scale: 1.6,
      failed: true,
    ),
  ]) {
    testWidgets('概览布局 ${preview.name} 保持主操作可见且无溢出', (tester) async {
      final controller = _PreviewController(failed: preview.failed);
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(preview.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey();
      await tester.pumpWidget(
        _testApp(
          controller,
          RepaintBoundary(key: key, child: const WebDavSyncPage()),
          brightness: preview.dark ? Brightness.dark : Brightness.light,
          textScale: preview.scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final button = find.byType(FilledButton).first;
      expect(tester.getRect(button).bottom, lessThan(preview.size.height));
      expect(button.hitTestable(), findsOneWidget);
      await _savePreview(tester, key, 'cloud-sync-${preview.name}.png');
      // Inspect the lower settings too, especially at large text scales.
      await tester.drag(find.byType(ListView).first, const Offset(0, -900));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final layout in [
    (name: 'phone', size: const Size(390, 844), inset: 47.0),
    (name: 'desktop', size: const Size(1080, 900), inset: 0.0),
  ]) {
    testWidgets('书籍与正文 ${layout.name} 首项位于导航栏下方', (tester) async {
      final controller = _DetailsLayoutController();
      addTearDown(controller.dispose);
      await tester.binding.setSurfaceSize(layout.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final key = GlobalKey();
      await tester.pumpWidget(
        _testApp(
          controller,
          RepaintBoundary(key: key, child: const TxtSyncDetailsPage()),
          topInset: layout.inset,
        ),
      );
      await tester.pump();
      final header = find.byKey(const ValueKey('floating-subpage-header'));
      final introduction = find.text('参与同步的书籍、正文更新与文件下载');
      await _savePreview(tester, key, 'book-text-${layout.name}.png');
      expect(
        tester.getTopLeft(introduction).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(header).dy + 20),
      );
      expect(
        find.widgetWithText(OutlinedButton, '选择书籍与下载').hitTestable(),
        findsOneWidget,
      );
      controller.loading.completeError(StateError('layout fixture'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(introduction).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(header).dy + 20),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('配置页先测试连接再允许保存', (tester) async {
    final controller = WebDavSyncController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_testApp(controller, const WebDavSetupPage()));
    await tester.pumpAndSettle();

    expect(find.text('WebDAV 地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('应用密码'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);

    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存配置'),
    );
    expect(saveButton.onPressed, isNull);
    expect(find.text('阅读进度'), findsNothing);
    expect(find.text('书籍原文件'), findsNothing);
  });

  testWidgets('同步失败时持续显示服务器返回的完整上下文', (tester) async {
    final controller = _FailureController();
    addTearDown(controller.dispose);
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_testApp(controller, const WebDavSyncPage()));
    await tester.pumpAndSettle();

    expect(find.text('服务器返回的响应与同步协议不兼容。'), findsWidgets);
    expect(find.textContaining('失败阶段：书籍原文件'), findsOneWidget);
    expect(find.text('服务器返回详情'), findsOneWidget);
    expect(find.textContaining('服务器忽略了仅在版本一致时才写入'), findsOneWidget);
    expect(
      find.textContaining('具体原因：The WebDAV server accepted a PUT'),
      findsOneWidget,
    );
    expect(find.textContaining('HTTP 状态码：412'), findsOneWidget);
    expect(find.textContaining('请求方法：PUT'), findsOneWidget);
    expect(
      find.textContaining('资源路径：/dav/OpenReading/v2/book.txt'),
      findsOneWidget,
    );
    expect(find.byType(SelectableText), findsOneWidget);
    Map<dynamic, dynamic>? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = call.arguments as Map;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byTooltip('复制').first);
    await tester.pump();
    expect(clipboard?['text'], contains('请求方法：PUT'));
    expect(clipboard?['text'], contains('/dav/OpenReading/v2/book.txt'));
  });

  testWidgets('连接测试失败时显示具体原因和 HTTP 上下文', (tester) async {
    final controller = _ConnectionFailureController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_testApp(controller, const WebDavSetupPage()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'WebDAV 地址'),
      'https://dav.example.test',
    );
    await tester.enterText(find.widgetWithText(TextFormField, '用户名'), 'user');
    await tester.enterText(
      find.widgetWithText(TextFormField, '应用密码'),
      'password',
    );
    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pumpAndSettle();

    expect(find.text('服务器返回的响应与同步协议不兼容。'), findsOneWidget);
    expect(find.textContaining('ETag 可能缺失或过弱'), findsOneWidget);
    expect(
      find.textContaining('具体原因：Safe editable TXT sync requires'),
      findsOneWidget,
    );
    expect(find.textContaining('HTTP 状态码：207'), findsOneWidget);
    expect(find.textContaining('请求方法：PROPFIND'), findsOneWidget);
    expect(find.textContaining('资源路径：/dav/OpenReading'), findsOneWidget);
  });

  testWidgets('同步内容开关在独立页面即时保存', (tester) async {
    final preferences = _MemoryPreferences();
    final store = SecureSyncConfigStore(
      secretStorage: _MemorySecrets(),
      preferences: preferences,
    );
    final controller = _ScopeController(store);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _testApp(controller, const WebDavSyncContentPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('书源'), findsOneWidget);
    expect(find.text('书架与在线书籍'), findsOneWidget);
    expect(find.text('笔记与高亮'), findsOneWidget);
    expect(find.text('阅读器设置'), findsOneWidget);
    expect(find.text('替换规则'), findsOneWidget);
    expect(find.textContaining('未端到端加密'), findsNWidgets(2));
    final notesSwitch = find.widgetWithText(SwitchListTile, '笔记与高亮');
    final readerSettingsSwitch = find.widgetWithText(SwitchListTile, '阅读器设置');
    final replaceRulesSwitch = find.widgetWithText(SwitchListTile, '替换规则');
    expect(tester.widget<SwitchListTile>(notesSwitch).value, isFalse);
    expect(tester.widget<SwitchListTile>(readerSettingsSwitch).value, isTrue);
    expect(tester.widget<SwitchListTile>(replaceRulesSwitch).value, isFalse);
    final progressSwitch = find.widgetWithText(SwitchListTile, '阅读进度');
    expect(progressSwitch, findsOneWidget);
    expect(tester.widget<SwitchListTile>(progressSwitch).value, isTrue);

    await tester.tap(progressSwitch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(controller.scope.progress, isFalse);
    expect((await store.readScope()).progress, isFalse);
  });
}

Widget _testApp(
  WebDavSyncController controller,
  Widget home, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  bool disableAnimations = false,
  double topInset = 0,
}) {
  return ChangeNotifierProvider<WebDavSyncController>.value(
    value: controller,
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
          viewPadding: EdgeInsets.only(top: topInset),
          padding: EdgeInsets.only(top: topInset),
        ),
        child: child!,
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF46658B),
          brightness: brightness,
        ),
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
      home: home,
    ),
  );
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

class _FailureController extends WebDavSyncController {
  static const failure = WebDavSyncFailure(
    WebDavSyncErrorCode.serverIncompatible,
    'The WebDAV server accepted a PUT that should have been rejected by '
    'If-Match. TXT overwrite protection could not be verified.',
    statusCode: 412,
    requestMethod: 'PUT',
    resourcePath: '/dav/OpenReading/v2/book.txt',
  );

  @override
  bool get isConfigured => true;

  @override
  WebDavSyncStatus get status => WebDavSyncStatus.failed;

  @override
  WebDavSyncFailure? get lastFailure => failure;

  @override
  WebDavSyncErrorCode? get lastError => failure.code;

  @override
  WebDavSyncPhase get lastFailedPhase => WebDavSyncPhase.none;

  @override
  bool get lastFailureIsFile => true;
}

class _ConnectionFailureController extends WebDavSyncController {
  @override
  Future<ConnectionTestResult> testConnection(
    WebDavSyncConfigDraft draft,
  ) async {
    const failure = WebDavSyncFailure(
      WebDavSyncErrorCode.serverIncompatible,
      'Safe editable TXT sync requires a strong WebDAV ETag.',
      statusCode: 207,
      requestMethod: 'PROPFIND',
      resourcePath: '/dav/OpenReading',
    );
    return const ConnectionTestResult(
      success: false,
      errorCode: WebDavSyncErrorCode.serverIncompatible,
      message: 'Safe editable TXT sync requires a strong WebDAV ETag.',
      failure: failure,
    );
  }
}

Future<void> _savePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  const directory = String.fromEnvironment('SYNC_PREVIEW_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

class _PreviewController extends _ScopeController {
  _PreviewController({this.failed = false, this.transferring = false})
    : super(
        SecureSyncConfigStore(
          secretStorage: _MemorySecrets(),
          preferences: _MemoryPreferences(),
        ),
      ) {
    value = const WebDavSyncScope(
      notes: true,
      replaceRules: true,
      bookFiles: true,
    );
  }
  final bool failed;
  final bool transferring;
  @override
  bool get autoSync => true;
  @override
  String? get serverUrl => 'https://dav.jianguoyun.com/dav/';
  @override
  WebDavSyncStatus get status =>
      failed ? WebDavSyncStatus.partialFailure : WebDavSyncStatus.success;
  @override
  DateTime? get lastSuccessfulSync => DateTime(2026, 9, 5, 17, 17);
  @override
  DateTime? get lastProgressSyncAt => lastSuccessfulSync;
  @override
  bool get syncingText => transferring;
  @override
  WebDavSyncFailure? get lastFailure =>
      failed ? _FailureController.failure : null;
  @override
  WebDavSyncErrorCode? get lastError => lastFailure?.code;
  @override
  bool get lastFailureIsFile => failed;
  @override
  List<BookContentState> get textStates => const [
    BookContentState(
      bookUid: 'book',
      localBookId: 1,
      localPath: '/books/book.txt',
      remotePath: 'books/book/current.txt',
      status: BookContentSyncStatus.synced,
    ),
  ];
}

class _DetailsLayoutController extends WebDavSyncController {
  final loading = Completer<void>();
  @override
  Future<void> refreshTextStates() => loading.future;
}
