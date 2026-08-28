import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/ai/ai_chat_history_store.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_ai_panel.dart';

class _FakeAiService implements ConfigurableAIService {
  _FakeAiService({required this.configured, this.answer = 'AI 的回答'});

  final bool configured;
  final String answer;
  List<AIChatMessage>? lastHistory;
  String? lastPageText;
  AIRequestMeta? lastMeta;

  @override
  Future<AIProviderSettings> loadSettings([AIProviderType? provider]) async =>
      AIProviderSettings.defaults(
        AIProviderType.openai,
      ).copyWith(apiKey: configured ? 'test-key' : '');

  @override
  Future<void> saveSettings(AIProviderSettings settings) async {}

  @override
  Future<String> chat({
    required List<AIChatMessage> history,
    required String pageText,
    required AIRequestMeta meta,
  }) async {
    lastHistory = history;
    lastPageText = pageText;
    lastMeta = meta;
    return answer;
  }

  @override
  Future<String> askSelection({
    required String selectedText,
    required String contextBefore,
    required String contextAfter,
    required AIRequestMeta meta,
  }) async => answer;

  @override
  Future<String> analyzePage({
    required String pageText,
    required AIRequestMeta meta,
  }) async => answer;
}

Widget _wrapPanel(ReaderAiPanel panel) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: panel),
);

void main() {
  const meta = AIRequestMeta(bookId: '1', chapterId: 'chapter-1', pageIndex: 2);

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('sends a typed question and renders the answer', (tester) async {
    final service = _FakeAiService(configured: true, answer: '这是模型的解释。');
    final historyStore = AiChatHistoryStore();
    addTearDown(historyStore.dispose);
    await tester.pumpWidget(
      _wrapPanel(
        ReaderAiPanel(
          palette: ReaderThemes.green,
          meta: meta,
          pageText: '当前页正文',
          aiService: service,
          historyStore: historyStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('reader-ai-input')),
      '这一段讲了什么？',
    );
    await tester.tap(find.byKey(const ValueKey('reader-ai-send')));
    await tester.pumpAndSettle();

    expect(find.text('这一段讲了什么？'), findsOneWidget);
    expect(find.text('这是模型的解释。'), findsOneWidget);
    expect(service.lastHistory, hasLength(1));
    expect(service.lastHistory!.single.role, 'user');
    expect(service.lastHistory!.single.content, '这一段讲了什么？');
    expect(service.lastPageText, '当前页正文');
    expect(service.lastMeta?.chapterId, 'chapter-1');
    expect(historyStore.sessions, hasLength(1));
    expect(historyStore.sessions.single.messages, hasLength(2));
    expect(historyStore.sessions.single.firstQuestion, '这一段讲了什么？');
    expect(historyStore.sessions.single.messages.first.content, '这一段讲了什么？');
  });

  testWidgets('shows the setup hint and disables sending when unconfigured', (
    tester,
  ) async {
    final service = _FakeAiService(configured: false);
    final historyStore = AiChatHistoryStore();
    addTearDown(historyStore.dispose);
    await tester.pumpWidget(
      _wrapPanel(
        ReaderAiPanel(
          palette: ReaderThemes.green,
          meta: meta,
          pageText: '当前页正文',
          aiService: service,
          historyStore: historyStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('尚未配置 AI 模型'), findsOneWidget);
    final sendButton = tester.widget<IconButton>(
      find.byKey(const ValueKey('reader-ai-send')),
    );
    expect(sendButton.onPressed, isNull);
    expect(service.lastHistory, isNull);
  });

  testWidgets('renders assistant answers as markdown', (tester) async {
    final service = _FakeAiService(
      configured: true,
      answer: '## 摘要\n\n- **要点**一\n- 要点二',
    );
    final historyStore = AiChatHistoryStore();
    addTearDown(historyStore.dispose);
    await tester.pumpWidget(
      _wrapPanel(
        ReaderAiPanel(
          palette: ReaderThemes.green,
          meta: meta,
          pageText: '当前页正文',
          aiService: service,
          historyStore: historyStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('reader-ai-input')),
      '总结一下',
    );
    await tester.tap(find.byKey(const ValueKey('reader-ai-send')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('release-notes-markdown')),
      findsOneWidget,
    );
    expect(find.text('摘要'), findsOneWidget);
    expect(find.text('要点二'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('##'), findsNothing);
  });

  testWidgets('auto-asks about the seeded selection', (tester) async {
    final service = _FakeAiService(configured: true, answer: '选中内容的解释。');
    final historyStore = AiChatHistoryStore();
    addTearDown(historyStore.dispose);
    await tester.pumpWidget(
      _wrapPanel(
        ReaderAiPanel(
          palette: ReaderThemes.night,
          meta: meta,
          pageText: '上文 选中文字 下文',
          aiService: service,
          historyStore: historyStore,
          selection: const ReaderAiSelectionContext(
            selectedText: '选中文字',
            contextBefore: '上文',
            contextAfter: '下文',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('解释这段选中内容'), findsOneWidget);
    expect(find.text('选中内容的解释。'), findsOneWidget);
    expect(service.lastHistory, hasLength(1));
    expect(service.lastHistory!.single.content, contains('选中文字'));
    expect(service.lastHistory!.single.content, contains('上文'));
    expect(service.lastHistory!.single.content, contains('下文'));
    expect(historyStore.sessions, hasLength(1));
    final session = historyStore.sessions.single;
    expect(session.bookId, meta.bookId);
    expect(session.messages, hasLength(2));
    final savedQuestion = session.messages.first;
    expect(savedQuestion.text, contains('解释这段选中内容'));
    expect(savedQuestion.text, contains('选中文字'));
    expect(savedQuestion.content, contains('选中文字'));
    expect(savedQuestion.content, contains('上文'));
    expect(savedQuestion.content, contains('下文'));
  });
}
