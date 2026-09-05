part of '../settings_page.dart';

extension _SettingsLayoutPart on _SettingsPageState {
  Widget _buildSettingsTopRow(AppLocalizations l10n, bool useRailNavigation) {
    final palette = PageStyleHelper.palette(context);
    return Row(
      children: [
        Text(
          l10n.settings,
          style: Theme.of(context).textTheme.headlineLarge?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.05,
          ),
        ),
        const Spacer(),
        InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () =>
              showSideToast(context, context.l10n.settingsHelpPlaceholder),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.card,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Icon(
              Icons.question_mark_rounded,
              size: 20,
              color: palette.iconMuted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: LayoutHelper.usesTabletLayout(context)
              ? const EdgeInsets.only(bottom: 10)
              : const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              Icon(icon, color: scheme.primary, size: 18),
              const SizedBox(width: 9),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: palette.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildSettingsLayout({
    required AppLocalizations l10n,
    required ThemeNotifier themeNotifier,
    required AppSettingsNotifier appSettings,
    required WebDavSyncController webDavSync,
    required bool useRailNavigation,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (useRailNavigation) ...[
          _buildSettingsTopRow(l10n, useRailNavigation),
          const SizedBox(height: 24),
        ],
        const SettingsAccountCard(),
        const SizedBox(height: 24),
        Row(
          key: const ValueKey('settings-wide-layout'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                key: const ValueKey('settings-primary-column'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildAppearanceSettingsSection(
                    l10n,
                    themeNotifier,
                    appSettings,
                  ),
                  const SizedBox(height: 20),
                  _buildReadingSettingsSection(l10n),
                  const SizedBox(height: 20),
                  _buildGeneralSettingsSection(l10n, appSettings),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                key: const ValueKey('settings-secondary-column'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildDataServicesSection(l10n, webDavSync),
                  const SizedBox(height: 20),
                  _buildAdvancedSettingsSection(l10n, appSettings),
                  const SizedBox(height: 20),
                  _buildSupportSettingsSection(l10n),
                  const SizedBox(height: 20),
                  _buildAboutCard(),
                  const SizedBox(height: 20),
                  const ContributorsView(
                    repositoryOwner: 'miloquinn',
                    repositoryName: 'open-reading',
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 100),
      ],
    );
  }

  List<Widget> _buildSettingsSingleColumnChildren({
    required AppLocalizations l10n,
    required ThemeNotifier themeNotifier,
    required AppSettingsNotifier appSettings,
    required WebDavSyncController webDavSync,
    required bool useRailNavigation,
  }) {
    return [
      if (useRailNavigation) ...[
        _buildSettingsTopRow(l10n, useRailNavigation),
        const SizedBox(height: 24),
      ],
      const KeyedSubtree(
        key: ValueKey('settings-single-column-layout'),
        child: SettingsAccountCard(),
      ),
      const SizedBox(height: 20),
      _buildAppearanceSettingsSection(l10n, themeNotifier, appSettings),
      const SizedBox(height: 20),
      _buildReadingSettingsSection(l10n),
      const SizedBox(height: 20),
      _buildDataServicesSection(l10n, webDavSync),
      const SizedBox(height: 20),
      _buildGeneralSettingsSection(l10n, appSettings),
      const SizedBox(height: 20),
      _buildAdvancedSettingsSection(l10n, appSettings),
      const SizedBox(height: 20),
      _buildSupportSettingsSection(l10n),
      const SizedBox(height: 20),
      _buildAboutCard(),
      const SizedBox(height: 20),
      const ContributorsView(
        repositoryOwner: 'miloquinn',
        repositoryName: 'open-reading',
      ),
      const SizedBox(height: 100),
    ];
  }

  Widget _buildAppearanceSettingsSection(
    AppLocalizations l10n,
    ThemeNotifier themeNotifier,
    AppSettingsNotifier appSettings,
  ) {
    return _buildSectionCard(
      title: l10n.settingsSectionAppearanceFonts,
      icon: Icons.palette_outlined,
      children: [
        _buildUiStyleSelector(themeNotifier),
        _buildThemeToggle(themeNotifier),
        _buildAccentColorSelector(themeNotifier),
        _buildAppFontSelector(appSettings),
        _buildReaderFontSelector(appSettings),
        _buildCustomFontsManager(appSettings),
        _buildActionSetting(
          title: l10n.settingsLibraryLayoutTitle,
          subtitle: l10n.settingsCurrentValue(
            appSettings.libraryLayoutMode == LibraryLayoutMode.card
                ? l10n.settingsLibraryLayoutCard
                : l10n.settingsLibraryLayoutGrid,
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const LibraryLayoutSettingsPage(),
            ),
          ),
          icon: Icons.view_module_outlined,
        ),
        _buildActionSetting(
          title: l10n.settingsFloatingNavigationTitle,
          subtitle: l10n.settingsFloatingNavigationSubtitle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const FloatingNavigationSettingsPage(),
            ),
          ),
          icon: Icons.dock_outlined,
        ),
      ],
    );
  }

  Widget _buildReadingSettingsSection(AppLocalizations l10n) {
    return _buildSectionCard(
      title: l10n.readingSettings,
      icon: Icons.book_outlined,
      children: [
        _buildSwitchSetting(
          title: l10n.settingsVolumeKeyTurnTitle,
          subtitle: l10n.settingsVolumeKeyTurnSubtitle,
          value: _enableVolumeKeyTurn,
          onChanged: (value) => _mutate(() => _enableVolumeKeyTurn = value),
          icon: Icons.volume_up,
        ),
        _buildSwitchSetting(
          title: l10n.settingsAutoResumeReadingTitle,
          subtitle: l10n.settingsAutoResumeReadingSubtitle,
          value: _autoResumeReading,
          onChanged: (value) => _mutate(() => _autoResumeReading = value),
          icon: Icons.restore,
        ),
        _buildActionSetting(
          title: l10n.readerTopBarStyleTitle,
          subtitle: _readerTopBarStyleTitle(_readerTopBarStyle),
          onTap: _showReaderTopBarStylePicker,
          icon: Icons.vertical_align_top_rounded,
        ),
      ],
    );
  }

  Widget _buildDataServicesSection(
    AppLocalizations l10n,
    WebDavSyncController webDavSync,
  ) {
    return _buildSectionCard(
      title: l10n.settingsSectionDataServices,
      icon: Icons.hub_outlined,
      children: [
        _buildActionSetting(
          title: l10n.bookSourceManagementTitle,
          subtitle: l10n.settingsContentSourcesSubtitle,
          onTap: _openBookSourceManagement,
          icon: Icons.travel_explore_outlined,
        ),
        _buildActionSetting(
          title: l10n.replaceRulesTitle,
          subtitle: l10n.replaceRulesSettingsSubtitle,
          onTap: _openReplaceRules,
          icon: Icons.find_replace_outlined,
        ),
        _buildActionSetting(
          title: l10n.cloudSyncTitle,
          badge: l10n.webDavBetaBadge,
          subtitle: _webDavSyncSubtitle(webDavSync),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const WebDavSyncPage()),
          ),
          icon: Icons.cloud_outlined,
          trailing: _webDavSyncTrailing(webDavSync),
        ),
        _buildActionSetting(
          title: l10n.settingsCacheManagementTitle,
          subtitle: l10n.settingsCacheManagementSubtitle(
            _loadingCacheUsage
                ? l10n.settingsCacheCalculating
                : AppCacheManager.formatBytes(_cacheUsage?.totalBytes ?? 0),
          ),
          onTap: () => unawaited(_openCacheManagement()),
          icon: Icons.cleaning_services_outlined,
        ),
        _buildActionSetting(
          title: l10n.settingsAiAssistantTitle,
          subtitle: (_activeAiSettings?.isConfigured ?? false)
              ? l10n.settingsCurrentValue(_activeAiSettings!.model)
              : l10n.settingsAiApiKeyTapToConfigure,
          onTap: () => unawaited(_openAiSettings()),
          icon: Icons.auto_awesome_outlined,
        ),
      ],
    );
  }

  Widget _buildGeneralSettingsSection(
    AppLocalizations l10n,
    AppSettingsNotifier appSettings,
  ) {
    return _buildSectionCard(
      title: l10n.settingsSectionGeneral,
      icon: Icons.tune_rounded,
      children: [
        _buildLanguageSelector(appSettings),
        _buildSwitchSetting(
          title: l10n.settingsKeepScreenOnTitle,
          subtitle: l10n.settingsKeepScreenOnSubtitle,
          value: _keepScreenOn,
          onChanged: _setKeepScreenOn,
          icon: Icons.stay_current_portrait,
        ),
        if (!kIsWeb &&
            (Theme.of(context).platform == TargetPlatform.android ||
                Theme.of(context).platform == TargetPlatform.iOS))
          _buildSwitchSetting(
            key: const ValueKey('settings-power-saving-mode'),
            title: l10n.settingsPowerSavingModeTitle,
            subtitle: l10n.settingsPowerSavingModeSubtitle,
            value: appSettings.powerSavingMode,
            onChanged: appSettings.setPowerSavingMode,
            icon: Icons.battery_saver_outlined,
            persistPageSettings: false,
          ),
        _buildSwitchSetting(
          title: l10n.settingsAutoSaveTitle,
          subtitle: l10n.settingsAutoSaveSubtitle,
          value: _enableAutoSave,
          onChanged: (value) => _mutate(() => _enableAutoSave = value),
          icon: Icons.save_outlined,
        ),
      ],
    );
  }

  Widget _buildAdvancedSettingsSection(
    AppLocalizations l10n,
    AppSettingsNotifier appSettings,
  ) {
    return _buildSectionCard(
      title: l10n.settingsSectionAdvancedFeatures,
      icon: Icons.science_outlined,
      children: [
        _buildSwitchSetting(
          title: l10n.settingsAdditionalSourceProtocolsTitle,
          subtitle: l10n.settingsAdditionalSourceProtocolsSubtitle,
          value: appSettings.additionalSourceProtocolsEnabled,
          onChanged: appSettings.setAdditionalSourceProtocolsEnabled,
          icon: Icons.extension_outlined,
        ),
        _buildSwitchSetting(
          title: l10n.settingsPrivateBookSourceNetworkTitle,
          subtitle: l10n.settingsPrivateBookSourceNetworkSubtitle,
          value: appSettings.privateBookSourceNetworkEnabled,
          onChanged: appSettings.setPrivateBookSourceNetworkEnabled,
          icon: Icons.lan_outlined,
          persistPageSettings: false,
        ),
      ],
    );
  }

  Widget _buildSupportSettingsSection(AppLocalizations l10n) {
    return KeyedSubtree(
      key: _supportSectionKey,
      child: _buildSectionCard(
        title: l10n.settingsSectionAboutSupport,
        icon: Icons.volunteer_activism_outlined,
        children: [
          DeveloperSupportCard(
            onWechatTap: () =>
                _showDonationDialog(DeveloperDonationMethod.wechat),
            onAlipayTap: () =>
                _showDonationDialog(DeveloperDonationMethod.alipay),
          ),
        ],
      ),
    );
  }
}
