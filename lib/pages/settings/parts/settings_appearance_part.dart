part of '../settings_page.dart';

extension _SettingsAppearancePart on _SettingsPageState {
  Widget _buildThemeToggle(ThemeNotifier themeNotifier) {
    final mode = themeNotifier.themeMode;
    final l10n = context.l10n;
    return _buildActionSetting(
      title: l10n.settingsDarkModeTitle,
      subtitle: l10n.settingsCurrentValue(_themeModeLabel(mode)),
      onTap: () => _showThemeModeModal(themeNotifier),
      icon: _themeModeIcon(mode),
    );
  }

  Widget _buildUiStyleSelector(ThemeNotifier themeNotifier) {
    final l10n = context.l10n;
    return _buildSwitchSetting(
      title: l10n.settingsUiStyleTitle,
      subtitle: l10n.settingsGlassEffectSubtitle,
      value: themeNotifier.isGlassEffectsEnabled,
      onChanged: themeNotifier.setGlassEffectsEnabled,
      icon: Icons.blur_on_rounded,
    );
  }

  Widget _buildAccentColorSelector(ThemeNotifier themeNotifier) {
    final l10n = context.l10n;
    final accentColor = themeNotifier.accentColor;
    final colorName = accentColorDisplayName(
      context,
      AppThemes.getAccentColorName(accentColor),
    );
    final subtitle = '$colorName · ${_hexColor(accentColor)}';

    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showAccentColorModal(themeNotifier),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.secondary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.color_lens_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.settingsAccentColorTitle,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
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
                Container(
                  width: 24,
                  height: 24,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outline.withValues(alpha: 0.3),
                    ),
                  ),
                ),
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

  String _themeModeLabel(ThemeMode mode) {
    final l10n = context.l10n;
    switch (mode) {
      case ThemeMode.system:
        return l10n.systemMode;
      case ThemeMode.dark:
        return l10n.darkMode;
      case ThemeMode.light:
        return l10n.lightMode;
    }
  }

  IconData _themeModeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return Icons.brightness_auto;
      case ThemeMode.dark:
        return Icons.dark_mode;
      case ThemeMode.light:
        return Icons.light_mode;
    }
  }

  void _showThemeModeModal(ThemeNotifier themeNotifier) {
    final l10n = context.l10n;
    final options =
        <({ThemeMode mode, String label, String hint, IconData icon})>[
          (
            mode: ThemeMode.system,
            label: l10n.systemMode,
            hint: l10n.settingsThemeModeSystemHint,
            icon: Icons.brightness_auto,
          ),
          (
            mode: ThemeMode.light,
            label: l10n.lightMode,
            hint: l10n.settingsThemeModeLightHint,
            icon: Icons.light_mode,
          ),
          (
            mode: ThemeMode.dark,
            label: l10n.darkMode,
            hint: l10n.settingsThemeModeDarkHint,
            icon: Icons.dark_mode,
          ),
        ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(modalContext).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 14),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      modalContext,
                    ).colorScheme.onSurface.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 2, 24, 12),
                  child: Row(
                    children: [
                      Icon(
                        _themeModeIcon(themeNotifier.themeMode),
                        color: Theme.of(modalContext).colorScheme.primary,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        l10n.settingsDarkModeTitle,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(modalContext).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                ...options.map((item) {
                  final selected = themeNotifier.themeMode == item.mode;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          themeNotifier.setThemeMode(item.mode);
                          Navigator.of(modalContext).pop();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected
                                  ? Theme.of(modalContext).colorScheme.primary
                                  : Theme.of(modalContext).colorScheme.outline
                                        .withValues(alpha: 0.35),
                              width: selected ? 1.6 : 1,
                            ),
                            color: selected
                                ? Theme.of(
                                    modalContext,
                                  ).colorScheme.primary.withValues(alpha: 0.08)
                                : Colors.transparent,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                item.icon,
                                color: selected
                                    ? Theme.of(modalContext).colorScheme.primary
                                    : Theme.of(modalContext)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.75),
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.label,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: selected
                                            ? Theme.of(
                                                modalContext,
                                              ).colorScheme.primary
                                            : Theme.of(
                                                modalContext,
                                              ).colorScheme.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      item.hint,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(modalContext)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.62),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (selected)
                                Icon(
                                  Icons.check_circle,
                                  color: Theme.of(
                                    modalContext,
                                  ).colorScheme.primary,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAppFontSelector(AppSettingsNotifier appSettings) {
    final l10n = context.l10n;
    final selected = appSettings.appFont;
    return _buildActionSetting(
      title: l10n.appFont,
      subtitle:
          '${FontCatalog.labelFor(l10n, selected)} · ${l10n.appFontDescription}',
      icon: Icons.font_download_outlined,
      onTap: () => _showFontModal(
        appSettings: appSettings,
        domain: FontDomain.app,
        title: l10n.appFont,
        description: l10n.appFontDescription,
      ),
    );
  }

  Widget _buildReaderFontSelector(AppSettingsNotifier appSettings) {
    final l10n = context.l10n;
    final selected = appSettings.readerFont;
    return _buildActionSetting(
      title: l10n.readerFont,
      subtitle:
          '${FontCatalog.labelFor(l10n, selected)} · ${l10n.readerFontDescription}',
      icon: Icons.chrome_reader_mode_outlined,
      onTap: () => _showFontModal(
        appSettings: appSettings,
        domain: FontDomain.reader,
        title: l10n.readerFont,
        description: l10n.readerFontDescription,
      ),
    );
  }

  Widget _buildCustomFontsManager(AppSettingsNotifier appSettings) {
    final l10n = context.l10n;
    return _buildActionSetting(
      title: l10n.customFonts,
      subtitle: appSettings.customFonts.isEmpty
          ? l10n.customFontsEmpty
          : l10n.customFontsCount(appSettings.customFonts.length),
      icon: Icons.folder_copy_outlined,
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const CustomFontsPage())),
    );
  }

  Future<void> _showFontModal({
    required AppSettingsNotifier appSettings,
    required FontDomain domain,
    required String title,
    required String description,
  }) async {
    final l10n = context.l10n;
    await appSettings.prepareCustomFontPreviews();
    if (!mounted) return;
    final importStatus = await showModalBottomSheet<CustomFontImportStatus>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FontSelectionSheet(
        settings: appSettings,
        domain: domain,
        title: title,
        description: description,
      ),
    );
    if (importStatus == null || !mounted) return;
    final message = importStatus == CustomFontImportStatus.duplicate
        ? l10n.customFontAlreadyImported
        : domain == FontDomain.app
        ? l10n.customFontAppliedToApp
        : l10n.customFontAppliedToReader;
    showSideToast(context, message, kind: SideToastKind.success);
  }

  Widget _buildLanguageSelector(AppSettingsNotifier appSettings) {
    final l10n = context.l10n;
    final currentCode = appSettings.localeCode;
    final currentLabel = _languageLabel(l10n, currentCode);

    return _buildActionSetting(
      title: l10n.language,
      subtitle: currentLabel,
      icon: Icons.translate,
      onTap: () => _showLanguageModal(appSettings),
    );
  }

  String _languageLabel(AppLocalizations l10n, String code) {
    switch (code) {
      case 'zh':
      case 'zh-CN':
      case 'zh_CN':
        return l10n.languageChinese;
      case 'zh-TW':
      case 'zh_TW':
      case 'zh-Hant':
      case 'zh_Hant':
        return l10n.languageTraditionalChinese;
      case 'ja':
      case 'ja-JP':
      case 'ja_JP':
        return l10n.languageJapanese;
      case 'en':
      case 'en-US':
      case 'en_US':
        return l10n.languageEnglish;
      default:
        return l10n.languageSystem;
    }
  }

  void _showLanguageModal(AppSettingsNotifier appSettings) {
    final l10n = context.l10n;
    final options = [
      _LanguageOption(code: 'system', label: l10n.languageSystem),
      _LanguageOption(code: 'zh', label: l10n.languageChinese),
      _LanguageOption(code: 'zh-TW', label: l10n.languageTraditionalChinese),
      _LanguageOption(code: 'en', label: l10n.languageEnglish),
      _LanguageOption(code: 'ja', label: l10n.languageJapanese),
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 16),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Icon(
                      Icons.translate,
                      color: Theme.of(context).colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      l10n.language,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ...options.map((option) {
                final isSelected = appSettings.localeCode == option.code;
                return ListTile(
                  title: Text(option.label),
                  trailing: isSelected
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    appSettings.setLocaleCode(option.code);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAccentColorModal(ThemeNotifier themeNotifier) async {
    final selectedColor = await showModalBottomSheet<Color>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          AccentColorPickerSheet(initialColor: themeNotifier.accentColor),
    );
    if (selectedColor == null || !mounted) return;
    await themeNotifier.setAccentColor(selectedColor);
  }
}
