import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Disk-backed HTTP fixture: no ETags, deliberately no conditional-write
/// semantics. It exercises Dio, XML paths, streaming and real socket I/O.
class LocalWebDavServer {
  LocalWebDavServer._(this.root, this.server);
  final Directory root;
  final HttpServer server;
  bool rejectHead = false;
  bool rejectOptions = false;
  bool failNextPut = false;
  bool malformedListing = false;
  int uploaded = 0, downloaded = 0, puts = 0;
  final requests = <String>[];
  String get url => 'http://127.0.0.1:${server.port}';

  static Future<LocalWebDavServer> start() async {
    final root = await Directory.systemTemp.createTemp('dav-http-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = LocalWebDavServer._(root, server);
    server.listen((request) async {
      try {
        await fixture._handle(request);
      } catch (_) {
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });
    return fixture;
  }

  Future<void> close() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final parts = request.uri.pathSegments.where((p) => p.isNotEmpty).toList();
    if (parts.any((p) => p == '..' || p == '.')) {
      request.response.statusCode = 400;
      await request.response.close();
      return;
    }
    final target = '${root.path}/${parts.join('/')}';
    requests.add('${request.method} ${request.uri.path}');
    final response = request.response;
    switch (request.method) {
      case 'OPTIONS':
        response.statusCode = rejectOptions ? 405 : 200;
      case 'MKCOL':
        final directory = Directory(target);
        if (await directory.exists()) {
          response.statusCode = 405;
        } else {
          await directory.create(recursive: true);
          response.statusCode = 201;
        }
      case 'PUT':
        if (failNextPut) {
          failNextPut = false;
          await request.drain<void>();
          response.statusCode = 503;
          break;
        }
        final file = File(target);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        try {
          await sink.addStream(
            request.map((bytes) {
              uploaded += bytes.length;
              return bytes;
            }),
          );
        } finally {
          await sink.close();
        }
        puts++;
        response.statusCode = 201;
      case 'HEAD':
        if (rejectHead) {
          response.statusCode = 405;
          break;
        }
        if (!await File(target).exists()) {
          response.statusCode = 404;
          break;
        }
        response.contentLength = await File(target).length();
      case 'GET':
        final file = File(target);
        if (!await file.exists()) {
          response.statusCode = 404;
          break;
        }
        response.contentLength = await file.length();
        await response.addStream(
          file.openRead().map((bytes) {
            downloaded += bytes.length;
            return bytes;
          }),
        );
      case 'DELETE':
        final type = await FileSystemEntity.type(target);
        if (type == FileSystemEntityType.directory) {
          await Directory(target).delete(recursive: true);
        } else if (type == FileSystemEntityType.file) {
          await File(target).delete();
        }
        response.statusCode = 204;
      case 'PROPFIND':
        final properties = await utf8.decoder.bind(request).join();
        if (malformedListing) {
          response.statusCode = 207;
          response.write('<html>proxy error</html>');
          break;
        }
        final type = await FileSystemEntity.type(target);
        if (type == FileSystemEntityType.notFound) {
          response.statusCode = 404;
          break;
        }
        final entries = <FileSystemEntity>[
          if (type == FileSystemEntityType.directory)
            Directory(target)
          else
            File(target),
          if (type == FileSystemEntityType.directory &&
              request.headers.value('Depth') == '1')
            ...await Directory(target).list().toList(),
        ];
        final xml = StringBuffer('<d:multistatus xmlns:d="DAV:">');
        for (final entry in entries) {
          final isDirectory = entry is Directory;
          final relative = entry.path.substring(root.path.length);
          final href = Uri(
            path: '$relative${isDirectory ? '/' : ''}',
          ).toString();
          xml.write(
            '<d:response><d:href>${const HtmlEscape().convert(href)}</d:href><d:propstat><d:prop>',
          );
          if (properties.contains('resourcetype')) {
            xml.write(
              isDirectory
                  ? '<d:resourcetype><d:collection/></d:resourcetype>'
                  : '<d:resourcetype/>',
            );
          }
          if (!isDirectory) {
            xml.write(
              '<d:getcontentlength>${await File(entry.path).length()}</d:getcontentlength>',
            );
          }
          xml.write(
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
        }
        xml.write('</d:multistatus>');
        response.statusCode = 207;
        response.headers.contentType = ContentType(
          'application',
          'xml',
          charset: 'utf-8',
        );
        response.write(xml.toString());
      default:
        response.statusCode = 405;
    }
    await response.close();
  }
}
