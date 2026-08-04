import 'dart:convert';

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
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(storageKey);
      if (encoded == null || encoded.isEmpty) return null;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      return MemberAccountSummary.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
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
