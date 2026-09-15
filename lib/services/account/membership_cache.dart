import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'account_models.dart';

class CachedMemberMembership {
  const CachedMemberMembership({
    required this.userId,
    required this.membership,
  });

  final String userId;
  final MemberMembership membership;
}

/// An account-bound membership snapshot used while the server refresh is in
/// flight. The account ID is checked against the restored authenticated
/// session before this value can grant access.
class MemberMembershipCache {
  const MemberMembershipCache();

  static const storageKey = 'member_membership_v1';

  Future<CachedMemberMembership?> load() async {
    late final SharedPreferences prefs;
    String? encoded;
    try {
      prefs = await SharedPreferences.getInstance();
      encoded = prefs.getString(storageKey);
    } catch (error, stackTrace) {
      debugPrint('Failed to read membership cache (${error.runtimeType}).');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
    if (encoded == null || encoded.isEmpty) return null;

    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        throw const FormatException('Membership cache root must be an object.');
      }
      final json = decoded.cast<String, dynamic>();
      return CachedMemberMembership(
        userId: json['user_id'] as String,
        membership: MemberMembership.fromJson(
          (json['membership'] as Map).cast<String, dynamic>(),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Discarding invalid membership cache (${error.runtimeType}).');
      debugPrintStack(stackTrace: stackTrace);
      try {
        await prefs.remove(storageKey);
      } catch (_) {
        // A malformed cache cannot authorize access, even if cleanup fails.
      }
      return null;
    }
  }

  Future<void> save(String userId, MemberMembership membership) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      storageKey,
      jsonEncode({
        'user_id': userId,
        'membership': _membershipJson(membership),
      }),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(storageKey);
  }
}

Map<String, Object?> _membershipJson(MemberMembership membership) => {
  'user_id': membership.userId,
  'purchase_allowed': membership.purchaseAllowed,
  'premium': membership.premium,
  'test_purchase': membership.testPurchase,
  'purchase_status': membership.purchaseStatus,
  'features': membership.features,
  'entitlements': membership.entitlements
      .map(
        (entry) => {
          'feature_key': entry.featureKey,
          'source': entry.source,
          'status': entry.status,
          'granted_at': entry.grantedAt.toIso8601String(),
          'expires_at': entry.expiresAt?.toIso8601String(),
        },
      )
      .toList(growable: false),
  'redeemed': membership.redeemed,
};
