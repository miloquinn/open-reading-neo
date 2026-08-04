import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/utils/ui_style.dart';

void main() {
  group('appUiStyleFromStorage', () {
    test('defaults to glass effects when no preference is saved', () {
      expect(appUiStyleFromStorage(null), AppUiStyle.glass);
    });

    test('keeps explicitly saved glass preference', () {
      expect(appUiStyleFromStorage('glass'), AppUiStyle.glass);
    });

    test('keeps explicitly saved Material 3 preference', () {
      expect(appUiStyleFromStorage('material3'), AppUiStyle.material3);
    });
  });
}
