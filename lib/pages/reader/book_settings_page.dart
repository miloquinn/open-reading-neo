import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../library/source_book_status_card.dart';

import '../../book_sources/models/registered_book_source.dart';
import '../../book_sources/services/book_source_client.dart';
import '../../book_sources/source_engine/source_config.dart';
import '../../book_sources/source_engine/source_login_session.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';
import '../book_sources/source_login_page.dart';
import '../book_sources/widgets/book_source_text_normalizer.dart';

enum BookSettingsAction { editText, changeSource, readingSettings }

/// Reader-specific book management, separate from the discovery details page.
class BookSettingsPage extends StatefulWidget {
  const BookSettingsPage({
    super.key,
    required this.title,
    required this.author,
    required this.cover,
    required this.format,
    this.shelfBook,
    this.onBookChanged,
    this.description = '',
    this.canEditText = false,
    this.canChangeSource = false,
    this.source,
    this.client,
    this.loginSessionStore,
  });

  final ValueChanged<Book>? onBookChanged;
  final Book? shelfBook;
  final String title;
  final String author;
  final Widget cover;
  final String format;
  final String description;
  final bool canEditText;
  final bool canChangeSource;
  final RegisteredBookSource? source;
  final BookSourceClient? client;
  final SourceLoginSessionStore? loginSessionStore;

  @override
  State<BookSettingsPage> createState() => _BookSettingsPageState();
}

class _BookSettingsPageState extends State<BookSettingsPage> {
  late Book? _book = widget.shelfBook;
  RegisteredBookSource? get _source {
    try {
      return _book?.hasSourceBinding == true
          ? RegisteredBookSource.fromJson(
              jsonDecode(_book!.sourceJson!) as Map<String, dynamic>,
            )
          : widget.source;
    } catch (_) {
      return widget.source;
    }
  }

  bool _loggedIn = false;
  bool _loadingLogin = true;

  String _copy(String zh, String en, String ja) =>
      switch (Localizations.localeOf(context).languageCode) {
        'en' => en,
        'ja' => ja,
        _ => zh,
      };

  @override
  void initState() {
    super.initState();
    _refreshLogin();
  }

  Future<void> _refreshLogin() async {
    final config = _source?.sourceConfig;
    var loggedIn = false;
    try {
      if (config != null) {
        final session =
            await (widget.loginSessionStore ?? SecureSourceLoginSessionStore())
                .read(ReadingSourceConfig.fromJson(config).stableId);
        loggedIn =
            session.browserSession.active ||
            session.loginInfo.isNotEmpty ||
            session.loginHeaders.isNotEmpty;
      }
    } catch (_) {
      // Secure storage can be unavailable; keep the login entry usable.
    }
    if (mounted) {
      setState(() {
        _loggedIn = loggedIn;
        _loadingLogin = false;
      });
    }
  }

  Future<void> _login() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            SourceLoginPage(source: _source!, client: widget.client),
      ),
    );
    if (mounted) await _refreshLogin();
  }

  Widget _action(
    IconData icon,
    String title,
    BookSettingsAction action, {
    bool enabled = true,
    String? subtitle,
  }) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: const Icon(Icons.chevron_right_rounded),
    enabled: enabled,
    onTap: enabled ? () => Navigator.of(context).pop(action) : null,
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FloatingSubpageScaffold(
      key: const Key('book-settings-page'),
      title: _copy('书籍设置', 'Book settings', '書籍設定'),
      maxHeaderWidth: 800,
      body: SingleChildScrollView(
        padding: floatingSubpagePadding(context, left: 24, right: 24, top: 24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 752),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 96,
                        height: 136,
                        child: _book?.coverImagePath != null && !kIsWeb
                            ? Image.file(
                                File(_book!.coverImagePath!),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => widget.cover,
                              )
                            : widget.cover,
                      ),
                    ),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title, style: text.headlineSmall),
                          const SizedBox(height: 12),
                          Text(widget.author, style: text.bodyLarge),
                          const SizedBox(height: 12),
                          Text(
                            _source?.name ?? widget.format.toUpperCase(),
                            style: text.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 24),
                  SelectableText(
                    normalizeBookSourceDescription(widget.description),
                    style: text.bodyMedium,
                  ),
                ],
                const SizedBox(height: 28),
                if (_book != null)
                  SourceBookStatusCard(
                    book: _book!,
                    allowSourceBinding: !widget.canChangeSource,
                    onBookChanged: (book) {
                      setState(() => _book = book);
                      widget.onBookChanged?.call(book);
                      _refreshLogin();
                    },
                  ),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      _action(
                        Icons.edit_note_rounded,
                        _copy('编辑正文', 'Edit text', '本文を編集'),
                        BookSettingsAction.editText,
                        enabled: widget.canEditText,
                        subtitle: widget.canEditText
                            ? null
                            : _copy(
                                '仅本地 TXT 书籍可用',
                                'Available for local TXT books only',
                                'ローカル TXT 書籍のみ対応',
                              ),
                      ),
                      if (widget.canChangeSource)
                        _action(
                          Icons.swap_horiz_rounded,
                          context.l10n.bookSourceChangeSourceTitle,
                          BookSettingsAction.changeSource,
                        ),
                      if (_source != null)
                        ListTile(
                          leading: const Icon(Icons.account_circle_outlined),
                          title: Text(
                            _loggedIn
                                ? _copy('已登录', 'Logged in', 'ログイン済み')
                                : context.l10n.sourceLoginTitle,
                          ),
                          subtitle: _loggedIn
                              ? Text(context.l10n.sourceLoginTitle)
                              : null,
                          trailing: _loadingLogin
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: _login,
                        ),
                      _action(
                        Icons.tune_rounded,
                        context.l10n.readingSettings,
                        BookSettingsAction.readingSettings,
                      ),
                    ],
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
