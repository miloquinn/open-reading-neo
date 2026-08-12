import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/source_engine/source_debug.dart';
import '../../book_sources/source_engine/source_debug_session.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';

class SourceDebugPage extends StatefulWidget {
  const SourceDebugPage({super.key, required this.source});

  final RegisteredBookSource source;

  @override
  State<SourceDebugPage> createState() => _SourceDebugPageState();
}

class _SourceDebugPageState extends State<SourceDebugPage> {
  late final SourceDebugSession _session = SourceDebugSession(widget.source);
  late final StreamSubscription<SourceDebugEvent> _subscription;
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final List<SourceDebugEvent> _events = [];
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _subscription = _session.events.listen(_onEvent);
  }

  @override
  void dispose() {
    _subscription.cancel();
    _session.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onEvent(SourceDebugEvent event) {
    if (!mounted) return;
    setState(() => _events.add(event));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  Future<void> _run() async {
    final input = _inputController.text.trim();
    if (input.isEmpty || _running) return;
    setState(() => _running = true);
    await _session.run(input);
    if (mounted) setState(() => _running = false);
  }

  void _stop() => _session.cancel();

  void _clear() => setState(() => _events.clear());

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.sourceDebugCopied)));
  }

  void _showDetail(SourceDebugEvent event) {
    final detail = event.detail;
    if (detail == null || detail.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        event.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_rounded),
                      tooltip: context.l10n.sourceDebugCopy,
                      onPressed: () => _copy(detail),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    detail,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingSubpageScaffold(
      title: context.l10n.sourceDebugTitle,
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_sweep_rounded),
          tooltip: context.l10n.sourceDebugClear,
          onPressed: _events.isEmpty ? null : _clear,
        ),
      ],
      body: Padding(
        padding: EdgeInsets.only(
          top: FloatingSubpageScaffold.headerExtentOf(context),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      textInputAction: TextInputAction.go,
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(
                        hintText: context.l10n.sourceDebugInputHint,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_running)
                    OutlinedButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(context.l10n.sourceDebugStop),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _run,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(context.l10n.sourceDebugRun),
                    ),
                ],
              ),
            ),
            if (_running) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _events.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          context.l10n.sourceDebugEmpty,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                      itemCount: _events.length,
                      itemBuilder: (context, index) =>
                          _EventTile(event: _events[index], onTap: _showDetail),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.onTap});

  final SourceDebugEvent event;
  final void Function(SourceDebugEvent event) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (event) {
      SourceDebugEvent(isError: true) => (Icons.error_rounded, scheme.error),
      SourceDebugEvent(kind: SourceDebugEventKind.stageStart) => (
        Icons.play_circle_outline_rounded,
        scheme.onSurfaceVariant,
      ),
      SourceDebugEvent(kind: SourceDebugEventKind.stageSuccess) => (
        Icons.check_circle_rounded,
        Colors.green,
      ),
      SourceDebugEvent(kind: SourceDebugEventKind.network) => (
        Icons.swap_horiz_rounded,
        scheme.primary,
      ),
      _ => (Icons.circle, scheme.onSurfaceVariant),
    };
    final hasDetail = (event.detail ?? '').isNotEmpty;
    return ListTile(
      dense: true,
      leading: Icon(icon, color: color, size: 20),
      title: Text(
        event.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: event.kind == SourceDebugEventKind.network
              ? 'monospace'
              : null,
          fontSize: 13,
        ),
      ),
      subtitle: Text(
        [
          event.stage.toUpperCase(),
          if (event.elapsed != null) '${event.elapsed!.inMilliseconds}ms',
        ].join(' · '),
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
      trailing: hasDetail
          ? Icon(
              Icons.chevron_right_rounded,
              color: scheme.onSurfaceVariant,
              size: 18,
            )
          : null,
      onTap: hasDetail ? () => onTap(event) : null,
    );
  }
}
