// 文件说明：AI 阅读助手独立设置页，管理快捷模型卡片与 AI 预处理开关。
// 技术要点：Flutter UI、SharedPreferences、底部弹层表单。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/services/ai/book_preprocess_service.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/side_toast.dart';

import 'ai_model_editor_page.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, this.aiService});

  final ReaderHttpAIService? aiService;

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  static const _aiQuickModelsKey = 'reader_ai_quick_models_v1';
  static const _activeAiQuickModelKey = 'reader_ai_active_quick_model_v1';

  late final ReaderHttpAIService _aiService;

  final Map<AIProviderType, AIProviderSettings> _aiDraftByProvider =
      <AIProviderType, AIProviderSettings>{};
  AIProviderType _selectedAiProvider = AIProviderType.openai;
  List<_AiQuickModel> _aiQuickModels = const [];
  String? _activeAiQuickModelId;
  bool _aiSettingsLoaded = false;
  bool _aiPreprocessEnabled = false;

  String _copy(String zh, String ja, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'zh' => zh,
        'ja' => ja,
        _ => en,
      };

  @override
  void initState() {
    super.initState();
    _aiService = widget.aiService ?? ReaderHttpAIService();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final activeAiSettings = await _aiService.loadSettings();
    final aiSettingsByProvider = <AIProviderType, AIProviderSettings>{
      for (final provider in AIProviderType.values)
        provider: provider == activeAiSettings.provider
            ? activeAiSettings
            : await _aiService.loadSettings(provider),
    };
    final quickModels = _loadAiQuickModels(
      prefs,
      activeAiSettings,
      aiSettingsByProvider,
    );
    var activeQuickModelId = prefs.getString(_activeAiQuickModelKey);
    if (activeQuickModelId == null) {
      for (final item in quickModels) {
        if (item.matches(activeAiSettings)) {
          activeQuickModelId = item.id;
          break;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _aiDraftByProvider
        ..clear()
        ..addAll(aiSettingsByProvider);
      _selectedAiProvider = activeAiSettings.provider;
      _aiQuickModels = quickModels;
      _activeAiQuickModelId = activeQuickModelId;
      _aiPreprocessEnabled = prefs.getBool(aiPreprocessBooksPrefsKey) ?? false;
      _aiSettingsLoaded = true;
    });
  }

  List<_AiQuickModel> _loadAiQuickModels(
    SharedPreferences prefs,
    AIProviderSettings activeSettings,
    Map<AIProviderType, AIProviderSettings> settingsByProvider,
  ) {
    final raw = prefs.getString(_aiQuickModelsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final saved = decoded
              .whereType<Map>()
              .map(
                (item) =>
                    _AiQuickModel.fromJson(Map<String, dynamic>.from(item)),
              )
              .whereType<_AiQuickModel>()
              .toList(growable: false);
          if (saved.isNotEmpty) return saved;
        }
      } catch (_) {
        // Fall back to the curated starter cards below.
      }
    }

    final result = <_AiQuickModel>[
      _AiQuickModel.fromSettings(activeSettings, isCustom: true),
    ];
    const starterPresetIds = <String>[
      'deepseek_chat',
      'openai_gpt_4_1_mini',
      'gemini_2_flash',
    ];
    for (final presetId in starterPresetIds) {
      final preset = AIModelPresets.all.firstWhere(
        (item) => item.id == presetId,
        orElse: () => AIModelPresets.all.first,
      );
      final providerSettings = settingsByProvider[preset.provider];
      final sameEndpoint =
          providerSettings != null &&
          providerSettings.baseUrl == preset.toSettings().baseUrl;
      final settings = preset.toSettings(
        apiKey: sameEndpoint ? providerSettings.apiKey : '',
      );
      if (result.any((item) => item.matches(settings))) continue;
      result.add(
        _AiQuickModel(
          id: 'preset-${preset.id}',
          settings: settings,
          isCustom: false,
        ),
      );
    }
    return result;
  }

  Future<void> _persistAiQuickModels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _aiQuickModelsKey,
      jsonEncode(_aiQuickModels.map((item) => item.toJson()).toList()),
    );
    if (_activeAiQuickModelId != null) {
      await prefs.setString(_activeAiQuickModelKey, _activeAiQuickModelId!);
    }
  }

  String _knownAiApiKey(
    AIProviderType provider,
    String baseUrl, {
    AIProtocolType? protocol,
  }) {
    final effectiveProtocol = provider == AIProviderType.custom
        ? protocol ?? provider.defaultProtocol
        : provider.defaultProtocol;
    final normalizedBase = normalizeAIBaseUrl(
      provider,
      baseUrl,
      protocol: effectiveProtocol,
    );
    for (final item in _aiQuickModels) {
      if (item.settings.provider == provider &&
          item.settings.effectiveProtocol == effectiveProtocol &&
          item.settings.baseUrl == normalizedBase &&
          item.settings.apiKey.isNotEmpty) {
        return item.settings.apiKey;
      }
    }
    final draft = _aiDraftByProvider[provider];
    if (draft != null &&
        draft.effectiveProtocol == effectiveProtocol &&
        draft.baseUrl == normalizedBase &&
        draft.apiKey.isNotEmpty) {
      return draft.apiKey;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = PageStyleHelper.palette(context);
    return FloatingSubpageScaffold(
      title: l10n.settingsAiAssistantTitle,
      body: !_aiSettingsLoaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: floatingSubpagePadding(context),
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _copy(
                            '选择一个模型用于阅读问答，也可以添加自己的服务。',
                            '読書中の質問に使うモデルを選ぶか、独自のサービスを追加できます。',
                            'Choose a model for reading questions, or add your own service.',
                          ),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                        ),
                        const SizedBox(height: 16),
                        _buildCard(
                          palette,
                          children: [
                            for (final item in _aiQuickModels)
                              _buildAiModelRow(item),
                            _buildAddAiModelRow(),
                          ],
                        ),
                        const SizedBox(height: 20),
                        _buildCard(
                          palette,
                          children: [_buildPreprocessSwitch()],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildCard(
    PageVisualPalette palette, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: palette.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _buildPreprocessSwitch() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_setAiPreprocessEnabled(!_aiPreprocessEnabled)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.secondary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.auto_stories_outlined,
                  size: 16,
                  color: scheme.secondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsAiPreprocessTitle,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      l10n.settingsAiPreprocessSubtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _aiPreprocessEnabled,
                onChanged: (value) => unawaited(_setAiPreprocessEnabled(value)),
                activeTrackColor: scheme.primary,
                thumbColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? scheme.onPrimary
                      : scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 开启前校验已有可用 AI 模型，并提示大量 token 消耗；关闭无需确认。
  Future<void> _setAiPreprocessEnabled(bool value) async {
    final l10n = context.l10n;
    if (value) {
      final settings = await _aiService.loadSettings();
      if (!mounted) return;
      if (!settings.isConfigured) {
        showSideToast(
          context,
          l10n.settingsAiPreprocessNeedModel,
          kind: SideToastKind.error,
        );
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.settingsAiPreprocessTitle),
          content: Text(l10n.settingsAiPreprocessWarning),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _aiPreprocessEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(aiPreprocessBooksPrefsKey, value);
  }

  Widget _buildAiModelRow(_AiQuickModel item) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final selected = item.id == _activeAiQuickModelId;
    final configured = item.settings.isConfigured;
    final host = Uri.tryParse(item.settings.baseUrl)?.host ?? '';
    final providerName = item.settings.provider == AIProviderType.custom
        ? l10n.settingsAiCustomProvider
        : item.settings.provider.displayName;
    final protocolName = switch (item.settings.effectiveProtocol) {
      AIProtocolType.openai => l10n.settingsAiProtocolOpenAi,
      AIProtocolType.anthropic => l10n.settingsAiProtocolAnthropic,
      AIProtocolType.gemini => 'Gemini',
    };
    final subtitle = configured
        ? '$providerName${item.settings.provider == AIProviderType.custom ? ' · $protocolName' : ''} · '
              '${host.isNotEmpty ? host : item.settings.baseUrl}'
        : l10n.settingsAiApiKeyTapToConfigure;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_activateAiQuickModel(item)),
        onLongPress: () => unawaited(_showAiQuickModelMenu(item)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: (selected ? scheme.primary : scheme.onSurfaceVariant)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  selected
                      ? Icons.auto_awesome_rounded
                      : Icons.auto_awesome_outlined,
                  size: 16,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.settings.model,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: selected && configured
                    ? Icon(
                        Icons.check_circle_rounded,
                        key: const ValueKey('selected'),
                        size: 20,
                        color: scheme.primary,
                      )
                    : const SizedBox.square(
                        key: ValueKey('not-selected'),
                        dimension: 20,
                      ),
              ),
              IconButton(
                tooltip: l10n.edit,
                onPressed: () => unawaited(_openAiModelEditor(editing: item)),
                icon: const Icon(Icons.edit_outlined, size: 20),
                visualDensity: VisualDensity.compact,
              ),
              if (item.isCustom && _aiQuickModels.length > 1)
                IconButton(
                  onPressed: () => unawaited(_showAiQuickModelMenu(item)),
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddAiModelRow() {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => unawaited(_openAiModelEditor()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(Icons.add_rounded, size: 16, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Text(
                l10n.settingsAiAddModel,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _activateAiQuickModel(_AiQuickModel item) async {
    if (!item.settings.isConfigured) {
      await _openAiModelEditor(editing: item);
      return;
    }
    try {
      await _aiService.saveSettings(item.settings);
      if (!mounted) return;
      setState(() {
        _activeAiQuickModelId = item.id;
        _selectedAiProvider = item.settings.provider;
        _aiDraftByProvider[item.settings.provider] = item.settings;
      });
      await _persistAiQuickModels();
      if (mounted) {
        showSideToast(
          context,
          context.l10n.settingsAiSwitchedToModel(item.settings.model),
          kind: SideToastKind.success,
        );
      }
    } catch (error) {
      if (mounted) {
        showSideToast(context, '$error', kind: SideToastKind.error);
      }
    }
  }

  Future<void> _showAiQuickModelMenu(_AiQuickModel item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(sheetContext.l10n.edit),
                onTap: () => Navigator.of(sheetContext).pop('edit'),
              ),
              if (item.isCustom && _aiQuickModels.length > 1)
                ListTile(
                  leading: Icon(Icons.delete_outline, color: scheme.error),
                  title: Text(
                    sheetContext.l10n.delete,
                    style: TextStyle(color: scheme.error),
                  ),
                  onTap: () => Navigator.of(sheetContext).pop('delete'),
                ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    switch (action) {
      case 'edit':
        await _openAiModelEditor(editing: item);
      case 'delete':
        await _removeAiQuickModel(item);
    }
  }

  Future<void> _removeAiQuickModel(_AiQuickModel item) async {
    if (_aiQuickModels.length <= 1) return;
    setState(() {
      _aiQuickModels = _aiQuickModels
          .where((candidate) => candidate.id != item.id)
          .toList(growable: false);
      if (_activeAiQuickModelId == item.id) {
        _activeAiQuickModelId = _aiQuickModels.first.id;
      }
    });
    await _persistAiQuickModels();
  }

  Future<void> _openAiModelEditor({_AiQuickModel? editing}) async {
    final initial =
        editing?.settings ??
        AIProviderSettings.defaults(_selectedAiProvider).copyWith(
          apiKey: _aiDraftByProvider[_selectedAiProvider]?.apiKey ?? '',
        );
    final result = await Navigator.of(context).push<AiModelEditorResult>(
      MaterialPageRoute(
        builder: (_) => AiModelEditorPage(
          initialSettings: initial,
          initialIsCustom:
              editing?.isCustom ?? initial.provider == AIProviderType.custom,
          isEditing: editing != null,
          aiService: _aiService,
          knownApiKey: (provider, baseUrl, protocol) =>
              _knownAiApiKey(provider, baseUrl, protocol: protocol),
        ),
      ),
    );
    if (result == null || !mounted) return;
    final item = _AiQuickModel(
      id: editing?.id ?? _AiQuickModel.idFor(result.settings),
      settings: result.settings,
      isCustom: result.isCustom,
    );
    setState(() {
      final existingIndex = _aiQuickModels.indexWhere(
        (candidate) => candidate.id == item.id,
      );
      if (existingIndex >= 0) {
        final next = [..._aiQuickModels];
        next[existingIndex] = item;
        _aiQuickModels = next;
      } else {
        _aiQuickModels = [..._aiQuickModels, item];
      }
      _activeAiQuickModelId = item.id;
      _selectedAiProvider = item.settings.provider;
      _aiDraftByProvider[item.settings.provider] = item.settings;
    });
    await _persistAiQuickModels();
  }
}

class _AiQuickModel {
  const _AiQuickModel({
    required this.id,
    required this.settings,
    required this.isCustom,
  });

  final String id;
  final AIProviderSettings settings;
  final bool isCustom;

  factory _AiQuickModel.fromSettings(
    AIProviderSettings settings, {
    required bool isCustom,
  }) {
    final normalized = settings.normalized();
    return _AiQuickModel(
      id: idFor(normalized),
      settings: normalized,
      isCustom: isCustom,
    );
  }

  static String idFor(AIProviderSettings settings) {
    final source =
        '${settings.provider.value}|${settings.effectiveProtocol.value}|${settings.baseUrl}|${settings.model}';
    return 'model-${base64Url.encode(utf8.encode(source)).replaceAll('=', '')}';
  }

  bool matches(AIProviderSettings other) {
    final normalized = other.normalized();
    return settings.provider == normalized.provider &&
        settings.effectiveProtocol == normalized.effectiveProtocol &&
        settings.baseUrl == normalized.baseUrl &&
        settings.model == normalized.model;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': settings.provider.value,
    'protocol': settings.effectiveProtocol.value,
    'apiKey': settings.apiKey,
    'baseUrl': settings.baseUrl,
    'model': settings.model,
    'temperature': settings.temperature,
    'isCustom': isCustom,
  };

  static _AiQuickModel? fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final model = json['model']?.toString() ?? '';
    final baseUrl = json['baseUrl']?.toString() ?? '';
    if (id.isEmpty || model.isEmpty || baseUrl.isEmpty) return null;
    final settings = AIProviderSettings(
      provider: AIProviderTypeX.fromValue(json['provider']?.toString()),
      protocol: AIProtocolTypeX.fromValue(
        json['protocol']?.toString(),
        fallback: AIProviderTypeX.fromValue(
          json['provider']?.toString(),
        ).defaultProtocol,
      ),
      apiKey: json['apiKey']?.toString() ?? '',
      baseUrl: baseUrl,
      model: model,
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
    ).normalized();
    return _AiQuickModel(
      id: id,
      settings: settings,
      isCustom: json['isCustom'] == true,
    );
  }
}
