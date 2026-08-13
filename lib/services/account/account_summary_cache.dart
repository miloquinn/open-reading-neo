import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_models.dart';

class MemberAccountSummary {
  const MemberAccountSummary({
    required this.userId,
    required this.username,
    required this.effectiveName,
    required this.premium,
    this.avatarUrl,
  });

  factory MemberAccountSummary.fromAccount(
    MemberUser user, {
    required bool premium,
  }) => MemberAccountSummary(
    userId: user.id,
    username: user.username,
    effectiveName: user.effectiveName,
    avatarUrl: user.avatarUrl,
    premium: premium,
  );

  factory MemberAccountSummary.fromJson(Map<String, dynamic> json) =>
      MemberAccountSummary(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        effectiveName: json['effective_name'] as String,
        avatarUrl: json['avatar_url'] as String?,
        premium: json['premium'] as bool? ?? false,
      );

  final String userId;
  final String username;
  final String effectiveName;
  final String? avatarUrl;
  final bool premium;

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'username': username,
    'effective_name': effectiveName,
    'avatar_url': avatarUrl,
    'premium': premium,
  };
}

class MemberAccountSummaryCache {
  const MemberAccountSummaryCache();

  static const storageKey = 'member_account_summary_v1';

  Future<MemberAccountSummary?> load() async {
    late final SharedPreferences prefs;
    String? encoded;
    try {
      prefs = await SharedPreferences.getInstance();
      encoded = prefs.getString(storageKey);
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to read account summary cache (${error.runtimeType}).',
      );
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
    if (encoded == null || encoded.isEmpty) return null;

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw const FormatException('Account summary root must be an object.');
      }
      return MemberAccountSummary.fromJson(decoded.cast<String, dynamic>());
    } catch (error, stackTrace) {
      debugPrint(
        'Discarding invalid account summary cache (${error.runtimeType}).',
      );
      debugPrintStack(stackTrace: stackTrace);
      try {
        await prefs.remove(storageKey);
      } catch (cleanupError, cleanupStackTrace) {
        debugPrint(
          'Failed to clear invalid account summary cache '
          '(${cleanupError.runtimeType}).',
        );
        debugPrintStack(stackTrace: cleanupStackTrace);
      }
      return null;
    }
  }

  Future<void> save(MemberAccountSummary summary) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(summary.toJson()));
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }
}
