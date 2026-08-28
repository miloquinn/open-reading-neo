import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/ai/ai_history_page.dart';
import 'package:xxread/pages/ai/ai_page.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/ai/ai_chat_history_store.dart';

class _RecordingAiService implements ConfigurableAIService {
  List<AIChatMessage>? lastHistory;

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
  }) async {
    lastHistory = history;
    return '新的原始回答';
  }

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

AiChatHistorySession _savedSession() {
  final at = DateTime(2026, 8, 28, 12);
  return AiChatHistorySession(
    id: 'saved-session',
    bookTitle: '',
    createdAt: at,
    updatedAt: at,
    messages: [
      AiChatHistoryMessage(
        role: 'user',
        text: '界面里的旧问题',
        content: '模型看到的完整旧问题',
        at: at,
      ),
      AiChatHistoryMessage(
        role: 'assistant',
        text: '界面里的旧回答',
        content: '模型返回的原始旧回答',
        at: at,
      ),
    ],
  );
}

Widget _localizedApp(Widget home) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('history page reads and clears the injected store', (
    tester,
  ) async {
    final store = AiChatHistoryStore();
    addTearDown(store.dispose);
    await store.upsertSession(_savedSession());

    await tester.pumpWidget(_localizedApp(AiHistoryPage(store: store)));
    await tester.pumpAndSettle();

    expect(find.text('界面里的旧问题'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-history-clear-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(store.sessions, isEmpty);
    expect(find.text('界面里的旧问题'), findsNothing);
  });

  testWidgets('continued chat sends restored model content, not display text', (
    tester,
  ) async {
    final store = AiChatHistoryStore();
    addTearDown(store.dispose);
    await store.upsertSession(_savedSession());
    final service = _RecordingAiService();
    final controller = AiPageController();

    await tester.pumpWidget(
      _localizedApp(
        Scaffold(
          body: NavigationContext(
            useRailNavigation: true,
            child: AiPage(
              historyStore: store,
              controller: controller,
              aiService: service,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.openHistory();
    await tester.pumpAndSettle();
    await tester.tap(find.text('界面里的旧问题'));
    await tester.pumpAndSettle();

    expect(find.text('界面里的旧问题'), findsOneWidget);
    expect(find.text('界面里的旧回答'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('ai-page-input')), '新的追问');
    await tester.tap(find.byKey(const ValueKey('ai-page-send')));
    await tester.pumpAndSettle();

    expect(service.lastHistory?.map((message) => message.content), [
      '模型看到的完整旧问题',
      '模型返回的原始旧回答',
      '新的追问',
    ]);
  });
}
