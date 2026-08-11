import 'dart:typed_data';

import 'package:epubx/epubx.dart';
import 'package:html/parser.dart' as html_parser;

class EnhancedBookMetadata {
  const EnhancedBookMetadata({
    required this.title,
    required this.author,
    required this.estimatedPages,
    this.description,
    this.language,
    this.publisher,
    this.publishDate,
    this.isbn,
    this.coverImage,
    this.tags,
    this.additionalInfo,
    this.textEncoding,
  });

  final String title;
  final String author;
  final String? description;
  final String? language;
  final String? publisher;
  final String? publishDate;
  final String? isbn;
  final Uint8List? coverImage;
  final int estimatedPages;
  final List<String>? tags;
  final Map<String, dynamic>? additionalInfo;
  final String? textEncoding;
}

typedef ImportProgressCallback = void Function(double progress, String message);

typedef ImportMetadataExtractor =
    Future<EnhancedBookMetadata> Function(
      String filePath,
      String fileName,
      String extension,
      ImportProgressCallback? onProgress,
    );

Future<Map<String, dynamic>> extractEpubMetadataInIsolate(
  Uint8List bytes,
) async {
  final book = await EpubReader.openBook(bytes);
  final package = book.Schema?.Package;
  final metadata = package?.Metadata;
  final manifest = package?.Manifest?.Items ?? const <EpubManifestItem>[];
  final manifestById = <String, EpubManifestItem>{
    for (final item in manifest)
      if (item.Id != null) item.Id!: item,
  };

  Uint8List? coverImage;
  try {
    EpubManifestItem? coverItem;
    for (final item in manifest) {
      if ((item.Properties ?? '')
          .split(RegExp(r'\s+'))
          .contains('cover-image')) {
        coverItem = item;
        break;
      }
    }
    if (coverItem == null) {
      String? coverId;
      final metaItems = metadata?.MetaItems;
      if (metaItems != null) {
        for (final item in metaItems) {
          if (item.Name?.toLowerCase() == 'cover') {
            coverId = item.Content;
            break;
          }
        }
      }
      coverItem = coverId == null ? null : manifestById[coverId];
    }
    final href = coverItem?.Href;
    final reference = href == null ? null : book.Content?.Images?[href];
    if (reference != null) {
      coverImage = Uint8List.fromList(await reference.readContentAsBytes());
    }
  } catch (_) {
    // A malformed optional cover must not make an otherwise readable EPUB fail.
  }

  final htmlRefs = book.Content?.Html ?? const {};
  var htmlBytes = 0;
  var chapterCount = 0;
  String? fallbackDescription;
  for (final itemRef in package?.Spine?.Items ?? const <EpubSpineItemRef>[]) {
    final href = manifestById[itemRef.IdRef]?.Href;
    final reference = href == null ? null : htmlRefs[href];
    if (reference == null) continue;
    chapterCount++;
    htmlBytes += reference.getContentFileEntry().size;
    if ((metadata?.Description ?? '').trim().isNotEmpty ||
        fallbackDescription != null) {
      continue;
    }
    try {
      final document = html_parser.parse(await reference.readContentAsText());
      final text = document.body?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text != null && text.isNotEmpty) {
        fallbackDescription = text.length <= 500
            ? text
            : '${text.substring(0, 497)}...';
      }
    } catch (_) {
      // Description inference is optional; later chapters may still be valid.
    }
  }
  if (chapterCount == 0) {
    chapterCount = htmlRefs.length;
    for (final reference in htmlRefs.values) {
      htmlBytes += reference.getContentFileEntry().size;
    }
  }

  String? isbn;
  final identifiers = metadata?.Identifiers;
  if (identifiers != null) {
    for (final identifier in identifiers) {
      if (identifier.Scheme?.toLowerCase().contains('isbn') == true) {
        isbn = identifier.Identifier;
        break;
      }
    }
  }
  final description = (metadata?.Description ?? '').trim();
  return <String, dynamic>{
    'title': book.Title ?? '',
    'author': book.Author ?? '',
    'description': description.isEmpty ? fallbackDescription : description,
    'language': metadata?.Languages?.firstOrNull,
    'publisher': metadata?.Publishers?.firstOrNull,
    'publishDate': metadata?.Dates?.firstOrNull?.Date,
    'isbn': isbn,
    'coverImage': coverImage,
    'estimatedPages': (htmlBytes / 3000).ceil().clamp(1, 9999),
    'tags': metadata?.Subjects
        ?.where((subject) => subject.isNotEmpty)
        .toList(growable: false),
    'additionalInfo': <String, dynamic>{
      'format': 'EPUB',
      'hasImages': book.Content?.Images?.isNotEmpty == true,
      'chapterCount': chapterCount,
    },
  };
}
