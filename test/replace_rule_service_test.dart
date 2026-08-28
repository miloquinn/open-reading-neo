import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/services/reader/replace_rule_executor.dart';
import 'package:xxread/services/reader/replace_rule_service.dart';

void main() {
  late ReplaceRuleService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = ReplaceRuleService();
  });

  tearDown(() async {
    service.dispose();
    await service.close();
  });

  test('applies enabled regex rules in order and supports deletion', () {
    final rules = [
      const ReplaceRule(
        id: 'ad',
        name: '广告',
        pattern: r'\[广告].*?\n',
        replacement: '',
      ),
      const ReplaceRule(
        id: 'name',
        name: '称呼',
        pattern: '小编',
        replacement: '作者',
        isRegex: false,
      ),
    ];
    expect(
      service.applyRules(rules, '[广告]下载APP\n正文 小编', bookTitle: '书'),
      '正文 作者',
    );
  });

  test('decodes current and legacy reading source fields', () {
    final current = ReplaceRuleService.decodeImport('''[
      {
        "pattern":"广告.*",
        "name":"清理广告",
        "isEnabled":0,
        "scopeContent":1,
        "sortOrder":"9"
      }
    ]''').single;
    expect(current.enabled, isFalse);
    expect(current.scopeContent, isTrue);
    expect(current.order, 9);
    expect(current.isRegex, isTrue);

    final legacy = ReplaceRuleService.decodeImport('''[
      {
        "regex":"广告.*",
        "replacement":"",
        "replaceSummary":"旧版规则",
        "enable":true,
        "serialNumber":3
      }
    ]''').single;
    expect(legacy.name, '旧版规则');
    expect(legacy.pattern, '广告.*');
    expect(legacy.enabled, isTrue);
    expect(legacy.order, 3);
    expect(legacy.isRegex, isFalse);
  });

  test('expands numbered capture groups in replacement text', () {
    const rule = ReplaceRule(
      id: 'capture',
      name: 'capture',
      pattern: r'(广告)[:：]?([^\n]+)',
      replacement: r'$1已移除',
    );
    expect(service.applyRules([rule], '广告：下载应用', bookTitle: '书'), '广告已移除');
  });

  test('uses standard regular expression dot behavior across lines', () {
    const rule = ReplaceRule(
      id: 'dot',
      name: 'dot',
      pattern: r'a.*b',
      replacement: 'removed',
    );
    expect(service.applyRules([rule], 'a\nb', bookTitle: '书'), 'a\nb');
    expect(
      service.applyRules(
        [rule.copyWith(pattern: r'(?s)a.*b')],
        'a\nb',
        bookTitle: '书',
      ),
      'removed',
    );
  });

  test('adapts Legado inline flags and horizontal whitespace', () {
    const rule = ReplaceRule(
      id: 'legado',
      name: 'legado',
      pattern: r'广告|(?i)APP\h+下载',
      replacement: '',
    );
    expect(service.applyRules([rule], '广告 APP  下载', bookTitle: '书'), ' ');

    const classRule = ReplaceRule(
      id: 'legado-class',
      name: 'legado-class',
      pattern: r'字[\h\-]数',
      replacement: '',
    );
    expect(service.applyRules([classRule], '字-数 字 数', bookTitle: '书'), ' ');
  });

  test('separates title and content rules', () {
    const titleRule = ReplaceRule(
      id: 'title',
      name: 'title',
      pattern: '[广告]',
      replacement: '',
      isRegex: false,
      scopeTitle: true,
      scopeContent: false,
    );
    expect(
      service.applyRules([titleRule], '[广告] 第一章', bookTitle: '书', title: true),
      ' 第一章',
    );
    expect(
      service.applyRules([titleRule], '[广告] 正文', bookTitle: '书'),
      '[广告] 正文',
    );
  });

  test('matches semicolon and newline scopes without splitting letter n', () {
    const scoped = ReplaceRule(
      id: 'scope',
      name: 'scope',
      pattern: '广告',
      replacement: '',
      isRegex: false,
      scope: 'Origin Name\nAnother Source',
      excludeScope: 'Blocked Book',
    );
    expect(
      service.applyRules(
        [scoped],
        '正文广告',
        bookTitle: 'Novel',
        sourceName: 'Origin Name',
      ),
      '正文',
    );
    expect(
      service.applyRules(
        [scoped],
        '正文广告',
        bookTitle: 'Blocked Book',
        sourceName: 'Origin Name',
      ),
      '正文广告',
    );
  });

  test('merges imports and persists normalized order', () async {
    await service.load();
    await service.saveAll(const [
      ReplaceRule(
        id: 'original',
        name: '广告',
        pattern: 'ad',
        replacement: '',
        isRegex: false,
      ),
    ]);
    final merged = service.mergeImported(const [
      ReplaceRule(
        id: 'different-id',
        name: '广告',
        pattern: 'ad',
        replacement: 'clean',
        isRegex: false,
        order: 99,
      ),
      ReplaceRule(
        id: 'second',
        name: '推广',
        pattern: 'promo',
        replacement: '',
        isRegex: false,
      ),
    ]);
    await service.saveAll(merged);

    final reloadedService = ReplaceRuleService();
    await reloadedService.load();
    expect(reloadedService.rules, hasLength(2));
    expect(reloadedService.rules.first.id, 'different-id');
    expect(reloadedService.rules.first.replacement, 'clean');
    expect(reloadedService.rules.first.order, 0);
    expect(reloadedService.rules.last.order, 1);
    reloadedService.dispose();
    await reloadedService.close();
  });

  test('keeps state isolated between service instances', () async {
    final otherService = ReplaceRuleService();
    await service.load();
    await otherService.load();

    await service.saveAll(const [
      ReplaceRule(
        id: 'local',
        name: 'local',
        pattern: 'ad',
        replacement: '',
        isRegex: false,
      ),
    ]);

    expect(service.rules.map((rule) => rule.id), ['local']);
    expect(otherService.rules, isEmpty);
    otherService.dispose();
    await otherService.close();
  });

  test('closes an injected executor exactly once', () async {
    final executor = _TrackingReplaceRuleExecutor();
    final disposableService = ReplaceRuleService(executor: executor);

    await disposableService.close();
    await disposableService.close();

    expect(executor.disposeCalls, 1);
    expect(disposableService.load, throwsStateError);
  });

  testWidgets('provider disposal closes its owned service', (tester) async {
    final executor = _TrackingReplaceRuleExecutor();
    await tester.pumpWidget(
      ChangeNotifierProvider<ReplaceRuleService>(
        create: (_) => ReplaceRuleService(executor: executor),
        child: Builder(
          builder: (context) {
            context.read<ReplaceRuleService>();
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(executor.disposeCalls, 1);
  });

  test(
    'does not notify when an in-flight load finishes after dispose',
    () async {
      var notifications = 0;
      service.addListener(() => notifications++);

      final loading = service.load();
      service.dispose();
      await loading;

      expect(notifications, 0);
    },
  );

  test(
    'does not notify when an in-flight save finishes after dispose',
    () async {
      await service.load();
      var notifications = 0;
      service.addListener(() => notifications++);

      final saving = service.saveAll(const [
        ReplaceRule(
          id: 'pending',
          name: 'pending',
          pattern: 'ad',
          replacement: '',
          isRegex: false,
        ),
      ]);
      service.dispose();
      await saving;

      expect(notifications, 0);
    },
  );

  test('rejects invalid regular expressions', () {
    expect(
      () => ReplaceRuleService.validate(
        const ReplaceRule(
          id: 'bad',
          name: 'bad',
          pattern: '(',
          replacement: '',
        ),
      ),
      throwsA(isA<ReplaceRuleValidationException>()),
    );
  });

  test('async batch preserves order, scopes, and capture expansion', () async {
    await service.load();
    await service.saveAll(const [
      ReplaceRule(
        id: 'one',
        name: 'one',
        pattern: r'(广告)(\d+)',
        replacement: r'$2-$1',
        scope: 'Target Source',
        order: 0,
      ),
      ReplaceRule(
        id: 'two',
        name: 'two',
        pattern: '2-广告',
        replacement: 'clean',
        isRegex: false,
        order: 1,
      ),
    ]);

    final result = await service.applyBatchAsync(
      const ['广告1', '广告2'],
      bookTitle: 'Book',
      sourceName: 'Target Source',
    );

    expect(result.values, ['1-广告', 'clean']);
    expect(result.degraded, isFalse);
  });

  test('async cleaning retains non-empty source when rules erase it', () async {
    await service.load();
    await service.saveAll(const [
      ReplaceRule(
        id: 'erase',
        name: 'erase',
        pattern: r'(?s).*',
        replacement: '',
      ),
    ]);

    final result = await service.applyBatchAsync(const [
      'meaningful chapter',
    ], bookTitle: 'Book');

    expect(result.values.single, 'meaningful chapter');
    expect(result.degraded, isTrue);
    expect(
      result.diagnostics.map((item) => item.kind.name),
      contains('emptyOutput'),
    );
  });
}

class _TrackingReplaceRuleExecutor extends ReplaceRuleExecutor {
  var disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}
