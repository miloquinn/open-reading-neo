part of '../settings_page.dart';

extension _SettingsAboutPart on _SettingsPageState {
  Widget _buildAboutCard() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final palette = PageStyleHelper.palette(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppBrandIcon(
                size: 48,
                borderRadius: 12,
                border: Border.all(
                  color: scheme.primary.withValues(alpha: 0.22),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsAppName,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.settingsAboutTagline,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 14),
          _buildAboutLine(l10n.settingsVersionLabel, _appVersion),
          _buildAboutLine(l10n.settingsLicenseLabel, 'AGPL-3.0'),
          const SizedBox(height: 8),
          _buildOpenSourceLicensesLink(),
          const SizedBox(height: 10),
          _buildChangelogLink(),
          const SizedBox(height: 14),
          _buildCommunityButton(
            onPressed: _checkForUpdates,
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            icon: _isCheckingForUpdates
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onPrimary,
                    ),
                  )
                : const Icon(Icons.system_update_alt_rounded),
            title: l10n.updateCheckNow,
            subtitle: l10n.updateCheckNowSubtitle,
          ),
          const SizedBox(height: 10),
          _buildCommunityButton(
            onPressed: _openOfficialWebsite,
            backgroundColor: const Color(0xFF2D6A4F),
            foregroundColor: Colors.white,
            icon: const Icon(Icons.language_rounded),
            title: l10n.settingsOfficialWebsite,
            subtitle: l10n.settingsOfficialWebsiteSubtitle,
          ),
          const SizedBox(height: 10),
          _buildCommunityButton(
            onPressed: _openGithubRepo,
            backgroundColor: const Color(0xFF181717),
            foregroundColor: Colors.white,
            icon: const _GithubMark(),
            title: 'GitHub',
            subtitle: l10n.settingsViewSourceSubtitle,
          ),
          const SizedBox(height: 10),
          _buildCommunityButton(
            onPressed: _openTelegramChannel,
            backgroundColor: const Color(0xFF229ED9),
            foregroundColor: Colors.white,
            icon: const Icon(Icons.send_rounded),
            title: l10n.settingsTelegramChannel,
            subtitle: l10n.settingsTelegramSubtitle,
          ),
          const SizedBox(height: 10),
          _buildCommunityButton(
            onPressed: _openQqChannel,
            backgroundColor: const Color(0xFF12B7F5),
            foregroundColor: Colors.white,
            icon: const _QqMark(),
            title: l10n.settingsQqChannel,
            subtitle: l10n.settingsQqChannelSubtitle,
          ),
          const SizedBox(height: 10),
          _buildCommunityButton(
            onPressed: _openQqGroup,
            backgroundColor: const Color(0xFF1677FF),
            foregroundColor: Colors.white,
            icon: const _QqMark(),
            title: l10n.settingsJoinQqGroup,
            subtitle: '1003560209',
          ),
        ],
      ),
    );
  }

  Widget _buildChangelogLink() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey('settings-changelog-link'),
        onTap: _openChangelogHistory,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.changelogHistoryTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.changelogHistorySubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOpenSourceLicensesLink() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey('settings-open-source-licenses-link'),
        onTap: _openSourceLicenses,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.openSourceLicensesTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.openSourceLicensesSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _openChangelogHistory() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ChangelogPage()));
  }

  void _openSourceLicenses() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OpenSourceLicensesPage(appVersion: _appVersion),
      ),
    );
  }

  Widget _buildCommunityButton({
    required VoidCallback onPressed,
    required Color backgroundColor,
    required Color foregroundColor,
    required Widget icon,
    required String title,
    required String subtitle,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: FilledButton(
        onPressed: onPressed,
        style:
            FilledButton.styleFrom(
              backgroundColor: backgroundColor,
              foregroundColor: foregroundColor,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              elevation: 0,
            ).copyWith(
              overlayColor: WidgetStatePropertyAll(
                foregroundColor.withValues(alpha: 0.12),
              ),
            ),
        child: Row(
          children: [
            SizedBox(width: 24, height: 24, child: icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: foregroundColor.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_outward_rounded,
              size: 19,
              color: foregroundColor.withValues(alpha: 0.78),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutLine(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openGithubRepo() async {
    final uri = Uri.parse('https://github.com/miloquinn/open-reading');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsGithubOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openOfficialWebsite() async {
    final ok = await launchUrl(
      Uri.parse('https://open.xxread.top/'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsOfficialWebsiteOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  void _showDonationDialog(DeveloperDonationMethod method) {
    showDialog<void>(
      context: context,
      builder: (_) => DeveloperDonationDialog(method: method),
    );
  }

  Future<void> _openTelegramChannel() async {
    final uri = Uri.parse('https://t.me/origoreading');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsTelegramOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _openQqChannel() async {
    final uri = Uri.parse('https://pd.qq.com/s/diin97dya?b=9');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsQqChannelOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _checkForUpdates() async {
    if (_isCheckingForUpdates) return;
    _mutate(() => _isCheckingForUpdates = true);
    await UpdatePromptController.check(context, manual: true);
    if (mounted) {
      _mutate(() => _isCheckingForUpdates = false);
    }
  }

  Future<void> _openQqGroup() async {
    final uri = Uri.parse(
      'mqqapi://card/show_pslcard?src_type=internal&version=1&uin=1003560209&card_type=group&source=qrcode',
    );
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      showSideToast(
        context,
        context.l10n.settingsQqOpenFailed,
        icon: Icons.error_outline,
        kind: SideToastKind.error,
      );
    }
  }

  // 构建操作设置
  Widget _buildActionSetting({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    required IconData icon,
    String? badge,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.tertiary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    icon,
                    size: 16,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          if (badge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                badge,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSecondaryContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing,
                ] else
                  Icon(
                    Icons.arrow_forward_ios,
                    size: 16,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
