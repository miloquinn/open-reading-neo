import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/services/book_source_maintenance_assessment.dart';
import 'package:xxread/book_sources/source_engine/source_health_checker.dart';

void main() {
  test(
    'classifies full, limited, failed, timed out, and unchecked results',
    () {
      expect(
        bookSourceMaintenanceAssessment(_checked('available')).classification,
        BookSourceMaintenanceClassification.available,
      );
      expect(
        bookSourceMaintenanceAssessment(
          _checked(
            'limited',
            checked: const {
              SourceHealthCapability.search,
              SourceHealthCapability.info,
              SourceHealthCapability.catalog,
              SourceHealthCapability.content,
            },
          ),
        ).classification,
        BookSourceMaintenanceClassification.limited,
      );
      expect(
        bookSourceMaintenanceAssessment(
          _checked('failed', failed: const {SourceHealthCapability.content}),
        ).classification,
        BookSourceMaintenanceClassification.failed,
      );
      expect(
        bookSourceMaintenanceAssessment(
          _checked('timeout', timedOut: true),
        ).classification,
        BookSourceMaintenanceClassification.timedOut,
      );
      expect(
        bookSourceMaintenanceAssessment(_source('unchecked')).classification,
        BookSourceMaintenanceClassification.unchecked,
      );
      expect(
        bookSourceMaintenanceAssessment(
          _checked('error'),
          error: StateError('request failed'),
        ).classification,
        BookSourceMaintenanceClassification.unchecked,
      );
    },
  );

  test('one failed optional surface stays limited when reading succeeds', () {
    final source = _checked(
      'limited-failure',
      checked: SourceHealthCheckResult.fullAvailabilityCapabilities,
      failed: const {SourceHealthCapability.discover},
    );

    expect(
      bookSourceMaintenanceAssessment(source).classification,
      BookSourceMaintenanceClassification.limited,
    );
  });
}

RegisteredBookSource _checked(
  String id, {
  Set<SourceHealthCapability> checked =
      SourceHealthCheckResult.fullAvailabilityCapabilities,
  Set<SourceHealthCapability> failed = const {},
  bool timedOut = false,
}) => withSourceHealthCheckResult(
  _source(id),
  SourceHealthCheckResult(
    checked: checked,
    failed: failed,
    checkedAt: DateTime.utc(2026),
    timedOut: timedOut,
  ),
);

RegisteredBookSource _source(String id) => RegisteredBookSource(
  id: id,
  name: id,
  description: '',
  manifestUrl: Uri.parse('https://$id.example/source.json'),
  apiBaseUrl: Uri.parse('https://$id.example/'),
  protocolVersion: 'reading-1',
  languages: const [],
  capabilities: const {'search'},
  enabled: true,
  addedAt: DateTime.utc(2026),
  sourceProtocol: BookSourceProtocolKind.readingSource,
  sourceConfig: {'bookSourceUrl': 'https://$id.example'},
);
