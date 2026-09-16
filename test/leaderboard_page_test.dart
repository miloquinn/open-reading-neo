import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/reading_stats/leaderboard_page.dart';
import 'package:xxread/services/account/member_account_controller.dart';
import 'package:xxread/services/reading/reading_account_scope.dart';
import 'package:xxread/services/reading/reading_cloud_controller.dart';
import 'package:xxread/services/reading/reading_cloud_store.dart';

import 'reading_cloud_test.dart' show TestReadingApi, TestReadingAccount, a;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile board, opt-in, history confirmation and large text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final scope = ReadingAccountScope();
    await scope.setOwner(a);
    final api = _BoardApi();
    final account = TestReadingAccount(api, a);
    final store = _MemoryStore();
    final cloud = ReadingCloudController(
      account: account,
      scope: scope,
      store: store,
      automatic: false,
    );
    final boundary = GlobalKey();
    final font = File('/System/Library/Fonts/Hiragino Sans GB.ttc');
    final capture = Platform.environment['READING_PREVIEW_PATH'];
    if (capture != null) {
      await tester.runAsync(() async {
        if (!await font.exists()) return;
        final loader = FontLoader('ReadingPreview')
          ..addFont(font.readAsBytes().then(ByteData.sublistView));
        await loader.load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }

    Widget app({double scale = 1}) => MultiProvider(
      providers: [
        ChangeNotifierProvider<MemberAccountController>.value(value: account),
        ChangeNotifierProvider<ReadingCloudController>.value(value: cloud),
      ],
      child: RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF527761),
            fontFamily: capture == null ? null : 'ReadingPreview',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const ReadingLeaderboardPage(),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('阅读排行榜'), findsOneWidget);
    expect(find.text('我的阅读'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(
      find.byKey(const ValueKey('reading-public-switch')),
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(cloud.summary?['public'], true);
    await tester.ensureVisible(find.byKey(const ValueKey('reading-my-rank')));
    expect(find.text('#2'), findsOneWidget);
    await tester.tap(find.text('月榜'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('合并'));
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不能再转给其他账号'), findsOneWidget);
    await tester.tap(find.text('暂不合并'));
    await tester.pumpAndSettle();
    expect(store.claimed, isNull);
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并到此账号'));
    await tester.pumpAndSettle();
    expect(store.claimed, a);

    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    if (capture != null) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(capture).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.binding.setSurfaceSize(const Size(360, 780));
    await tester.pumpWidget(app(scale: 1.5));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -1800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    cloud.dispose();
    account.dispose();
    scope.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}

class _MemoryStore extends ReadingCloudStore {
  String? claimed;
  Map<String, dynamic>? snapshot;
  @override
  Future<int> guestSeconds() async => claimed == null ? 32400 : 0;
  @override
  Future<void> claimGuest(String owner) async {
    claimed ??= owner;
  }

  @override
  Future<List<Map<String, Object?>>> pending(String owner) async => [];
  @override
  Future<({int pending, int rejected})> counts(String owner) async =>
      (pending: 0, rejected: 0);
  @override
  Future<Map<String, dynamic>?> cached(String owner) async => snapshot;
  @override
  Future<void> cache(String owner, Map<String, dynamic> payload) async {
    snapshot = payload;
  }
}

class _BoardApi extends TestReadingApi {
  bool public = false;
  @override
  Future<Map<String, dynamic>> readingRequest(
    String method,
    String endpoint,
    String owner, {
    Map<String, Object?>? data,
    String? period,
  }) async {
    if (endpoint == 'preferences') {
      public = data!['public'] as bool;
      return {'user_id': owner, 'public': public};
    }
    if (endpoint == 'summary') {
      return {
        'user_id': owner,
        'public': public,
        'total_seconds': 34200,
        'week_seconds': 10800,
        'month_seconds': 34200,
      };
    }
    final me = {
      'user_id': owner,
      'rank': 2,
      'name': '我的阅读时光',
      'seconds': 10800,
    };
    return {
      'user_id': owner,
      'me': public ? me : null,
      'items': [
        {'user_id': 'another', 'rank': 1, 'name': '山间读书人', 'seconds': 14400},
        if (public) me,
        {
          'user_id': 'third',
          'rank': public ? 3 : 2,
          'name': '翻过这一页',
          'seconds': 7200,
        },
      ],
    };
  }
}
