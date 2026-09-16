import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/reader_aloud_session.dart';

import '../../services/reader_aloud_service.dart';
import '../../utils/page_style_helper.dart';
import '../../widgets/floating_subpage_scaffold.dart';

String cloudTtsCopy(BuildContext context, String zh, String en, String ja) =>
    switch (Localizations.localeOf(context).languageCode) {
      'en' => en,
      'ja' => ja,
      _ => zh,
    };

/// Shared by app settings and the audiobook player's quick settings.
class CloudTtsEditorPage extends StatefulWidget {
  const CloudTtsEditorPage({
    super.key,
    required this.service,
    this.pauseBook,
    this.profile,
    this.preset,
  });

  final ReaderAloudCloudProfile? profile;
  final ReaderAloudProviderPreset? preset;
  final ReaderAloudService service;
  final Future<void> Function()? pauseBook;

  @override
  State<CloudTtsEditorPage> createState() => _CloudTtsEditorPageState();
}

class _CloudTtsEditorPageState extends State<CloudTtsEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  String? _editingId;
  bool _hasProfileKey = false;
  bool _previewing = false;
  int _previewGeneration = 0;
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _voice = TextEditingController();
  final _apiKey = TextEditingController();
  ReaderAloudCloudProvider _provider = ReaderAloudCloudProvider.openai;
  bool _advancedExpanded = false;
  bool _loaded = false;
  bool _saving = false;
  bool _obscureKey = true;
  bool _clearKey = false;
  bool _fallback = true;
  String _format = 'mp3';
  String? _error;

  String _copy(String zh, String en, String ja) =>
      cloudTtsCopy(context, zh, en, ja);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await widget.service.initialize();
      if (!mounted) return;
      _editingId = widget.profile?.id;
      _hasProfileKey = !widget.service.supportsProfiles
          ? widget.service.hasCloudApiKey
          : _editingId != null &&
                await widget.service.profileHasKey(_editingId!);
      if (!mounted) return;
      final settings =
          widget.profile?.settings ??
          widget.preset?.settings ??
          widget.service.cloudSettings;
      _provider = settings.provider;
      _advancedExpanded = widget.preset?.url == '';
      _name.text = widget.profile?.name ?? widget.preset?.name ?? 'Cloud TTS';
      _baseUrl.text = settings.baseUrl;
      _model.text = settings.model;
      _voice.text = settings.voice;
      setState(() {
        _format = settings.responseFormat;
        _fallback = settings.fallbackToSystem;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _copy(
            '加载失败，请重试',
            'Could not load. Retry.',
            '読み込みに失敗しました',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    ++_previewGeneration;
    unawaited(widget.service.stopPreview());
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _voice.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  String? _required(String? value) => value == null || value.trim().isEmpty
      ? _copy('请填写此项', 'This field is required', '入力してください')
      : null;

  String? _validateUrl(String? value) {
    try {
      readerAloudCloudEndpoint(value ?? '');
      return null;
    } on ReaderAloudCloudException {
      return _copy(
        '请使用有效的 HTTPS 地址，不含账号、查询参数或片段',
        'Use a valid HTTPS URL without credentials, query or fragment',
        '認証情報・クエリ・フラグメントのない HTTPS URL を入力してください',
      );
    }
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final settings = ReaderAloudCloudSettings(
        provider: _provider,
        baseUrl: _baseUrl.text,
        model: _model.text,
        voice: _voice.text,
        responseFormat: _format,
        fallbackToSystem: _fallback,
      ).normalized();
      validateReaderAloudCloudSettings(settings);
      await _stopPreview();
      if (widget.service.supportsProfiles) {
        await _pauseBook();
        final id = _editingId ??= DateTime.now().microsecondsSinceEpoch
            .toString();
        await widget.service.saveCloudProfile(
          ReaderAloudCloudProfile(
            id: id,
            name: _name.text.trim(),
            settings: settings,
          ),
          apiKey: _apiKey.text,
          clearKey: _clearKey,
        );
        await widget.service.selectCloudProfile(id);
        await widget.service.setEngineType(ReaderAloudEngineType.cloud);
      } else {
        // Blank input retains the existing key.
        if (_apiKey.text.trim().isNotEmpty) {
          await widget.service.saveCloudApiKey(_apiKey.text);
        } else if (_clearKey) {
          await widget.service.clearCloudApiKey();
        }
        await widget.service.updateCloudSettings(settings);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _copy(
            '未能完成保存，请检查系统存储后重试。输入内容已保留。',
            'Could not finish saving. Check device storage and retry. Your input is kept.',
            '保存できませんでした。端末のストレージを確認して再試行してください。入力は保持されています。',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pauseBook() async {
    if (widget.pauseBook != null) {
      await widget.pauseBook!();
    } else {
      await context.read<ReaderAloudSession?>()?.controller?.pause();
    }
  }

  Future<void> _stopPreview() async {
    ++_previewGeneration;
    await widget.service.stopPreview();
    if (mounted) setState(() => _previewing = false);
  }

  Future<void> _preview() async {
    if (!_formKey.currentState!.validate()) return;
    final generation = ++_previewGeneration;
    setState(() {
      _previewing = true;
      _error = null;
    });
    try {
      await _pauseBook();
      if (!mounted || generation != _previewGeneration) return;
      await widget.service.previewCloudVoice(
        settings: ReaderAloudCloudSettings(
          provider: _provider,
          baseUrl: _baseUrl.text,
          model: _model.text,
          voice: _voice.text,
          responseFormat: _format,
          fallbackToSystem: false,
        ).normalized(),
        profileId: _editingId,
        apiKey: _apiKey.text,
        useSavedKey:
            !_clearKey &&
            (_editingId != null || !widget.service.supportsProfiles),
        text: _copy(
          '夜色渐深，窗外的风轻轻翻过书页。愿每一个故事，都能陪你走过一段美好的时光。',
          'The evening breeze gently turns the pages. Let each story accompany you on a wonderful journey.',
          '夜が更け、窓の外の風が静かにページをめくります。物語とともに、穏やかな時間を過ごしましょう。',
        ),
      );
    } catch (error) {
      if (mounted && generation == _previewGeneration) {
        setState(
          () => _error = error is ReaderAloudCloudException
              ? error.message
              : _copy(
                  '试听失败，请检查连接与密钥后重试',
                  'Preview failed. Check the connection and API key.',
                  '接続と API キーを確認してください',
                ),
        );
      }
    } finally {
      if (mounted && generation == _previewGeneration) {
        setState(() => _previewing = false);
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_copy('删除此语音配置？', 'Delete this voice?', 'この音声を削除しますか？')),
        content: Text(
          _copy(
            '同时移除本机保存的密钥。',
            'Also removes its saved key from this device.',
            '保存したキーも削除されます。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_copy('删除', 'Delete', '削除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await _stopPreview();
      if (_editingId == widget.service.activeProfileId) await _pauseBook();
      await widget.service.deleteCloudProfile(_editingId!);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _copy(
            '删除失败，请重试',
            'Could not delete. Retry.',
            '削除できませんでした',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _decoration(
    String label, {
    String? hint,
    String? helper,
    Widget? suffix,
  }) {
    final palette = PageStyleHelper.palette(context);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
      filled: true,
      fillColor: palette.card,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: palette.border),
      ),
      suffixIcon: suffix,
    );
  }

  ReaderAloudProviderPreset get _preset =>
      readerAloudProviderPresets.firstWhere((p) => p.provider == _provider);

  Future<void> _choose(
    TextEditingController controller,
    Map<String, String> options,
    String title,
  ) async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _TtsChoicePage(
          title: title,
          options: options,
          selected: controller.text,
        ),
      ),
    );
    if (value != null && mounted) {
      await _stopPreview();
      if (mounted) setState(() => controller.text = value);
    }
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    bool url = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey(key),
      controller: controller,
      enabled: !_saving,
      validator: url ? _validateUrl : _required,
      autocorrect: false,
      decoration: _decoration(label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hasKey = _hasProfileKey && !_clearKey;
    return PopScope(
      canPop: !_saving,
      child: FloatingSubpageScaffold(
        title: widget.preset?.name ?? _name.text,
        resizeToAvoidBottomInset: true,
        bottomNavigationBar: !_loaded
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    12 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 688),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            key: const ValueKey('cloud-tts-save'),
                            onPressed: _saving ? null : _save,
                            child: Text(
                              _saving
                                  ? _copy('正在保存…', 'Saving…', '保存中…')
                                  : _copy('保存并使用', 'Save and use', '保存して使用'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        body: !_loaded
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : TextButton(onPressed: _load, child: Text(_error!)),
              )
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Form(
                    key: _formKey,
                    child: SingleChildScrollView(
                      padding: floatingSubpagePadding(context),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _copy('选择喜欢的声音', 'Choose your voice', '音声を選択'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _copy(
                              '填入服务商 API Key，即可试听。',
                              'Enter your provider API key to preview.',
                              'API キーを入力して試聴できます。',
                            ),
                          ),
                          const SizedBox(height: 24),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(_copy('语音模型', 'Speech model', '音声モデル')),
                            subtitle: Text(
                              _preset.models[_model.text] ?? _model.text,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _saving
                                ? null
                                : () => _choose(
                                    _model,
                                    _preset.models,
                                    _copy('语音模型', 'Speech model', '音声モデル'),
                                  ),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(_copy('音色', 'Voice', '声')),
                            subtitle: Text(
                              _preset.voices[_voice.text] ?? _voice.text,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _saving
                                ? null
                                : () => _choose(
                                    _voice,
                                    _preset.voices,
                                    _copy('音色', 'Voice', '声'),
                                  ),
                          ),
                          const SizedBox(height: 24),
                          TextFormField(
                            key: const ValueKey('cloud-tts-key'),
                            controller: _apiKey,
                            enabled: !_saving,
                            obscureText: _obscureKey,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: _decoration(
                              'API Key',
                              hint: hasKey ? '••••••••' : null,
                              helper: hasKey
                                  ? _copy(
                                      '已保存，留空保留',
                                      'Saved; leave blank to keep',
                                      '保存済み・空欄で維持',
                                    )
                                  : _copy(
                                      '密钥保存在本机安全存储中',
                                      'Stored securely on this device',
                                      '端末に安全に保存',
                                    ),
                              suffix: IconButton(
                                onPressed: () =>
                                    setState(() => _obscureKey = !_obscureKey),
                                tooltip: _copy(
                                  '显示或隐藏密钥',
                                  'Toggle key visibility',
                                  'キーの表示切替',
                                ),
                                icon: Icon(
                                  _obscureKey
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          OutlinedButton.icon(
                            key: const ValueKey('cloud-tts-preview'),
                            onPressed: _saving
                                ? null
                                : (_previewing ? _stopPreview : _preview),
                            icon: Icon(
                              _previewing
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                            label: Text(
                              _previewing
                                  ? _copy('停止试听', 'Stop preview', '試聴を停止')
                                  : _copy('试听当前音色', 'Preview voice', '音声を試聴'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _copy(
                              '试听会暂停听书，并使用当前语速。服务商可能计费。',
                              'Preview pauses the book and uses the current speed. Provider charges may apply.',
                              '試聴時は読書を一時停止します。料金が発生する場合があります。',
                            ),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 16),
                          if (_provider == ReaderAloudCloudProvider.mimo)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _copy(
                                  'MiMo 通过指令调整语速，实际倍速可能略有差异。',
                                  'MiMo adjusts pace through instructions; actual speed may vary.',
                                  'MiMo は指示で話速を調整するため、実際の速度は異なる場合があります。',
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ExpansionTile(
                            maintainState: true,
                            tilePadding: EdgeInsets.zero,
                            title: Text(
                              _copy('高级自定义', 'Advanced customization', '詳細設定'),
                            ),
                            subtitle: Text(
                              _copy(
                                '名称、地址与自定义模型 / 音色',
                                'Name, endpoint and custom model / voice',
                                '名前・URL・カスタム音声',
                              ),
                            ),
                            initiallyExpanded: _advancedExpanded,
                            onExpansionChanged: (value) =>
                                _advancedExpanded = value,
                            children: [
                              _field(
                                'cloud-tts-name',
                                _name,
                                _copy('配置名称', 'Name', '設定名'),
                              ),
                              _field(
                                'cloud-tts-url',
                                _baseUrl,
                                _copy('服务地址', 'Service URL', 'サービス URL'),
                                url: true,
                              ),
                              _field(
                                'cloud-tts-model',
                                _model,
                                _copy('自定义模型 ID', 'Custom model ID', 'モデル ID'),
                              ),
                              _field(
                                'cloud-tts-voice',
                                _voice,
                                _copy('自定义音色 ID', 'Custom voice ID', '音声 ID'),
                              ),
                              DropdownButtonFormField<String>(
                                initialValue: _format,
                                isExpanded: true,
                                decoration: _decoration(
                                  _copy('音频格式', 'Audio format', '音声形式'),
                                ),
                                items:
                                    {
                                          _format,
                                          ...readerAloudCloudFormats(_provider),
                                        }
                                        .map(
                                          (f) => DropdownMenuItem(
                                            value: f,
                                            child: Text(f.toUpperCase()),
                                          ),
                                        )
                                        .toList(),
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(() => _format = v!),
                              ),
                              const SizedBox(height: 12),
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  _copy(
                                    '失败时使用系统语音',
                                    'Use system voice on failure',
                                    '失敗時にシステム音声',
                                  ),
                                ),
                                value: _fallback,
                                onChanged: _saving
                                    ? null
                                    : (v) => setState(() => _fallback = v),
                              ),
                              if (_editingId != null &&
                                  widget.service.cloudProfiles.length > 1)
                                TextButton(
                                  onPressed: _saving ? null : _delete,
                                  child: Text(
                                    _copy('删除配置', 'Delete voice', '設定を削除'),
                                  ),
                                ),
                              if (_hasProfileKey)
                                TextButton(
                                  onPressed: _saving
                                      ? null
                                      : () => setState(
                                          () => _clearKey = !_clearKey,
                                        ),
                                  child: Text(
                                    _clearKey
                                        ? _copy(
                                            '保留原密钥',
                                            'Keep saved key',
                                            '保存キーを維持',
                                          )
                                        : _copy(
                                            '移除已保存的密钥',
                                            'Remove saved key',
                                            '保存キーを削除',
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _TtsChoicePage extends StatefulWidget {
  const _TtsChoicePage({
    required this.title,
    required this.options,
    required this.selected,
  });
  final String title;
  final Map<String, String> options;
  final String selected;
  @override
  State<_TtsChoicePage> createState() => _TtsChoicePageState();
}

class _TtsChoicePageState extends State<_TtsChoicePage> {
  String _query = '';
  @override
  Widget build(BuildContext context) => FloatingSubpageScaffold(
    title: widget.title,
    body: ListView(
      padding: floatingSubpagePadding(context),
      children: [
        TextField(
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: cloudTtsCopy(context, '搜索', 'Search', '検索'),
          ),
          onChanged: (v) => setState(() => _query = v.toLowerCase()),
        ),
        const SizedBox(height: 12),
        for (final entry in widget.options.entries.where(
          (e) => '${e.key} ${e.value}'.toLowerCase().contains(_query),
        ))
          ListTile(
            title: Text(entry.value),
            trailing: entry.key == widget.selected
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.pop(context, entry.key),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            cloudTtsCopy(
              context,
              '其他模型与音色可在高级自定义中输入。',
              'Enter other IDs under Advanced customization.',
              'その他の ID は詳細設定で入力できます。',
            ),
          ),
        ),
      ],
    ),
  );
}

/// Saved configurations are separate from the editor, shared by settings and player.
class CloudTtsSettingsPage extends StatefulWidget {
  const CloudTtsSettingsPage({
    super.key,
    required this.service,
    this.pauseBook,
  });
  final ReaderAloudService service;
  final Future<void> Function()? pauseBook;
  @override
  State<CloudTtsSettingsPage> createState() => _CloudTtsSettingsPageState();
}

class _CloudTtsSettingsPageState extends State<CloudTtsSettingsPage> {
  bool _loaded = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      await widget.service.initialize();
      if (mounted) {
        setState(() {
          _loaded = true;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = cloudTtsCopy(
            context,
            '加载失败，请重试',
            'Could not load. Retry.',
            '読み込みに失敗しました',
          ),
        );
      }
    }
  }

  Future<void> _edit({
    ReaderAloudCloudProfile? profile,
    ReaderAloudProviderPreset? preset,
  }) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CloudTtsEditorPage(
          service: widget.service,
          pauseBook: widget.pauseBook,
          profile: profile,
          preset: preset,
        ),
      ),
    );
    if (mounted) {
      if (saved == true) {
        Navigator.pop(context, true);
      } else {
        setState(() {});
      }
    }
  }

  Future<void> _add() async {
    final preset = await Navigator.of(context).push<ReaderAloudProviderPreset>(
      MaterialPageRoute(
        builder: (context) => FloatingSubpageScaffold(
          title: cloudTtsCopy(context, '添加语音', 'Add voice', '音声を追加'),
          body: ListView(
            padding: floatingSubpagePadding(context),
            children: [
              Text(
                cloudTtsCopy(context, '选择语音服务', 'Choose a provider', 'サービスを選択'),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              for (final preset in readerAloudProviderPresets)
                ListTile(
                  leading: const Icon(Icons.record_voice_over_outlined),
                  title: Text(preset.name),
                  subtitle: Text(preset.models.values.join(' · ')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, preset),
                ),
              const Divider(),
              ListTile(
                title: Text(
                  cloudTtsCopy(
                    context,
                    '自定义兼容服务',
                    'Custom compatible service',
                    'カスタム互換サービス',
                  ),
                ),
                subtitle: const Text('OpenAI API'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(
                  context,
                  const ReaderAloudProviderPreset(
                    'Cloud TTS',
                    ReaderAloudCloudProvider.openai,
                    '',
                    {'': '自定义'},
                    {'': '自定义'},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (preset != null && mounted) await _edit(preset: preset);
  }

  @override
  Widget build(BuildContext context) => FloatingSubpageScaffold(
    title: cloudTtsCopy(context, '云端 TTS', 'Cloud TTS', 'クラウド TTS'),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: !_loaded
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : TextButton(onPressed: _load, child: Text(_error!)),
              )
            : ListView(
                padding: floatingSubpagePadding(context),
                children: [
                  Text(
                    cloudTtsCopy(context, '我的语音', 'My voices', '保存した音声'),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    cloudTtsCopy(
                      context,
                      '为不同的书，选一副喜欢的声音。',
                      'Choose a voice for every story.',
                      '物語に合う音声を選びましょう。',
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (final p in widget.service.cloudProfiles)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        p.id == widget.service.activeProfileId
                            ? Icons.check_circle_outline
                            : Icons.record_voice_over_outlined,
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        readerAloudProviderPresets
                                .firstWhere(
                                  (v) => v.provider == p.settings.provider,
                                )
                                .voices[p.settings.voice] ??
                            p.settings.voice,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _edit(profile: p),
                    ),
                  if (!widget.service.supportsProfiles)
                    ListTile(
                      title: Text(
                        cloudTtsCopy(
                          context,
                          '当前配置',
                          'Current settings',
                          '現在の設定',
                        ),
                      ),
                      onTap: () => _edit(),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('cloud-tts-add'),
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    label: Text(
                      cloudTtsCopy(context, '添加语音配置', 'Add voice', '音声設定を追加'),
                    ),
                  ),
                ],
              ),
      ),
    ),
  );
}
