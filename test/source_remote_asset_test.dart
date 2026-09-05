import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_remote_asset.dart';

void main() {
  test(
    'preserves image headers when nested options contain later delimiters',
    () {
      final options = jsonEncode({
        'headers': {'Referer': 'https://reader.test/', 'Cookie': 'a=1; b=2'},
        'unused': [
          {'one': 1},
          {'two': 2},
        ],
      });
      final asset = parseRemoteAsset(
        '../images/a,b.jpg,$options',
        Uri.parse('https://cdn.test/book/chapter/1'),
        {'User-Agent': 'fixture', 'Referer': 'https://fallback.test/'},
      );

      expect(asset?.url, Uri.parse('https://cdn.test/book/images/a,b.jpg'));
      expect(asset?.headers, {
        'User-Agent': 'fixture',
        'Referer': 'https://reader.test/',
        'Cookie': 'a=1; b=2',
      });
    },
  );

  test('keeps legacy image options and rejects embedded image schemes', () {
    final baseUri = Uri.parse('https://books.test/chapter/1');
    final asset = parseRemoteAsset(
      "//cdn.test/1.jpg,{headers:{Referer:'https://reader.test/'}}",
      baseUri,
    );
    expect(asset?.url, Uri.parse('https://cdn.test/1.jpg'));
    expect(asset?.headers, {'Referer': 'https://reader.test/'});
    expect(parseRemoteAsset('data:image/png;base64,AAAA', baseUri), isNull);
    expect(parseRemoteAsset('javascript:alert(1)', baseUri), isNull);
  });
}
