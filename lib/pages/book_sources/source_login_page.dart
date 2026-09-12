import 'package:flutter/material.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_client.dart';
import '../../book_sources/source_engine/source_browser_session.dart';
import '../../book_sources/source_engine/source_login_ui.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';

class SourceLoginPage extends StatefulWidget {
  const SourceLoginPage({super.key, required this.source, this.client});

  final RegisteredBookSource source;
  final BookSourceClient? client;

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  BookSourceClient? _ownedClient;
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _choices = {};
  List<SourceLoginField> _fields = const [];
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  BookSourceClient get _client =>
      widget.client ?? (_ownedClient ??= BookSourceClient());

  Uri? get _browserLoginUri {
    final config = widget.source.sourceConfig;
    return config == null ? null : sourceBrowserLoginUri(config);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _ownedClient?.close();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final fields = await _client.loadLoginFields(widget.source);
      for (final field in fields) {
        if (field.isInput) {
          _controllers[field.name] = TextEditingController(
            text: field.defaultValue ?? '',
          );
        } else if (field.chars.isNotEmpty) {
          _choices[field.name] = field.defaultValue ?? field.chars.first;
        } else if (field.type == 'toggle') {
          _choices[field.name] = field.defaultValue ?? 'false';
        }
      }
      if (!mounted) return;
      setState(() {
        _fields = fields;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _message(error);
        _loading = false;
      });
    }
  }

  Future<void> _login() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _client.loginSource(widget.source, {
        for (final entry in _controllers.entries) entry.key: entry.value.text,
        ..._choices,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.sourceLoginSaved)));
    } on SourceBrowserCancelled {
      // Closing the browser is an expected way to leave sign-in unchanged.
    } on Object catch (error) {
      debugPrint('[SourceLoginPage] login failed: $error');
      if (!mounted) return;
      setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _clear() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _client.clearSourceLogin(widget.source);
      if (!mounted) return;
      for (final controller in _controllers.values) {
        controller.clear();
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.sourceLoginCleared)));
    } on Object catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _message(Object error) => error is BookSourceProtocolException
      ? error.message
      : context.l10n.sourceLoginFailed('$error');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final browserLoginUri = _browserLoginUri;
    return FloatingSubpageScaffold(
      title: context.l10n.sourceLoginTitle,
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: floatingSubpagePadding(
              context,
              left: 20,
              top: 8,
              right: 20,
              bottom: 40,
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: scheme.primary,
                      foregroundColor: scheme.onPrimary,
                      child: const Icon(Icons.key_rounded),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.source.name,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            context.l10n.sourceLoginSecureStorageNotice,
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else ...[
                if (browserLoginUri != null) ...[
                  _buildBrowserLogin(browserLoginUri),
                  const SizedBox(height: 18),
                ],
                for (final field in _fields)
                  if (!field.isButton) ...[
                    _buildField(field),
                    const SizedBox(height: 13),
                  ],
                if (_fields.isEmpty && browserLoginUri == null) ...[
                  Text(
                    context.l10n.sourceLoginNoForm,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 13),
                ],
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: scheme.error)),
                  const SizedBox(height: 13),
                ],
                if (_fields.isNotEmpty) ...[
                  FilledButton.icon(
                    onPressed: _submitting ? null : _login,
                    icon: _submitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login_rounded),
                    label: Text(context.l10n.sourceLoginSave),
                  ),
                  const SizedBox(height: 8),
                ],
                TextButton.icon(
                  key: const ValueKey('source-login-clear'),
                  onPressed: _submitting ? null : _clear,
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(context.l10n.sourceLoginClear),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrowserLogin(Uri loginUri) {
    final scheme = Theme.of(context).colorScheme;
    final supported = const SourceBrowserSessionClient().isSupported;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.sourceLoginBrowserTitle,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SelectableText(
            loginUri.toString(),
            key: const ValueKey('source-login-browser-url'),
            style: TextStyle(color: scheme.primary),
          ),
          const SizedBox(height: 8),
          Text(
            supported
                ? context.l10n.sourceLoginBrowserNotice
                : context.l10n.sourceLoginBrowserUnsupported,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('source-login-browser-open'),
              onPressed: supported && !_submitting ? _login : null,
              icon: _submitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded),
              label: Text(context.l10n.sourceLoginBrowserOpen),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildField(SourceLoginField field) {
    final label = field.viewName ?? field.name;
    if (field.chars.isNotEmpty) {
      return DropdownButtonFormField<String>(
        initialValue: _choices[field.name],
        decoration: InputDecoration(labelText: label),
        items: [
          for (final value in field.chars)
            DropdownMenuItem(value: value, child: Text(value)),
        ],
        onChanged: (value) {
          if (value != null) setState(() => _choices[field.name] = value);
        },
      );
    }
    if (field.type == 'toggle') {
      final enabled = _choices[field.name] == 'true';
      return SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: enabled,
        onChanged: (value) =>
            setState(() => _choices[field.name] = value ? 'true' : 'false'),
      );
    }
    return TextField(
      controller: _controllers[field.name],
      obscureText: field.type == 'password',
      enableSuggestions: field.type != 'password',
      autocorrect: false,
      decoration: InputDecoration(labelText: label),
    );
  }
}
