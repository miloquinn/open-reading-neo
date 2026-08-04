import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/widgets/qr_code_view.dart';

void main() {
  test('TOTP QR encoder is deterministic and keeps finder patterns', () {
    const uri =
        'otpauth://totp/OpenReading:reader?secret=BASE32SECRET&issuer=OpenReading';
    final first = encodeQrModules(uri);
    final second = encodeQrModules(uri);

    expect(first, second);
    expect(first.length, greaterThanOrEqualTo(21));
    expect(first.every((row) => row.length == first.length), isTrue);
    expect(_finderPatternMatches(first, 0, 0), isTrue);
    expect(_finderPatternMatches(first, 0, first.length - 7), isTrue);
    expect(_finderPatternMatches(first, first.length - 7, 0), isTrue);
    expect(
      first.expand((row) => row).where((module) => module).length,
      inInclusiveRange(
        first.length * first.length ~/ 3,
        first.length * first.length * 2 ~/ 3,
      ),
    );
  });
}

bool _finderPatternMatches(List<List<bool>> modules, int row, int column) {
  for (var r = 0; r < 7; r++) {
    for (var c = 0; c < 7; c++) {
      final expected =
          r == 0 ||
          r == 6 ||
          c == 0 ||
          c == 6 ||
          (r >= 2 && r <= 4 && c >= 2 && c <= 4);
      if (modules[row + r][column + c] != expected) return false;
    }
  }
  return true;
}
