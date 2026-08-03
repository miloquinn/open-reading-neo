import 'book_source_registry_storage_stub.dart'
    if (dart.library.io) 'book_source_registry_storage_io.dart'
    as backend;

abstract interface class BookSourceRegistryStorage {
  Future<String?> read();

  /// Returns whether [value] was persisted outside legacy SharedPreferences.
  Future<bool> write(String value);
}

class DefaultBookSourceRegistryStorage implements BookSourceRegistryStorage {
  const DefaultBookSourceRegistryStorage();

  @override
  Future<String?> read() => backend.readBookSourceRegistry();

  @override
  Future<bool> write(String value) => backend.writeBookSourceRegistry(value);
}
