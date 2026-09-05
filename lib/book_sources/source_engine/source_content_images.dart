import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'source_remote_asset.dart';

typedef SourceContentImagePage = ({String content, Uri baseUri});

class SourceContentImageAccumulator {
  final Map<Uri, SourceRuntimeRemoteAsset> _assets = {};

  void add(SourceRuntimeRemoteAsset asset) {
    final previous = _assets[asset.url];
    _assets[asset.url] = previous == null
        ? asset
        : SourceRuntimeRemoteAsset(
            url: asset.url,
            headers: Map.unmodifiable({...previous.headers, ...asset.headers}),
          );
  }

  void addAll(Iterable<SourceRuntimeRemoteAsset> assets) {
    for (final asset in assets) {
      add(asset);
    }
  }

  bool get isEmpty => _assets.isEmpty;
  bool get isNotEmpty => _assets.isNotEmpty;
  List<SourceRuntimeRemoteAsset> get values =>
      _assets.values.toList(growable: false);
}

/// Extracts remote image assets from evaluated chapter content without
/// depending on runtime state or performing network requests.
class SourceContentImageExtractor {
  const SourceContentImageExtractor();

  List<SourceRuntimeRemoteAsset> extract(
    Iterable<SourceContentImagePage> pages, {
    Map<String, String> fallbackHeaders = const {},
    bool allowPlainValues = false,
  }) {
    final assets = SourceContentImageAccumulator();

    bool add(String raw, Uri baseUri, {bool srcset = false}) {
      final value = srcset ? _firstSrcsetCandidate(raw) : raw.trim();
      final asset = parseRemoteAsset(value, baseUri, fallbackHeaders);
      if (asset == null) return false;
      assets.add(asset);
      return true;
    }

    for (final page in pages) {
      final content = page.content.trim();
      if (content.isEmpty) continue;
      if (allowPlainValues && !content.contains('<')) {
        for (final value in content.split(RegExp(r'[\r\n]+'))) {
          if (_looksLikePlainImageValue(value)) {
            add(value, page.baseUri, srcset: _hasSrcsetDescriptor(value));
          }
        }
        continue;
      }

      final fragment = html_parser.parseFragment(content);
      for (final element in fragment.querySelectorAll('*')) {
        for (final name in _attributeNames) {
          final raw = element.attributes[name];
          if (raw == null || raw.trim().isEmpty) {
            continue;
          }
          if (add(raw, page.baseUri, srcset: name.endsWith('srcset'))) break;
        }
      }

      // Imported reading-source rules may append request options inside an HTML
      // attribute. Nested quotes can make a standards parser truncate the
      // value, so recover only this narrow compatibility shape from raw HTML.
      for (final match in _legacyAttributePattern.allMatches(content)) {
        final raw = match.group(2)!;
        if (raw.contains(RegExp(r',\s*\{'))) add(raw, page.baseUri);
      }
      for (final match in _legacyOptionsPattern.allMatches(content)) {
        add(match.group(1)!, page.baseUri);
      }
    }
    return assets.values;
  }

  List<SourceContentImagePage> recoverComicContainers(
    Iterable<SourceContentImagePage> pages,
  ) {
    final recovered = <SourceContentImagePage>[];
    for (final page in pages) {
      final body = _fallbackComicImageHtml(page.content);
      if (body.isNotEmpty) {
        recovered.add((content: body, baseUri: page.baseUri));
      }
    }
    return recovered;
  }
}

const _attributeNames = [
  'src',
  'data-src',
  'data-original',
  'data-original-src',
  'data-lazy',
  'data-lazy-src',
  'data-url',
  'data-image',
  'data-srcset',
  'srcset',
];

final _legacyAttributePattern = RegExp(
  r'''(?:src|data-src|data-original|data-original-src|data-lazy|data-lazy-src|data-url|data-image)\s*=\s*(["'])(.*?)\1''',
  caseSensitive: false,
  dotAll: true,
);

final _legacyOptionsPattern = RegExp(
  r'''(?:src|data-src|data-original|data-original-src|data-lazy|data-lazy-src|data-url|data-image)\s*=\s*["'](.*?,\s*\{headers:.*?\}\})["']''',
  caseSensitive: false,
  dotAll: true,
);

String _firstSrcsetCandidate(String raw) {
  if (raw.contains(RegExp(r',\s*\{'))) return raw.trim();
  final first = raw.split(',').first.trim();
  final whitespace = first.indexOf(RegExp(r'\s'));
  return whitespace < 0 ? first : first.substring(0, whitespace);
}

bool _looksLikePlainImageValue(String raw) {
  final value = raw.trim();
  if (value.isEmpty || value.startsWith('{') || value.startsWith('[')) {
    return false;
  }
  final optionsStart = value.lastIndexOf(RegExp(r',\s*\{'));
  final url = optionsStart < 0
      ? value
      : value.substring(0, optionsStart).trim();
  if (RegExp(r'\s').hasMatch(url) && !_hasSrcsetDescriptor(url)) return false;
  if (url.startsWith(RegExp(r'https?://', caseSensitive: false)) ||
      url.startsWith('//') ||
      url.startsWith('/') ||
      url.startsWith('./') ||
      url.startsWith('../')) {
    return true;
  }
  return RegExp(
    r'\.(?:avif|bmp|gif|jpe?g|png|svg|webp)(?:[?#,]|$)',
    caseSensitive: false,
  ).hasMatch(url);
}

bool _hasSrcsetDescriptor(String value) => RegExp(
  r'\s+(?:\d+(?:\.\d+)?x|\d+w)(?:\s*,|$)',
  caseSensitive: false,
).hasMatch(value);

String _fallbackComicImageHtml(String body) {
  if (body.trim().isEmpty) return '';
  final fragment = html_parser.parse(body);
  final scoped = <dom.Element>[];
  for (final selector in const [
    '.comic-contain',
    '.comiclist',
    '.comicpage',
    '#imgsec',
    '#images',
    '.reading-content',
    '.chapter-content',
    '.comic-content',
    '.page-content',
  ]) {
    scoped.addAll(fragment.querySelectorAll(selector));
  }
  if (scoped.isEmpty) return '';
  final tags = <String>[];
  final seen = <String>{};
  for (final root in scoped) {
    final elements = <dom.Element>[
      if (root.localName == 'img' ||
          root.localName == 'amp-img' ||
          root.localName == 'source')
        root,
      ...root.querySelectorAll('img,amp-img,source'),
    ];
    for (final element in elements) {
      String value = '';
      for (final name in const [
        'data-src',
        'data-original',
        'data-lazy-src',
        'src',
        'srcset',
      ]) {
        value = element.attributes[name]?.trim() ?? '';
        if (value.isNotEmpty && !value.startsWith('data:')) {
          if (name == 'srcset') value = _firstSrcsetCandidate(value);
          break;
        }
        value = '';
      }
      if (value.isEmpty || !seen.add(value)) continue;
      tags.add('<img src="${htmlEscape.convert(value)}">');
    }
  }
  return tags.join('\n');
}
