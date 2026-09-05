import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart';
import 'package:xxread/book_sources/source_engine/rules/source_rule_xpath.dart';
import 'package:xxread/book_sources/source_engine/source_rule_engine.dart';

void main() {
  const engine = SourceRuleEngine();

  SourceRuleDocument document(String body) => SourceRuleDocument.parse(
    '<html><body>$body</body></html>',
    Uri.parse('https://books.test/book/1'),
  );

  List<String> ids(List<Object?> nodes) => nodes
      .cast<Element>()
      .map((element) => element.id)
      .toList(growable: false);

  group('SourceRuleEngine XPath positional predicates', () {
    test('selects the complete Shengxu catalog instead of latest chapters', () {
      final latest = List.generate(
        15,
        (index) =>
            '<li><a href="/latest/${15 - index}">第${15 - index}章</a></li>',
      ).join();
      final complete = List.generate(
        18,
        (index) =>
            '<li><a href="/chapter/${index + 1}">第${index + 1}章</a></li>',
      ).join();
      final page = document('''
        <main>
          <div class="notice">无关内容</div>
          <div class="card mt20">
            <h2>最新章节</h2>
            <ul class="dirlist clearfix">$latest</ul>
          </div>
          <div class="card mt20">
            <h2>完整目录</h2>
            <ul class="dirlist clearfix">$complete</ul>
          </div>
        </main>
      ''');

      final chapters = engine.evaluateList(
        page,
        null,
        '//div[@class="card mt20"][2]'
        '//ul[@class="dirlist clearfix"]/li',
      );
      final names = chapters
          .map((chapter) => engine.evaluateString(page, chapter, '//a/text()'))
          .toList(growable: false);

      expect(names, List.generate(18, (index) => '第${index + 1}章'));
    });

    test('applies predicates from left to right', () {
      final page = document('''
        <section>
          <div id="first-x" class="x">first x</div>
          <div id="second-node" class="y">second node</div>
          <div id="second-x" class="x">second x</div>
        </section>
      ''');

      expect(
        ids(engine.evaluateList(page, null, '//section/div[@class="x"][2]')),
        ['second-x'],
      );
      expect(
        engine.evaluateList(page, null, '//section/div[2][@class="x"]'),
        isEmpty,
      );
    });

    test('evaluates positions independently for every parent context', () {
      final page = document('''
        <article>
          <div id="a1" class="chapter">a1</div>
          <div class="ad">ad</div>
          <div id="a2" class="chapter">a2</div>
        </article>
        <aside>
          <div id="b1" class="chapter">b1</div>
          <div class="ad">ad</div>
          <div id="b2" class="chapter">b2</div>
        </aside>
      ''');

      expect(
        ids(engine.evaluateList(page, null, '//div[@class="chapter"][2]')),
        ['a2', 'b2'],
      );
    });

    test('reindexes the node sequence after each positional predicate', () {
      final page = document('''
        <ul id="a"><li id="a1">a1</li><li id="a2">a2</li><li id="a3">a3</li></ul>
        <ul id="b"><li id="b1">b1</li><li id="b2">b2</li><li id="b3">b3</li></ul>
      ''');

      expect(ids(engine.evaluateList(page, null, '//ul/li[position()>1][1]')), [
        'a2',
        'b2',
      ]);
    });

    test('counts mixed wildcard candidates after filtering', () {
      final page = document('''
        <section><div class="x">one</div><p>ad</p>
          <span id="second" class="x">two</span><p class="x">three</p>
        </section>
      ''');
      expect(
        ids(engine.evaluateList(page, null, '//section/*[@class="x"][2][1]')),
        ['second'],
      );
      expect(engine.evaluateList(page, null, '//section/*[0]'), isEmpty);
      expect(engine.evaluateList(page, null, '//section/*[-1]'), isEmpty);
    });
  });

  group('SourceRuleEngine XPath axes and node sets', () {
    test('keeps the document node as the XPath evaluation root', () {
      final page = document('<p>root content</p>');

      for (final rule in ['@xpath:/html', '//html']) {
        final matches = engine.evaluateList(page, null, rule).cast<Element>();
        expect(matches.map((element) => element.localName), [
          'html',
        ], reason: rule);
      }
    });

    test('counts following siblings relative to the current context node', () {
      final page = document('''
        <ul>
          <li class="anchor">anchor</li>
          <div class="separator"></div>
          <li id="next">next</li>
          <li id="later" class="wanted">later</li>
        </ul>
      ''');

      expect(
        ids(
          engine.evaluateList(
            page,
            null,
            '//li[@class="anchor"]/following-sibling::li[1]',
          ),
        ),
        ['next'],
      );
    });

    test('filters following siblings before applying their position', () {
      final page = document('''
        <ul>
          <li class="anchor">anchor</li>
          <li>other</li>
          <li id="first-wanted" class="wanted">first wanted</li>
          <li id="second-wanted" class="wanted">second wanted</li>
        </ul>
      ''');

      expect(
        ids(
          engine.evaluateList(
            page,
            null,
            '//li[@class="anchor"]'
            '/following-sibling::li[@class="wanted"][1]',
          ),
        ),
        ['first-wanted'],
      );
    });

    test('deduplicates overlapping contexts in document order', () {
      final page = document('''
        <div id="outer">
          <b id="before">before</b>
          <div id="inner"><b id="deep">deep</b></div>
          <b id="after">after</b>
        </div>
      ''');

      expect(ids(engine.evaluateList(page, null, '//div//b')), [
        'before',
        'deep',
        'after',
      ]);
    });

    test('deduplicates following siblings from multiple context nodes', () {
      final page = document('''
        <ul><li id="a">a</li><li id="b">b</li><li id="c">c</li></ul>
      ''');
      expect(
        ids(engine.evaluateList(page, null, '//li/following-sibling::li')),
        ['b', 'c'],
      );
      expect(
        ids(
          engine.evaluateList(
            page,
            (page.value as Document).getElementById('a'),
            '@xpath:following-sibling::li',
          ),
        ),
        ['b', 'c'],
      );
    });

    test('descendant attributes keep node identity and document order', () {
      final page = document('''
        <div href="/outer"><a href="/one">one</a>
          <div><a href="/two">two</a></div>
          <a href="/one">another node with the same value</a>
        </div>
      ''');
      for (final rule in ['//@href', '//div//@href']) {
        expect(evaluateSourceXPath(page.value, rule, listMode: true), [
          '/outer',
          '/one',
          '/two',
          '/one',
        ], reason: rule);
        expect(evaluateSourceXPath(page.value, rule, listMode: false), [
          '/outer',
        ], reason: rule);
      }
    });

    test(
      'returns an empty node set for non-matches and out-of-range positions',
      () {
        final page = document('<ul><li id="only"></li></ul>');

        expect(
          engine.evaluateList(page, null, '//li[@class="missing"][1]'),
          isEmpty,
        );
        expect(engine.evaluateList(page, null, '//li[99]'), isEmpty);
      },
    );
  });
}
