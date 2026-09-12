import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_storage_paths.dart';

/// Database rows carry stable managed paths; application Book objects carry
/// paths usable by File/Image.file. Never cache a sandbox root in persisted data.
Future<List<Book>> booksFromStorageMaps(
  List<Map<String, dynamic>> rows, {
  Future<Directory> Function()? documentsDirectory,
}) async {
  final needsResolution =
      !kIsWeb &&
      rows.any((row) {
        return ['filePath', 'cover_image_path'].any((key) {
          final value = row[key];
          return value is String && BookStoragePaths.needsResolution(value);
        });
      });
  if (!needsResolution) return rows.map(Book.fromMap).toList(growable: false);
  final directory =
      await (documentsDirectory ?? getApplicationDocumentsDirectory)();
  final paths = BookStoragePaths(directory.path);
  return rows
      .map((row) => Book.fromMap(paths.decodeBookMap(row)))
      .toList(growable: false);
}

Future<Book> bookFromStorageMap(
  Map<String, dynamic> row, {
  Future<Directory> Function()? documentsDirectory,
}) async => (await booksFromStorageMaps([
  row,
], documentsDirectory: documentsDirectory)).single;

Future<String> resolveBookStoragePath(
  String value, {
  Future<Directory> Function()? documentsDirectory,
}) async {
  if (kIsWeb || !BookStoragePaths.needsResolution(value)) return value;
  final directory =
      await (documentsDirectory ?? getApplicationDocumentsDirectory)();
  return BookStoragePaths(directory.path).decode(value);
}

Future<Map<String, dynamic>> bookToStorageMap(
  Book book, {
  Future<Directory> Function()? documentsDirectory,
}) async {
  if (kIsWeb) return book.toMap();
  final directory =
      await (documentsDirectory ?? getApplicationDocumentsDirectory)();
  return BookStoragePaths(directory.path).encodeBookMap(book.toMap());
}
