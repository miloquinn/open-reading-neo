import 'package:flutter/material.dart';

import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';

enum PremiumPolicy { terms, privacy }

/// Readable offline: legal information never depends on a successful web load.
class PremiumPolicyPage extends StatelessWidget {
  const PremiumPolicyPage({
    super.key,
    required this.policy,
    this.usesAppleBilling = true,
  });

  static final appleEulaUri = Uri.parse(
    'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
  );
  final PremiumPolicy policy;
  final bool usesAppleBilling;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final sections = policy == PremiumPolicy.terms
        ? [
            (
              l10n.premiumBenefitsTitle,
              '${l10n.settingsAdditionalSourceProtocolsTitle}\n${l10n.premiumProtocolsBenefit}\n\n${l10n.settingsPrivateBookSourceNetworkTitle}\n${l10n.premiumPrivateNetworkBenefit}\n\n${l10n.premiumSourceNotice}\n${l10n.premiumSetupHint}',
            ),
            (
              l10n.premiumBillingTitle,
              usesAppleBilling
                  ? l10n.premiumBillingBody
                  : l10n.premiumBillingBodyOther,
            ),
            (l10n.premiumAccountBindingTitle, l10n.premiumAccountBindingBody),
            if (usesAppleBilling) ...[
              (l10n.accountAppleRestore, l10n.premiumRestoreHelp),
              (l10n.premiumRefundTitle, l10n.premiumRefundTerms),
            ],
          ]
        : [
            (l10n.agreementV2Section6Title, l10n.agreementV2Section6Body),
            (l10n.premiumPrivacyAccountTitle, l10n.premiumPrivacyAccountBody),
            Localizations.localeOf(context).languageCode == 'zh'
                ? (
                    '账号阅读统计与排行榜',
                    '登录后，阅读记录的唯一编号、账号归属、起止时间及阅读时长会同步到官方服务器，用于跨设备统计和去重；此功能不上传书籍正文、书名或书单。未登录的记录保存在本机，仅在你确认合并后归入所选账号，不能重复转给其他账号。公开排行榜默认关闭，开启后展示昵称、头像和有效阅读时长；关闭后不再公开排名，个人云端统计仍保留。注销账号会删除对应云端阅读记录。',
                  )
                : (
                    'Account reading statistics and leaderboards',
                    'While signed in, record IDs, account ownership, reading timestamps and durations sync to our server for cross-device statistics and deduplication. Book text, titles and book lists are not uploaded by this feature. Guest records stay on your device until you choose an account to import them into; imported records cannot be reassigned. Public rankings are off by default. Opting in shares your name, avatar and ranked reading time. Opting out hides your ranking while preserving private cloud statistics. Deleting your account deletes its cloud reading records.',
                  ),
            (l10n.premiumPrivacyPurchaseTitle, l10n.premiumPrivacyPurchaseBody),
          ];
    return FloatingSubpageScaffold(
      title: policy == PremiumPolicy.terms
          ? l10n.premiumMembershipTerms
          : l10n.premiumPrivacyPolicy,
      body: SingleChildScrollView(
        padding: floatingSubpagePadding(context, bottom: 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (title, body) in sections) ...[
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      body,
                      style: const TextStyle(fontSize: 16, height: 1.65),
                    ),
                    const SizedBox(height: 28),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
