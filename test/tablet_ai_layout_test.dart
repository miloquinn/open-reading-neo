import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/ai/ai_page.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/ai/ai_chat_history_store.dart';

class _ConfiguredAiService implements ConfigurableAIService {
  @override
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]) async =>
      AIProviderSettings.defaults(
        AIProviderType.openai,
      ).copyWith(apiKey: 'test-key');

  @override
  Future<void> saveSettings(AIProviderSettings settings) async {}

  @override
  Future<String> chat({
    required List<AIChatMessage> history,
    required String pageText,
    required AIRequestMeta meta,
  }) async => 'answer';

  @override
  Future<String> askSelection({
    required String selectedText,
    required String contextBefore,
    required String contextAfter,
    required AIRequestMeta meta,
  }) async => 'unused';

  @override
  Future<String> analyzePage({
    required String pageText,
    required AIRequestMeta meta,
  }) async => 'unused';
}

Widget _tabletApp({
  required AiChatHistoryStore store,
  required AiPageController controller,
  bool keyboardVisible = false,
  double textScale = 1,
}) {
  const size = Size(1024, 1366);
  final mediaQuery = MediaQueryData(
    size: size,
    viewPadding: const EdgeInsets.only(top: 24, bottom: 20),
    viewInsets: EdgeInsets.only(bottom: keyboardVisible ? 320 : 0),
    textScaler: TextScaler.linear(textScale),
  );
  final chrome = HomeMobileChromeMetrics.fromMediaQuery(
    mediaQuery,
    navigationAtTop: true,
  );
  return MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: mediaQuery,
      child: Scaffold(
        body: HomeMobileChromeScope(
          metrics: chrome,
          child: NavigationContext(
            useRailNavigation: false,
            child: AiPage(
              historyStore: store,
              controller: controller,
              aiService: _ConfiguredAiService(),
            ),
          ),
        ),
      ),
    ),
  );
}

AiChatHistorySession _session() {
  final at = DateTime(2026, 9, 5, 12);
  return AiChatHistorySession(
    id: 'tablet-session',
    bookTitle: '',
    createdAt: at,
    updatedAt: at,
    messages: [
      AiChatHistoryMessage(
        role: 'user',
        text: '平板上的旧问题',
        content: '平板上的旧问题',
        at: at,
      ),
      AiChatHistoryMessage(
        role: 'assistant',
        text: '平板上的旧回答',
        content: '平板上的旧回答',
        at: at,
      ),
    ],
  );
}

AiChatHistorySession _longSession() {
  final at = DateTime(2026, 9, 5, 13);
  return AiChatHistorySession(
    id: 'tablet-long-session',
    bookTitle: '',
    createdAt: at,
    updatedAt: at,
    messages: [
      for (var index = 0; index < 24; index++)
        AiChatHistoryMessage(
          role: index == 23 || index.isEven ? 'user' : 'assistant',
          text: index == 0
              ? '大字体历史问题'
              : index == 23
              ? '最后一条大字体回答'
              : '第 $index 条用于验证滚动位置的历史消息',
          content: 'message-$index',
          at: at.add(Duration(minutes: index)),
        ),
    ],
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  void configureTabletSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 1366);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  testWidgets(
    'tablet AI content respects the top navigation and reading width',
    (tester) async {
      configureTabletSurface(tester);
      final store = AiChatHistoryStore();
      addTearDown(store.dispose);
      final controller = AiPageController();

      await tester.pumpWidget(_tabletApp(store: store, controller: controller));
      await tester.pumpAndSettle();

      final contentRect = tester.getRect(
        find.byKey(const ValueKey('ai-page-content')),
      );
      final emptyIcon = tester.getRect(
        find.byIcon(Icons.auto_awesome_outlined),
      );
      final inputRect = tester.getRect(
        find.byKey(const ValueKey('ai-page-input')),
      );

      expect(contentRect.width, lessThanOrEqualTo(760));
      expect(contentRect.left, closeTo((1024 - contentRect.width) / 2, 1));
      expect(emptyIcon.top, greaterThanOrEqualTo(160));
      expect(inputRect.bottom, lessThanOrEqualTo(1366 - 40));
    },
  );

  testWidgets('tablet history opens as a centered bounded dialog', (
    tester,
  ) async {
    configureTabletSurface(tester);
    final store = AiChatHistoryStore();
    addTearDown(store.dispose);
    await store.upsertSession(_session());
    final controller = AiPageController();

    await tester.pumpWidget(_tabletApp(store: store, controller: controller));
    await tester.pumpAndSettle();
    controller.openHistory();
    await tester.pumpAndSettle();

    final dialog = find.byKey(const ValueKey('ai-history-tablet-dialog'));
    expect(dialog, findsOneWidget);
    final rect = tester.getRect(dialog);
    expect(rect.width, lessThanOrEqualTo(720));
    expect(rect.height, lessThanOrEqualTo(820));
    expect(rect.center.dx, closeTo(512, 1));

    await tester.tap(find.text('平板上的旧问题'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(find.text('平板上的旧回答'), findsOneWidget);
  });

  testWidgets('tablet keyboard keeps the input bar above the keyboard', (
    tester,
  ) async {
    configureTabletSurface(tester);
    final store = AiChatHistoryStore();
    addTearDown(store.dispose);
    final controller = AiPageController();

    await tester.pumpWidget(
      _tabletApp(store: store, controller: controller, keyboardVisible: true),
    );
    await tester.pumpAndSettle();

    final inputRect = tester.getRect(
      find.byKey(const ValueKey('ai-page-input')),
    );
    expect(inputRect.bottom, lessThan(1366 - 320));
    expect(1366 - 320 - inputRect.bottom, inInclusiveRange(10, 30));
  });

  for (final scale in [2.0, 3.0]) {
    testWidgets('tablet AI measures its overlay at ${scale}x text scale', (
      tester,
    ) async {
      configureTabletSurface(tester);
      final store = AiChatHistoryStore();
      addTearDown(store.dispose);
      await store.upsertSession(_longSession());
      final controller = AiPageController();

      await tester.pumpWidget(_tabletApp(store: store, controller: controller));
      await tester.pumpAndSettle();
      controller.openHistory();
      await tester.pumpAndSettle();
      await tester.tap(find.text('大字体历史问题'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _tabletApp(store: store, controller: controller, textScale: scale),
      );
      await tester.pumpAndSettle();

      final overlayRect = tester.getRect(
        find.byKey(const ValueKey('ai-page-overlay')),
      );
      final lastMessage = find.text('最后一条大字体回答');
      await tester.scrollUntilVisible(
        lastMessage,
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(lastMessage, findsOneWidget);
      final lastMessageRect = tester.getRect(lastMessage);
      final list = tester.widget<ListView>(find.byType(ListView));
      final listBottomPadding = list.padding!.resolve(TextDirection.ltr).bottom;

      expect(listBottomPadding, closeTo(overlayRect.height + 8, 1));
      expect(lastMessageRect.bottom, lessThanOrEqualTo(overlayRect.top - 8));
      expect(tester.takeException(), isNull);
    });
  }
}
