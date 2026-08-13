enum BookSourceIdentityKind { http, opaque }

/// Stable identity keys derived from a Reading Source `bookSourceUrl`.
class BookSourceIdentity {
  const BookSourceIdentity({
    required this.raw,
    required this.exactKey,
    required this.canonicalKey,
    required this.siteKey,
    required this.kind,
  });

  factory BookSourceIdentity.parse(String value) {
    final raw = value.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        (uri.scheme.toLowerCase() != 'http' &&
            uri.scheme.toLowerCase() != 'https') ||
        uri.host.isEmpty) {
      return BookSourceIdentity(
        raw: raw,
        exactKey: raw,
        canonicalKey: raw,
        siteKey: raw,
        kind: BookSourceIdentityKind.opaque,
      );
    }

    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    final port = _effectivePort(uri, scheme);
    final authority = _authority(uri, host, port);
    final path = _normalizedPath(uri.path);
    final fragment = uri.hasFragment ? '#${uri.fragment}' : '';
    final canonicalQuery = _canonicalQuery(uri.query);
    final canonical =
        '$scheme://$authority$path'
        '${canonicalQuery.isEmpty ? '' : '?$canonicalQuery'}$fragment';

    return BookSourceIdentity(
      raw: raw,
      exactKey: raw,
      canonicalKey: canonical,
      siteKey: _siteAuthority(host, port),
      kind: BookSourceIdentityKind.http,
    );
  }

  final String raw;
  final String exactKey;
  final String canonicalKey;
  final String siteKey;
  final BookSourceIdentityKind kind;

  bool get isHttp => kind == BookSourceIdentityKind.http;

  static int? _effectivePort(Uri uri, String scheme) {
    if (!uri.hasPort) return null;
    if ((scheme == 'http' && uri.port == 80) ||
        (scheme == 'https' && uri.port == 443)) {
      return null;
    }
    return uri.port;
  }

  static String _authority(Uri uri, String host, int? port) {
    final displayHost = _displayHost(host);
    final userInfo = uri.userInfo.isEmpty ? '' : '${uri.userInfo}@';
    return '$userInfo$displayHost${port == null ? '' : ':$port'}';
  }

  static String _siteAuthority(String host, int? port) =>
      '${_displayHost(host)}${port == null ? '' : ':$port'}';

  static String _displayHost(String host) =>
      host.contains(':') ? '[$host]' : host;

  static String _normalizedPath(String path) {
    if (path.isEmpty || path == '/') return '';
    var normalized = path;
    while (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  static String _canonicalQuery(String query) {
    if (query.isEmpty) return '';
    final entries = <_QueryEntry>[];
    for (final component in query.split('&')) {
      final separator = component.indexOf('=');
      final rawName = separator < 0
          ? component
          : component.substring(0, separator);
      String decodedName;
      try {
        decodedName = Uri.decodeQueryComponent(rawName).toLowerCase();
      } on FormatException {
        decodedName = rawName.toLowerCase();
      }
      if (_trackingParameters.contains(decodedName) ||
          decodedName.startsWith('utm_')) {
        continue;
      }
      entries.add(_QueryEntry(component, decodedName));
    }
    entries.sort((left, right) {
      final nameOrder = left.name.compareTo(right.name);
      return nameOrder != 0 ? nameOrder : left.raw.compareTo(right.raw);
    });
    return entries.map((entry) => entry.raw).join('&');
  }

  static const _trackingParameters = {
    'fbclid',
    'gclid',
    'dclid',
    'msclkid',
    'mc_cid',
    'mc_eid',
    '_ga',
    'from',
    'ref',
    'referrer',
    'spm',
  };
}

class _QueryEntry {
  const _QueryEntry(this.raw, this.name);

  final String raw;
  final String name;
}
