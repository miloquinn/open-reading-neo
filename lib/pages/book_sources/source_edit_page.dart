import 'package:flutter/material.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_registry.dart';
import '../../book_sources/source_engine/source_config.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import 'models/source_edit_draft.dart';
import 'models/source_edit_fields.dart';
import 'source_debug_page.dart';

class SourceEditPage extends StatefulWidget {
  const SourceEditPage({super.key, required this.source, this.registry});

  final RegisteredBookSource source;
  final BookSourceRegistry? registry;

  @override
  State<SourceEditPage> createState() => _SourceEditPageState();
}

class _SourceEditPageState extends State<SourceEditPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final SourceEditDraft _draft;
  final _controllers = <String, TextEditingController>{};
  late bool _enabled;
  late bool _explore;
  late bool _cookies;
  late int _type;
  bool _saving = false;
  bool _allowPop = false;
  bool _confirming = false;
  bool _invalid = false;
  bool _loadFailed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: sourceEditSections.length, vsync: this);
    _enabled = widget.source.enabled;
    _explore = widget.source.sourceConfig?['enabledExplore'] != false;
    _cookies = widget.source.sourceConfig?['enabledCookieJar'] == true;
    _type = 0;
    try {
      _draft = SourceEditDraft(widget.source);
      _type = ReadingSourceConfig.fromJson(widget.source.sourceConfig!).type;
      for (final section in sourceEditSections) {
        for (final field in section.fields) {
          _controllers[field.id] = TextEditingController(
            text: _draft.text(field),
          )..addListener(_changed);
        }
      }
    } on Object {
      _loadFailed = true;
    }
  }

  void _changed() => setState(() => _error = null);

  bool get _dirty {
    if (_loadFailed) return false;
    final original = ReadingSourceConfig.fromJson(widget.source.sourceConfig!);
    if (_enabled != widget.source.enabled ||
        _explore != original.enabledExplore ||
        _cookies != original.enabledCookieJar ||
        _type != original.type) {
      return true;
    }
    return sourceEditSections.any(
      (section) => section.fields.any(
        (field) => _controllers[field.id]!.text != _draft.text(field),
      ),
    );
  }

  Map<String, dynamic>? _configuration() {
    final copy = SourceEditCopy.of(context);
    if (_controllers['bookSourceName']!.text.trim().isEmpty ||
        _controllers['bookSourceUrl']!.text.trim().isEmpty) {
      setState(() => _invalid = true);
      _tabs.animateTo(0);
      return null;
    }
    try {
      return _draft.build(
        values: _controllers.map(
          (key, controller) => MapEntry(key, controller.text),
        ),
        enabled: _enabled,
        enabledExplore: _explore,
        enabledCookieJar: _cookies,
        type: _type,
      );
    } on Object {
      setState(() => _error = copy.invalidConfig);
      return null;
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final config = _configuration();
    if (config == null) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await (widget.registry ?? BookSourceRegistry()).updateReadingSource(
        widget.source.id,
        config,
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          final copy = SourceEditCopy.of(context);
          _error = error is ReadingSourceEditConflictException
              ? copy.duplicateUrl
              : copy.saveFailed;
        });
      }
      return;
    }
    await _close(true);
  }

  Future<void> _debug() async {
    final config = _configuration();
    if (config == null) return;
    final source = ReadingSourceConfig.fromJson(config).toRegisteredSource(
      id: widget.source.id,
      addedAt: widget.source.addedAt,
      enabled: true,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SourceDebugPage(source: source)),
    );
  }

  Future<void> _close(bool saved) async {
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(saved);
  }

  Future<void> _back() async {
    if (_saving || _confirming) return;
    if (!_dirty) {
      await _close(false);
      return;
    }
    _confirming = true;
    final copy = SourceEditCopy.of(context);
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(copy.discardTitle),
        content: Text(copy.discardMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(copy.keepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(copy.discard),
          ),
        ],
      ),
    );
    _confirming = false;
    if (discard == true) await _close(false);
  }

  @override
  void dispose() {
    _tabs.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = SourceEditCopy.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope<bool>(
      canPop: _allowPop || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: FloatingSubpageScaffold(
        title: copy.edit,
        onBack: _back,
        actions: [
          IconButton(
            key: const Key('sourceEditDebug'),
            tooltip: copy.debug,
            onPressed: _loadFailed || _saving ? null : _debug,
            icon: const Icon(Icons.bug_report_outlined),
          ),
        ],
        bottomNavigationBar: _loadFailed
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Center(
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('sourceEditSave'),
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.check_rounded),
                          label: Text(copy.save),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        body: Padding(
          padding: EdgeInsets.only(
            top: FloatingSubpageScaffold.headerExtentOf(context),
          ),
          child: _loadFailed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(copy.invalidConfig),
                  ),
                )
              : Column(
                  children: [
                    TabBar(
                      controller: _tabs,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        for (final section in sourceEditSections)
                          Tab(text: section.label(context)),
                      ],
                    ),
                    if (_error != null)
                      Container(
                        width: double.infinity,
                        color: scheme.errorContainer,
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    Expanded(
                      child: AbsorbPointer(
                        absorbing: _saving,
                        child: TabBarView(
                          controller: _tabs,
                          children: [
                            for (var i = 0; i < sourceEditSections.length; i++)
                              _section(i),
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

  Widget _section(int index) {
    final fields = sourceEditSections[index].fields;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 752),
        child: ListView.builder(
          key: PageStorageKey('sourceEditSection$index'),
          padding: const EdgeInsets.all(16),
          itemCount: fields.length + (index == 0 ? 1 : 0),
          itemBuilder: (context, position) {
            if (index == 0 && position == 0) return _options();
            return _field(fields[position - (index == 0 ? 1 : 0)]);
          },
        ),
      ),
    );
  }

  Widget _options() {
    final copy = SourceEditCopy.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(copy.basicHint, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            key: const Key('sourceEditType'),
            initialValue: _type,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: copy.type,
              border: const OutlineInputBorder(),
            ),
            items: [
              for (final value in {
                ...List.generate(5, (index) => index),
                _type,
              })
                DropdownMenuItem(
                  value: value,
                  child: Text(copy.typeLabel(value)),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: Text(copy.enabled),
                selected: _enabled,
                onSelected: (value) => setState(() => _enabled = value),
              ),
              FilterChip(
                label: Text(copy.explore),
                selected: _explore,
                onSelected: (value) => setState(() => _explore = value),
              ),
              FilterChip(
                label: Text(copy.cookies),
                selected: _cookies,
                onSelected: (value) => setState(() => _cookies = value),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(SourceEditField field) {
    final copy = SourceEditCopy.of(context);
    final controller = _controllers[field.id]!;
    final error = _invalid && controller.text.trim().isEmpty
        ? switch (field.id) {
            'bookSourceName' => copy.requiredName,
            'bookSourceUrl' => copy.requiredUrl,
            _ => null,
          }
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            field.label(context),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            field.key,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('sourceEdit.${field.id}'),
            controller: controller,
            minLines: 1,
            maxLines: field.multiline ? 8 : 1,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: field.multiline
                ? TextInputType.multiline
                : TextInputType.text,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              filled: true,
              fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
              errorText: error,
            ),
          ),
        ],
      ),
    );
  }
}
