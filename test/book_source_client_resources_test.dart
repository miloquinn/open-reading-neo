import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_client_resources.dart';
import 'package:xxread/book_sources/source_engine/source_login_ui.dart';
import 'package:xxread/book_sources/source_engine/source_runtime.dart';

void main() {
  test(
    'factory-created runtime closes before Dio once and forwards force',
    () async {
      final order = <String>[];
      final resources = BookSourceClientResources.create(
        dioFactory: Dio.new,
        closeDio: (dio, {required bool force}) => order.add('dio:$force'),
        runtimeFactory: () => _TrackingRuntime(order),
        additionalProtocolsEnabled: () async => true,
      );

      await resources.readingBackend.loadLoginFields(_readingSource());
      resources.close(force: false);
      resources.close(force: true);

      expect(order, ['runtime:false', 'dio:false']);
    },
  );

  test('unused lazy runtime is not created during close', () {
    final order = <String>[];
    var runtimeCreates = 0;
    final resources = BookSourceClientResources.create(
      dioFactory: Dio.new,
      closeDio: (dio, {required bool force}) => order.add('dio:$force'),
      runtimeFactory: () {
        runtimeCreates++;
        return _TrackingRuntime(order);
      },
    );

    resources.close();

    expect(runtimeCreates, 0);
    expect(order, ['dio:true']);
  });

  test('injected runtime and Dio are borrowed', () async {
    final order = <String>[];
    final resources = BookSourceClientResources.create(
      dio: Dio(),
      runtime: _TrackingRuntime(order),
      additionalProtocolsEnabled: () async => true,
      closeDio: (dio, {required bool force}) => order.add('dio:$force'),
    );

    await resources.readingBackend.loadLoginFields(_readingSource());
    resources.close(force: false);

    expect(order, isEmpty);
  });
}

RegisteredBookSource _readingSource() => RegisteredBookSource(
  id: 'reading',
  name: 'Reading',
  description: '',
  manifestUrl: Uri.parse('https://example.test/source.json'),
  apiBaseUrl: Uri.parse('https://example.test/api/'),
  protocolVersion: '1.0',
  languages: const [],
  capabilities: const {},
  enabled: true,
  addedAt: DateTime(2025),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: const {},
);

class _TrackingRuntime extends SourceRuntime {
  _TrackingRuntime(this.order);

  final List<String> order;

  @override
  Future<List<SourceLoginField>> loadLoginFields(
    RegisteredBookSource registered,
  ) async => const [];

  @override
  void close({bool force = true}) {
    order.add('runtime:$force');
  }
}
