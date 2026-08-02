import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/services/core/custom_font_service.dart';

Uint8List _validTtfBytes([int marker = 1]) =>
    Uint8List.fromList(<int>[0, 1, 0, 0, marker, 2, 3, 4]);

Uint8List _variableTtfBytes({int min = 200, int max = 900}) {
  final bytes = Uint8List(68);
  final data = ByteData.sublistView(bytes);
  bytes.setAll(0, const <int>[0, 1, 0, 0]);
  data.setUint16(4, 1, Endian.big);
  bytes.setAll(12, 'fvar'.codeUnits);
  data.setUint32(20, 32, Endian.big);
  data.setUint32(24, 36, Endian.big);
  data.setUint16(32, 1, Endian.big);
  data.setUint16(36, 16, Endian.big);
  data.setUint16(40, 1, Endian.big);
  data.setUint16(42, 20, Endian.big);
  bytes.setAll(48, 'wght'.codeUnits);
  data.setInt32(52, min << 16, Endian.big);
  data.setInt32(56, 400 << 16, Endian.big);
  data.setInt32(60, max << 16, Endian.big);
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('imports, persists, reloads, renames and deletes a font', () async {
    final sandbox = await Directory.systemTemp.createTemp('custom-font-test-');
    addTearDown(() => sandbox.delete(recursive: true));
    final registeredFamilies = <String>[];
    final service = CustomFontService(
      supportDirectory: () async => sandbox,
      registrar: (family, bytes) async => registeredFamilies.add(family),
    );

    await service.initialize();
    final imported = await service.importFontBytes(
      fileName: 'Reading Font.ttf',
      bytes: _validTtfBytes(),
    );

    expect(imported.status, CustomFontImportStatus.imported);
    expect(imported.font?.displayName, 'Reading Font');
    expect(imported.font?.weightAxisInspected, isTrue);
    expect(imported.font?.variableWeightMin, isNull);
    expect(service.fonts, hasLength(1));
    expect(registeredFamilies, <String>[imported.font!.runtimeFamily]);

    final duplicate = await service.importFontBytes(
      fileName: 'renamed-copy.ttf',
      bytes: _validTtfBytes(),
    );
    expect(duplicate.status, CustomFontImportStatus.duplicate);
    expect(service.fonts, hasLength(1));

    await service.renameFont(imported.font!.id, 'My Reading Font');
    expect(service.fonts.single.displayName, 'My Reading Font');

    final reloadedFamilies = <String>[];
    final reloaded = CustomFontService(
      supportDirectory: () async => sandbox,
      registrar: (family, bytes) async => reloadedFamilies.add(family),
    );
    await reloaded.initialize();
    expect(reloaded.fonts.single.displayName, 'My Reading Font');
    expect(await reloaded.ensureLoaded(imported.font!.id), isTrue);
    expect(reloadedFamilies, <String>[imported.font!.runtimeFamily]);

    await reloaded.deleteFont(imported.font!.id);
    expect(reloaded.fonts, isEmpty);
  });

  test('detects and persists a custom font wght variation axis', () async {
    final sandbox = await Directory.systemTemp.createTemp('custom-font-test-');
    addTearDown(() => sandbox.delete(recursive: true));
    final service = CustomFontService(
      supportDirectory: () async => sandbox,
      registrar: (family, bytes) async {},
    );
    await service.initialize();

    final imported = await service.importFontBytes(
      fileName: 'Variable Reading.ttf',
      bytes: _variableTtfBytes(min: 150, max: 850),
    );

    expect(imported.font?.weightAxisInspected, isTrue);
    expect(imported.font?.variableWeightMin, 150);
    expect(imported.font?.variableWeightMax, 850);

    final manifest = File(
      '${sandbox.path}${Platform.pathSeparator}custom_fonts'
      '${Platform.pathSeparator}manifest.json',
    );
    final legacyManifest = jsonDecode(await manifest.readAsString()) as List;
    final legacyRecord = legacyManifest.single as Map<String, dynamic>;
    legacyRecord
      ..remove('variableWeightMin')
      ..remove('variableWeightMax')
      ..remove('weightAxisInspected');
    await manifest.writeAsString(jsonEncode(legacyManifest));

    final reloaded = CustomFontService(
      supportDirectory: () async => sandbox,
      registrar: (family, bytes) async {},
    );
    await reloaded.initialize();
    expect(reloaded.fonts.single.variableWeightMin, 150);
    expect(reloaded.fonts.single.variableWeightMax, 850);
    expect(reloaded.fonts.single.weightAxisInspected, isTrue);
  });

  test('rejects unsupported extensions and invalid font signatures', () async {
    final sandbox = await Directory.systemTemp.createTemp('custom-font-test-');
    addTearDown(() => sandbox.delete(recursive: true));
    final service = CustomFontService(
      supportDirectory: () async => sandbox,
      registrar: (family, bytes) async {},
    );
    await service.initialize();

    await expectLater(
      service.importFontBytes(fileName: 'font.woff', bytes: _validTtfBytes()),
      throwsA(
        isA<CustomFontException>().having(
          (error) => error.code,
          'code',
          CustomFontErrorCode.unsupportedFormat,
        ),
      ),
    );
    await expectLater(
      service.importFontBytes(
        fileName: 'font.ttf',
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      ),
      throwsA(
        isA<CustomFontException>().having(
          (error) => error.code,
          'code',
          CustomFontErrorCode.invalidFont,
        ),
      ),
    );
  });
}
