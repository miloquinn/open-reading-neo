import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/pages/book_sources/models/source_edit_draft.dart';
import 'package:xxread/pages/book_sources/models/source_edit_fields.dart';

void main() {
  final raw = <String, dynamic>{
    'bookSourceUrl': 'https://example.org',
    'bookSourceName': 'Original',
    'bookSourceGroup': 'Imported',
    'searchUrl': '/search?q={{key}}',
    'header': {'User-Agent': 'custom'},
    'ruleSearch': jsonEncode({
      'bookList': 'li',
      'name': 'a@text',
      'future': [1, true],
    }),
    'ruleContent': {
      'content': '#content@text',
      'future': {'version': 2},
    },
    'future': {
      'nested': [false, 42],
    },
  };

  SourceEditDraft draft() => SourceEditDraft(
    ReadingSourceConfig.fromJson(
      raw,
    ).toRegisteredSource().copyWith(groups: ['Local']),
  );

  Map<String, dynamic> build(
    SourceEditDraft draft,
    Map<String, String> edits,
  ) => draft.build(
    values: edits,
    enabled: true,
    enabledExplore: true,
    enabledCookieJar: false,
    type: 0,
  );

  test(
    'unchanged encoded rules and unknown values retain their JSON types',
    () {
      final result = build(draft(), {'bookSourceName': 'Renamed'});
      expect(result['ruleSearch'], raw['ruleSearch']);
      expect(result['ruleContent'], raw['ruleContent']);
      expect(result['header'], raw['header']);
      expect(result['future'], raw['future']);
      expect(result['bookSourceGroup'], 'Local');
      expect(result['bookSourceName'], 'Renamed');
      expect(raw['bookSourceName'], 'Original');
    },
  );

  test(
    'multiple edits merge into encoded rule object without losing extensions',
    () {
      final result = build(draft(), {
        'ruleSearch.name': 'h2@text',
        'ruleSearch.bookList': '.book',
        'ruleContent.content': 'article@textNodes',
      });
      expect(result['ruleSearch'], {
        'bookList': '.book',
        'name': 'h2@text',
        'future': [1, true],
      });
      expect(result['ruleContent'], {
        'content': 'article@textNodes',
        'future': {'version': 2},
      });
      expect(raw['ruleSearch'], isA<String>());
      expect((raw['ruleContent'] as Map)['content'], '#content@text');
    },
  );

  test('clearing a rule persists the explicit empty string', () {
    final result = build(draft(), {'ruleContent.content': ''});
    expect((result['ruleContent'] as Map)['content'], '');
  });

  test(
    'structured input validates and retains its original container type',
    () {
      expect(build(draft(), {'header': ''})['header'], '');
      expect(build(draft(), {'header': '{"User-Agent":"new"}'})['header'], {
        'User-Agent': 'new',
      });
      expect(() => build(draft(), {'header': '[]'}), throwsFormatException);
      expect(
        () => build(draft(), {'header': '{broken'}),
        throwsFormatException,
      );
    },
  );

  test('malformed rule group cannot be silently replaced by an empty form', () {
    final source = ReadingSourceConfig.fromJson({
      ...raw,
      'ruleSearch': '{broken',
    }).toRegisteredSource();
    expect(
      () => SourceEditDraft(
        source,
      ).text(const SourceEditField('name', group: 'ruleSearch')),
      throwsFormatException,
    );
  });

  test(
    'blank legacy rule strings remain editable without touching other groups',
    () {
      final source = ReadingSourceConfig.fromJson({
        ...raw,
        'ruleExplore': '  ',
      }).toRegisteredSource();
      final edit = SourceEditDraft(source);
      expect(
        edit.text(const SourceEditField('bookList', group: 'ruleExplore')),
        '',
      );
      expect(build(edit, {})['ruleExplore'], '  ');
      expect(build(edit, {'ruleExplore.bookList': 'li'})['ruleExplore'], {
        'bookList': 'li',
      });
    },
  );

  test('invalid URL target is rejected before persistence', () {
    expect(
      () => build(draft(), {'bookSourceUrl': 'invalid'}),
      throwsFormatException,
    );
  });
}
