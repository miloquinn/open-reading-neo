import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xxread/services/ai/ai_chat_history_store.dart';

AiChatHistorySession _session(
  String id, {
  String bookTitle = '测试书',
  String? bookId,
  DateTime? updatedAt,
}) {
  final at = updatedAt ?? DateTime(2026, 7, 26, 12);
  return AiChatHistorySession(
    id: id,
    bookTitle: bookTitle,
    bookId: bookId,
    createdAt: at,
    updatedAt: at,
    messages: [
      AiChatHistoryMessage(role: 'user', text: '问题 $id', at: at),
      AiChatHistoryMessage(role: 'assistant', text: '回答 $id', at: at),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AiChatHistoryStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = AiChatHistoryStore();
  });

  tearDown(() => store.dispose());

  test('sessions persist across reloads and keep newest first', () async {
    await store.upsertSession(
      _session('a', updatedAt: DateTime(2026, 7, 26, 10)),
    );
    await store.upsertSession(
      _session('b', bookId: '42', updatedAt: DateTime(2026, 7, 26, 11)),
    );

    final reloadedStore = AiChatHistoryStore();
    addTearDown(reloadedStore.dispose);
    await reloadedStore.ensureLoaded();

    expect(reloadedStore.sessions.map((s) => s.id), ['b', 'a']);
    expect(reloadedStore.sessions.first.firstQuestion, '问题 b');
    expect(reloadedStore.sessions.first.bookTitle, '测试书');
    expect(reloadedStore.sessions.first.bookId, '42');
    expect(reloadedStore.sessions.last.bookId, isNull);
    expect(reloadedStore.sessions.first.messages, hasLength(2));
  });

  test('upsert replaces an existing session by id', () async {
    await store.upsertSession(_session('a'));
    final updated = AiChatHistorySession(
      id: 'a',
      bookTitle: '测试书',
      createdAt: DateTime(2026, 7, 26, 12),
      updatedAt: DateTime(2026, 7, 26, 13),
      messages: [
        AiChatHistoryMessage(
          role: 'user',
          text: '追问',
          at: DateTime(2026, 7, 26, 13),
        ),
      ],
    );
    await store.upsertSession(updated);

    expect(store.sessions, hasLength(1));
    expect(store.sessions.single.firstQuestion, '追问');
  });

  test('delete and clear remove sessions permanently', () async {
    await store.upsertSession(_session('a'));
    await store.upsertSession(_session('b'));

    await store.deleteSession('a');
    expect(store.sessions.map((s) => s.id), ['b']);

    await store.clearAll();
    expect(store.sessions, isEmpty);

    final reloadedStore = AiChatHistoryStore();
    addTearDown(reloadedStore.dispose);
    await reloadedStore.ensureLoaded();
    expect(reloadedStore.sessions, isEmpty);
  });

  test('session count is capped at the configured maximum', () async {
    for (var index = 0; index < AiChatHistoryStore.maxSessions + 5; index++) {
      await store.upsertSession(
        _session('s$index', updatedAt: DateTime(2026, 7, 26, 0, index)),
      );
    }
    expect(store.sessions, hasLength(AiChatHistoryStore.maxSessions));
    expect(store.sessions.first.id, 's${AiChatHistoryStore.maxSessions + 4}');
  });

  test('corrupt stored payload degrades to an empty history', () async {
    SharedPreferences.setMockInitialValues({
      'reader_ai_chat_history_v1': '{not json]',
    });
    await store.ensureLoaded();
    expect(store.sessions, isEmpty);
  });

  test('legacy message JSON falls back to display text for content', () {
    final message = AiChatHistoryMessage.fromJson({
      'role': 'assistant',
      'text': '展示文本',
      'at': '2026-07-26T12:00:00.000Z',
    });

    expect(message, isNotNull);
    expect(message!.content, '展示文本');
  });

  test('message display text and model content round-trip independently', () {
    final original = AiChatHistoryMessage(
      role: 'assistant',
      text: '简短展示',
      content: '用于后续对话的完整内容',
      at: DateTime.utc(2026, 7, 26, 12),
    );

    final restored = AiChatHistoryMessage.fromJson(original.toJson());

    expect(restored, isNotNull);
    expect(restored!.text, '简短展示');
    expect(restored.content, '用于后续对话的完整内容');
    expect(restored.at, original.at.toLocal());
  });

  test('malformed records and fields do not discard valid history', () async {
    SharedPreferences.setMockInitialValues({
      'reader_ai_chat_history_v1': jsonEncode([
        {
          'id': 'valid',
          'bookTitle': 42,
          'bookId': true,
          'createdAt': ['invalid'],
          'updatedAt': {'invalid': true},
          'messages': [
            {'role': 7, 'text': '无效消息', 'at': '2026-07-26T11:00:00.000Z'},
            {'role': 'user', 'text': '保留我', 'at': 123},
          ],
        },
        {
          'id': 'invalid-session',
          'bookTitle': '无效会话',
          'createdAt': '2026-07-26T10:00:00.000Z',
          'updatedAt': '2026-07-26T10:00:00.000Z',
          'messages': [
            {'role': 'user', 'text': false, 'at': null},
          ],
        },
      ]),
    });

    await store.ensureLoaded();

    expect(store.sessions, hasLength(1));
    expect(store.sessions.single.id, 'valid');
    expect(store.sessions.single.bookTitle, '');
    expect(store.sessions.single.bookId, isNull);
    expect(store.sessions.single.messages, hasLength(1));
    expect(store.sessions.single.firstQuestion, '保留我');
    expect(store.sessions.single.messages.single.content, '保留我');
  });

  test('stores keep independent in-memory state', () async {
    final otherStore = AiChatHistoryStore();
    addTearDown(otherStore.dispose);
    await Future.wait([store.ensureLoaded(), otherStore.ensureLoaded()]);

    await store.upsertSession(_session('a'));

    expect(store.sessions.map((session) => session.id), ['a']);
    expect(otherStore.sessions, isEmpty);
  });

  test('disposed store rejects loading and mutations', () async {
    store.dispose();
    store.dispose();

    expect(store.ensureLoaded, throwsStateError);
    await expectLater(store.upsertSession(_session('a')), throwsStateError);
    await expectLater(store.deleteSession('a'), throwsStateError);
    await expectLater(store.clearAll(), throwsStateError);
  });

  test('in-flight load does not commit or notify after dispose', () async {
    var notifications = 0;
    store.addListener(() => notifications++);

    final loading = store.ensureLoaded();
    store.dispose();
    await loading;

    expect(store.sessions, isEmpty);
    expect(notifications, 0);
  });
}
