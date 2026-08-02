import 'dart:io';

import '../protocol/book_source_protocol.dart';

typedef BookSourceAddressLookup =
    Future<List<InternetAddress>> Function(String host);

class BookSourceNetworkPolicy {
  const BookSourceNetworkPolicy({
    BookSourceAddressLookup? lookup,
    this.allowPrivateNetwork = false,
    this.allowSyntheticDns = false,
  }) : _lookup = lookup ?? InternetAddress.lookup;

  final BookSourceAddressLookup _lookup;
  final bool allowPrivateNetwork;
  final bool allowSyntheticDns;

  Future<void> validate(Uri uri) async {
    await resolve(uri);
  }

  Future<List<InternetAddress>> resolve(Uri uri) async {
    if (!uri.hasAuthority || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const BookSourceProtocolException(
        'Book source targets must use HTTP or HTTPS.',
      );
    }
    final literal = InternetAddress.tryParse(uri.host);
    final addresses = literal == null ? await _lookup(uri.host) : [literal];
    if (addresses.isEmpty ||
        addresses.any(
          (address) =>
              _isAlwaysBlockedAddress(address) ||
              (!allowPrivateNetwork &&
                  isBlockedAddress(
                    address,
                    allowSyntheticDns: allowSyntheticDns,
                  )),
        )) {
      throw const BookSourceProtocolException(
        'This address is not allowed as a book source target.',
      );
    }
    return addresses;
  }

  HttpClient createPinnedHttpClient() {
    final client = HttpClient();
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final targetHost = proxyHost ?? uri.host;
      final targetPort = proxyPort ?? uri.port;
      final targetUri = proxyHost == null
          ? uri
          : Uri(scheme: 'http', host: targetHost, port: targetPort);
      final addresses = await resolve(targetUri);
      // Prefer IPv4 on mobile networks, then fall back through every validated
      // address. Pinning only the first DNS answer made a single unreachable
      // IPv6/CDN node fail the whole source, unlike OkHttp's address fallback.
      final ordered = [
        ...addresses.where(
          (address) => address.type == InternetAddressType.IPv4,
        ),
        ...addresses.where(
          (address) => address.type == InternetAddressType.IPv6,
        ),
      ];
      ConnectionTask<Socket>? activeTask;
      var cancelled = false;
      final socket = () async {
        Object? lastError;
        for (final address in ordered) {
          if (cancelled) {
            throw const SocketException('Connection attempt was cancelled.');
          }
          try {
            activeTask = await Socket.startConnect(address, targetPort);
            return await activeTask!.socket.timeout(
              const Duration(seconds: 3),
              onTimeout: () {
                activeTask?.cancel();
                throw SocketException(
                  'Timed out connecting to ${address.address}:$targetPort.',
                );
              },
            );
          } on Object catch (error) {
            lastError = error;
          }
        }
        if (lastError is SocketException) throw lastError;
        throw SocketException(
          'Could not connect to any validated address for $targetHost.',
        );
      }();
      return ConnectionTask.fromSocket(socket, () {
        cancelled = true;
        activeTask?.cancel();
      });
    };
    return client;
  }

  static bool isBlockedAddress(
    InternetAddress address, {
    bool allowSyntheticDns = false,
  }) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }

    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return _isBlockedIpv4(bytes, allowSyntheticDns: allowSyntheticDns);
    }
    if (bytes.length != 16) return true;

    // IPv4-mapped IPv6 addresses must inherit the IPv4 restrictions.
    final isIpv4Mapped =
        bytes.take(10).every((byte) => byte == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (isIpv4Mapped) {
      return _isBlockedIpv4(
        bytes.sublist(12),
        allowSyntheticDns: allowSyntheticDns,
      );
    }

    // Unspecified, loopback, and unique-local (fc00::/7) addresses.
    if (bytes.every((byte) => byte == 0) ||
        (bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1) ||
        (bytes[0] & 0xfe) == 0xfc) {
      return true;
    }
    return false;
  }

  static bool isSyntheticDnsAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    return bytes.length == 4 &&
        bytes[0] == 198 &&
        (bytes[1] == 18 || bytes[1] == 19);
  }

  static bool _isAlwaysBlockedAddress(InternetAddress address) {
    if (address.isMulticast) return true;
    final bytes = address.rawAddress;
    if (bytes.every((byte) => byte == 0)) return true;
    return bytes.length == 4 && bytes[0] >= 224;
  }

  static bool _isBlockedIpv4(
    List<int> bytes, {
    bool allowSyntheticDns = false,
  }) {
    final first = bytes[0];
    final second = bytes[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && (second & 0xc0) == 0x40) ||
        (first == 169 && second == 254) ||
        (first == 172 && (second & 0xf0) == 16) ||
        (first == 192 && second == 168) ||
        (!allowSyntheticDns &&
            first == 198 &&
            (second == 18 || second == 19)) ||
        first >= 224;
  }

  static Uri redirectTarget(Uri current, String? location) {
    if (location == null || location.trim().isEmpty) {
      throw const BookSourceProtocolException(
        'Book source redirect is missing its target.',
      );
    }
    final target = current.resolve(location.trim());
    if (target.scheme != 'http' && target.scheme != 'https') {
      throw const BookSourceProtocolException(
        'Book source redirects must use HTTP or HTTPS.',
      );
    }
    if (current.scheme == 'https' && target.scheme == 'http') {
      throw const BookSourceProtocolException(
        'Book source redirects cannot downgrade HTTPS to HTTP.',
      );
    }
    return target;
  }
}
