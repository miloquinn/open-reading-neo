import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AI chat history has one explicit application owner', () {
    const servicePath = 'lib/services/ai/ai_chat_history_store.dart';
    final serviceSource = File(servicePath).readAsStringSync();
    final constructionFiles = _dartFiles(Directory('lib'))
        .where(
          (file) =>
              file.path != servicePath &&
              RegExp(
                r'\bAiChatHistoryStore\s*\(',
              ).hasMatch(file.readAsStringSync()),
        )
        .map((file) => file.path)
        .toList(growable: false);

    expect(
      constructionFiles,
      ['lib/main.dart'],
      reason:
          'AI chat history must be constructed only by the application root '
          'and injected into every consumer.',
    );
    expect(
      serviceSource,
      isNot(matches(RegExp(r'factory\s+AiChatHistoryStore\s*\('))),
      reason: 'The store must not hide a singleton behind a factory.',
    );
    expect(
      serviceSource,
      isNot(matches(RegExp(r'static\s+final\s+AiChatHistoryStore\b'))),
      reason: 'The store must not retain a process-global static instance.',
    );
    expect(
      serviceSource,
      isNot(matches(RegExp(r'AiChatHistoryStore\._\s*\('))),
      reason: 'The application root must be able to construct the store.',
    );
    expect(
      serviceSource,
      isNot(contains('debugResetForTest')),
      reason: 'Tests must own isolated stores instead of resetting globals.',
    );
    expect(
      File('lib/main.dart').readAsStringSync(),
      matches(
        RegExp(
          r'ChangeNotifierProvider\s*\(\s*create:\s*\(_\)\s*=>\s*'
          r'AiChatHistoryStore\(\)',
        ),
      ),
      reason: 'The root Provider must own and dispose the chat-history store.',
    );
  });
}

Iterable<File> _dartFiles(Directory directory) => directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));
