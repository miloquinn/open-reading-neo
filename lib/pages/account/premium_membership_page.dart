import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/account/account.dart';
import '../../services/core/app_distribution.dart';
import '../../utils/localization_extension.dart';
import '../../utils/page_style_helper.dart';
import '../../widgets/premium_card_style.dart';
import '../../widgets/app_brand_icon.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import 'premium_policy_page.dart';

class PremiumMembershipPage extends StatefulWidget {
  const PremiumMembershipPage({super.key, required this.account});

  final MemberAccountController account;

  @override
  State<PremiumMembershipPage> createState() => _PremiumMembershipPageState();
}

class _PremiumMembershipPageState extends State<PremiumMembershipPage>
    with WidgetsBindingObserver {
  final _redemptionCode = TextEditingController();
  late final _changes = Listenable.merge([
    widget.account,
    widget.account.applePurchase,
  ]);
  String? _message;
  bool _messageIsError = false;

  bool get _usesAppleBilling => AppDistribution.usesAppleBilling;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_usesAppleBilling && widget.account.isAuthenticated) {
      unawaited(widget.account.applePurchase.initialize());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.account.synchronize());
    }
  }

  void _showMessage(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  void _showFailure(Object error) {
    if (!mounted) return;
    _showMessage(switch (error) {
      MemberAccountException() => error.message,
      PlatformException() =>
        error.message ?? context.l10n.premiumOperationFailed,
      _ => context.l10n.premiumOperationFailed,
    }, error: true);
  }

  Future<void> _perform(
    Future<void> Function() action, {
    bool usePurchaseStatus = false,
  }) async {
    setState(() {
      _message = null;
      _messageIsError = false;
    });
    try {
      await action();
    } catch (error) {
      // StoreKit may deliver a verified transaction after a restore timeout.
      // Keep that flow driven by its live status instead of pinning an error.
      if (usePurchaseStatus &&
          widget.account.applePurchase.phase == ApplePurchasePhase.failed) {
        return;
      }
      _showFailure(error);
    }
  }

  Future<void> _redeem() async {
    await _perform(() async {
      await widget.account.redeemMembership(_redemptionCode.text);
      _redemptionCode.clear();
      if (mounted) _showMessage(context.l10n.premiumPurchaseSuccess);
    });
  }

  Future<void> _openUrl(
    Uri uri, {
    LaunchMode mode = LaunchMode.inAppBrowserView,
  }) async {
    try {
      final opened = await launchUrl(uri, mode: mode);
      if (!opened && mounted) {
        _showMessage(context.l10n.premiumLinkFailed, error: true);
      }
    } catch (_) {
      if (mounted) _showMessage(context.l10n.premiumLinkFailed, error: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _redemptionCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _changes,
    builder: (context, _) {
      final l10n = context.l10n;
      final account = widget.account;
      final purchase = account.applePurchase;
      final premium = account.hasPremiumAccess;
      final busy = purchase.loading || account.loading;
      final colors = Theme.of(context).colorScheme;
      final status = account.isAuthenticated
          ? _message ?? _purchaseStatus(context, purchase)
          : null;
      return FloatingSubpageScaffold(
        title: l10n.accountSupportTitle,
        body: ListView(
          padding: floatingSubpagePadding(context, bottom: 40),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _membershipCard(premium),
                    if (premium) ...[
                      const SizedBox(height: 12),
                      Text(
                        _membershipSourceMessage(context, account),
                        key: const ValueKey('premium-membership-source'),
                      ),
                    ],
                    if (account.membershipSyncFailed ||
                        (account.isAuthenticated &&
                            account.membership == null)) ...[
                      const SizedBox(height: 12),
                      Text(
                        account.membershipSyncFailed
                            ? l10n.premiumSyncFailed
                            : l10n.premiumSyncPending,
                        key: const ValueKey('premium-sync-failed'),
                      ),
                    ],
                    const SizedBox(height: 24),
                    _section(l10n.premiumBenefitsTitle, [
                      _benefit(
                        Icons.layers_outlined,
                        l10n.settingsAdditionalSourceProtocolsTitle,
                        l10n.premiumProtocolsBenefit,
                      ),
                      const Divider(height: 28),
                      _benefit(
                        Icons.wifi_rounded,
                        l10n.settingsPrivateBookSourceNetworkTitle,
                        l10n.premiumPrivateNetworkBenefit,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        l10n.premiumSourceNotice,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (premium) ...[
                        const SizedBox(height: 12),
                        Text(
                          l10n.premiumSetupHint,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 20),
                    if (!premium ||
                        _usesAppleBilling ||
                        status != null ||
                        account.membership?.premiumExpiresAt != null)
                      _section(
                        premium
                            ? l10n.premiumAccountBindingTitle
                            : l10n.premiumBillingTitle,
                        [
                          if (!account.isAuthenticated)
                            Text(l10n.premiumSignInRequired)
                          else if (_usesAppleBilling) ...[
                            if (!premium ||
                                account.membership?.premiumExpiresAt !=
                                    null) ...[
                              if (purchase.product case final product?) ...[
                                Text(
                                  product.price,
                                  key: const ValueKey('premium-store-price'),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  l10n.premiumLifetimeCaption,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                              FilledButton(
                                key: const ValueKey('account-apple-purchase'),
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: busy
                                    ? null
                                    : () => _perform(
                                        purchase.product == null
                                            ? purchase.initialize
                                            : account.purchaseApplePremium,
                                        usePurchaseStatus: true,
                                      ),
                                child: busy
                                    ? const CupertinoActivityIndicator()
                                    : Text(
                                        purchase.product == null
                                            ? l10n.accountAppleProductRetry
                                            : l10n.accountApplePurchase,
                                        textAlign: TextAlign.center,
                                      ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            TextButton.icon(
                              key: const ValueKey('account-apple-restore'),
                              icon: const Icon(Icons.restore_rounded, size: 20),
                              onPressed: busy
                                  ? null
                                  : () => _perform(
                                      account.restoreApplePremium,
                                      usePurchaseStatus: true,
                                    ),
                              label: Text(
                                l10n.accountAppleRestore,
                                textAlign: TextAlign.center,
                              ),
                            ),
                            Text(
                              l10n.premiumRestoreHelp,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            if (!premium ||
                                account.membership?.premiumExpiresAt !=
                                    null) ...[
                              const SizedBox(height: 16),
                              Text(
                                l10n.premiumBillingBody,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.6,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ] else if (!premium ||
                              account.membership?.premiumExpiresAt != null) ...[
                            TextField(
                              key: const ValueKey('account-redemption-code'),
                              controller: _redemptionCode,
                              textCapitalization: TextCapitalization.characters,
                              decoration: InputDecoration(
                                labelText: l10n.accountRedemptionCode,
                              ),
                            ),
                            const SizedBox(height: 14),
                            FilledButton(
                              key: const ValueKey('account-redeem-premium'),
                              onPressed: busy ? null : _redeem,
                              child: Text(l10n.accountRedeemPremium),
                            ),
                            if (account.membershipConfig?.purchaseUrl
                                case final url?) ...[
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () => _openUrl(
                                  Uri.parse(url),
                                  mode: LaunchMode.externalApplication,
                                ),
                                child: Text(l10n.accountSupportAction),
                              ),
                            ],
                          ],
                          if (status != null) ...[
                            const SizedBox(height: 14),
                            Semantics(
                              liveRegion: true,
                              child: Text(
                                status,
                                key: const ValueKey('premium-purchase-status'),
                                style: TextStyle(
                                  height: 1.5,
                                  color:
                                      _messageIsError ||
                                          purchase.phase ==
                                              ApplePurchasePhase.failed
                                      ? colors.error
                                      : colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    const SizedBox(height: 22),
                    if (!premium)
                      Text(
                        _usesAppleBilling
                            ? l10n.premiumPurchaseConsent
                            : l10n.premiumPurchaseConsentOther,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      children: [
                        TextButton(
                          key: const ValueKey('premium-terms-link'),
                          onPressed: () => _openPolicy(PremiumPolicy.terms),
                          child: Text(l10n.premiumMembershipTerms),
                        ),
                        TextButton(
                          key: const ValueKey('premium-privacy-link'),
                          onPressed: () => _openPolicy(PremiumPolicy.privacy),
                          child: Text(l10n.premiumPrivacyPolicy),
                        ),
                        if (_usesAppleBilling)
                          TextButton(
                            key: const ValueKey('premium-eula-link'),
                            onPressed: () =>
                                _openUrl(PremiumPolicyPage.appleEulaUri),
                            child: Text(l10n.premiumAppleEula),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  void _openPolicy(PremiumPolicy policy) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => PremiumPolicyPage(
        policy: policy,
        usesAppleBilling: _usesAppleBilling,
      ),
    ),
  );

  String _membershipSourceMessage(
    BuildContext context,
    MemberAccountController account,
  ) {
    final l10n = context.l10n;
    final expiresAt = account.membership?.premiumExpiresAt;
    if (expiresAt != null) {
      final local = expiresAt.toLocal();
      return l10n.premiumTrialExpiresAt(
        '${MaterialLocalizations.of(context).formatMediumDate(local)} '
        '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(local))}',
      );
    }
    final sources = account.membership?.activePremiumSources ?? <String>{};
    if (sources.any(
      {'admin', 'manual', 'promotion', 'referral_card'}.contains,
    )) {
      return l10n.premiumGrantedAccess;
    }
    if (sources.contains('card')) return l10n.premiumOtherChannelAccess;
    if (sources.contains('apple')) return l10n.premiumAppleAccess;
    return l10n.premiumExistingAccess;
  }

  Widget _membershipCard(bool premium) {
    final l10n = context.l10n;
    final user = widget.account.user;
    return Container(
      key: const ValueKey('premium-membership-card'),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: premiumCardGradient,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: premiumGold.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: premiumGold.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppBrandIcon(size: 44, borderRadius: 12),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      premium &&
                              widget.account.membership?.premiumExpiresAt !=
                                  null
                          ? l10n.premiumTrialTitle
                          : l10n.premiumLifetimeTitle,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: premiumIvory,
                        fontWeight: FontWeight.w700,
                        fontSize: 24,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      premium &&
                              widget.account.membership?.premiumExpiresAt !=
                                  null
                          ? _membershipSourceMessage(context, widget.account)
                          : l10n.premiumLifetimeCaption,
                      style: TextStyle(
                        color: premiumIvory.withValues(alpha: 0.76),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (premium) ...[
            const SizedBox(height: 22),
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: premiumGold.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: premiumGold.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.verified_rounded,
                      size: 18,
                      color: premiumGold,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l10n.premiumPurchaseSuccess,
                        key: const ValueKey('premium-active'),
                        style: const TextStyle(
                          color: premiumIvory,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (user != null) ...[
            const SizedBox(height: 20),
            Divider(height: 1, color: premiumIvory.withValues(alpha: 0.16)),
            const SizedBox(height: 14),
            Text(
              user.effectiveName,
              style: const TextStyle(
                color: premiumIvory,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              user.email,
              style: TextStyle(
                color: premiumIvory.withValues(alpha: 0.68),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PageStyleHelper.palette(context).card,
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.35),
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _benefit(IconData icon, String title, String description) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          icon,
          size: 24,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              description,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  String? _purchaseStatus(
    BuildContext context,
    ApplePremiumPurchaseService purchase,
  ) {
    final l10n = context.l10n;
    return switch (purchase.phase) {
      ApplePurchasePhase.idle ||
      ApplePurchasePhase.loadingProduct ||
      ApplePurchasePhase.purchasing => null,
      ApplePurchasePhase.pending => l10n.premiumPendingApproval,
      ApplePurchasePhase.verifying => l10n.premiumVerifying,
      ApplePurchasePhase.restoring => l10n.premiumRestoring,
      ApplePurchasePhase.purchased =>
        widget.account.hasPremiumAccess ? l10n.premiumPurchaseSuccess : null,
      ApplePurchasePhase.restored =>
        widget.account.hasPremiumAccess ? l10n.premiumRestoreSuccess : null,
      ApplePurchasePhase.testVerified => l10n.premiumTestPurchaseVerified,
      ApplePurchasePhase.revoked => l10n.premiumPurchaseRevoked,
      ApplePurchasePhase.nothingToRestore => l10n.premiumRestoreEmpty,
      ApplePurchasePhase.canceled => l10n.premiumPurchaseCanceled,
      ApplePurchasePhase.failed => purchase.error,
    };
  }
}
