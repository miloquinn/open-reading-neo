import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_config.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_crypto_api.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_encoding_api.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_engine.dart';
import 'package:xxread/book_sources/source_engine/scripting/source_script_text_api.dart';

void main() {
  late QuickJsSourceScriptEvaluator evaluator;
  late SourceScriptContext context;
  setUp(() {
    evaluator = QuickJsSourceScriptEvaluator();
    context = SourceScriptContext(
      source: ReadingSourceConfig.fromJson({
        'bookSourceName': 'Compatibility fixture',
        'bookSourceUrl': 'https://books.test',
      }),
    );
  });
  tearDown(() => evaluator.dispose());

  test('DOM helpers apply replacements and preserve multiple attributes', () {
    const html = '<a href="/one">广告甲</a><a href="/two">广告乙</a>';
    expect(
      evaluator.evaluate("java.getString('a@text##广告', '$html')", context),
      '甲\n乙',
    );
    expect(
      evaluator.evaluate("java.getString('a@href', '$html')", context),
      '/one\n/two',
    );
    expect(
      evaluator.evaluate("java.getStringList('a@text##广告', '$html')", context),
      ['甲', '乙'],
    );
  });

  test(
    'JavaImporter honors named packages and MIME base64 has no trailing CRLF',
    () {
      expect(
        evaluator.evaluate(
          "with (new JavaImporter(Packages.java.util)) { Base64.getUrlEncoder().encodeToString([63,63,63]); }",
          context,
        ),
        'Pz8_',
      );
      expect(
        evaluator.evaluate(
          "importPackage(Packages.java.net, Packages.java.util); Base64.getMimeEncoder().encodeToString([97])",
          context,
        ),
        'YQ==',
      );
    },
  );

  test('Java collections remove one entry without clearing the list', () {
    expect(
      evaluator.evaluate(
        "var items = new java.util.ArrayList(['a','b','c']); var removed = items.remove(1); [removed, items.size(), items.get(1), items.remove('a'), items.toArray()]",
        context,
      ),
      [
        'b',
        2,
        'c',
        true,
        ['c'],
      ],
    );
    expect(
      evaluator.evaluate(
        "with (new JavaImporter(Packages.java.util.Base64)) { Base64.getUrlEncoder().encodeToString([63,63,63]); }",
        context,
      ),
      'Pz8_',
    );
  });

  test('honors charset overloads and Java signed bytes', () {
    expect(
      evaluator.evaluate(
        "java.bytesToStr(java.strToBytes('中文', 'GBK'), 'GBK')",
        context,
      ),
      '中文',
    );
    expect(evaluator.evaluate("java.strToBytes('中文', 'GBK')", context), [
      214,
      208,
      206,
      196,
    ]);
    expect(
      evaluator.evaluate("java.bytesToStr([-42,-48,-50,-60], 'GBK')", context),
      '中文',
    );
    expect(
      evaluator.evaluate(
        "java.bytesToStr(java.strToBytes('A中', 'UTF-16LE'), 'UTF-16LE')",
        context,
      ),
      'A中',
    );
  });

  test('uses Java form URL encoding including charset overloads', () {
    expect(
      evaluator.evaluate("java.encodeURI('A中', 'UTF-16')", context),
      'A%FE%FF%4E%2D',
    );
    expect(
      evaluator.evaluate("java.encodeURI('中文 ~!*')", context),
      '%E4%B8%AD%E6%96%87+%7E%21*',
    );
    expect(
      evaluator.evaluate("java.encodeURI('中文 空', 'GBK')", context),
      '%D6%D0%CE%C4+%BF%D5',
    );
    expect(
      evaluator.evaluate(
        "Packages.java.net.URLDecoder.decode('%D6%D0%CE%C4+%BF%D5', 'GBK')",
        context,
      ),
      '中文 空',
    );
  });

  test('supports hex helpers and Base64 charset and flags', () {
    expect(
      evaluator.evaluate("java.hexEncodeToString('中文')", context),
      'e4b8ade69687',
    );
    expect(evaluator.evaluate("java.hexDecodeToByteArray('00FF10')", context), [
      0,
      255,
      16,
    ]);
    expect(
      evaluator.evaluate("java.base64Decode('1tDOxA==', 'GBK')", context),
      '中文',
    );
    expect(evaluator.evaluate("java.base64Encode('???', 10)", context), 'Pz8_');
    expect(evaluator.evaluate("java.base64Encode('a', 11)", context), 'YQ');
    expect(
      evaluator.evaluate("java.base64DecodeToByteArray('Pz8_', 8)", context),
      [63, 63, 63],
    );
    expect(evaluator.evaluate("java.base64Encode('a', 0)", context), 'YQ==\n');
  });

  test('byte host APIs return plain lists across the JS bridge', () {
    const encoding = SourceScriptEncodingApi();
    const crypto = SourceScriptCryptoApi();
    const text = SourceScriptTextApi();
    final hostBytes = encoding.handle('base64DecodeBytes', const ['AQID']);
    for (final bytes in [
      encoding.handle('strToBytes', const ['abc', 'UTF-8']),
      encoding.handle('hexDecodeToBytes', const ['010203']),
      hostBytes,
      text.handle('utf8Bytes', const ['abc']),
      crypto.handle('digestBytes', const ['abc', 'SHA-256']),
      crypto.handle('hmacBytes', const ['abc', 'HmacSHA256', 'key']),
      crypto.handle('symmetricCrypto', [
        'encryptBytes',
        'AES/ECB/PKCS7Padding',
        List<int>.filled(16, 0),
        const <int>[],
        const [1, 2, 3],
      ]),
    ]) {
      expect(bytes, isA<List<int>>());
      expect(bytes, isNot(isA<Uint8List>()));
    }
    expect(hostBytes, [1, 2, 3]);
    expect(
      evaluator.evaluate(
        "java.base64DecodeToByteArray('AQID').join(',')",
        context,
      ),
      '1,2,3',
    );
  });

  test('constructs Java String and accesses named Java package classes', () {
    expect(
      evaluator.evaluate(
        "String(new Packages.java.lang.String([214,208,206,196], 'GBK'))",
        context,
      ),
      '中文',
    );
    expect(
      evaluator.evaluate(
        "new Packages.java.lang.String('中文').getBytes('GBK')",
        context,
      ),
      [214, 208, 206, 196],
    );
    expect(
      evaluator.evaluate(
        "Packages.java.util.Base64.getUrlEncoder().withoutPadding().encodeToString([255,255])",
        context,
      ),
      '__8',
    );
    expect(
      evaluator.evaluate(
        "Packages.java.util.Base64.getUrlDecoder().decode('__8')",
        context,
      ),
      [255, 255],
    );
    expect(
      evaluator.evaluate(
        "Packages.java.net.URLEncoder.encode('a b', 'UTF-8')",
        context,
      ),
      'a+b',
    );
  });

  test('streams MessageDigest updates and resets after digest', () {
    expect(
      evaluator.evaluate("""
      var digest = Packages.java.security.MessageDigest.getInstance('SHA-256');
      digest.update(java.strToBytes('a'));
      digest.update(java.strToBytes('b'));
      [java.bytesToStr([]), digest.digest(java.strToBytes('c')), digest.digest()];
    """, context),
      [
        '',
        [
          186,
          120,
          22,
          191,
          143,
          1,
          207,
          234,
          65,
          65,
          64,
          222,
          93,
          174,
          34,
          35,
          176,
          3,
          97,
          163,
          150,
          23,
          122,
          156,
          180,
          16,
          255,
          97,
          242,
          0,
          21,
          173,
        ],
        [
          227,
          176,
          196,
          66,
          152,
          252,
          28,
          20,
          154,
          251,
          244,
          200,
          153,
          111,
          185,
          36,
          39,
          174,
          65,
          228,
          100,
          155,
          147,
          76,
          164,
          149,
          153,
          27,
          120,
          82,
          184,
          85,
        ],
      ],
    );
  });

  test('connect preserves header overload and response metadata', () async {
    SourceScriptNetworkRequest? captured;
    final result = await evaluator.evaluateAsync(
      """
      var response = java.connect('https://books.test/data', '{"X-Token":"abc"}');
      [response.header('Content-Type'), response.contentType(), response.charset(), response.headers().get('cOnTeNt-TyPe')];
    """,
      SourceScriptContext(
        source: context.source,
        networkHandler: (request) async {
          captured = request;
          return const SourceScriptNetworkResult(
            body: 'ok',
            finalUrl: 'https://books.test/data',
            headers: {'cOnTeNt-TyPe': 'text/html; charset=gbk'},
          );
        },
      ),
    );
    expect(captured?.headers, {'X-Token': 'abc'});
    expect(result, [
      'text/html; charset=gbk',
      'text/html; charset=gbk',
      'gbk',
      'text/html; charset=gbk',
    ]);
  });

  test('scopes imported Java classes to each invocation including failures', () {
    expect(
      evaluator.evaluate(
        "importClass(Packages.java.lang.String); String('中文').getBytes('GBK')",
        context,
      ),
      [214, 208, 206, 196],
    );
    expect(evaluator.evaluate("typeof String('x')", context), 'string');
    expect(
      () => evaluator.evaluate(
        "importPackage(Packages.java.util); throw new Error('fixture')",
        context,
      ),
      throwsA(anything),
    );
    expect(evaluator.evaluate("typeof ArrayList", context), 'undefined');
    expect(
      evaluator.evaluate(
        "importPackage(Packages.java.util); var values = new ArrayList(); values.add('a'); values.add('b'); values.toArray()",
        context,
      ),
      ['a', 'b'],
    );
  });

  test('reports unsupported Java classes by name', () {
    expect(
      () => evaluator.evaluate(
        "new Packages.java.io.File('/tmp/source')",
        context,
      ),
      throwsA(
        predicate(
          (error) => '$error'.contains(
            'Unsupported source Java class or method: java.io.File',
          ),
        ),
      ),
    );
  });
}
