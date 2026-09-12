import 'package:flutter/material.dart';

import 'package:xxread/reader_core/ai/ai_service.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';

class AiModelEditorResult {
  const AiModelEditorResult({required this.settings, required this.isCustom});

  final AIProviderSettings settings;
  final bool isCustom;
}

class AiModelEditorPage extends StatefulWidget {
  const AiModelEditorPage({
    super.key,
    required this.initialSettings,
    required this.initialIsCustom,
    required this.isEditing,
    required this.aiService,
    required this.knownApiKey,
  });

  final AIProviderSettings initialSettings;
  final bool initialIsCustom;
  final bool isEditing;
  final ReaderHttpAIService aiService;
  final String Function(
    AIProviderType provider,
    String baseUrl,
    AIProtocolType protocol,
  )
  knownApiKey;

  @override
  State<AiModelEditorPage> createState() => _AiModelEditorPageState();
}

class _AiModelEditorPageState extends State<AiModelEditorPage> {
  late AIProviderType _provider;
  late AIProtocolType _protocol;
  late AIModelPreset _preset;
  late bool _isCustom;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _temperatureController;

  bool _obscureApiKey = true;
  bool _loadingModels = false;
  bool _saving = false;
  List<String> _fetchedModels = const [];
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSettings;
    _provider = initial.provider;
    _protocol = initial.effectiveProtocol;
    _preset =
        AIModelPresets.match(initial) ??
        AIModelPresets.defaultForProvider(
          _provider == AIProviderType.custom
              ? AIProviderType.openai
              : _provider,
        );
    _isCustom = widget.initialIsCustom;
    _apiKeyController = TextEditingController(text: initial.apiKey);
    _baseUrlController = TextEditingController(text: initial.baseUrl);
    _modelController = TextEditingController(text: initial.model);
    _temperatureController = TextEditingController(
      text: initial.temperature.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _temperatureController.dispose();
    super.dispose();
  }

  String _protocolLabel(AIProtocolType value) => switch (value) {
    AIProtocolType.openai => context.l10n.settingsAiProtocolOpenAi,
    AIProtocolType.anthropic => context.l10n.settingsAiProtocolAnthropic,
    AIProtocolType.gemini => 'Gemini',
  };

  String? _baseUrlHint() {
    if (_provider != AIProviderType.custom) return null;
    return switch (_protocol) {
      AIProtocolType.openai => context.l10n.settingsAiBaseUrlHintOpenAi,
      AIProtocolType.anthropic => context.l10n.settingsAiBaseUrlHintAnthropic,
      AIProtocolType.gemini => null,
    };
  }

  void _applyPreset(AIModelPreset preset) {
    final previousProvider = _provider;
    final previousProtocol = _protocol;
    final previousBaseUrl = normalizeAIBaseUrl(
      previousProvider,
      _baseUrlController.text,
      protocol: previousProtocol,
    );
    final previousApiKey = _apiKeyController.text;
    _preset = preset;
    _provider = preset.provider;
    _protocol = preset.provider.defaultProtocol;
    _baseUrlController.text = preset.baseUrl;
    _modelController.text = preset.model;
    _temperatureController.text = preset.temperature.toStringAsFixed(2);
    final nextBaseUrl = normalizeAIBaseUrl(
      _provider,
      preset.baseUrl,
      protocol: _protocol,
    );
    _apiKeyController.text =
        previousProvider == _provider &&
            previousProtocol == _protocol &&
            previousBaseUrl == nextBaseUrl
        ? previousApiKey
        : widget.knownApiKey(_provider, preset.baseUrl, _protocol);
    _isCustom = false;
    _fetchedModels = const [];
    _errorText = null;
  }

  void _markCustomized([String? _]) {
    if (!_isCustom) setState(() => _isCustom = true);
  }

  Future<void> _fetchModels() async {
    final apiKey = _apiKeyController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    if (apiKey.isEmpty || baseUrl.isEmpty) {
      setState(() => _errorText = context.l10n.settingsAiFillBaseUrlAndApiKey);
      return;
    }
    setState(() {
      _loadingModels = true;
      _errorText = null;
    });
    try {
      final models = await widget.aiService.fetchAvailableModels(
        _buildSettings(),
      );
      if (!mounted) return;
      setState(() {
        _fetchedModels = models;
        _loadingModels = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _errorText = '$error';
      });
    }
  }

  AIProviderSettings _buildSettings() => AIProviderSettings(
    provider: _provider,
    protocol: _protocol,
    apiKey: _apiKeyController.text.trim(),
    baseUrl: _baseUrlController.text.trim(),
    model: _modelController.text.trim(),
    temperature: double.tryParse(_temperatureController.text.trim()) ?? 0.7,
  ).normalized();

  Future<void> _save() async {
    final settings = _buildSettings();
    final validation = validateAIProviderSettings(settings);
    if (validation != null) {
      setState(() => _errorText = validation);
      return;
    }
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await widget.aiService.saveSettings(settings);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(AiModelEditorResult(settings: settings, isCustom: _isCustom));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = '$error';
      });
    }
  }

  InputDecoration _fieldDecoration({
    required String label,
    required IconData icon,
    String? helper,
    Widget? suffix,
  }) {
    final palette = PageStyleHelper.palette(context);
    return InputDecoration(
      labelText: label,
      helperText: helper,
      helperMaxLines: 3,
      prefixIcon: Icon(icon),
      suffixIcon: suffix,
      filled: true,
      fillColor: palette.card,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.border),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 10),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  String _copy(String zh, String ja, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'zh' => zh,
        'ja' => ja,
        _ => en,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final presets = _provider == AIProviderType.custom
        ? const <AIModelPreset>[]
        : AIModelPresets.byProvider(_provider);
    return PopScope(
      canPop: !_saving,
      child: FloatingSubpageScaffold(
        title: widget.isEditing
            ? l10n.settingsAiEditModelTitle
            : l10n.settingsAiAddModel,
        canPop: !_saving,
        resizeToAvoidBottomInset: true,
        bottomNavigationBar: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            top: false,
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_errorText != null) ...[
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _errorText!,
                            style: TextStyle(color: scheme.error),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: _saving ? null : _save,
                        icon: _saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_rounded),
                        label: Text(
                          widget.isEditing
                              ? l10n.settingsAiSaveAndEnable
                              : l10n.settingsAiAddAndEnable,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        body: AbsorbPointer(
          absorbing: _saving,
          child: ListView(
            padding: floatingSubpagePadding(context, bottom: 24),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _copy(
                          '选择服务商，填写密钥并确认模型。预设参数也可以直接修改。',
                          'プロバイダーとキーを設定し、モデルを確認します。プリセットの内容も変更できます。',
                          'Choose a provider, enter its key, and confirm the model. Preset details remain editable.',
                        ),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _sectionLabel(_copy('服务商', 'プロバイダー', 'Provider')),
                      DropdownButtonFormField<AIProviderType>(
                        key: ValueKey('provider-${_provider.value}'),
                        initialValue: _provider,
                        decoration: _fieldDecoration(
                          label: l10n.settingsAiProviderLabel,
                          icon: Icons.hub_outlined,
                        ),
                        items: AIProviderType.values
                            .map(
                              (item) => DropdownMenuItem(
                                value: item,
                                child: Text(
                                  item == AIProviderType.custom
                                      ? l10n.settingsAiCustomProvider
                                      : item.displayName,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _provider = value;
                            _protocol = value.defaultProtocol;
                            _isCustom = value == AIProviderType.custom;
                            if (value == AIProviderType.custom) {
                              final defaults = AIProviderSettings.defaults(
                                value,
                              );
                              _baseUrlController.text = defaults.baseUrl;
                              _modelController.text = defaults.model;
                              _apiKeyController.text = widget.knownApiKey(
                                value,
                                defaults.baseUrl,
                                _protocol,
                              );
                              _fetchedModels = const [];
                              _errorText = null;
                            } else {
                              _applyPreset(
                                AIModelPresets.defaultForProvider(value),
                              );
                            }
                          });
                        },
                      ),
                      if (_provider == AIProviderType.custom) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<AIProtocolType>(
                          key: ValueKey('protocol-${_protocol.value}'),
                          initialValue: _protocol,
                          decoration: _fieldDecoration(
                            label: l10n.settingsAiProtocolLabel,
                            icon: Icons.swap_calls_rounded,
                          ),
                          items:
                              const [
                                    AIProtocolType.openai,
                                    AIProtocolType.anthropic,
                                  ]
                                  .map(
                                    (item) => DropdownMenuItem(
                                      value: item,
                                      child: Text(_protocolLabel(item)),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() {
                              _protocol = value;
                              _apiKeyController.text = widget.knownApiKey(
                                _provider,
                                _baseUrlController.text,
                                value,
                              );
                              _fetchedModels = const [];
                              _errorText = null;
                            });
                          },
                        ),
                      ],
                      if (presets.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<AIModelPreset>(
                          key: ValueKey(
                            'preset-${_provider.value}-${_preset.id}',
                          ),
                          initialValue: !_isCustom && presets.contains(_preset)
                              ? _preset
                              : null,
                          isExpanded: true,
                          decoration: _fieldDecoration(
                            label: l10n.settingsAiPresetModel,
                            icon: Icons.auto_awesome_outlined,
                          ),
                          items: presets
                              .map(
                                (preset) => DropdownMenuItem(
                                  value: preset,
                                  child: Text(
                                    '${preset.vendor} · ${preset.label}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _applyPreset(value));
                          },
                        ),
                      ],
                      const SizedBox(height: 20),
                      _sectionLabel(_copy('服务连接', '接続', 'Connection')),
                      TextFormField(
                        controller: _baseUrlController,
                        onChanged: _markCustomized,
                        keyboardType: TextInputType.url,
                        decoration: _fieldDecoration(
                          label: _copy('服务地址', 'サービス URL', 'Base URL'),
                          icon: Icons.link_rounded,
                          helper: _baseUrlHint(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _apiKeyController,
                        obscureText: _obscureApiKey,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: _fieldDecoration(
                          label: l10n.settingsAiApiKeyLabel,
                          icon: Icons.key_rounded,
                          suffix: IconButton(
                            tooltip: _obscureApiKey
                                ? _copy(
                                    '显示 API Key',
                                    'API Key を表示',
                                    'Show API Key',
                                  )
                                : _copy(
                                    '隐藏 API Key',
                                    'API Key を隠す',
                                    'Hide API Key',
                                  ),
                            onPressed: () => setState(
                              () => _obscureApiKey = !_obscureApiKey,
                            ),
                            icon: Icon(
                              _obscureApiKey
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _sectionLabel(_copy('模型', 'モデル', 'Model')),
                      TextFormField(
                        controller: _modelController,
                        onChanged: _markCustomized,
                        decoration: _fieldDecoration(
                          label: l10n.settingsAiModelNameLabel,
                          icon: Icons.smart_toy_outlined,
                          suffix: IconButton(
                            tooltip: l10n.settingsAiFetchModelsTooltip,
                            onPressed: _loadingModels ? null : _fetchModels,
                            icon: _loadingModels
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded),
                          ),
                        ),
                      ),
                      if (_fetchedModels.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _fetchedModels
                              .map(
                                (model) => ChoiceChip(
                                  label: Text(model),
                                  selected:
                                      _modelController.text.trim() == model,
                                  onSelected: (_) {
                                    setState(() {
                                      _modelController.text = model;
                                      _isCustom = true;
                                    });
                                  },
                                ),
                              )
                              .toList(),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Theme(
                        data: Theme.of(
                          context,
                        ).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          childrenPadding: const EdgeInsets.only(bottom: 8),
                          title: Text(
                            _copy('更多选项', 'その他の設定', 'More options'),
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          children: [
                            TextFormField(
                              controller: _temperatureController,
                              onChanged: _markCustomized,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: _fieldDecoration(
                                label: l10n.settingsAiTemperatureLabel,
                                icon: Icons.thermostat_rounded,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
