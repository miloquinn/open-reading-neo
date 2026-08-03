import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/book_sources/source_engine/source_request.dart';

import '../tool/diagnose_source_samples.dart' as diagnostic;

void main() {
  test(
    'runs opt-in reading source samples through the complete chain',
    () async {
      final files = Platform.environment['SOURCE_SAMPLE_FILES']
          ?.split(Platform.isWindows ? ';' : ':')
          .where((path) => path.trim().isNotEmpty)
          .toList();
      if (files == null || files.isEmpty) return;

      final probeUrl = Platform.environment['SOURCE_PROBE_URL'];
      if (probeUrl != null && probeUrl.isNotEmpty) {
        await _compareNetworkClients(Uri.parse(probeUrl));
      }

      final perKind = Platform.environment['SOURCE_SAMPLES_PER_KIND'] ?? '3';
      final stageSeconds =
          Platform.environment['SOURCE_SAMPLE_STAGE_SECONDS'] ?? '15';
      await diagnostic.main([
        if (Platform.environment['SOURCE_SAMPLE_STATIC_ONLY'] == 'true')
          '--static-only',
        '--per-kind=$perKind',
        '--stage-seconds=$stageSeconds',
        ...files,
      ]);
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

Future<void> _compareNetworkClients(Uri url) async {
  await _probeHttpClient('dart-http', HttpClient(), url);

  final hostSocketClient = HttpClient();
  hostSocketClient.connectionFactory = (uri, proxyHost, proxyPort) async {
    stdout.writeln(
      'PROBE connection-factory proxy=${proxyHost != null} '
      'scheme=${uri.scheme}',
    );
    final task = await Socket.startConnect(
      proxyHost ?? uri.host,
      proxyPort ?? uri.port,
    );
    return ConnectionTask.fromSocket(task.socket, task.cancel);
  };
  await _probeHttpClient('host-socket', hostSocketClient, url);

  final addresses = await InternetAddress.lookup(url.host);
  final ipSocketClient = HttpClient();
  ipSocketClient.connectionFactory = (uri, proxyHost, proxyPort) async {
    final task = await Socket.startConnect(
      proxyHost ?? addresses.first,
      proxyPort ?? uri.port,
    );
    return ConnectionTask.fromSocket(task.socket, task.cancel);
  };
  await _probeHttpClient('ip-socket', ipSocketClient, url);

  final transport = SourceHttpTransport();
  try {
    final request = SourceRequestTemplate.parse(url.toString(), baseUri: url);
    final response = await transport.send(request);
    stdout.writeln(
      'PROBE source-http status=success final=${response.finalUri}',
    );
  } catch (error) {
    stdout.writeln('PROBE source-http error=$error url=$url');
  } finally {
    transport.close();
  }
}

Future<void> _probeHttpClient(String name, HttpClient client, Uri url) async {
  try {
    final request = await client.getUrl(url);
    request.headers.set(HttpHeaders.userAgentHeader, sourceDefaultUserAgent);
    final response = await request.close();
    stdout.writeln('PROBE $name status=${response.statusCode} url=$url');
    await response.drain<void>();
  } catch (error) {
    stdout.writeln('PROBE $name error=$error url=$url');
  } finally {
    client.close(force: true);
  }
}
