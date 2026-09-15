import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xxread/services/sync/sync_models.dart';
import 'package:xxread/services/sync/webdav_sync_controller.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/page_style_helper.dart';
import 'package:xxread/widgets/floating_subpage_scaffold.dart';
import 'package:xxread/widgets/side_toast.dart';

import 'webdav_sync_translator.dart';

class WebDavSyncContentPage extends StatefulWidget {
  const WebDavSyncContentPage({super.key});

  @override
  State<WebDavSyncContentPage> createState() => _WebDavSyncContentPageState();
}

class _WebDavSyncContentPageState extends State<WebDavSyncContentPage> {
  late WebDavSyncScope _scope;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _scope = context.read<WebDavSyncController>().scope;
  }

  Future<void> _updateScope(WebDavSyncScope next) async {
    if (_saving) return;
    final previous = _scope;
    setState(() {
      _scope = next;
      _saving = true;
    });
    try {
      await context.read<WebDavSyncController>().setScope(next);
    } on WebDavSyncFailure catch (error) {
      if (!mounted) return;
      setState(() => _scope = previous);
      showSideToast(
        context,
        webDavSyncErrorText(context, error.code),
        kind: SideToastKind.error,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _scope = previous);
      showSideToast(
        context,
        webDavSyncErrorText(context, WebDavSyncErrorCode.unknown),
        kind: SideToastKind.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FloatingSubpageScaffold(
      title: l10n.webDavSyncContent,
      actions: [
        if (_saving)
          const Padding(
            padding: EdgeInsets.all(10),
            child: SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
      body: ListView(
        padding: floatingSubpagePadding(context, top: 20, bottom: 40),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ScopeSection(
                    key: const ValueKey('webdav-reading-data-section'),
                    title: l10n.settingsDataSyncTitle,
                    icon: Icons.auto_stories_outlined,
                    children: [
                      _ScopeSwitch(
                        title: l10n.webDavScopeBookSources,
                        subtitle: l10n.webDavScopeBookSourcesHint,
                        icon: Icons.hub_outlined,
                        value: _scope.bookSources,
                        enabled: !_saving,
                        onChanged: (value) =>
                            _updateScope(_scope.copyWith(bookSources: value)),
                      ),
                      _ScopeSwitch(
                        title: l10n.webDavScopeBooks,
                        icon: Icons.library_books_outlined,
                        value: _scope.books,
                        enabled: !_saving,
                        onChanged: (value) =>
                            _updateScope(_scope.copyWith(books: value)),
                      ),
                      _ScopeSwitch(
                        title: l10n.webDavScopeBookmarks,
                        icon: Icons.bookmark_border_rounded,
                        value: _scope.bookmarks,
                        enabled: !_saving,
                        onChanged: (value) =>
                            _updateScope(_scope.copyWith(bookmarks: value)),
                      ),
                      _ScopeSwitch(
                        title: l10n.webDavScopeNotes,
                        subtitle: l10n.webDavScopeNotesHint,
                        icon: Icons.draw_outlined,
                        value: _scope.notes,
                        enabled: !_saving,
                        onChanged: (value) =>
                            _updateScope(_scope.copyWith(notes: value)),
                      ),
                      _ScopeSwitch(
                        title: l10n.webDavScopeReadingSessions,
                        icon: Icons.bar_chart_rounded,
                        value: _scope.readingSessions,
                        enabled: !_saving,
                        onChanged: (value) => _updateScope(
                          _scope.copyWith(readingSessions: value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _ScopeSection(
                    key: const ValueKey('webdav-reading-preferences-section'),
                    title: l10n.readingSettings,
                    icon: Icons.tune_rounded,
                    children: [
                      _ScopeSwitch(
                        title: l10n.webDavScopeReaderSettings,
                        subtitle: l10n.webDavScopeReaderSettingsHint,
                        icon: Icons.text_fields_rounded,
                        value: _scope.readerSettings,
                        enabled: !_saving,
                        onChanged: (value) => _updateScope(
                          _scope.copyWith(readerSettings: value),
                        ),
                      ),
                      _ScopeSwitch(
                        title: l10n.webDavScopeReplaceRules,
                        subtitle: l10n.webDavScopeReplaceRulesHint,
                        icon: Icons.find_replace_rounded,
                        value: _scope.replaceRules,
                        enabled: !_saving,
                        onChanged: (value) =>
                            _updateScope(_scope.copyWith(replaceRules: value)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopeSection extends StatelessWidget {
  const _ScopeSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = PageStyleHelper.palette(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 9),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        Material(
          color: palette.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: palette.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var index = 0; index < children.length; index++) ...[
                children[index],
                if (index < children.length - 1)
                  Divider(height: 1, indent: 56, color: palette.border),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ScopeSwitch extends StatelessWidget {
  const _ScopeSwitch({
    required this.title,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = PageStyleHelper.palette(context);
    return SwitchListTile.adaptive(
      contentPadding: const EdgeInsets.fromLTRB(14, 2, 10, 2),
      visualDensity: const VisualDensity(vertical: -1),
      secondary: Icon(icon, size: 22, color: palette.iconMuted),
      title: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: palette.textMuted,
                  height: 1.35,
                ),
              ),
            ),
      value: value,
      onChanged: enabled ? onChanged : null,
    );
  }
}
