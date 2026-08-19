import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' hide Digest;

class SourceScriptCryptoApi {
  const SourceScriptCryptoApi();

  Object? handle(String operation, List arguments) {
    final value = arguments.isEmpty ? '' : '${arguments.first ?? ''}';
    return switch (operation) {
      'md5' => md5.convert(utf8.encode(value)).toString(),
      'base64Encode' => base64Encode(utf8.encode(value)),
      'base64Decode' => utf8.decode(base64Decode(value), allowMalformed: true),
      'base64DecodeBytes' => List<int>.from(base64Decode(value)),
      'base64EncodeBytes' => base64Encode(_argumentBytes(arguments)),
      'bytesToUtf8' => utf8.decode(
        _argumentBytes(arguments),
        allowMalformed: true,
      ),
      'hexDecodeToString' => _hexDecode(value),
      'aesBase64DecodeToString' => _aesBase64Decode(arguments),
      'hmacBase64' => _hmac(arguments, base64Output: true),
      'hmacHex' => _hmac(arguments, base64Output: false),
      'symmetricCrypto' => _symmetricCrypto(arguments),
      'randomUUID' => _randomUuid(),
      'androidId' => _androidId(),
      'digestHex' => _digestHex(arguments),
      'digestBytes' => _digestBytes(arguments),
      'hmacBytes' => _hmacBytes(arguments),
      _ => null,
    };
  }
}

String _hexDecode(String value) {
  final normalized = value.replaceAll(RegExp(r'\s+'), '');
  if (normalized.length.isOdd) return '';
  try {
    final bytes = <int>[
      for (var index = 0; index < normalized.length; index += 2)
        int.parse(normalized.substring(index, index + 2), radix: 16),
    ];
    return utf8.decode(bytes, allowMalformed: true);
  } on FormatException {
    return '';
  }
}

String _randomUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

String _androidId() => sha256
    .convert(utf8.encode('open-reading-source-runtime'))
    .toString()
    .substring(0, 16);

String _digestHex(List arguments) {
  if (arguments.isEmpty) return '';
  final value = utf8.encode('${arguments[0] ?? ''}');
  final algorithm = arguments.length > 1
      ? '${arguments[1] ?? ''}'.toLowerCase().replaceAll('-', '')
      : 'sha256';
  return _digestFor(algorithm, value)?.toString() ?? '';
}

List<int> _digestBytes(List arguments) {
  if (arguments.isEmpty) return const [];
  final value = _scriptBytes(arguments[0]);
  final algorithm = arguments.length > 1
      ? '${arguments[1] ?? ''}'.toLowerCase().replaceAll('-', '')
      : 'sha256';
  return _digestFor(algorithm, value)?.bytes ?? const [];
}

Digest? _digestFor(String algorithm, List<int> value) => switch (algorithm) {
  'md5' => md5.convert(value),
  'sha1' => sha1.convert(value),
  'sha224' => sha224.convert(value),
  'sha256' => sha256.convert(value),
  'sha384' => sha384.convert(value),
  'sha512' => sha512.convert(value),
  _ => null,
};

List<int> _hmacBytes(List arguments) {
  if (arguments.length < 3) return const [];
  final data = _scriptBytes(arguments[0]);
  final algorithm = '${arguments[1] ?? ''}'.toLowerCase().replaceAll('-', '');
  final key = _scriptBytes(arguments[2]);
  final digest = switch (algorithm) {
    'hmacmd5' || 'md5' => Hmac(md5, key).convert(data),
    'hmacsha1' || 'sha1' => Hmac(sha1, key).convert(data),
    'hmacsha256' || 'sha256' => Hmac(sha256, key).convert(data),
    'hmacsha512' || 'sha512' => Hmac(sha512, key).convert(data),
    _ => null,
  };
  return digest?.bytes ?? const [];
}

List<int> _argumentBytes(List arguments) =>
    arguments.isEmpty ? const [] : _scriptBytes(arguments.first);

String _aesBase64Decode(List arguments) {
  if (arguments.length < 3) return '';
  try {
    final encrypted = Uint8List.fromList(base64Decode('${arguments[0] ?? ''}'));
    final key = Uint8List.fromList(utf8.encode('${arguments[1] ?? ''}'));
    final transformation = '${arguments[2] ?? 'AES/CBC/PKCS5Padding'}'
        .toUpperCase();
    final iv = arguments.length > 3
        ? Uint8List.fromList(utf8.encode('${arguments[3] ?? ''}'))
        : Uint8List(16);
    final ecb = transformation.contains('/ECB/');
    final padded =
        transformation.contains('PKCS5') || transformation.contains('PKCS7');
    Uint8List decrypted;
    if (padded) {
      final cipher = PaddedBlockCipher(ecb ? 'AES/ECB/PKCS7' : 'AES/CBC/PKCS7');
      final parameters = ecb
          ? KeyParameter(key)
          : ParametersWithIV<KeyParameter>(KeyParameter(key), iv);
      cipher.init(
        false,
        PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
          parameters,
          null,
        ),
      );
      decrypted = cipher.process(encrypted);
    } else {
      final cipher = BlockCipher(ecb ? 'AES/ECB' : 'AES/CBC');
      cipher.init(
        false,
        ecb
            ? KeyParameter(key)
            : ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
      );
      decrypted = Uint8List(encrypted.length);
      for (var offset = 0; offset < encrypted.length; offset += 16) {
        cipher.processBlock(encrypted, offset, decrypted, offset);
      }
      if (transformation.contains('ZEROPADDING')) {
        var length = decrypted.length;
        while (length > 0 && decrypted[length - 1] == 0) {
          length--;
        }
        decrypted = Uint8List.sublistView(decrypted, 0, length);
      }
    }
    return utf8.decode(decrypted, allowMalformed: true);
  } on Object {
    return '';
  }
}

String _hmac(List arguments, {required bool base64Output}) {
  if (arguments.length < 3) return '';
  final data = utf8.encode('${arguments[0] ?? ''}');
  final algorithm = '${arguments[1] ?? ''}'.toLowerCase();
  final key = utf8.encode('${arguments[2] ?? ''}');
  final digest = switch (algorithm.replaceAll('-', '')) {
    'hmacmd5' || 'md5' => Hmac(md5, key).convert(data),
    'hmacsha1' || 'sha1' => Hmac(sha1, key).convert(data),
    'hmacsha256' || 'sha256' => Hmac(sha256, key).convert(data),
    'hmacsha512' || 'sha512' => Hmac(sha512, key).convert(data),
    _ => null,
  };
  if (digest == null) return '';
  return base64Output ? base64Encode(digest.bytes) : digest.toString();
}

Object _symmetricCrypto(List arguments) {
  if (arguments.length < 5) return '';
  final operation = '${arguments[0] ?? ''}';
  final transformation = '${arguments[1] ?? ''}';
  final key = _scriptBytes(arguments[2]);
  final iv = _scriptBytes(arguments[3]);
  final encrypting = operation.startsWith('encrypt');
  final input = encrypting
      ? _scriptBytes(arguments[4])
      : _encryptedScriptBytes(arguments[4]);
  try {
    final output = _processSymmetric(
      input,
      key: key,
      iv: iv,
      transformation: transformation,
      encrypting: encrypting,
    );
    return switch (operation) {
      'decryptBytes' || 'encryptBytes' => output.toList(growable: false),
      'decryptString' => utf8.decode(output, allowMalformed: true),
      'encryptBase64' => base64Encode(output),
      'encryptHex' =>
        output.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      _ => '',
    };
  } on Object {
    return operation.endsWith('Bytes') ? const <int>[] : '';
  }
}

Uint8List _processSymmetric(
  Uint8List input, {
  required Uint8List key,
  required Uint8List iv,
  required String transformation,
  required bool encrypting,
}) {
  final normalized = transformation.toUpperCase();
  late final BlockCipher engine;
  var effectiveKey = key;
  if (normalized.startsWith('DESEDE') || normalized.startsWith('TRIPLEDES')) {
    engine = DESedeEngine();
  } else if (normalized.startsWith('DES')) {
    // A single DES key is equivalent to 3DES with K1=K2=K3.
    engine = DESedeEngine();
    effectiveKey = Uint8List.fromList([...key, ...key, ...key]);
  } else {
    engine = AESEngine();
  }
  final blockSize = engine.blockSize;
  final blockCipher = normalized.contains('/ECB/')
      ? engine
      : CBCBlockCipher(engine);
  final baseParameters = KeyParameter(effectiveKey);
  final parameters = normalized.contains('/ECB/')
      ? baseParameters
      : ParametersWithIV<KeyParameter>(
          baseParameters,
          iv.isEmpty ? Uint8List(blockSize) : iv,
        );
  if (normalized.contains('PKCS5') || normalized.contains('PKCS7')) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), blockCipher);
    cipher.init(
      encrypting,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters?>(
        parameters,
        null,
      ),
    );
    return cipher.process(input);
  }
  var data = input;
  if (encrypting && data.length % blockSize != 0) {
    final paddedLength =
        ((data.length + blockSize - 1) ~/ blockSize) * blockSize;
    final padded = Uint8List(paddedLength)..setAll(0, data);
    data = padded;
  }
  if (data.length % blockSize != 0) {
    throw const FormatException('Encrypted data is not block aligned.');
  }
  blockCipher.init(encrypting, parameters);
  var output = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += blockSize) {
    blockCipher.processBlock(data, offset, output, offset);
  }
  if (!encrypting && normalized.contains('ZEROPADDING')) {
    var length = output.length;
    while (length > 0 && output[length - 1] == 0) {
      length--;
    }
    output = Uint8List.sublistView(output, 0, length);
  }
  return output;
}

Uint8List _scriptBytes(Object? value) {
  if (value is List) {
    return Uint8List.fromList(
      value.whereType<num>().map((item) => item.toInt() & 0xff).toList(),
    );
  }
  return Uint8List.fromList(utf8.encode('${value ?? ''}'));
}

Uint8List _encryptedScriptBytes(Object? value) {
  if (value is List) return _scriptBytes(value);
  final text = '${value ?? ''}'.trim();
  try {
    return Uint8List.fromList(base64Decode(text));
  } on FormatException {
    if (text.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) {
      return Uint8List.fromList([
        for (var index = 0; index < text.length; index += 2)
          int.parse(text.substring(index, index + 2), radix: 16),
      ]);
    }
    return _scriptBytes(text);
  }
}
