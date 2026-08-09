import 'package:flutter/foundation.dart';
import 'package:xxread/book_sources/models/registered_book_source.dart';
import 'package:xxread/book_sources/protocol/book_source_protocol.dart';

/// A book returned by one concrete registered source.
@immutable
class SourcedBook {
  const SourcedBook({required this.source, required this.book});

  final RegisteredBookSource source;
  final BookSourceBook book;

  SourcedBook copyWith({BookSourceBook? book}) =>
      SourcedBook(source: source, book: book ?? this.book);
}
