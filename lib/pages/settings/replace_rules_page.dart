import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:xxread/services/reader/replace_rule_service.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/side_toast.dart';

class ReplaceRulesPage extends StatefulWidget {
  const ReplaceRulesPage({super.key});

  @override
  State<ReplaceRulesPage> createState() => _ReplaceRulesPageState();
}

class _ReplaceRulesPageState extends State<ReplaceRulesPage> {
  final _service = ReplaceRuleService.instance;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_service.load());
    _service.addListener(_onRulesChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onRulesChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onRulesChanged() {
    if (mounted) setState(() {});
  }

  List<ReplaceRule> get _visibleRules {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return _service.rules;
    return _service.rules
        .where(
          (rule) => '${rule.name} ${rule.pattern} ${rule.group}'
              .toLowerCase()
              .contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _edit([ReplaceRule? rule]) async {
    final result = await showModalBottomSheet<ReplaceRule>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => _ReplaceRuleEditor(rule: rule),
    );
    if (result == null) return;
    try {
      await _service.upsert(result);
    } catch (error) {
      if (mounted) _showMessage(_localizedError(error), SideToastKind.error);
    }
  }

  Future<void> _import() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (!mounted) return;
    final file = result?.files.single;
    if (file == null) return;
    if (file.size > ReplaceRuleService.maxImportBytes) {
      _showMessage(
        context.l10n.replaceRulesImportTooLarge('8 MiB'),
        SideToastKind.warning,
      );
      return;
    }
    final bytes = file.bytes;
    if (bytes == null) return;
    try {
      final imported = ReplaceRuleService.decodeImport(utf8.decode(bytes));
      final merged = _service.mergeImported(imported);
      await _service.saveAll(merged);
      if (mounted) {
        _showMessage(
          context.l10n.replaceRulesImported(imported.length),
          SideToastKind.success,
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage(
          context.l10n.replaceRulesImportFailed(_localizedError(error)),
          SideToastKind.error,
        );
      }
    }
  }

  Future<void> _export() async {
    final bytes = utf8.encode(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(_service.rules.map((rule) => rule.toJson()).toList()),
    );
    final path = await FilePicker.saveFile(
      dialogTitle: context.l10n.replaceRulesExport,
      fileName: 'open-reading-replace-rules.json',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: Uint8List.fromList(bytes),
    );
    if (!kIsWeb && (path == null || path.isEmpty)) return;
    if (mounted) {
      _showMessage(context.l10n.replaceRulesExported, SideToastKind.success);
    }
  }

  Future<void> _toggle(ReplaceRule rule, bool enabled) async {
    try {
      await _service.toggle(rule.id, enabled);
    } catch (error) {
      if (mounted) _showMessage(_localizedError(error), SideToastKind.error);
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final next = [..._service.rules];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    try {
      await _service.saveAll(next);
    } catch (error) {
      if (mounted) _showMessage(_localizedError(error), SideToastKind.error);
    }
  }

  String _localizedError(Object error) {
    final l10n = context.l10n;
    if (error is ReplaceRuleValidationException) {
      return switch (error.kind) {
        ReplaceRuleValidationKind.emptyPattern =>
          l10n.replaceRulesPatternRequired,
        ReplaceRuleValidationKind.patternTooLong =>
          l10n.replaceRulesPatternTooLong(ReplaceRuleService.maxPatternLength),
        ReplaceRuleValidationKind.invalidRegex => l10n.replaceRulesInvalidRegex(
          error.message,
        ),
        ReplaceRuleValidationKind.tooManyRules => l10n.replaceRulesTooMany(
          ReplaceRuleService.maxRules,
        ),
      };
    }
    return error.toString().replaceFirst('FormatException: ', '');
  }

  void _showMessage(String message, SideToastKind kind) {
    showSideToast(context, message, kind: kind);
  }

  @override
  Widget build(BuildContext context) {
    final rules = _visibleRules;
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.replaceRulesTitle,
      actions: [
        FloatingSubpageMenuButton<_ReplaceRulesMenuAction>(
          key: const ValueKey('replaceRulesToolButton'),
          tooltip: l10n.replaceRulesTitle,
          icon: Icons.tune_rounded,
          items: [
            FloatingSubpageMenuItem(
              value: _ReplaceRulesMenuAction.import,
              child: ListTile(
                leading: const Icon(Icons.file_upload_outlined),
                title: Text(l10n.replaceRulesImport),
              ),
            ),
            FloatingSubpageMenuItem(
              value: _ReplaceRulesMenuAction.export,
              enabled: _service.rules.isNotEmpty,
              child: ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: Text(l10n.replaceRulesExport),
              ),
            ),
          ],
          onSelected: (action) => switch (action) {
            _ReplaceRulesMenuAction.import => _import(),
            _ReplaceRulesMenuAction.export => _export(),
          },
        ),
      ],
      tools: _ReplaceRulesSearchField(
        controller: _searchController,
        query: _query,
        hintText: l10n.replaceRulesSearchHint,
        onChanged: (value) => setState(() => _query = value),
      ),
      body: Column(
        children: [
          Expanded(
            child: !_service.isLoaded
                ? const Center(child: CircularProgressIndicator())
                : rules.isEmpty
                ? _EmptyRules(
                    title: _query.trim().isEmpty
                        ? l10n.replaceRulesEmptyTitle
                        : l10n.replaceRulesNoSearchResults,
                    body: _query.trim().isEmpty
                        ? l10n.replaceRulesEmptyBody
                        : null,
                    onCreate: _query.trim().isEmpty ? () => _edit() : null,
                  )
                : _buildRuleList(rules),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(l10n.replaceRulesCreate),
      ),
    );
  }

  Widget _buildRuleList(List<ReplaceRule> rules) {
    final reorderable = _query.trim().isEmpty;
    final list = ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: rules.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final rule = rules[index];
        return KeyedSubtree(
          key: ValueKey(rule.id),
          child: _buildRuleCard(rule, index, reorderable),
        );
      },
    );
    if (!reorderable) return list;
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: rules.length,
      onReorderItem: _reorder,
      buildDefaultDragHandles: false,
      itemBuilder: (context, index) {
        final rule = rules[index];
        return KeyedSubtree(
          key: ValueKey(rule.id),
          child: Padding(
            padding: EdgeInsets.only(bottom: index == rules.length - 1 ? 0 : 8),
            child: _buildRuleCard(rule, index, true),
          ),
        );
      },
    );
  }

  Widget _buildRuleCard(ReplaceRule rule, int index, bool reorderable) {
    final l10n = context.l10n;
    return Card(
      child: ListTile(
        onTap: () => _edit(rule),
        leading: Icon(
          rule.enabled
              ? Icons.find_replace_rounded
              : Icons.pause_circle_outline,
        ),
        title: Text(
          rule.name.trim().isEmpty ? l10n.replaceRulesUnnamed : rule.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${rule.pattern} → ${rule.replacement.isEmpty ? l10n.replaceRulesDeleteValue : rule.replacement}'
          '${rule.group.isEmpty ? '' : ' · ${rule.group}'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch.adaptive(
              value: rule.enabled,
              onChanged: (value) => _toggle(rule, value),
            ),
            if (reorderable)
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsetsDirectional.only(start: 4),
                  child: Icon(Icons.drag_handle),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _ReplaceRulesMenuAction { import, export }

class _ReplaceRulesSearchField extends StatelessWidget {
  const _ReplaceRulesSearchField({
    required this.controller,
    required this.query,
    required this.hintText,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String query;
  final String hintText;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: TextField(
        key: const ValueKey('replaceRulesSearchField'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: Icon(
            Icons.search_rounded,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.78),
          ),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
          filled: true,
          fillColor: scheme.surfaceContainerLow.withValues(alpha: 0.72),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.46),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.46),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: scheme.primary, width: 1.2),
          ),
        ),
      ),
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules({required this.title, this.body, this.onCreate});
  final String title;
  final String? body;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.filter_alt_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 18)),
          if (body != null) ...[
            const SizedBox(height: 8),
            Text(body!, textAlign: TextAlign.center),
          ],
          if (onCreate != null) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: Text(context.l10n.replaceRulesCreate),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ReplaceRuleEditor extends StatefulWidget {
  const _ReplaceRuleEditor({this.rule});
  final ReplaceRule? rule;

  @override
  State<_ReplaceRuleEditor> createState() => _ReplaceRuleEditorState();
}

class _ReplaceRuleEditorState extends State<_ReplaceRuleEditor> {
  late final TextEditingController _name;
  late final TextEditingController _pattern;
  late final TextEditingController _replacement;
  late final TextEditingController _group;
  late final TextEditingController _scope;
  late final TextEditingController _excludeScope;
  late bool _isRegex;
  late bool _scopeTitle;
  late bool _scopeContent;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _name = TextEditingController(text: rule?.name ?? '');
    _pattern = TextEditingController(text: rule?.pattern ?? '');
    _replacement = TextEditingController(text: rule?.replacement ?? '');
    _group = TextEditingController(text: rule?.group ?? '');
    _scope = TextEditingController(text: rule?.scope ?? '');
    _excludeScope = TextEditingController(text: rule?.excludeScope ?? '');
    _isRegex = rule?.isRegex ?? true;
    _scopeTitle = rule?.scopeTitle ?? false;
    _scopeContent = rule?.scopeContent ?? true;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _pattern,
      _replacement,
      _group,
      _scope,
      _excludeScope,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final rule = ReplaceRule(
      id: widget.rule?.id ?? '${DateTime.now().microsecondsSinceEpoch}',
      name: _name.text.trim(),
      pattern: _pattern.text,
      replacement: _replacement.text,
      group: _group.text.trim(),
      scope: _scope.text.trim(),
      excludeScope: _excludeScope.text.trim(),
      enabled: widget.rule?.enabled ?? true,
      isRegex: _isRegex,
      scopeTitle: _scopeTitle,
      scopeContent: _scopeContent,
      order: widget.rule?.order ?? 0,
    );
    try {
      ReplaceRuleService.validate(rule);
      Navigator.of(context).pop(rule);
    } catch (error) {
      showSideToast(context, _localizedError(error), kind: SideToastKind.error);
    }
  }

  String _localizedError(Object error) {
    final l10n = context.l10n;
    if (error is ReplaceRuleValidationException) {
      return switch (error.kind) {
        ReplaceRuleValidationKind.emptyPattern =>
          l10n.replaceRulesPatternRequired,
        ReplaceRuleValidationKind.patternTooLong =>
          l10n.replaceRulesPatternTooLong(ReplaceRuleService.maxPatternLength),
        ReplaceRuleValidationKind.invalidRegex => l10n.replaceRulesInvalidRegex(
          error.message,
        ),
        ReplaceRuleValidationKind.tooManyRules => l10n.replaceRulesTooMany(
          ReplaceRuleService.maxRules,
        ),
      };
    }
    return error.toString().replaceFirst('FormatException: ', '');
  }

  Future<void> _delete() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.replaceRulesDeleteConfirmTitle),
        content: Text(l10n.replaceRulesDeleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.replaceRulesDeleteValue),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await ReplaceRuleService.instance.remove(widget.rule!.id);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        showSideToast(
          context,
          _localizedError(error),
          kind: SideToastKind.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: FractionallySizedBox(
        heightFactor: 0.92,
        alignment: Alignment.bottomCenter,
        child: Material(
          key: const ValueKey('replace-rule-editor-sheet'),
          color: scheme.surface,
          surfaceTintColor: Colors.transparent,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                key: const ValueKey('replace-rule-editor-drag-handle'),
                width: 42,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 10, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.rule == null
                            ? l10n.replaceRulesCreateTitle
                            : l10n.replaceRulesEditTitle,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  key: const ValueKey('replace-rule-editor-fields'),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  children: [
                    TextField(
                      controller: _name,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l10n.replaceRulesNameLabel,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pattern,
                      minLines: 2,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: l10n.replaceRulesPatternLabel,
                        helperText: l10n.replaceRulesPatternHelper,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _replacement,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        labelText: l10n.replaceRulesReplacementLabel,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.replaceRulesRegexLabel),
                      value: _isRegex,
                      onChanged: (value) => setState(() => _isRegex = value),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.replaceRulesScopeTitleLabel),
                      value: _scopeTitle,
                      onChanged: (value) =>
                          setState(() => _scopeTitle = value ?? false),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.replaceRulesScopeContentLabel),
                      value: _scopeContent,
                      onChanged: (value) =>
                          setState(() => _scopeContent = value ?? true),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _group,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l10n.replaceRulesGroupLabel,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _scope,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l10n.replaceRulesScopeLabel,
                        helperText: l10n.replaceRulesScopeHelper,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _excludeScope,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: l10n.replaceRulesExcludeScopeLabel,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Row(
                  children: [
                    if (widget.rule != null) ...[
                      OutlinedButton.icon(
                        key: const ValueKey('replace-rule-editor-delete'),
                        onPressed: _delete,
                        icon: const Icon(Icons.delete_outline),
                        label: Text(l10n.replaceRulesDeleteValue),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey('replace-rule-editor-save'),
                        onPressed: _submit,
                        icon: const Icon(Icons.check),
                        label: Text(l10n.save),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
