import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/reader/replace_rule_executor.dart';

ReplaceRuleExecutionRule _rule({
  required String id,
  required String pattern,
  String replacement = '',
  bool isRegex = true,
  int order = 0,
}) => ReplaceRuleExecutionRule(
  id: id,
  name: id,
  pattern: pattern,
  replacement: replacement,
  group: '',
  scope: '',
  excludeScope: '',
  enabled: true,
  isRegex: isRegex,
  scopeTitle: false,
  scopeContent: true,
  order: order,
);

ReplaceRuleExecutionBatch _batch({
  required String signature,
  required List<String> values,
  required List<ReplaceRuleExecutionRule> rules,
}) => ReplaceRuleExecutionBatch(
  values: values,
  rules: rules,
  rulesSignature: signature,
  bookTitle: 'Book',
  target: ReplaceRuleTarget.content,
);

void main() {
  test('worker applies a batch with sequential rule semantics', () async {
    final executor = ReplaceRuleExecutor();
    addTearDown(executor.dispose);

    final result = await executor.applyBatch(
      _batch(
        signature: 'normal',
        values: const ['ad one', 'ad two'],
        rules: [
          _rule(id: 'regex', pattern: r'ad (\w+)', replacement: r'$1'),
          _rule(
            id: 'literal',
            pattern: 'two',
            replacement: '2',
            isRegex: false,
            order: 1,
          ),
        ],
      ),
    );

    expect(result.values, ['one', '2']);
    expect(result.degraded, isFalse);
  });

  test(
    'timeout kills worker, quarantines rule, and replays atomically',
    () async {
      final executor = ReplaceRuleExecutor(
        timeout: const Duration(milliseconds: 80),
        maximumTimeoutRetries: 1,
      );
      addTearDown(executor.dispose);
      final diagnostics = <ReplaceRuleDiagnostic>[];
      final subscription = executor.diagnostics.listen(diagnostics.add);
      addTearDown(subscription.cancel);

      // The near-match forces exponential backtracking on a valid expression.
      final pathologicalInput = '${'a' * 30000}b';
      final stopwatch = Stopwatch()..start();
      final result = await executor
          .applyBatch(
            _batch(
              signature: 'pathological',
              values: [pathologicalInput],
              rules: [
                _rule(id: 'danger', pattern: r'^(a+)+$'),
                _rule(
                  id: 'safe',
                  pattern: 'b',
                  replacement: 'B',
                  isRegex: false,
                  order: 1,
                ),
              ],
            ),
          )
          .timeout(const Duration(seconds: 3));
      stopwatch.stop();

      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      expect(result.values.single, '${'a' * 30000}B');
      expect(result.degraded, isTrue);
      expect(result.skippedRuleIds, contains('danger'));
      expect(
        diagnostics,
        contains(
          isA<ReplaceRuleDiagnostic>()
              .having(
                (diagnostic) => diagnostic.kind,
                'kind',
                ReplaceRuleDiagnosticKind.timeout,
              )
              .having((diagnostic) => diagnostic.ruleId, 'rule id', 'danger'),
        ),
      );

      // The executor must remain usable after the timed-out isolate is killed.
      final next = await executor.applyBatch(
        _batch(
          signature: 'after-restart',
          values: const ['foo'],
          rules: [
            _rule(
              id: 'literal',
              pattern: 'foo',
              replacement: 'bar',
              isRegex: false,
            ),
          ],
        ),
      );
      expect(next.values, ['bar']);
    },
  );

  test('serializes concurrent batches without mixing responses', () async {
    final executor = ReplaceRuleExecutor();
    addTearDown(executor.dispose);

    final results = await Future.wait([
      executor.applyBatch(
        _batch(
          signature: 'first',
          values: const ['one'],
          rules: [
            _rule(
              id: 'first',
              pattern: 'one',
              replacement: '1',
              isRegex: false,
            ),
          ],
        ),
      ),
      executor.applyBatch(
        _batch(
          signature: 'second',
          values: const ['two'],
          rules: [
            _rule(
              id: 'second',
              pattern: 'two',
              replacement: '2',
              isRegex: false,
            ),
          ],
        ),
      ),
    ]);

    expect(results[0].values, ['1']);
    expect(results[1].values, ['2']);
  });
}
