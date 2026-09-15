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
    await widget.service.initialize();
    if (!mounted) return;
    _editingId = widget.service.activeProfileId;
    _hasProfileKey = widget.service.hasCloudApiKey;
    final profiles = widget.service.cloudProfiles;
    _name.text =
        profiles.where((p) => p.id == _editingId).firstOrNull?.name ??
        'Cloud TTS';
    final settings = widget.service.cloudSettings;
    _baseUrl.text = settings.baseUrl;
    _model.text = settings.model;
    _voice.text = settings.voice;
    setState(() {
      _format = settings.responseFormat;
      _fallback = settings.fallbackToSystem;
      _loaded = true;
    });
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
          baseUrl: _baseUrl.text,
          model: _model.text,
          voice: _voice.text,
          responseFormat: _format,
          fallbackToSystem: false,
        ).normalized(),
        profileId: _editingId,
        apiKey: _apiKey.text,
        useSavedKey: !_clearKey && _editingId != null,
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

  Future<void> _editProfile(ReaderAloudCloudProfile? profile) async {
    await _stopPreview();
    final hasKey = profile == null
        ? false
        : await widget.service.profileHasKey(profile.id);
    if (!mounted) return;
    final settings = profile?.settings ?? const ReaderAloudCloudSettings();
    setState(() {
      _editingId = profile?.id;
      _name.text = profile?.name ?? '';
      _baseUrl.text = settings.baseUrl;
      _model.text = settings.model;
      _voice.text = settings.voice;
      _apiKey.clear();
      _clearKey = false;
      _hasProfileKey = hasKey;
      _format = settings.responseFormat;
      _fallback = settings.fallbackToSystem;
      _error = null;
    });
  }

  Future<void> _deleteProfile(ReaderAloudCloudProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          _copy(
            '删除「${profile.name}」？',
            'Delete “${profile.name}”?',
            '「${profile.name}」を削除しますか？',
          ),
        ),
        content: Text(
          _copy(
            '将移除此配置和保存在本机的密钥。',
            'Remove this configuration and its saved key from this device.',
            '設定と端末に保存されたキーを削除します。',
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
      if (profile.id == widget.service.activeProfileId) await _pauseBook();
      await widget.service.deleteCloudProfile(profile.id);
      await _editProfile(
        widget.service.cloudProfiles.firstWhere(
          (p) => p.id == widget.service.activeProfileId,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _copy(
            '删除失败，请重试',
            'Could not delete. Please retry.',
            '削除できませんでした。再試行してください',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _profilesSection() => ExpansionTile(
    key: const ValueKey('cloud-tts-profiles'),
    tilePadding: EdgeInsets.zero,
    title: Text(
      _copy(
        '已保存的语音（${widget.service.cloudProfiles.length}）',
        'Saved voices (${widget.service.cloudProfiles.length})',
        '保存した音声（${widget.service.cloudProfiles.length}）',
      ),
    ),
    subtitle: Text(
      _copy(
        '可添加不同服务商、模型和音色',
        'Add services, models and voices',
        'サービス・モデル・音声を追加',
      ),
    ),
    children: [
      for (final profile in widget.service.cloudProfiles)
        ListTile(
          contentPadding: EdgeInsets.zero,
          selected: profile.id == _editingId,
          leading: Icon(
            profile.id == widget.service.activeProfileId
                ? Icons.check_circle_outline
                : Icons.record_voice_over_outlined,
          ),
          title: Text(profile.name),
          subtitle: Text(
            '${profile.settings.model} · ${profile.settings.voice}',
          ),
          onTap: _saving ? null : () => _editProfile(profile),
          trailing: widget.service.cloudProfiles.length > 1
              ? IconButton(
                  tooltip: _copy('删除配置', 'Delete voice', '設定を削除'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _saving ? null : () => _deleteProfile(profile),
                )
              : null,
        ),
      TextButton.icon(
        key: const ValueKey('cloud-tts-add'),
        onPressed: _saving ? null : () => _editProfile(null),
        icon: const Icon(Icons.add),
        label: Text(_copy('添加语音配置', 'Add voice', '音声設定を追加')),
      ),
    ],
  );

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

  Widget _heading(String title, {String? subtitle}) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasKey = _hasProfileKey && !_clearKey;
    return PopScope(
      canPop: !_saving,
      child: FloatingSubpageScaffold(
        title: _copy('云端 TTS', 'Cloud TTS', 'クラウド TTS'),
        resizeToAvoidBottomInset: true,
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      padding: floatingSubpagePadding(context),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      children: [
                        if (widget.service.supportsProfiles) ...[
                          _profilesSection(),
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const ValueKey('cloud-tts-name'),
                            controller: _name,
                            enabled: !_saving && !_previewing,
                            validator: _required,
                            decoration: _decoration(
                              _copy('配置名称', 'Voice name', '設定名'),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                        Text(
                          _copy(
                            '连接语音服务，让阅读有声。',
                            'Connect a voice service for read aloud.',
                            '音声サービスに接続して読み上げます。',
                          ),
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _copy(
                            '支持 OpenAI 兼容的语音服务。可保存多套配置，试听后选择喜欢的音色。',
                            'Supports OpenAI-compatible speech services. Save multiple configurations and preview your favorite voices.',
                            'OpenAI 互換の音声サービスに対応。複数の設定を保存し、好みの音声を試聴できます。',
                          ),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                        ),
                        const SizedBox(height: 28),
                        _heading(_copy('服务连接', 'Connection', '接続')),
                        TextFormField(
                          key: const ValueKey('cloud-tts-url'),
                          controller: _baseUrl,
                          enabled: !_saving,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          validator: _validateUrl,
                          decoration: _decoration(
                            _copy('服务地址', 'Service URL', 'サービス URL'),
                            hint: 'https://api.openai.com/v1',
                            helper: _copy(
                              '填写服务商提供的 API 地址，通常以 /v1 结尾。',
                              'Use your provider’s API URL, usually ending in /v1.',
                              '通常は /v1 で終わる API URL を入力します。',
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          key: const ValueKey('cloud-tts-key'),
                          controller: _apiKey,
                          enabled: !_saving,
                          obscureText: _obscureKey,
                          enableSuggestions: false,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          decoration: _decoration(
                            'API Key',
                            hint: hasKey ? '••••••••' : null,
                            helper: hasKey
                                ? _copy(
                                    '密钥已保存，留空即可保留。',
                                    'Key saved. Leave blank to keep it.',
                                    '保存済み。空欄のままでキーを維持します。',
                                  )
                                : _clearKey
                                ? _copy(
                                    '保存时移除原密钥；填写新密钥可替换。',
                                    'Saving removes the old key; enter a new key to replace it.',
                                    '保存時に元のキーを削除します。新しいキーで置き換えられます。',
                                  )
                                : _copy(
                                    '密钥保存在本机安全存储中。',
                                    'Stored in this device’s secure storage.',
                                    'キーは端末の安全なストレージに保存されます。',
                                  ),
                            suffix: IconButton(
                              tooltip: _obscureKey
                                  ? _copy('显示密钥', 'Show key', 'キーを表示')
                                  : _copy('隐藏密钥', 'Hide key', 'キーを非表示'),
                              onPressed: _saving
                                  ? null
                                  : () => setState(
                                      () => _obscureKey = !_obscureKey,
                                    ),
                              icon: Icon(
                                _obscureKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                        ),
                        if (widget.service.hasCloudApiKey)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _saving
                                  ? null
                                  : () =>
                                        setState(() => _clearKey = !_clearKey),
                              child: Text(
                                _clearKey
                                    ? _copy(
                                        '保留原密钥',
                                        'Keep saved key',
                                        '保存済みキーを維持',
                                      )
                                    : _copy(
                                        '移除已保存的密钥',
                                        'Remove saved key',
                                        '保存済みキーを削除',
                                      ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        _heading(_copy('朗读声音', 'Reading voice', '読み上げ音声')),
                        TextFormField(
                          key: const ValueKey('cloud-tts-model'),
                          controller: _model,
                          enabled: !_saving,
                          autocorrect: false,
                          textInputAction: TextInputAction.next,
                          validator: _required,
                          decoration: _decoration(
                            _copy('语音模型', 'Speech model', '音声モデル'),
                            hint: 'gpt-4o-mini-tts',
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextFormField(
                          key: const ValueKey('cloud-tts-voice'),
                          controller: _voice,
                          enabled: !_saving,
                          autocorrect: false,
                          validator: _required,
                          decoration: _decoration(
                            _copy('音色', 'Voice', '声'),
                            hint: 'alloy',
                            helper: _copy(
                              '填写服务商支持的音色名称或 ID。',
                              'Enter a voice name or ID supported by your provider.',
                              'サービスが対応する声の名前または ID を入力します。',
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
                        Text(
                          _copy(
                            '试听使用上方配置与当前语速，可能产生服务费用。听书会先暂停。',
                            'Preview uses this configuration and current speed. Service charges may apply. Book playback pauses first.',
                            '現在の設定と速度で試聴します。料金が発生する場合があります。読み上げは一時停止します。',
                          ),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 16),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          childrenPadding: const EdgeInsets.only(top: 12),
                          shape: const Border(),
                          collapsedShape: const Border(),
                          title: Text(
                            _copy('更多选项', 'More options', '詳細設定'),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          subtitle: Text(
                            _copy(
                              '音频格式与失败处理',
                              'Audio format and fallback',
                              '音声形式とエラー時の動作',
                            ),
                          ),
                          children: [
                            DropdownButtonFormField<String>(
                              initialValue: _format,
                              isExpanded: true,
                              decoration: _decoration(
                                _copy('音频格式', 'Audio format', '音声形式'),
                              ),
                              items: [
                                for (final format in [
                                  'mp3',
                                  'opus',
                                  'aac',
                                  'flac',
                                  'wav',
                                  'pcm',
                                ])
                                  DropdownMenuItem(
                                    value: format,
                                    child: Text(format.toUpperCase()),
                                  ),
                              ],
                              onChanged: _saving
                                  ? null
                                  : (value) => setState(() => _format = value!),
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile.adaptive(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                _copy(
                                  '自动切换系统语音',
                                  'Use system voice on failure',
                                  '失敗時にシステム音声を使用',
                                ),
                              ),
                              subtitle: Text(
                                _copy(
                                  '云端服务不可用时，继续使用设备语音朗读。',
                                  'Keep reading with the device voice when the cloud service is unavailable.',
                                  'クラウドサービスが利用できない場合、端末の音声で読み上げを続けます。',
                                ),
                              ),
                              value: _fallback,
                              onChanged: _saving
                                  ? null
                                  : (value) =>
                                        setState(() => _fallback = value),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        bottomNavigationBar: !_loaded
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    16 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: TextStyle(color: scheme.error),
                            ),
                          ),
                        ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 688),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            key: const ValueKey('cloud-tts-save'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: _saving ? null : _save,
                            child: Text(
                              _saving
                                  ? _copy('正在保存…', 'Saving…', '保存中…')
                                  : widget.service.supportsProfiles
                                  ? _copy('保存并使用', 'Save and use', '保存して使用')
                                  : _copy('保存配置', 'Save settings', '設定を保存'),
                            ),
                          ),
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
