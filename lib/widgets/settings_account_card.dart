import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/account/account_page.dart';
import '../services/account/account.dart';
import '../utils/localization_extension.dart';
import 'account_avatar_image.dart';

class SettingsAccountCard extends StatelessWidget {
  const SettingsAccountCard({super.key});

  static const _premiumGold = Color(0xFFF1CA86);
  static const _premiumIvory = Color(0xFFFFEAC1);

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    final summary = account.summary;
    final premium = summary?.premium == true;
    final scheme = Theme.of(context).colorScheme;
    final title =
        summary?.effectiveName ?? context.l10n.settingsAccountGuestTitle;
    final subtitle = summary == null
        ? context.l10n.settingsAccountGuestSubtitle
        : '@${summary.username} · ${context.l10n.settingsAccountVerified}';

    return Semantics(
      button: true,
      label: context.l10n.settingsAccountOpen,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('settings-account-card'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const AccountPage())),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: premium
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF171629),
                        Color(0xFF39244A),
                        Color(0xFF795039),
                      ],
                      stops: [0, 0.56, 1],
                    )
                  : const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF123456), Color(0xFF1768B4)],
                    ),
              border: premium
                  ? Border.all(
                      color: _premiumGold.withValues(alpha: 0.78),
                      width: 1.5,
                    )
                  : null,
              boxShadow: [
                BoxShadow(
                  color: (premium ? _premiumGold : const Color(0xFF1768B4))
                      .withValues(alpha: premium ? 0.24 : 0.2),
                  blurRadius: premium ? 30 : 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Stack(
              children: [
                if (premium)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(painter: _PremiumCardPattern()),
                    ),
                  )
                else
                  const Positioned(
                    right: -18,
                    bottom: -32,
                    child: _AccountCardMark(),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(18, 17, 16, premium ? 14 : 17),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _AccountAvatar(
                            effectiveName: summary?.effectiveName,
                            avatarUrl: summary?.avatarUrl,
                            premium: premium,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              color: premium
                                                  ? _premiumIvory
                                                  : Colors.white,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: -0.2,
                                            ),
                                      ),
                                    ),
                                    if (premium) ...[
                                      const SizedBox(width: 8),
                                      _PremiumBadge(
                                        label:
                                            context.l10n.accountSupporterBadge,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Colors.white.withValues(
                                          alpha: premium ? 0.68 : 0.72,
                                        ),
                                      ),
                                ),
                              ],
                            ),
                          ),
                          if (account.loading && summary == null)
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          else
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(
                                  alpha: premium ? 0.1 : 0.12,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: (premium ? _premiumGold : Colors.white)
                                      .withValues(alpha: premium ? 0.28 : 0.14),
                                ),
                              ),
                              child: Icon(
                                Icons.arrow_forward_rounded,
                                color: premium ? _premiumIvory : scheme.surface,
                                size: 20,
                              ),
                            ),
                        ],
                      ),
                      if (premium) ...[
                        const SizedBox(height: 13),
                        Row(
                          children: [
                            const Icon(
                              Icons.auto_awesome_rounded,
                              color: _premiumGold,
                              size: 16,
                            ),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(
                                context.l10n.accountPremiumLifetime,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFF8DDA9),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.1,
                                ),
                              ),
                            ),
                            Text(
                              'PREMIUM',
                              style: TextStyle(
                                color: _premiumIvory.withValues(alpha: 0.48),
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('settings-account-premium-badge'),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: SettingsAccountCard._premiumGold.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(
        color: SettingsAccountCard._premiumGold.withValues(alpha: 0.34),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.workspace_premium_rounded,
          color: SettingsAccountCard._premiumGold,
          size: 12,
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: const TextStyle(
            color: SettingsAccountCard._premiumIvory,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _PremiumCardPattern extends CustomPainter {
  const _PremiumCardPattern();

  @override
  void paint(Canvas canvas, Size size) {
    final glow = Paint()
      ..shader =
          RadialGradient(
            colors: [
              SettingsAccountCard._premiumGold.withValues(alpha: 0.17),
              SettingsAccountCard._premiumGold.withValues(alpha: 0),
            ],
          ).createShader(
            Rect.fromCircle(
              center: Offset(size.width * 0.92, size.height * 0.04),
              radius: size.width * 0.74,
            ),
          );
    canvas.drawRect(Offset.zero & size, glow);
    final line = Paint()
      ..color = SettingsAccountCard._premiumIvory.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final radius = size.height * 0.64;
    final center = Offset(size.width * 0.98, size.height * 0.03);
    canvas.drawCircle(center, radius, line);
    canvas.drawCircle(center, radius * 0.72, line);

    final innerBorder = Paint()
      ..color = SettingsAccountCard._premiumIvory.withValues(alpha: 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(4.5, 4.5, size.width - 9, size.height - 9),
        const Radius.circular(18),
      ),
      innerBorder,
    );
  }

  @override
  bool shouldRepaint(covariant _PremiumCardPattern oldDelegate) => false;
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({
    required this.effectiveName,
    required this.avatarUrl,
    required this.premium,
  });

  final String? effectiveName;
  final String? avatarUrl;
  final bool premium;

  @override
  Widget build(BuildContext context) {
    final resolvedAvatarUrl = avatarUrl;
    final initial = (effectiveName?.trim().isNotEmpty ?? false)
        ? effectiveName!.trim().characters.first.toUpperCase()
        : null;
    final outerSize = premium ? 60.0 : 52.0;
    final imageSize = premium ? 52.0 : 50.0;
    return Container(
      key: const ValueKey('settings-account-avatar'),
      width: outerSize,
      height: outerSize,
      decoration: BoxDecoration(
        color: premium
            ? SettingsAccountCard._premiumGold.withValues(alpha: 0.18)
            : Colors.white.withValues(alpha: 0.13),
        shape: BoxShape.circle,
        border: Border.all(
          color: premium
              ? SettingsAccountCard._premiumGold.withValues(alpha: 0.95)
              : Colors.white.withValues(alpha: 0.2),
          width: premium ? 2.2 : 1,
        ),
        boxShadow: premium
            ? [
                BoxShadow(
                  color: SettingsAccountCard._premiumGold.withValues(
                    alpha: 0.2,
                  ),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      padding: EdgeInsets.all(premium ? 3 : 1),
      child: ClipOval(
        key: const ValueKey('settings-account-avatar-clip'),
        child: SizedBox(
          width: imageSize,
          height: imageSize,
          child: resolvedAvatarUrl != null
              ? AccountAvatarImage(
                  url: Uri.parse(resolvedAvatarUrl),
                  fallback: _avatarFallback(initial),
                  width: imageSize,
                  height: imageSize,
                  fit: BoxFit.cover,
                )
              : _avatarFallback(initial),
        ),
      ),
    );
  }

  Widget _avatarFallback(String? initial) => Center(
    key: const ValueKey('settings-account-avatar-fallback'),
    child: initial == null
        ? Icon(
            Icons.person_outline_rounded,
            color: premium ? SettingsAccountCard._premiumIvory : Colors.white,
            size: 27,
          )
        : Text(
            initial,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: premium ? SettingsAccountCard._premiumIvory : Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
  );
}

class _AccountCardMark extends StatelessWidget {
  const _AccountCardMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 126,
      height: 126,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 24,
        ),
      ),
    );
  }
}
