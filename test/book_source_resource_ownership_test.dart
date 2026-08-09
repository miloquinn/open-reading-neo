import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/services/book_source_change_service.dart';
import 'package:xxread/book_sources/services/book_source_client.dart';
import 'package:xxread/book_sources/services/book_source_shelf_service.dart';

void main() {
  group('BookSourceShelfService ownership', () {
    test('does not close an injected client', () {
      final client = _CloseTrackingClient();
      final service = BookSourceShelfService(client: client);

      service.close();
      service.close();

      expect(client.closeCount, 0);
    });

    test('closes a factory-created client exactly once', () {
      final client = _CloseTrackingClient();
      final service = BookSourceShelfService(clientFactory: () => client);

      service.close();
      service.close();

      expect(client.closeCount, 1);
    });
  });

  group('BookSourceChangeService ownership', () {
    test('owns and shares both default-created dependencies', () {
      final events = <String>[];
      final client = _CloseTrackingClient(events: events);
      late BookSourceClient shelfClient;
      final shelfService = _CloseTrackingShelfService(events: events);
      final service = BookSourceChangeService(
        clientFactory: () => client,
        shelfServiceFactory: (resolvedClient) {
          shelfClient = resolvedClient;
          return shelfService;
        },
      );

      service.close();
      service.close();

      expect(shelfClient, same(client));
      expect(shelfService.closeCount, 1);
      expect(client.closeCount, 1);
      expect(events, ['shelf', 'client']);
    });

    test('borrows an injected client and owns the default shelf service', () {
      final client = _CloseTrackingClient();
      late BookSourceClient shelfClient;
      final shelfService = _CloseTrackingShelfService();
      final service = BookSourceChangeService(
        client: client,
        shelfServiceFactory: (resolvedClient) {
          shelfClient = resolvedClient;
          return shelfService;
        },
      );

      service.close();
      service.close();

      expect(shelfClient, same(client));
      expect(shelfService.closeCount, 1);
      expect(client.closeCount, 0);
    });

    test('owns the default client and borrows an injected shelf service', () {
      final client = _CloseTrackingClient();
      final shelfService = _CloseTrackingShelfService();
      final service = BookSourceChangeService(
        clientFactory: () => client,
        shelfService: shelfService,
      );

      service.close();
      service.close();

      expect(shelfService.closeCount, 0);
      expect(client.closeCount, 1);
    });

    test('borrows both injected dependencies', () {
      final client = _CloseTrackingClient();
      final shelfService = _CloseTrackingShelfService();
      final service = BookSourceChangeService(
        client: client,
        shelfService: shelfService,
      );

      service.close();
      service.close();

      expect(shelfService.closeCount, 0);
      expect(client.closeCount, 0);
    });
  });
}

class _CloseTrackingClient extends BookSourceClient {
  _CloseTrackingClient({this.events});

  final List<String>? events;
  int closeCount = 0;

  @override
  void close({bool force = true}) {
    closeCount++;
    events?.add('client');
  }
}

class _CloseTrackingShelfService extends BookSourceShelfService {
  _CloseTrackingShelfService({this.events})
    : super(client: _CloseTrackingClient());

  final List<String>? events;
  int closeCount = 0;

  @override
  void close() {
    closeCount++;
    events?.add('shelf');
  }
}
