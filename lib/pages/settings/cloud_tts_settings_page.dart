import 'dart:async';

import 'package:flutter/material.dart';

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
  const CloudTtsSettingsPage({super.key, required this.service});

  final ReaderAloudService service;

  @override
  State<CloudTtsSettingsPage> createState() => _CloudTtsSettingsPageState();
}

class _CloudTtsSettingsPageState extends State<CloudTtsSettingsPage> {
  final _formKey = GlobalKey<FormState>();
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
      // Keep the form open on storage failure; blank input retains the key.
      if (_apiKey.text.trim().isNotEmpty) {
        await widget.service.saveCloudApiKey(_apiKey.text);
      } else if (_clearKey) {
        await widget.service.clearCloudApiKey();
      }
      await widget.service.updateCloudSettings(settings);
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
    final hasKey = widget.service.hasCloudApiKey && !_clearKey;
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
                            '支持 OpenAI 兼容的语音服务。保存后，在听书中选择「云端 TTS」即可使用。',
                            'Supports OpenAI-compatible speech services. After saving, choose Cloud TTS in the audiobook player.',
                            'OpenAI 互換の音声サービスに対応。保存後、プレーヤーでクラウド TTS を選択してください。',
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
