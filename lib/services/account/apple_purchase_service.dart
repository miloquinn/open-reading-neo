import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'account_models.dart';
import 'account_api_client.dart';

abstract interface class ApplePurchaseStore {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers);
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<void> restorePurchases();
  Future<void> completePurchase(PurchaseDetails purchase);
}

class InAppPurchaseStore implements ApplePurchaseStore {
  const InAppPurchaseStore(this._store);

  final InAppPurchase _store;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _store.purchaseStream;
  @override
  Future<bool> isAvailable() => _store.isAvailable();
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) =>
      _store.queryProductDetails(identifiers);
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _store.buyNonConsumable(purchaseParam: purchaseParam);
  @override
  Future<void> restorePurchases() => _store.restorePurchases();
  @override
  Future<void> completePurchase(PurchaseDetails purchase) =>
      _store.completePurchase(purchase);
}

typedef ApplePurchaseVerifier =
    Future<MemberMembership> Function(PurchaseDetails purchase);

/// StoreKit is only a payment channel. The verifier must be backed by the
/// account API so the server remains the source of truth for premium access.
class ApplePremiumPurchaseService extends ChangeNotifier {
  ApplePremiumPurchaseService({
    required this.productId,
    required this._verify,
    this._store,
    this.onMembership,
  });

  final String productId;
  final ApplePurchaseVerifier _verify;
  ApplePurchaseStore? _store;
  final ValueChanged<MemberMembership>? onMembership;
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  ProductDetails? _product;
  bool _loading = false;
  String? _error;

  bool get loading => _loading;
  String? get error => _error;
  ProductDetails? get product => _product;

  ApplePurchaseStore get _activeStore =>
      _store ??= InAppPurchaseStore(InAppPurchase.instance);

  Future<void> initialize() async {
    if (_subscription != null) return;
    _subscription = _activeStore.purchaseStream.listen(_handlePurchases);
    await _loadProduct();
  }

  Future<void> _loadProduct() async {
    if (!await _activeStore.isAvailable()) {
      throw const MemberAccountException('App Store 内购暂不可用');
    }
    final response = await _activeStore.queryProductDetails({productId});
    if (response.error != null) {
      throw MemberAccountException(response.error!.message);
    }
    if (response.productDetails.isEmpty) {
      throw const MemberAccountException('App Store 商品尚未配置或不可用');
    }
    _product = response.productDetails.first;
    notifyListeners();
  }

  Future<void> purchase() async {
    _setLoading(true);
    try {
      await initialize();
      final product = _product;
      if (product == null) throw const MemberAccountException('商品信息未加载');
      final started = await _activeStore.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      if (!started) throw const MemberAccountException('无法启动 App Store 购买');
    } catch (error) {
      _setError(error);
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> restore() async {
    _setLoading(true);
    try {
      await initialize();
      await _activeStore.restorePurchases();
    } catch (error) {
      _setError(error);
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _handlePurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      if (purchase.productID != productId) continue;
      if (purchase.status == PurchaseStatus.pending) continue;
      if (purchase.status == PurchaseStatus.error ||
          purchase.status == PurchaseStatus.canceled) {
        _setError(purchase.error?.message ?? 'App Store 购买未完成');
        continue;
      }
      if (purchase.status != PurchaseStatus.purchased &&
          purchase.status != PurchaseStatus.restored) {
        continue;
      }
      try {
        final membership = await _verify(purchase);
        onMembership?.call(membership);
        if (purchase.pendingCompletePurchase) {
          await _activeStore.completePurchase(purchase);
        }
        _setError(null);
      } catch (error) {
        // Keep the transaction unfinished so the next stream delivery can
        // retry server verification instead of losing a paid purchase.
        _setError(error);
      }
    }
  }

  void _setLoading(bool value) {
    _loading = value;
    notifyListeners();
  }

  void _setError(Object? error) {
    _error = error == null
        ? null
        : error is MemberAccountException
        ? error.message
        : error.toString();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
