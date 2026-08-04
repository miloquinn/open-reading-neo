import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:xxread/services/account/account.dart';

void main() {
  test('verified Apple purchase completes and publishes membership', () async {
    final store = _FakeAppleStore();
    MemberMembership? membership;
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      store: store,
      verify: (purchase) async {
        expect(purchase.verificationData.serverVerificationData, 'signed-jws');
        return _premiumMembership();
      },
      onMembership: (value) => membership = value,
    );
    addTearDown(service.dispose);

    await service.initialize();
    await service.purchase();
    expect(store.purchaseStarted, isTrue);

    store.emit(_purchase(PurchaseStatus.purchased));
    await pumpEventQueue();

    expect(membership?.premium, isTrue);
    expect(store.completed, hasLength(1));
  });

  test('failed server verification keeps transaction unfinished', () async {
    final store = _FakeAppleStore();
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      store: store,
      verify: (_) async => throw const MemberAccountException('交易验证失败'),
    );
    addTearDown(service.dispose);

    await service.initialize();
    store.emit(_purchase(PurchaseStatus.purchased));
    await pumpEventQueue();

    expect(store.completed, isEmpty);
    expect(service.error, '交易验证失败');
  });

  test('restore asks StoreKit to replay purchases', () async {
    final store = _FakeAppleStore();
    final service = ApplePremiumPurchaseService(
      productId: _productId,
      store: store,
      verify: (_) async => _premiumMembership(),
    );
    addTearDown(service.dispose);

    await service.restore();

    expect(store.restoreCalled, isTrue);
  });
}

const _productId = 'com.niki.xxread.premium.lifetime';

MemberMembership _premiumMembership() => MemberMembership.fromJson({
  'premium': true,
  'features': <String, bool>{},
  'entitlements': [
    {
      'feature_key': 'premium',
      'source': 'apple_app_store',
      'status': 'active',
      'granted_at': '2026-08-04T00:00:00Z',
      'expires_at': null,
    },
  ],
});

PurchaseDetails _purchase(PurchaseStatus status) => _TestPurchaseDetails(
  purchaseID: '200000000000001',
  productID: _productId,
  verificationData: PurchaseVerificationData(
    localVerificationData: '{}',
    serverVerificationData: 'signed-jws',
    source: 'app_store',
  ),
  transactionDate: '1785801600000',
  status: status,
);

class _TestPurchaseDetails extends PurchaseDetails {
  _TestPurchaseDetails({
    super.purchaseID,
    required super.productID,
    required super.verificationData,
    required super.transactionDate,
    required super.status,
  });

  @override
  bool get pendingCompletePurchase => true;
}

class _FakeAppleStore implements ApplePurchaseStore {
  final _controller = StreamController<List<PurchaseDetails>>.broadcast();
  final completed = <PurchaseDetails>[];
  bool purchaseStarted = false;
  bool restoreCalled = false;

  void emit(PurchaseDetails purchase) => _controller.add([purchase]);

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _controller.stream;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async => ProductDetailsResponse(
    productDetails: [
      ProductDetails(
        id: _productId,
        title: '永久高级版',
        description: '永久解锁高级版',
        price: '¥28.00',
        rawPrice: 28,
        currencyCode: 'CNY',
        currencySymbol: '¥',
      ),
    ],
    notFoundIDs: const [],
  );

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    purchaseStarted = true;
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase);
  }

  @override
  Future<void> restorePurchases() async {
    restoreCalled = true;
  }
}
