import 'package:flutter/material.dart';

import '../../book_sources/source_engine/source_interaction_coordinator.dart';
import '../../book_sources/source_engine/source_interactive_browser.dart';
import '../../book_sources/protocol/book_source_protocol.dart';
import '../../book_sources/source_engine/source_script_contract.dart';
import '../../utils/localization_extension.dart';
import '../../widgets/floating_subpage_scaffold.dart';

class SourceVerificationPage extends StatefulWidget {
  const SourceVerificationPage({super.key, required this.ticket});

  final SourceInteractionTicket ticket;

  @override
  State<SourceVerificationPage> createState() => _SourceVerificationPageState();
}

class _SourceVerificationPageState extends State<SourceVerificationPage> {
  final _codeController = TextEditingController();
  bool _working = false;
  bool _completed = false;
  String? _error;

  SourceScriptInteractionRequest get _request => widget.ticket.request;

  @override
  void initState() {
    super.initState();
    if (_request.kind != SourceScriptInteractionKind.verificationCode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openBrowser());
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _openBrowser() async {
    if (_working || _completed) return;
    setState(() => _working = true);
    try {
      final url = Uri.tryParse(_request.url);
      if (url == null || !url.hasAuthority) {
        throw StateError('Invalid verification URL');
      }
      final result = await const SourceInteractiveBrowser().open(
        url: url,
        headers: _request.headers,
        html: _request.html,
      );
      _complete(
        SourceScriptInteractionResult(
          body: result.body,
          finalUrl: result.finalUri.toString(),
          cookieHeader: result.cookieHeader,
        ),
      );
    } on SourceInteractiveBrowserCancelled {
      _cancel();
    } on Object catch (error) {
      if (!mounted || _completed) return;
      setState(() {
        _working = false;
        final details = error is BookSourceProtocolException
            ? error.message
            : '$error';
        _error = context.l10n.sourceVerificationFailed(details);
      });
    }
  }

  void _submitCode() {
    final value = _codeController.text.trim();
    if (value.isEmpty) return;
    _complete(SourceScriptInteractionResult(value: value));
  }

  void _complete(SourceScriptInteractionResult result) {
    if (_completed) return;
    _completed = true;
    SourceInteractionCoordinator.instance.complete(
      widget.ticket.requestId,
      result,
    );
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  void _cancel() =>
      _complete(const SourceScriptInteractionResult(cancelled: true));

  @override
  Widget build(BuildContext context) {
    final isCode =
        _request.kind == SourceScriptInteractionKind.verificationCode;
    return PopScope(
      canPop: _completed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: FloatingSubpageScaffold(
        title: _request.title.trim().isEmpty
            ? context.l10n.sourceVerificationTitle
            : _request.title,
        onBack: _cancel,
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: floatingSubpagePadding(
                context,
                left: 20,
                right: 20,
                bottom: 40,
              ),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.verified_user_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            isCode
                                ? context.l10n.sourceVerificationCodeHint
                                : context.l10n.sourceVerificationBrowserHint,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (isCode) ...[
                  const SizedBox(height: 18),
                  if (_request.imageBytes != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.memory(
                        _request.imageBytes!,
                        height: 150,
                        fit: BoxFit.contain,
                      ),
                    ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _codeController,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submitCode(),
                    decoration: InputDecoration(
                      labelText: context.l10n.sourceVerificationCodeLabel,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _submitCode,
                    icon: const Icon(Icons.check_rounded),
                    label: Text(context.l10n.sourceVerificationSubmit),
                  ),
                ] else ...[
                  const SizedBox(height: 18),
                  if (_working) const LinearProgressIndicator(),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: _openBrowser,
                      icon: const Icon(Icons.refresh_rounded),
                      label: Text(context.l10n.sourceVerificationRetry),
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.close_rounded),
                  label: Text(context.l10n.sourceVerificationCancel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
