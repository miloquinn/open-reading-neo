# Open Reading — Flutter App Architecture Analysis

Repo: /Users/xiaoyuan/code/open-reading (package name `xxread`, app title "开元阅读"). Findings verified by direct source inspection. DESIGN.md is the source-of-truth design doc; it documents the WebDAV sync & book-source-grouping workstreams, while most code under analysis has evolved beyond it.

## 1. Page/navigation architecture & home shell

### App bootstrap (lib/main.dart)
- main() ensures binding init, warms BookSourceRegistry.prepareStorage(), pre-warms ReaderThemes.loadSavedPalette(), applies saved refresh-rate via DisplayRefreshRateController, and on desktop inits sqflite_common_ffi.
- DI root is a provider.MultiProvider: ThemeNotifier, AppSettingsNotifier, TtsService + ChangeNotifierProxyProvider<TtsService, ReaderAloudService>, DownloadTaskController, BookSourceMaintenanceCoordinator, WebDavSyncController, MemberAccountController()..initialize().
- RestartableApp (main.dart) gives a stateful KeyedSubtree for full-subtree restart.
- XxReadApp (_XxReadAppState) is a MaterialApp wrapper owning the navigator, WidgetsBindingObserver, incoming-book bridging, notification taps, source-interaction queue, WebDAV auto-sync on resume, and "resume last reading" (ReadingResumeService).
- MaterialApp wrapped in Consumer<ThemeNotifier> and Selector<AppSettingsNotifier,(appFontFamily,locale)> so only theme/font/locale rebuild.

### Startup gate
XxReadApp._buildHome: bootstrap-error page -> loading page -> UserAgreementPage (lib/pages/legal/user_agreement_page.dart) -> UpdateCheckGate(child: HomeShellPage(...)).

### Home shell (lib/pages/home/home_shell_page.dart -> HomeShellPage)
- "Navigation shell only". Holds PageController, _selectedIndex, one controller per tab (HomeDashboardController, LibraryPageController, AiPageController, BookSourcesPageController, SettingsPageController), a tab-transition token, and _mobilePages.
- Single source of truth nav table _navigationItems keyed by HomeNavigationDestination, consumed by BOTH mobile bottom nav and wide NavigationRail; built from AppSettingsNotifier.visibleHomeNavigationOrder (user reorderable).
- Responsive switch via LayoutHelper.getNavigationType(context): NavigationType.rail (wide) vs NavigationType.bottom (phone).
- Wide layout (home_shell_layout_part.dart, a "part of"): NavigationRail in glass/M3 panel + content. Rail extended on tablet/desktop, brand header, per-page top actions.
- Mobile: PageView per tab inside RepaintBoundary (allowImplicitScrolling for prefetch), floating glass "pill" bottom nav, top glass bar overlay, library multi-select delete bar swaps in place of the nav.
- Wrappers (lib/pages/home/widgets/home_page_wrappers.dart): HomeGenericPageWrapper (PageStyleHelper.backgroundGradient), HomeSettingsPageWrapper (system UI + HomeMobileTopBar), HomeTabFocusScope + HomeTabFocusGate (InheritedWidget + ExcludeFocus to stop kept-alive tab TextFields from stealing focus and dragging the PageView), HomeKeepAlivePageWrapper (AutomaticKeepAliveClientMixin).
- NavigationContext (InheritedWidget) broadcasts useRailNavigation.
- HomeMobileTopBar + HomeMobileChromeMetrics / dimension helpers (home_mobile_chrome.dart) with constants (floating nav height 56) and HomeMobileSystemInsetsStabilizer (locks bottom inset during book-open transition).
- HomeDashboardPage (home_dashboard_page.dart) is a marker delegating to HomeMobileDashboardPage (993 lines, "continue reading/reading cadence/recently read") via _HomePalette.fromTheme; rail path reuses the same mobile dashboard via _resolveRailPage.
- Floating pill uses HomeBounceNavigationItem; hide-on-reader/keyboard driven by BookOpenTransition.navigationHiddenListenable + keyboardVisible.

### Navigation strengths
1. Single nav source of truth shared by phone and desktop; user tab reorder reflected everywhere.
2. Exhaustive edge handling: keyboard-hide nav, mid-transition bounce, focus gate for kept-alive tabs, selection-mode nav swap, BookOpenTransition/system-bar coordination.
3. Clear comment-led architecture notes atop each shell file.
4. Page table rebuilt only on l10n identity or nav-order change (listEquals guard).

### Navigation weaknesses
1. home_shell_page.dart + its 901-line part file form a very large state class; extension split helps but couples shell building, immersive mode, navigation, and per-page top-bar actions in one object.
2. Many magic layout constants + a "page assembly center" branching on page runtime types (currentPage is HomeDashboardPage etc.) makes adding a tab require touching shell code.
3. PageView + KeepAlive keeps all 5 tabs resident.

## 2. Theming system

### Accent color -> Material 3 (lib/utils/app_themes.dart)
- AppTheme bundles seedColor during light+dark ColorScheme.fromSeed.
- AppThemes: defaultAccentColor 0xFF1976D2, curated accentColors (18 swatches), accentColorForLegacyTheme migration collapsing old "double theme + accent" to one accent, getAccentColorName.
- ThemeNotifier (main.dart) is the runtime single source: setAccentColor stores appAccentColorV2 (int), migrates legacy keys (appTheme, customAccentColor, globalAccentColor, last_preset_app_theme), rebuilds AppThemes.fromAccentColor. Persisted keys: isDarkMode, ui_style_mode, appAccentColorV2.
- XxReadApp._buildThemeData builds light/dark ThemeData from those color schemes, sets fontFamily + FontCatalog.appFallbacks, differentiates card/dialog/surface colors between glass and M3, zero-elevation app bar, and injects UiStyleThemeExtension(style: uiStyle).

### glass vs material3 (lib/utils/ui_style.dart)
- enum AppUiStyle { glass, material3 } + appUiStyleFromStorage; UiStyleThemeExtension (isMaterial3Style, lerp chooses at t>=0.5).
- ThemeNotifier.isGlassEffectsEnabled / shouldDisableGlassEffects fold into GlassEffectConfig via _syncGlassEffectState: choosing material3 disables all blur and forces opacity 1.0.
- Most chrome/BackdropFilter branches on isMaterial3Style OR GlassEffectConfig.shouldDisableBlur.

### Glass effect config (lib/utils/glass_config.dart)
- GlassEffectConfig centralizes blur sigma bases (chrome 15, card 20, lightCard 8, dialog 30, modal 25), global _blurScale (0.85; 0.65 perf; 0 when disabled), opacity bases (chrome 0.3 dark / 0.6 light chrome).
- Getters: appBarBlur, navigationBarBlur, readingTopBarBlur/_BottomBarBlur, cardBlur, dialogBlur, modalBlur, opacities; chromeSurfaceColor(context), chromeOpacityFor, chromeShadowColor, surfaceColor.
- Presets: GlassPreset clearMode / standardMode / dreamyMode (blur multiplier + opacity delta).
- GlassEffectHelper: getAppBarConfig/getNavigationConfig/getReadingControlConfig + progressive blur builders createProgressiveAppBar/Card/Dialog/BottomNav, delegating to ProgressiveBlurPresets (lib/utils/progressive_blur.dart); they avoid double darkening (single base + light overlay blur).
- Config is the single tuning knob for the whole app's glass look.

### Glass chrome widgets
- GlassTopBar (lib/widgets/glass_top_bar.dart): "single glass chrome surface shared by home shell and pushed pages".
- FloatingSubpageScaffold (lib/widgets/floating_subpage_scaffold.dart): shared glass shell for pushed secondary pages (title/body/actions/tools, maxHeaderWidth, header height, optional FAB/bottom nav), equal hit targets.

### Reader themes (lib/utils/reader_themes.dart)
- ReaderThemePalette: reader-only color system decoupled from AppThemes. Fields: brightness, background, text, secondaryText, surface, controlBar, controlFill, accent, onAccent, border, shadow, + optional backgroundImagePath / backgroundImageOpacity (0.0-0.75). Custom themes support background images.
- toThemeData derives a full M3 ColorScheme from accent seed.
- Built-in palettes: system / day / mist / green / rose / parchment / navy / night / pureBlack (ReaderThemes.all).
- ReaderThemes manages custom themes (ReaderCustomTheme from core/reader/reader_custom_theme.dart), user _themeOrder, warm palette cache. fromCustomTheme uses luminance-based brightness + alpha-blended derived colors. cachedSavedPalette (loadSavedPalette pre-warmed in main) gives the book-open transition the right canvas on cold open.
- Background images picked/stored via platform-switched lib/services/core/reader_theme_background_service{_io,_web}.dart, rendered by lib/widgets/reader_theme_background*.dart.

### Theming strengths
1. Clean single-accent-seed model via ColorScheme.fromSeed; deliberate legacy migration that removes old keys.
2. Reader themes intentionally separate from app themes AND support custom background images with opacity.
3. Glass config genuinely centralized; M3-vs-glass degrades cleanly.
4. UiStyleThemeExtension carries UI style through the theme tree, no global singleton for consumers.

### Theming weaknesses
1. Glass mix of BackdropFilter sprinkled in pages + ProgressiveBlurPresets; consistency depends on discipline.
2. UiStyleThemeExtension.lerp uses a hard t>=0.5 branch (not a true lerp).
3. Custom reader theme accent == text color; limits accent distinctness.
4. DESIGN.md visual-language section does not document the glass system, ui_style enum, or reader-theme palette model.

## 3. AI services

### Config model (lib/reader_core/ai/ai_service.dart, 1463 lines)
- AIProviderType { minimax, glm, openai, claude, gemini, custom }; AIProtocolType { openai, anthropic, gemini } with per-provider defaultProtocol.
- normalizeAIBaseUrl, AIProviderSettings (provider, protocol, apiKey, baseUrl, model, temperature; normalized()/isConfigured), AIChatMessage.
- AIModelPreset / AIModelPresets: curated catalog incl. GPT-4o/4.1/GPT-4o-mini, GLM-4-Flash/Plus, MiniMax-M2.5, Claude 3.5 Sonnet/Haiku, Gemini 2.0 Flash/2.5 Pro, plus OpenAI-compatible entries (DeepSeek, Qwen, Moonshot/Kimi, Groq Llama, SiliconFlow Qwen2.5).
- AIService abstract: askSelection, analyzePage, chat. ConfigurableAIService adds loadSettings/saveSettings. AIServiceException rich error type (code,status,text,endpoint,provider,snippet) translated by lib/reader_core/ai/ai_error_translator.dart.
- ReaderHttpAIService implements ConfigurableAIService (Dio-backed). MockAIService for tests.
- Config UI: lib/pages/settings/ai_settings_page.dart (1173 lines) with AiSettingsPage (_buildCard, _buildPreprocessSwitch, _buildAiModelRow(_AiQuickModel), _buildAddAiModelRow). Preprocess toggle uses aiPreprocessBooksPrefsKey.

### Reading service (lib/services/ai/global_ai_reading_service.dart + _translator)
- GlobalAIReadingService (singleton .instance) = local knowledge base persisted under ai_knowledge/books/<sanitizedId>/ with memory.json + index.json.
  - saveBookSummary writes preprocess Markdown into memory.json.summary.
  - findRelevantSnippets does local keyword scoring (CN/EN tokenization with stop-word lists).
  - buildInjectedContext and buildLocalFallbackAnswer emit placeholder tokens ([[readerAiMemorySummaryHeading]], [[snippetLocation:{chapter}:{start}:{end}]]) localized later by localizeAiResponseBuffer (global_ai_reading_translator.dart).
  - appendConversationMemory keeps last 20 Q&As (memory.json.qaMemory).
  - scheduleImportedBookAnalysis auto-enqueues preprocess after import.
- Chat UI: lib/pages/ai/ai_page.dart (AiPageController, _AiChatEntry, _buildBookContext, _buildFloatingInputBar, _AiChatBubble); history lib/pages/ai/ai_history_page.dart + services/ai/ai_chat_history_store.dart.

### Preprocess coordinator
- AiRequestCoordinator (lib/services/ai/ai_request_coordinator.dart): singleton coordinating interactive vs background AI requests. Interactive (runInteractive) always proceeds; background preprocess calls waitUntilInteractiveIdle() (Completers) so conversations stay responsive.
- BookPreprocessService (lib/services/ai/book_preprocess_service.dart): extract chapters via BookTextExtractionService, chunk ~2800 chars (max 24, evenly sampled), summarize each chunk, hierarchical merge fan-in 3 until <=3 merged, then one final Markdown assembly. Backoff retry (5/15/45s) only for retryable status/code classes (_isRetryable); cancellable via BookPreprocessCancelToken; persists via GlobalAIReadingService.saveBookSummary.
- AiPreprocessTaskController (lib/services/ai/ai_preprocess_task_controller.dart): ChangeNotifier singleton FIFO queue (queued/running/completed/failed/cancelled), dedupes per book, serial pump, holds raw error objects for UI-only translation, drives the preprocess row.

### AI strengths
1. Clean provider/protocol abstraction with a large preset catalog; custom OpenAI-compatible endpoints.
2. Excellent "job/CPU conscious" design: interactive-first coordinator + faceted preprocess merge (fan-in, chunk limits, sampling) avoiding model context overflow.
3. Placeholder-token i18n for AI output decouples templates from l10n; rich AIServiceException.
4. On-disk per-book knowledge base + local retrieval fallback.

### AI weaknesses
1. ReaderHttpAIService + ai_service.dart is one 1463-line file mixing config, presets, protocol adapters, and request logic.
2. Hardcoded Chinese in service/prompt strings (flagged in l10n README "待迁移").
3. Dead compat: ensureKnowledgeForParsedBook stub and legacy ParsedBook reference ("parsers removed").
4. Local retrieval is naive regex tokenization, not embeddings/BM25.

## 4. Account system (lib/services/account/)

- account.dart = barrel exporting all account services.
- MemberAccountController (member_account_controller.dart, 682 lines): ChangeNotifier exposing authConfig, membershipConfig, user/membership/summary/referral/mfaStatus, loading/error; wires collaborators (MemberAccountApiClient, AccountAvatarCache, MemberAccountSummaryCache, SecurePendingDeviceAuthorizationStore, AccountAuthCallbackBridge, ApplePremiumPurchaseService).
  - Auth methods: loginPassword, loginPasskey, loginWithApple, requestCode/verifyEmailCode, password register/reset, MFA (setupMfa/confirmMfa/disableMfa/verifyMfa), profile update, avatar upload/delete, membership (loadMembership/redeemMembership/bindReferral), logout.
  - Sign in with Apple: loginWithApple -> SignInWithApple.getAppleIDCredential(scopes: [.email, .fullName]) -> _api.loginApple(identityToken, fullName).
  - Passkeys: loginPasskey -> _api.beginPasskeyLogin() -> PasskeyAuthenticator().authenticate(AuthenticateRequestType.fromJson(...)) -> _api.finishPasskeyLogin(challengeId, credential).
  - Apple purchase: ApplePremiumPurchaseService(productId: com.niki.xxread.premium.lifetime, verify: (_) => _api.submitApplePurchase(...), onMembership: ...).
- MemberAccountApiClient (account_api_client.dart, 612 lines): Dio REST client; single _refreshing future guards concurrent refresh; authConfig/membershipConfig/restoreSession/loginPassword/requestCode/registerPassword/mfaStatus/beginExternalLogin/loginApple/beginPasskeyLogin/finishPasskeyLogin/pollDeviceAuthorization/updateProfile/avatar/membership/submitApplePurchase/logout/refreshSession. Throws MemberAccountException.
- account_models.dart: MemberUser, MemberAuthProviders (google/github/apple/passkey flags), MemberAuthConfig, MemberEmailCodePurpose, MemberExternalAuthMethod { google, github, apple, passkey }.
- Token store (account_token_store.dart): MemberTokenStore + SecureMemberTokenStore on FlutterSecureStorage (open_reading.account.{access_token,refresh_token,mfa_pending}); PendingDeviceAuthorizationStore + SecurePendingDeviceAuthorizationStore; write-back rollback.
- Avatar cache (account_avatar_cache.dart): LRU memory (LinkedHashMap) + disk cache (account_avatars/), in-flight de-dup, epoch invalidation, size/TTL bounds, Dio loader; avatar_image_processor.dart; AccountSummaryCache.
- Apple purchase (apple_purchase_service.dart): ApplePurchaseStore + InAppPurchaseStore (wraps in_app_purchase); ApplePremiumPurchaseService listens to purchaseStream, server verify (_verify = source of truth), keeps unfinished transaction on verify failure for retry, 8s timeouts, restore.
- Device authorization: beginExternalLogin -> DeviceAuthorization persisted for recovery, polled (pollDeviceAuthorization) with native deep-link bridge (AccountAuthCallbackBridge, MethodChannel com.niki.xxread/account_auth) primary + polling fallback.
- UI: lib/pages/account/account_page.dart (_buildSignedOut/_buildSignedIn/_buildMfaChallenge, _formCard/_profileCard, _loginWithApple, _externalLogin); parts/: account_auth_part.dart (_ExternalLoginMethods, _ProviderBrand, custom GitHub/Google painters), account_membership_part.dart (924 lines), account_security_part.dart (_ChangeEmail/_ChangePassword/_MfaOverview/_MfaEmailCode/_MfaAuthenticator/_MfaRecoveryCodes), avatar_crop_page.dart. Entry: lib/widgets/settings_account_card.dart pushes AccountPage.

### Account strengths
1. Server-verified premium with client only a StoreKit gateway (correct "server is source of truth").
2. Clean external-auth architecture: deep-link bridge + durable polling fallback + persisted pending-device-authorization for recovery.
3. Token store keeps MFA pending flag and rolls back writes; refresh guarded by single in-flight future.
4. Testable interfaces everywhere (stores, purchase store, loader, dio injectable).

### Account weaknesses
1. Large single files: MemberAccountController, account_api_client, account_models, and account parts (800-924 lines each).
2. Hardcoded Chinese UI/exception strings (e.g. "App Store 内购暂不可用") - incomplete i18n.
3. Login flows somewhat duplicated between direct (loginWithApple/passkey) and generic (beginExternalLogin / pollDeviceAuthorization) paths.

## 5. Update/download services & online-font infrastructure

### Update check (lib/services/core/update_check_service.dart + app_update_download_policy.dart)
- AppRelease, WebsiteReleaseAsset (downloadUrl, websiteUrl, sha256, fileSize, platform, architecture, packageType, buildNumber, mandatory) from GitHub JSON and a website JSON API (per-platform/arch asset matching). Version normalization + URL allow-listing.
- UpdateCheckGate (lib/widgets/update_check_gate.dart) wraps home shell; UpdatePromptController + _UpdateDialog/_WebsiteUpdateProgressDialog/_VersionBadge.

### Download & install (app_update_download_service{_io,_stub})
- AppUpdateDownloadService (top-level file is a 3-line export) with logic in _io.dart (267 lines). downloadAndInstall: Android-only, validates official-APK size, downloads to updates/*.apk.part then rename, streams via Dio, CancelToken, SHA-256 verify (AppUpdateException/AppUpdateFailure { cancelled, download, fileSize, checksum, install, unsupported }), native install via MethodChannel com.niki.xxread/app_update (installDownloadedApk), reports via BackgroundDownloadNotifier.
- background_download_notifier{_io,_stub}: platform channel/isolate bridge for a background download notification (BackgroundDownloadKind update vs book; taps handled in XxReadApp).

### Online/custom fonts
- OnlineFontService (online_font_service{_io,_web}): _io does Dio range/byte-range downloads with offline ZIP entry extraction (OnlineFontZipEntry byte ranges from central dir), SHA-256 verification, FontLoader runtime registration, atomic manifest.json; host whitelist (cdn.jsdelivr.net, developer.huawei.com, fastly.jsdelivr.net, gcore.jsdelivr.net, raw.githubusercontent.com) = SSRF guard. online_font_models.dart defines types incl. OnlineFontDownloadStatus/Progress/ErrorCode. inflateFontEntryInIsolate decompresses in a background isolate.
- CustomFontService (custom_font_service{_io,_web}): manages user-imported font files (custom_font_models.dart) with private storage + FontLoader registration on io.
- ChangelogService (changelog_service.dart): ChangelogService.load(locale) parses assets/changelog/changelog.json (schemaVersion 1) with locale cascade (lang-tag -> lang-country -> lang -> en -> any); powers changelog_page.dart.
- app_settings_service.dart (AppSettingsNotifier) ties it together: app/reader font selection in FontCatalog (local/online/custom), online-font download gating, font fallback.

### Update/font strengths
1. Checksum enforcement on update APK and font bytes; SSRF-safe host whitelisting; atomic manifest.
2. Genuine byte-range ZIP extraction for large official font packages + background-isolate decompression.
3. Consistent platform-switch (_io/_web/_stub) pattern across update/notify/font/reader-theme services.

### Update/font weaknesses
1. Online/custom font + update logic spread across several _io/_web/_stub triples; platform choice relies on the export if (dart.library.html) pattern per file.
2. Update install is Android-only; other platforms rely on website flow. Mandatory build flag representation is thin.
3. AppUpdateDownloadService top-level is just an export shell (naming surprise).

## 6. Localization (4-language: zh, zh_TW, en, ja)

- Flutter gen-l10n. Config l10n.yaml (arb-dir lib/l10n, template app_en.arb, output-class AppLocalizations, nullable-getter false, untranslated report l10n_untranslated.json).
- ARB files in lib/l10n/: app_en.arb (template, ~3859 lines incl. metadata), app_zh.arb, app_zh_TW.arb, app_ja.arb.
- Generated lib/l10n/app_localizations.dart + _en/_zh/_ja files: AppLocalizations.supportedLocales = [Locale(en), Locale(ja), Locale(zh), Locale(zh,TW)]; delegates combine app + Global Material/Cupertino/Widgets.
- Locale selection: AppSettingsNotifier persists app_locale/legacy; setLocaleCode -> _parseLocale ("system" -> null, else Locale(lang[,country]) from "xx-YY"); passed to MaterialApp.locale.
- Constrained use: context.l10n extension (lib/utils/localization_extension.dart, 9 lines) = AppLocalizations.of(context); l10n README documents key conventions (camelCase prefix per page/feature), placeholder types, and bans hardcoding user-facing strings in widgets/services (use enums/keys translated in UI).
- Also localized: localizeAiResponseBuffer for AI tokens; ChangelogService locale cascade; tts_service_translator.dart and app_themes_translator.dart translate model display names.

### l10n strengths
1. Clean disciplined gen-l10n flow with untranslated-messages report and documented key conventions.
2. nullable-getter false forces non-null lookups; "no hardcoded strings in widgets/services" is codified and largely enforced.
3. Editor-facing metadata kept in en template.
4. Locale is movable ("system" or any of the 4).

### l10n weaknesses
1. Generated app_localizations*.dart checked in (gen-l10n norm, adds noise).
2. Several service/model layers still contain hardcoded Chinese (l10n README "待迁移" list): book_import_service.dart, enhanced_txt_import_service.dart, reader_core/ai/ai_service.dart, services/ai/global_ai_reading_service.dart, models/book_note.dart, utils/app_themes.dart (theme display names), plus account purchase exceptions.
3. zh_TW/ja lines equal en counts partly because en carries @metadata; parity enforced via untranslated report but not auto-blocked.
4. Enforcement depends on l10n_untranslated.json being empty (gitignored), so drift is possible.

## Cross-cutting strengths
- Consistent platform-switch (_io/_web/_stub) service pattern + heavy interface/injected-impl/singleton/forTesting testable pattern.
- Comment-led architecture: shell pages, services, l10n README document intent inline; top-of-file "文件说明/技术要点".
- Careful progressive-enhancement & offline-first: pre-warmed reader palette, focus gate, BookOpenTransition, local-first reading, local AI knowledge retrieval.

## Cross-cutting weaknesses
- Very large files: home_shell(+901-line part), settings_page, ai_settings_page (1173), account_page/security_part/membership_part (800-924), reader_settings_controls (1367), reader_navigation_sheet (1161), ai_service (1463) - hard to navigate/test in isolation.
- Documentation drift: DESIGN.md documents the WebDAV/sync + book-source grouping workstreams and asks to reuse "existing theme/Material 3"; it does not cover glass system, ui_style enum, reader-theme model, AI/account/update subsystems.
- Incomplete i18n in service/model layers + leftover dead/compat code (ParsedBook stub, old controller session methods).
- Monolithic part files and magic-type branches tie shell/layout/navigation to concrete page types, reducing extensibility.

## Quick file map (path -> key classes)
- Shell/nav: lib/main.dart (ThemeNotifier, XxReadApp, RestartableApp); lib/pages/home_* (HomeShellPage, HomeMobileDashboardPage, HomeBounceNavigationItem, HomePageWrappers, LayoutHelper).
- Theme/glass: lib/utils/app_themes.dart (AppThemes/AppTheme), reader_themes.dart (ReaderThemes/ReaderThemePalette), ui_style.dart (UiStyleThemeExtension), glass_config.dart (GlassEffectConfig/GlassEffectHelper/GlassPreset), progressive_blur.dart; lib/widgets/glass_top_bar.dart (GlassTopBar), floating_subpage_scaffold.dart, side_toast.dart (showSideToast, SideToastKind).
- AI: lib/reader_core/ai/ai_service.dart (ReaderHttpAIService, AIService, ConfigurableAIService, AIProviderSettings, AIModelPresets) + ai_error_translator.dart; lib/services/ai/ (GlobalAIReadingService, AiRequestCoordinator, BookPreprocessService, AiPreprocessTaskController, AiChatHistoryStore, GlobalAIReadingTranslator).
- Account: lib/services/account/ (MemberAccountController, MemberAccountApiClient, SecureMemberTokenStore, AccountAvatarCache, ApplePremiumPurchaseService, AccountAuthCallbackBridge, AccountSummaryCache, AvatarImageProcessor, account_models, account.dart); UI lib/pages/account/*.
- Updates/fonts: lib/services/core/ (UpdateCheckService, AppUpdateDownloadService*, BackgroundDownloadNotifier*, OnlineFontService*, CustomFontService*, ChangelogService, ReaderThemeBackgroundService*, AppSettingsService, DisplayRefreshRateController); lib/widgets/update_check_gate.dart.
- TTS/read-aloud: lib/services/tts_service.dart (TtsService, TtsVoiceOption); lib/services/reader_aloud_service.dart (ReaderAloudService, ReaderAloudEngineType{system,cloud}, OpenAiCompatibleReaderAloudCloudClient, ReaderAloudCloudAudioCache, AudioplayersReaderAloudBytesPlayer).
- Reader widgets: lib/widgets/reader_settings_controls.dart (ReaderSettingsSheet, ReaderTopBarStyleSheet, ReaderPageModeSheet, ReaderThemeStrip, ReaderSettingSlider, ReaderMarginControls); reader_navigation_sheet.dart (ReaderNavigationSheet, ReaderNavigationCatalog, ReaderNavigationChapter); lib/utils/book_open_transition.dart (BookOpenTransition, BookOpenAnimation).
- L10n: l10n.yaml, lib/l10n/app_*.{arb,dart}, lib/utils/localization_extension.dart.
