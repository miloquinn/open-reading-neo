import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/pages/reader/comic/comic_debug_log.dart';

void main() {
  test('comic debug URLs redact credentials, query values, and fragments', () {
    final output = comicDebugUri(
      Uri.parse('https://user:pass@example.test/page?token=secret&id=123#key'),
    );

    expect(output, contains('%3Credacted%3E'));
    expect(output, contains('token=%3Credacted%3E'));
    expect(output, contains('id=%3Credacted%3E'));
    expect(output, isNot(contains('secret')));
    expect(output, isNot(contains('user')));
    expect(output, isNot(contains('pass')));
    expect(output, isNot(contains('123')));
  });

  test('comic debug headers expose names but never values', () {
    final output = comicDebugHeaderNames({
      'Cookie': 'sid=secret',
      'Referer': 'https://private.example/path',
      'Authorization': 'Bearer secret',
    });

    expect(output, 'authorization,cookie,referer');
    expect(output, isNot(contains('secret')));
    expect(output, isNot(contains('private.example')));
  });
}
