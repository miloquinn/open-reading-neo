import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../pages/account/account_page.dart';
import '../services/account/account.dart';
import '../utils/localization_extension.dart';

class SettingsAccountCard extends StatelessWidget {
  const SettingsAccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    final account = context.watch<MemberAccountController>();
    final user = account.user;
    final scheme = Theme.of(context).colorScheme;
    final title = user?.effectiveName ?? context.l10n.settingsAccountGuestTitle;
    final subtitle = user == null
        ? context.l10n.settingsAccountGuestSubtitle
        : '@${user.username} · ${context.l10n.settingsAccountVerified}';

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
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF123456), Color(0xFF1768B4)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF1768B4).withValues(alpha: 0.2),
                  blurRadius: 28,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Stack(
              children: [
                const Positioned(
                  right: -18,
                  bottom: -32,
                  child: _AccountCardMark(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 17, 16, 17),
                  child: Row(
                    children: [
                      _AccountAvatar(user: user),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.2,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.72),
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (account.loading)
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
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                          ),
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            color: scheme.surface,
                            size: 20,
                          ),
                        ),
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

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.user});

  final MemberUser? user;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = user?.avatarUrl;
    final initial = (user?.effectiveName.trim().isNotEmpty ?? false)
        ? user!.effectiveName.trim().characters.first.toUpperCase()
        : null;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: avatarUrl != null
          ? Image.network(
              avatarUrl,
              width: 52,
              height: 52,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _avatarFallback(initial),
            )
          : _avatarFallback(initial),
    );
  }

  Widget _avatarFallback(String? initial) => initial == null
      ? const Icon(Icons.person_outline_rounded, color: Colors.white, size: 27)
      : Text(
          initial,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
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
