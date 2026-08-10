import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/services/reader/replace_rule_service.dart';

void main() {
  final service = ReplaceRuleService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service.resetForTesting();
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

    service.resetForTesting();
    await service.load();
    expect(service.rules, hasLength(2));
    expect(service.rules.first.id, 'different-id');
    expect(service.rules.first.replacement, 'clean');
    expect(service.rules.first.order, 0);
    expect(service.rules.last.order, 1);
  });

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
}
