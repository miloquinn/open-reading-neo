// 文件说明：登录方式摘要、账号操作、会员支持与推荐关系界面。
// 技术要点：同一账号功能库内的私有实现拆分，不扩大公开 API。

part of '../account_page.dart';

class _LoginMethodsCard extends StatelessWidget {
  const _LoginMethodsCard({required this.user});

  final MemberUser user;

  @override
  Widget build(BuildContext context) => _SectionCard(
    title: context.l10n.accountSignInMethodsTitle,
    icon: Icons.shield_outlined,
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: user.authMethods
          .map(
            (method) => Chip(
              avatar: const Icon(Icons.check_circle_rounded, size: 17),
              label: Text(_methodLabel(context, method)),
            ),
          )
          .toList(growable: false),
    ),
  );

  String _methodLabel(BuildContext context, String method) => switch (method) {
    'github' => 'GitHub',
    'google' => 'Google',
    'passkey' => 'Passkey',
    'password' => context.l10n.accountPassword,
    'email_code' => context.l10n.accountEmail,
    _ => method,
  };
}

class _AccountActionsCard extends StatelessWidget {
  const _AccountActionsCard({
    required this.user,
    required this.onEditProfile,
    required this.onOpenSecurity,
    required this.onOpenReferral,
    required this.onOpenSupport,
  });

  final MemberUser user;
  final VoidCallback onEditProfile;
  final VoidCallback onOpenSecurity;
  final VoidCallback onOpenReferral;
  final VoidCallback onOpenSupport;

  @override
  Widget build(BuildContext context) => _SectionCard(
    child: Column(
      children: [
        _AccountActionTile(
          key: const ValueKey('account-edit-profile'),
          icon: Icons.person_outline_rounded,
          title: context.l10n.accountEditProfile,
          subtitle: '@${user.username}',
          onTap: onEditProfile,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-security'),
          icon: Icons.shield_outlined,
          title: context.l10n.accountSecurityTitle,
          subtitle: user.email,
          onTap: onOpenSecurity,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-referral'),
          icon: Icons.group_add_rounded,
          title: context.l10n.accountInviteTitle,
          subtitle: context.l10n.accountInviteSubtitle,
          onTap: onOpenReferral,
        ),
        const Divider(height: 1),
        _AccountActionTile(
          key: const ValueKey('account-support'),
          icon: Icons.volunteer_activism_rounded,
          title: context.l10n.accountSupportTitle,
          subtitle: context.l10n.accountSupportFreeSubtitle,
          onTap: onOpenSupport,
        ),
      ],
    ),
  );
}

class _AccountReferralPage extends StatelessWidget {
  const _AccountReferralPage();

  @override
  Widget build(BuildContext context) => Consumer<MemberAccountController>(
    builder: (context, account, child) => FloatingSubpageScaffold(
      title: context.l10n.accountInviteTitle,
      body: ListView(
        padding: floatingSubpagePadding(context, bottom: 40),
        children: [
          if (account.referral != null)
            _ReferralCard(account: account)
          else
            _SectionCard(child: Text(context.l10n.accountInviteSubtitle)),
        ],
      ),
    ),
  );
}

class _AccountSupportPage extends StatelessWidget {
  const _AccountSupportPage();

  @override
  Widget build(BuildContext context) => Consumer<MemberAccountController>(
    builder: (context, account, child) => FloatingSubpageScaffold(
      title: context.l10n.accountSupportTitle,
      body: ListView(
        padding: floatingSubpagePadding(context, bottom: 40),
        children: [_SupportCard(account: account)],
      ),
    ),
  );
}

class _AccountActionTile extends StatelessWidget {
  const _AccountActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      leading: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 21,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

class _SupportCard extends StatefulWidget {
  const _SupportCard({required this.account});

  final MemberAccountController account;

  @override
  State<_SupportCard> createState() => _SupportCardState();
}

class _SupportCardState extends State<_SupportCard> {
  final _redemptionCode = TextEditingController();

  @override
  void dispose() {
    _redemptionCode.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    try {
      final wasWaitingForInviteReward =
          widget.account.referral?.inviter?.status == 'pending';
      await widget.account.redeemMembership(_redemptionCode.text);
      _redemptionCode.clear();
      if (mounted) {
        showSideToast(
          context,
          wasWaitingForInviteReward
              ? context.l10n.accountPremiumUnlockedReferral
              : context.l10n.accountPremiumUnlocked,
        );
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  Future<void> _purchaseWithApple() async {
    try {
      await widget.account.purchaseApplePremium();
      if (mounted) {
        showSideToast(context, context.l10n.accountApplePurchaseSubmitted);
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  Future<void> _restoreApplePurchase() async {
    try {
      await widget.account.restoreApplePremium();
      if (mounted) {
        showSideToast(context, context.l10n.accountAppleRestoreSubmitted);
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final purchaseUrl = account.membershipConfig?.purchaseUrl;
    final applePlatform =
        !kIsWeb &&
        {
          TargetPlatform.iOS,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform);
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.volunteer_activism_rounded,
                  size: 21,
                  color: colors.onPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  context.l10n.accountSupportTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            account.membership?.premium == true
                ? context.l10n.accountPremiumLifetime
                : context.l10n.accountSupportFreeTitle,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            account.membership?.premium == true
                ? context.l10n.accountPremiumLifetimeSubtitle
                : context.l10n.accountSupportFreeSubtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (account.membership?.premium != true) ...[
            const SizedBox(height: 12),
            Container(
              key: const ValueKey('account-premium-purchase-notice'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.tertiaryContainer.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: colors.tertiary.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.tips_and_updates_rounded,
                      size: 15,
                      color: colors.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.l10n.accountSupportPurchaseNotice,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onTertiaryContainer,
                        height: 1.55,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (account.isAuthenticated &&
              account.membership?.premium != true &&
              !applePlatform) ...[
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('account-redemption-code'),
              controller: _redemptionCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: context.l10n.accountRedemptionCode,
                prefixIcon: const Icon(Icons.key_rounded),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const ValueKey('account-redeem-premium'),
              onPressed: account.loading ? null : _redeem,
              icon: const Icon(Icons.lock_open_rounded),
              label: Text(context.l10n.accountRedeemPremium),
            ),
          ],
          if (account.isAuthenticated &&
              account.membership?.premium != true &&
              applePlatform) ...[
            const SizedBox(height: 14),
            Text(
              context.l10n.accountApplePurchaseHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            _AppleStorePurchaseButton(
              key: const ValueKey('account-apple-purchase'),
              purchase: account.applePurchase,
              onPurchase: _purchaseWithApple,
            ),
            const SizedBox(height: 4),
            Center(
              child: CupertinoButton(
                key: const ValueKey('account-apple-restore'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                minimumSize: Size.zero,
                onPressed: account.applePurchase.loading
                    ? null
                    : _restoreApplePurchase,
                child: Text(
                  context.l10n.accountAppleRestore,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: account.applePurchase.loading
                        ? CupertinoColors.inactiveGray
                        : CupertinoColors.activeBlue.resolveFrom(context),
                  ),
                ),
              ),
            ),
            if (account.applePurchase.error != null &&
                account.applePurchase.product != null) ...[
              const SizedBox(height: 4),
              Text(
                account.applePurchase.error!,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.error),
              ),
            ],
          ],
          if (purchaseUrl != null && !applePlatform) ...[
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(purchaseUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.favorite_outline_rounded),
              label: Text(context.l10n.accountSupportAction),
            ),
          ],
        ],
      ),
    );
  }
}

/// Mirrors the iOS "Get"/pill purchase button so App Store purchase reads as
/// a native control rather than a generic Material button. Product loading,
/// purchase-in-flight, and failed-to-load states share one pill so the
/// button never sits blank while StoreKit is still answering.
class _AppleStorePurchaseButton extends StatelessWidget {
  const _AppleStorePurchaseButton({
    super.key,
    required this.purchase,
    required this.onPurchase,
  });

  final ApplePremiumPurchaseService purchase;
  final VoidCallback onPurchase;

  @override
  Widget build(BuildContext context) {
    final product = purchase.product;
    final loading = purchase.loading;
    if (product == null) {
      return CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 13),
        borderRadius: BorderRadius.circular(14),
        color: CupertinoColors.systemFill.resolveFrom(context),
        onPressed: loading ? null : purchase.initialize,
        child: loading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CupertinoActivityIndicator(),
              )
            : Text(
                purchase.error != null
                    ? context.l10n.accountAppleProductRetry
                    : context.l10n.accountAppleProductLoading,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
      );
    }
    return CupertinoButton.filled(
      padding: const EdgeInsets.symmetric(vertical: 13),
      borderRadius: BorderRadius.circular(14),
      onPressed: loading ? null : onPurchase,
      child: loading
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CupertinoActivityIndicator(color: CupertinoColors.white),
            )
          : Text(
              '${context.l10n.accountApplePurchase} · ${product.price}',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.white,
              ),
            ),
    );
  }
}

class _ReferralCard extends StatefulWidget {
  const _ReferralCard({required this.account});

  final MemberAccountController account;

  @override
  State<_ReferralCard> createState() => _ReferralCardState();
}

class _ReferralCardState extends State<_ReferralCard> {
  final _inviteCode = TextEditingController();

  @override
  void dispose() {
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _copy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showSideToast(context, context.l10n.accountInviteCopied);
  }

  Future<void> _bind() async {
    try {
      await widget.account.bindReferral(_inviteCode.text);
      _inviteCode.clear();
      if (mounted) showSideToast(context, context.l10n.accountInviteBound);
    } catch (error) {
      if (mounted) {
        showSideToast(context, error.toString(), kind: SideToastKind.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final referral = widget.account.referral;
    if (referral == null) return const SizedBox.shrink();
    final inviter = referral.inviter;
    final colors = Theme.of(context).colorScheme;
    return _SectionCard(
      title: context.l10n.accountInviteTitle,
      icon: Icons.group_add_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.accountInviteSubtitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            key: const ValueKey('account-invite-ticket'),
            padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
            decoration: BoxDecoration(
              color: colors.tertiaryContainer.withValues(alpha: 0.52),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.tertiary.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.accountInviteMyCode,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: colors.onTertiaryContainer.withValues(
                                alpha: 0.7,
                              ),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        referral.inviteCode,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: colors.onTertiaryContainer,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('account-copy-invite-code'),
                  tooltip: context.l10n.accountInviteCopyCode,
                  onPressed: () => _copy(referral.inviteCode),
                  icon: const Icon(Icons.copy_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('account-share-invite'),
            onPressed: () => _copy(referral.inviteUrl.toString()),
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(context.l10n.accountInviteShareAction),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _InviteStat(
                  value: referral.invitedCount,
                  label: context.l10n.accountInviteStatsInvited,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _InviteStat(
                  value: referral.rewardedCount,
                  label: context.l10n.accountInviteStatsRewarded,
                  highlighted: referral.rewardedCount > 0,
                ),
              ),
            ],
          ),
          if (referral.recentInvites.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '最近邀请',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            ...referral.recentInvites
                .take(5)
                .map(
                  (item) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      child: Text(item.name.characters.first.toUpperCase()),
                    ),
                    title: Text(item.name),
                    subtitle: Text(
                      '绑定于 ${MaterialLocalizations.of(context).formatCompactDate(item.boundAt)}',
                    ),
                    trailing: Text(
                      item.status == 'rewarded' ? '已解锁奖励' : '等待兑换',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: item.status == 'rewarded'
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
          ],
          const SizedBox(height: 20),
          Text(
            context.l10n.accountInviteHowItWorks,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _InviteStep(
            number: 1,
            title: context.l10n.accountInviteStepShareTitle,
            body: context.l10n.accountInviteStepShareBody,
          ),
          _InviteStep(
            number: 2,
            title: context.l10n.accountInviteStepBindTitle,
            body: context.l10n.accountInviteStepBindBody,
          ),
          _InviteStep(
            number: 3,
            title: context.l10n.accountInviteStepRedeemTitle,
            body: context.l10n.accountInviteStepRedeemBody,
            last: true,
          ),
          const Divider(height: 30),
          Text(
            context.l10n.accountInviteMyBinding,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          if (inviter != null)
            Container(
              key: const ValueKey('account-inviter-bound'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest.withValues(alpha: 0.58),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(
                    inviter.status == 'rewarded'
                        ? Icons.verified_rounded
                        : Icons.hourglass_top_rounded,
                    color: inviter.status == 'rewarded'
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.l10n.accountInviterBound(inviter.name),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${inviter.code} · ${inviter.status == 'rewarded' ? context.l10n.accountInviteRewarded : context.l10n.accountInviteWaiting}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else if (widget.account.membership?.premium != true) ...[
            Text(
              context.l10n.accountInviteBindIntro,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('account-invite-code'),
              controller: _inviteCode,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: context.l10n.accountInviteBindLabel,
                helperText: context.l10n.accountInviteBindHint,
                prefixIcon: const Icon(Icons.person_add_alt_1_rounded),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              key: const ValueKey('account-bind-invite'),
              onPressed: widget.account.loading ? null : _bind,
              child: Text(context.l10n.accountInviteBindAction),
            ),
          ] else
            Text(
              context.l10n.accountInviteBindingNotNeeded,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _InviteStat extends StatelessWidget {
  const _InviteStat({
    required this.value,
    required this.label,
    this.highlighted = false,
  });

  final int value;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primaryContainer.withValues(alpha: 0.62)
            : colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: highlighted ? colors.primary : colors.onSurface,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InviteStep extends StatelessWidget {
  const _InviteStep({
    required this.number,
    required this.title,
    required this.body,
    this.last = false,
  });

  final int number;
  final String title;
  final String body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 34,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$number',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!last)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: colors.outlineVariant.withValues(alpha: 0.72),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.user, required this.size});

  final MemberUser user;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        (user.effectiveName.trim().isEmpty ? user.username : user.effectiveName)
            .characters
            .first
            .toUpperCase(),
        style: TextStyle(fontSize: size * 0.34, fontWeight: FontWeight.w800),
      ),
    );
    return ClipOval(
      child: user.avatarUrl == null
          ? fallback
          : AccountAvatarImage(
              url: Uri.parse(user.avatarUrl!),
              fallback: fallback,
              width: size,
              height: size,
              fit: BoxFit.cover,
            ),
    );
  }
}
