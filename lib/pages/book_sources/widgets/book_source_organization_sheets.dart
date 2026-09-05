import 'package:flutter/material.dart';

import '../../../book_sources/models/registered_book_source.dart';
import '../../../book_sources/services/book_source_registry.dart';
import 'book_source_organization_copy.dart';

Future<bool> showBookSourceGroupEditor(
  BuildContext context, {
  required BookSourceRegistry registry,
  required List<RegisteredBookSource> sources,
}) async {
  if (sources.isEmpty) return false;
  return await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => FractionallySizedBox(
          heightFactor: 0.82,
          child: _BookSourceGroupEditor(registry: registry, sources: sources),
        ),
      ) ??
      false;
}

Future<void> showBookSourceGroupManager(
  BuildContext context, {
  required BookSourceRegistry registry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.82,
      child: _BookSourceGroupManager(registry: registry),
    ),
  );
}

Future<String?> showBookSourceOrganizationGroupPicker(
  BuildContext context, {
  required BookSourceRegistry registry,
  String? selected,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.72,
      child: _BookSourceGroupPicker(registry: registry, selected: selected),
    ),
  );
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (subtitle case final subtitle?) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          trailing ??
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
        ],
      ),
    );
  }
}

class _BookSourceGroupEditor extends StatefulWidget {
  const _BookSourceGroupEditor({required this.registry, required this.sources});

  final BookSourceRegistry registry;
  final List<RegisteredBookSource> sources;

  @override
  State<_BookSourceGroupEditor> createState() => _BookSourceGroupEditorState();
}

class _BookSourceGroupEditorState extends State<_BookSourceGroupEditor> {
  final TextEditingController _search = TextEditingController();
  final Map<String, bool> _changes = {};
  final List<String> _newGroups = [];
  List<String>? _groups;
  Object? _loadError;
  bool _saving = false;
  String _query = '';
  late List<RegisteredBookSource> _sources = widget.sources;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        widget.registry.loadGroups(),
        widget.registry.load(),
      ]);
      if (!mounted) return;
      final loaded = results[0] as List<String>;
      final currentSources = results[1] as List<RegisteredBookSource>;
      final currentById = {
        for (final source in currentSources) source.id: source,
      };
      _sources = [
        for (final source in widget.sources) currentById[source.id] ?? source,
      ];
      final sourceGroups = _sources.expand((source) => source.groups);
      setState(() {
        _groups = _orderedUnion(loaded, sourceGroups);
        _loadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  bool? _valueFor(String group) {
    if (_changes.containsKey(group)) return _changes[group];
    final count = _sources
        .where((source) => source.groups.contains(group))
        .length;
    if (count == 0) return false;
    if (count == _sources.length) return true;
    return null;
  }

  void _toggle(String group, bool? current) {
    setState(() => _changes[group] = current != true);
  }

  Future<void> _newGroup() async {
    final groups = _groups;
    if (groups == null) return;
    final name = await _promptGroupName(context, existing: groups);
    if (name == null || !mounted) return;
    setState(() {
      groups.add(name);
      _newGroups.add(name);
      _changes[name] = true;
      _query = '';
      _search.clear();
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      for (final group in _newGroups) {
        await widget.registry.createGroup(group);
      }
      final added = _changes.entries
          .where((entry) => entry.value)
          .map((entry) => entry.key)
          .toList(growable: false);
      final removed = _changes.entries
          .where((entry) => !entry.value)
          .map((entry) => entry.key)
          .toList(growable: false);
      if (added.isNotEmpty || removed.isNotEmpty) {
        await widget.registry.updateGroups(
          widget.sources.map((source) => source.id),
          added: added,
          removed: removed,
        );
      }
      if (mounted) {
        Navigator.of(context).pop(_newGroups.isNotEmpty || _changes.isNotEmpty);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(BookSourceOrganizationCopy.of(context).saveFailed),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = BookSourceOrganizationCopy.of(context);
    final groups = _groups;
    final query = _query.trim().toLowerCase();
    final visible = groups
        ?.where((group) => query.isEmpty || group.toLowerCase().contains(query))
        .toList(growable: false);
    final subtitle = widget.sources.length == 1
        ? widget.sources.single.name
        : copy.selectedSourceCount(widget.sources.length);

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _SheetHeader(
            title: copy.addToGroups,
            subtitle: subtitle,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  key: const Key('bookSourceGroupEditorCancel'),
                  onPressed: _saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: Text(copy.cancel),
                ),
                TextButton(
                  key: const Key('bookSourceGroupEditorDone'),
                  onPressed: _saving || groups == null ? null : _save,
                  child: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(copy.done),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              key: const Key('bookSourceGroupSearch'),
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: copy.searchGroups,
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
          Expanded(
            child: switch ((groups, _loadError)) {
              (_, Object()) => Center(
                child: FilledButton.tonalIcon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(copy.retry),
                ),
              ),
              (null, _) => const Center(child: CircularProgressIndicator()),
              (_, _) when visible!.isEmpty => Center(
                child: Text(copy.noGroups),
              ),
              _ => ListView.builder(
                key: const Key('bookSourceGroupEditorList'),
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final group = visible[index];
                  final value = _valueFor(group);
                  return CheckboxListTile(
                    key: ValueKey('bookSourceGroupChoice-$group'),
                    value: value,
                    tristate: true,
                    onChanged: _saving ? null : (_) => _toggle(group, value),
                    secondary: const Icon(Icons.folder_outlined),
                    title: Text(group),
                    subtitle: value == null ? Text(copy.mixedSelection) : null,
                    controlAffinity: ListTileControlAffinity.trailing,
                  );
                },
              ),
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('bookSourceGroupEditorCreate'),
                onPressed: _saving || groups == null ? null : _newGroup,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(copy.newGroup),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookSourceGroupManager extends StatefulWidget {
  const _BookSourceGroupManager({required this.registry});

  final BookSourceRegistry registry;

  @override
  State<_BookSourceGroupManager> createState() =>
      _BookSourceGroupManagerState();
}

class _BookSourceGroupManagerState extends State<_BookSourceGroupManager> {
  List<String>? _groups;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final groups = await widget.registry.loadGroups();
    if (mounted) setState(() => _groups = groups.toList());
  }

  Future<void> _create() async {
    final groups = _groups;
    if (groups == null) return;
    final name = await _promptGroupName(context, existing: groups);
    if (name == null || !mounted) return;
    await _mutate(() async {
      await widget.registry.createGroup(name);
      groups.add(name);
    });
  }

  Future<void> _rename(String oldName) async {
    final groups = _groups;
    if (groups == null) return;
    final name = await _promptGroupName(
      context,
      existing: groups,
      initialValue: oldName,
    );
    if (name == null || name == oldName || !mounted) return;
    await _mutate(() async {
      await widget.registry.renameGroup(oldName, name);
      groups[groups.indexOf(oldName)] = name;
    });
  }

  Future<void> _delete(String name) async {
    final copy = BookSourceOrganizationCopy.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(copy.deleteGroupTitle),
        content: Text(copy.deleteGroupMessage(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(copy.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(copy.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mutate(() async {
      await widget.registry.deleteGroup(name);
      _groups!.remove(name);
    });
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    setState(() => _busy = true);
    try {
      await operation();
      if (mounted) setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(BookSourceOrganizationCopy.of(context).saveFailed),
        ),
      );
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (_busy || _groups == null) return;
    final previous = List<String>.of(_groups!);
    setState(() {
      final item = _groups!.removeAt(oldIndex);
      _groups!.insert(newIndex, item);
      _busy = true;
    });
    try {
      await widget.registry.reorderGroups(_groups!);
      if (mounted) setState(() => _busy = false);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _groups = previous;
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(BookSourceOrganizationCopy.of(context).saveFailed),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = BookSourceOrganizationCopy.of(context);
    final groups = _groups;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _SheetHeader(title: copy.manageGroups),
          Expanded(
            child: groups == null
                ? const Center(child: CircularProgressIndicator())
                : groups.isEmpty
                ? Center(child: Text(copy.noGroups))
                : ReorderableListView.builder(
                    key: const Key('bookSourceGroupManagerList'),
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: groups.length,
                    onReorderItem: _reorder,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      return ListTile(
                        key: ValueKey('bookSourceManagedGroup-$group'),
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(group),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: copy.rename,
                              onPressed: _busy ? null : () => _rename(group),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: copy.delete,
                              onPressed: _busy ? null : () => _delete(group),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: Tooltip(
                                message: copy.dragToReorder,
                                child: const SizedBox.square(
                                  dimension: 44,
                                  child: Icon(Icons.drag_handle_rounded),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('bookSourceGroupManagerCreate'),
                onPressed: _busy || groups == null ? null : _create,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(copy.newGroup),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BookSourceGroupPicker extends StatefulWidget {
  const _BookSourceGroupPicker({required this.registry, this.selected});

  final BookSourceRegistry registry;
  final String? selected;

  @override
  State<_BookSourceGroupPicker> createState() => _BookSourceGroupPickerState();
}

class _BookSourceGroupPickerState extends State<_BookSourceGroupPicker> {
  final TextEditingController _search = TextEditingController();
  List<String>? _groups;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final groups = await widget.registry.loadGroups();
    if (mounted) setState(() => _groups = groups);
  }

  Future<void> _manage() async {
    await showBookSourceGroupManager(context, registry: widget.registry);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final copy = BookSourceOrganizationCopy.of(context);
    final query = _query.trim().toLowerCase();
    final visible = _groups
        ?.where((group) => query.isEmpty || group.toLowerCase().contains(query))
        .toList(growable: false);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _SheetHeader(title: copy.groups),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              key: const Key('bookSourceGroupPickerSearch'),
              controller: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                hintText: copy.searchGroups,
                prefixIcon: const Icon(Icons.search_rounded),
              ),
            ),
          ),
          Expanded(
            child: visible == null
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? Center(child: Text(copy.noGroups))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final group = visible[index];
                      return ListTile(
                        key: ValueKey('bookSourceGroupPicker-$group'),
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(group),
                        trailing: group == widget.selected
                            ? const Icon(Icons.check_rounded)
                            : null,
                        selected: group == widget.selected,
                        onTap: () => Navigator.of(context).pop(group),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const Key('bookSourceGroupPickerManage'),
                onPressed: _manage,
                icon: const Icon(Icons.settings_outlined),
                label: Text(copy.manageGroups),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _promptGroupName(
  BuildContext context, {
  required List<String> existing,
  String? initialValue,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) =>
        _GroupNameDialog(existing: existing, initialValue: initialValue),
  );
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog({required this.existing, this.initialValue});

  final List<String> existing;
  final String? initialValue;

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = BookSourceOrganizationCopy.of(context);
    return AlertDialog(
      title: Text(widget.initialValue == null ? copy.newGroup : copy.rename),
      content: Form(
        key: _formKey,
        child: TextFormField(
          key: const Key('bookSourceGroupNameField'),
          controller: _controller,
          autofocus: true,
          maxLength: 40,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: copy.groupName),
          validator: (value) {
            final name = value?.trim() ?? '';
            if (name.isEmpty) return copy.groupNameRequired;
            if (name != widget.initialValue && widget.existing.contains(name)) {
              return copy.groupAlreadyExists;
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(copy.cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initialValue == null ? copy.create : copy.done),
        ),
      ],
    );
  }
}

List<String> _orderedUnion(Iterable<String> first, Iterable<String> second) {
  final seen = <String>{};
  return [
    for (final value in [...first, ...second])
      if (value.trim().isNotEmpty && seen.add(value)) value,
  ];
}
