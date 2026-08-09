import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/source_debug.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_dependencies.dart';
import 'package:xxread/book_sources/source_engine/source_runtime_state.dart';

void main() {
  group('SourceRuntimeState', () {
    test('reuses a remembered book response once', () {
      final state = SourceRuntimeState();
      final source = _source();
      final response = SourceResponse(
        body: 'info',
        finalUri: Uri.parse('https://books.test/book/1'),
        statusCode: 200,
      );

      state.rememberBookInfoResponse(source, '/book/1', response);

      expect(state.takeBookInfoResponse(source, '/book/1'), same(response));
      expect(state.takeBookInfoResponse(source, '/book/1'), isNull);
    });

    test('evicts the oldest remembered book state', () {
      final state = SourceRuntimeState(maxRememberedBookStates: 2);
      final source = _source();

      state.rememberRuleState(source, 'one', {'id': 1});
      state.rememberRuleState(source, 'two', {'id': 2});
      state.rememberRuleState(source, 'three', {'id': 3});

      expect(state.ruleStateFor(source, 'one', const {}), isEmpty);
      expect(state.ruleStateFor(source, 'two', const {}), {'id': 2});
      expect(state.ruleStateFor(source, 'three', const {}), {'id': 3});
    });
  });

  test(
    'SourceRuntimeTrace attributes network events to the active stage',
    () async {
      final recorder = _Recorder();
      final trace = SourceRuntimeTrace(recorder);
      final request = SourceRequestTemplate(
        url: Uri.parse('https://books.test/search'),
        method: SourceRequestMethod.get,
        headers: const {},
        charset: 'utf-8',
      );
      final response = SourceResponse(
        body: 'ok',
        finalUri: request.url,
        statusCode: 200,
      );

      await trace.stage('search', () async {
        trace.networkSuccess(request, response, null);
        return 1;
      }, describe: (value) => '$value result');

      expect(recorder.events, [
        'start:search',
        'network:search:GET:200',
        'success:search:1 result',
      ]);
    },
  );
}

ReadingSourceConfig _source() => ReadingSourceConfig.fromJson(const {
  'bookSourceUrl': 'https://books.test',
  'bookSourceName': 'Books',
});

class _Recorder implements SourceDebugRecorder {
  final List<String> events = [];

  @override
  void recordNetwork({
    required String stage,
    required String method,
    required Uri url,
    int? statusCode,
    String? bodyPreview,
    Object? error,
    Duration? elapsed,
  }) {
    events.add('network:$stage:$method:$statusCode');
  }

  @override
  void stageFailed(String stage, Object error) => events.add('failed:$stage');

  @override
  void stageStarted(String stage) => events.add('start:$stage');

  @override
  void stageSucceeded(String stage, String summary) =>
      events.add('success:$stage:$summary');
}
