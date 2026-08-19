// 文件说明：设置页面，负责应用主题、语言、同步、备份和外观设置。
// 技术要点：Flutter UI、Icons Plus、Package Info、Provider、SharedPreferences、URL Launcher。

import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:xxread/core/reader/reader_keep_screen_on.dart';
import 'package:xxread/core/reader/reader_settings.dart';
import 'package:xxread/core/reader/reader_system_ui.dart';
import 'package:xxread/l10n/app_localizations.dart';
import 'package:xxread/pages/book_sources/book_source_management_page.dart';
import 'package:xxread/pages/home/home_mobile_chrome.dart';
import 'package:xxread/pages/home/home_shell_page.dart';
import 'package:xxread/pages/settings/about/changelog_page.dart';
import 'package:xxread/pages/settings/about/open_source_licenses_page.dart';
import 'package:xxread/pages/settings/ai_settings_page.dart';
import 'package:xxread/pages/settings/cache_management_page.dart';
import 'package:xxread/pages/settings/font_selection_sheet.dart';
import 'package:xxread/pages/settings/floating_navigation_settings_page.dart';
import 'package:xxread/pages/settings/library_layout_settings_page.dart';
import 'package:xxread/pages/settings/replace_rules_page.dart';
import 'package:xxread/pages/settings/sync/webdav_sync_page.dart';
import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/core/core_services.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/app_themes.dart';
import 'package:xxread/utils/app_themes_translator.dart';
import 'package:xxread/utils/font_catalog_helper.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/utils/system_ui_helper.dart';
import 'package:xxread/utils/ui_style.dart';
import 'package:xxread/widgets/app_brand_icon.dart';
import 'package:xxread/widgets/accent_color_picker_sheet.dart';
import 'package:xxread/widgets/contributors_view.dart';
import 'package:xxread/widgets/developer_support_card.dart';
import 'package:xxread/widgets/reader_settings_controls.dart';
import 'package:xxread/widgets/restartable_app.dart';
import 'package:xxread/widgets/settings_account_card.dart';
import 'package:xxread/widgets/side_toast.dart';
import 'package:xxread/widgets/update_check_gate.dart';

import 'custom_fonts_page.dart';

part 'parts/settings_cover_actions_part.dart';
part 'parts/settings_community_marks_part.dart';
part 'parts/settings_appearance_part.dart';
part 'parts/settings_about_part.dart';
part 'parts/settings_layout_part.dart';

class SettingsPageController extends ChangeNotifier {
  int _supportRevealRequest = 0;

  int get supportRevealRequest => _supportRevealRequest;

  void revealSupportSection() {
    _supportRevealRequest += 1;
    notifyListeners();
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.controller,
    this.cacheManager,
    this.preferencesStore,
    this.aiService,
  });

  final SettingsPageController? controller;
  final AppCacheManager? cacheManager;
  final SettingsPagePreferencesStore? preferencesStore;
  final ConfigurableAIService? aiService;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _supportSectionKey = GlobalKey();
  late final AppCacheManager _cacheManager;
  late final SettingsPagePreferencesStore _preferencesStore;
  late final ConfigurableAIService _aiService;

  bool _enableAutoSave = true;
  bool _keepScreenOn = false;
  int _autoSaveInterval = 30;

  // 阅读设置
  bool _enableVolumeKeyTurn = true;
  bool _autoResumeReading = false;
  ReaderTopBarStyle _readerTopBarStyle = ReaderTopBarStyle.reader;

  bool _enableAutoExtractCover = true;

  // 其他设置
  bool _enableFullscreen = false;

  // 开发者设置
  bool _enableDeveloperMode = false;
  bool _enableDebugLogging = false;
  bool _enablePerformanceMonitor = false;
  bool _enableMemoryStats = false;
  bool _showFPS = false;
  String _appVersion = '0.9.1';
  bool _isCheckingForUpdates = false;
  AIProviderSettings? _activeAiSettings;
  int _lastSupportRevealRequest = 0;
  AppCacheUsage? _cacheUsage;
  bool _loadingCacheUsage = true;

  void _mutate(VoidCallback update) => setState(update);

  @override
  void initState() {
    super.initState();
    _cacheManager = widget.cacheManager ?? AppCacheManager();
    _preferencesStore =
        widget.preferencesStore ??
        SharedPreferencesSettingsPagePreferencesStore();
    _aiService = widget.aiService ?? ReaderHttpAIService();
    unawaited(_loadAppVersion());
    unawaited(_refreshCacheUsage());
    _loadSettings();
    _attachSettingsController(widget.controller);
    // 状态栏设置现在由_SettingsPageWrapper处理
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller?.removeListener(_handleSupportRevealRequest);
    _attachSettingsController(widget.controller);
  }

  void _attachSettingsController(SettingsPageController? controller) {
    _lastSupportRevealRequest = controller?.supportRevealRequest ?? 0;
    controller?.addListener(_handleSupportRevealRequest);
    if (_lastSupportRevealRequest > 0) {
      _scheduleSupportSectionReveal();
    }
  }

  void _handleSupportRevealRequest() {
    final request = widget.controller?.supportRevealRequest ?? 0;
    if (request == _lastSupportRevealRequest) return;
    _lastSupportRevealRequest = request;
    _scheduleSupportSectionReveal();
  }

  void _scheduleSupportSectionReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sectionContext = _supportSectionKey.currentContext;
      if (sectionContext == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _revealSupportSection();
        });
        return;
      }
      _revealSupportSection();
    });
  }

  void _revealSupportSection() {
    final sectionContext = _supportSectionKey.currentContext;
    if (sectionContext == null) return;
    unawaited(
      Scrollable.ensureVisible(
        sectionContext,
        alignment: 0.12,
        duration: const Duration(milliseconds: 620),
        curve: Curves.easeInOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_handleSupportRevealRequest);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 状态栏设置现在由_SettingsPageWrapper处理，这里保持简洁
  }

  Future<void> _loadSettings() async {
    final preferences = await _preferencesStore.load();
    final activeAiSettings = await _aiService.loadSettings();
    if (!mounted) {
      return;
    }
    setState(() {
      _enableAutoSave = preferences.enableAutoSave;
      _keepScreenOn = preferences.keepScreenOn;
      _autoSaveInterval = preferences.autoSaveInterval;
      _enableAutoExtractCover = preferences.enableAutoExtractCover;
      _enableVolumeKeyTurn = preferences.enableVolumeKeyTurn;
      _autoResumeReading = preferences.autoResumeReading;
      _readerTopBarStyle = preferences.readerTopBarStyle;
      _enableFullscreen = preferences.enableFullscreen;
      _enableDeveloperMode = preferences.enableDeveloperMode;
      _enableDebugLogging = preferences.enableDebugLogging;
      _enablePerformanceMonitor = preferences.enablePerformanceMonitor;
      _enableMemoryStats = preferences.enableMemoryStats;
      _showFPS = preferences.showFPS;
      _activeAiSettings = activeAiSettings;
    });
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      if (!mounted) {
        return;
      }
      setState(() {
        final buildNumber = info.buildNumber.trim();
        _appVersion = version.isNotEmpty
            ? (buildNumber.isNotEmpty ? '$version ($buildNumber)' : version)
            : '0.9.1';
      });
    } catch (_) {
      // Keep default version fallback.
    }
  }

  Future<void> _refreshCacheUsage() async {
    try {
      final usage = await _cacheManager.usage();
      if (!mounted) return;
      setState(() {
        _cacheUsage = usage;
        _loadingCacheUsage = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingCacheUsage = false);
    }
  }

  Future<void> _openCacheManagement() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CacheManagementPage(cacheManager: _cacheManager),
      ),
    );
    if (mounted) await _refreshCacheUsage();
  }

  Future<void> _openAiSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AiSettingsPage()));
    if (!mounted) return;
    final active = await _aiService.loadSettings();
    if (!mounted) return;
    setState(() => _activeAiSettings = active);
  }

  Future<void> _saveSettings() async {
    await _preferencesStore.save(
      SettingsPagePreferences(
        enableAutoSave: _enableAutoSave,
        keepScreenOn: _keepScreenOn,
        autoSaveInterval: _autoSaveInterval,
        enableAutoExtractCover: _enableAutoExtractCover,
        enableVolumeKeyTurn: _enableVolumeKeyTurn,
        autoResumeReading: _autoResumeReading,
        readerTopBarStyle: _readerTopBarStyle,
        enableFullscreen: _enableFullscreen,
        enableDeveloperMode: _enableDeveloperMode,
        enableDebugLogging: _enableDebugLogging,
        enablePerformanceMonitor: _enablePerformanceMonitor,
        enableMemoryStats: _enableMemoryStats,
        showFPS: _showFPS,
      ),
    );
  }

  void _setKeepScreenOn(bool value) {
    setState(() => _keepScreenOn = value);
    unawaited(ReaderKeepScreenOnController.setPreference(value));
  }

  String _readerTopBarStyleTitle(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.system => context.l10n.readerTopBarStyleSystem,
    ReaderTopBarStyle.reader => context.l10n.readerTopBarStyleReader,
    ReaderTopBarStyle.floating => context.l10n.readerTopBarStyleFloating,
    ReaderTopBarStyle.hidden => context.l10n.readerTopBarStyleHidden,
  };

  String _readerTopBarStyleHint(ReaderTopBarStyle style) => switch (style) {
    ReaderTopBarStyle.system => context.l10n.readerTopBarStyleSystemHint,
    ReaderTopBarStyle.reader => context.l10n.readerTopBarStyleReaderHint,
    ReaderTopBarStyle.floating => context.l10n.readerTopBarStyleFloatingHint,
    ReaderTopBarStyle.hidden => context.l10n.readerTopBarStyleHiddenHint,
  };

  Future<void> _showReaderTopBarStylePicker() async {
    final prefs = await SharedPreferences.getInstance();
    final palette = ReaderThemes.byId(
      prefs.getString(ReaderSettingsStore.themeKey) ??
          ReaderSettings.defaultThemeId,
    );
    if (!mounted) return;
    final selected = await showModalBottomSheet<ReaderTopBarStyle>(
      context: context,
      backgroundColor: palette.surface,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => ReaderTopBarStyleSheet(
        palette: palette,
        title: context.l10n.readerTopBarStyleTitle,
        selectedStyle: _readerTopBarStyle,
        titleFor: _readerTopBarStyleTitle,
        hintFor: _readerTopBarStyleHint,
        onSelected: (style) => Navigator.of(sheetContext).pop(style),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => _readerTopBarStyle = selected);
    await ReaderSystemUiController.savePreference(selected);
  }

  @override
  Widget build(BuildContext context) {
    final themeNotifier = Provider.of<ThemeNotifier>(context);
    final appSettings = Provider.of<AppSettingsNotifier>(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final isMaterial3Style = themeNotifier.uiStyle == AppUiStyle.material3;

    // 检查是否在侧边导航栏模式下
    final navContext = NavigationContext.of(context);
    final useRailNavigation = navContext?.useRailNavigation ?? false;

    // 在侧边导航栏模式下，不显示 Scaffold 和 AppBar
    if (useRailNavigation) {
      return _buildContent(context, themeNotifier, appSettings, isDarkMode);
    }

    // 手机模式：显示完整的 Scaffold + AppBar
    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: isMaterial3Style
            ? Theme.of(context).colorScheme.surface
            : Colors.transparent,
        elevation: 0,
        toolbarHeight: 0, // 关闭系统AppBar，使用自绘毛玻璃顶栏
        systemOverlayStyle: SystemUiHelper.overlayStyleForBrightness(
          Theme.of(context).brightness,
        ),
      ),
      body: _buildContent(context, themeNotifier, appSettings, isDarkMode),
    );
  }

  // 提取页面内容部分，在两种模式下共用
  Widget _buildContent(
    BuildContext context,
    ThemeNotifier themeNotifier,
    AppSettingsNotifier appSettings,
    bool isDarkMode,
  ) {
    final l10n = context.l10n;
    final webDavSync = Provider.of<WebDavSyncController>(context);
    final useRailNavigation =
        NavigationContext.of(context)?.useRailNavigation ?? false;
    final mobileChrome = HomeMobileChromeScope.of(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    return Container(
      decoration: BoxDecoration(
        gradient: PageStyleHelper.backgroundGradient(context),
      ),
      child: ListView(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          16,
          useRailNavigation ? viewPadding.top + 8 : mobileChrome.pageTopPadding,
          16,
          useRailNavigation
              ? viewPadding.bottom + 24
              : mobileChrome.pageBottomPadding,
        ),
        children: [
          if (useRailNavigation) ...[
            _buildSettingsTopRow(l10n, useRailNavigation),
            const SizedBox(height: 24),
          ],
          const SettingsAccountCard(),
          const SizedBox(height: 20),
          _buildSectionCard(
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
          ),
          const SizedBox(height: 20),
          _buildSectionCard(
            title: l10n.readingSettings,
            icon: Icons.book_outlined,
            children: [
              _buildSwitchSetting(
                title: l10n.settingsVolumeKeyTurnTitle,
                subtitle: l10n.settingsVolumeKeyTurnSubtitle,
                value: _enableVolumeKeyTurn,
                onChanged: (value) =>
                    setState(() => _enableVolumeKeyTurn = value),
                icon: Icons.volume_up,
              ),
              _buildSwitchSetting(
                title: l10n.settingsAutoResumeReadingTitle,
                subtitle: l10n.settingsAutoResumeReadingSubtitle,
                value: _autoResumeReading,
                onChanged: (value) =>
                    setState(() => _autoResumeReading = value),
                icon: Icons.restore,
              ),
              _buildActionSetting(
                title: l10n.readerTopBarStyleTitle,
                subtitle: _readerTopBarStyleTitle(_readerTopBarStyle),
                onTap: _showReaderTopBarStylePicker,
                icon: Icons.vertical_align_top_rounded,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildSectionCard(
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
                title: l10n.settingsWebDavSyncTitle,
                badge: l10n.webDavBetaBadge,
                subtitle: _webDavSyncSubtitle(webDavSync),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const WebDavSyncPage(),
                  ),
                ),
                icon: Icons.cloud_outlined,
                trailing: _webDavSyncTrailing(webDavSync),
              ),
              _buildActionSetting(
                title: l10n.settingsCacheManagementTitle,
                subtitle: l10n.settingsCacheManagementSubtitle(
                  _loadingCacheUsage
                      ? l10n.settingsCacheCalculating
                      : AppCacheManager.formatBytes(
                          _cacheUsage?.totalBytes ?? 0,
                        ),
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
          ),
          const SizedBox(height: 20),
          _buildSectionCard(
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
                onChanged: (value) => setState(() => _enableAutoSave = value),
                icon: Icons.save_outlined,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _buildSectionCard(
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
          ),
          const SizedBox(height: 20),
          KeyedSubtree(
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
          ),
          const SizedBox(height: 20),
          _buildAboutCard(),
          const SizedBox(height: 20),
          const ContributorsView(
            repositoryOwner: 'miloquinn',
            repositoryName: 'open-reading',
          ),
          const SizedBox(height: 100),
        ],
      ),
    );
  }

  String _webDavSyncSubtitle(WebDavSyncController sync) {
    final l10n = context.l10n;
    if (!sync.isConfigured) return l10n.webDavConfigureSubtitle;
    if (sync.status == WebDavSyncStatus.syncing ||
        sync.status == WebDavSyncStatus.testing) {
      return l10n.webDavSyncing;
    }
    if (sync.status == WebDavSyncStatus.failed) {
      return l10n.webDavSyncFailed;
    }
    if (sync.status == WebDavSyncStatus.partialFailure) {
      return l10n.webDavPartialFailure;
    }
    if (sync.pendingChanges > 0) {
      return l10n.webDavPendingChanges(sync.pendingChanges);
    }
    final lastSuccess = sync.lastSuccessfulSync;
    if (lastSuccess == null) return l10n.webDavNeverSynced;
    final local = lastSuccess.toLocal();
    final material = MaterialLocalizations.of(context);
    final date = material.formatShortDate(local);
    final time = material.formatTimeOfDay(TimeOfDay.fromDateTime(local));
    return l10n.webDavLastSync('$date $time');
  }

  Widget _webDavSyncTrailing(WebDavSyncController sync) {
    if (sync.status == WebDavSyncStatus.syncing ||
        sync.status == WebDavSyncStatus.testing) {
      return const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (sync.status == WebDavSyncStatus.failed ||
        sync.status == WebDavSyncStatus.partialFailure) {
      return Icon(
        Icons.error_outline_rounded,
        color: Theme.of(context).colorScheme.error,
      );
    }
    return const Icon(Icons.chevron_right_rounded);
  }

  void _openBookSourceManagement() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const BookSourceManagementPage()),
    );
  }

  void _openReplaceRules() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ReplaceRulesPage()));
  }

  Widget _buildSwitchSetting({
    Key? key,
    required String title,
    required String subtitle,
    required bool value,
    required Function(bool) onChanged,
    required IconData icon,
    bool enabled = true,
    bool persistPageSettings = true,
  }) {
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled
              ? () {
                  onChanged(!value);
                  if (persistPageSettings) {
                    unawaited(_saveSettings());
                  }
                }
              : null,
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
                    icon,
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
                        title,
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
                Switch(
                  value: value,
                  onChanged: enabled
                      ? (newValue) {
                          onChanged(newValue);
                          if (persistPageSettings) {
                            unawaited(_saveSettings());
                          }
                        }
                      : null,
                  activeTrackColor: Theme.of(context).colorScheme.primary,
                  thumbColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.outline,
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

class _LanguageOption {
  final String code;
  final String label;

  const _LanguageOption({required this.code, required this.label});
}

String _hexColor(Color color) =>
    '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
