import 'package:flutter/material.dart';

import 'package:xxread/services/core/app_settings_service.dart';
import 'package:xxread/services/core/custom_font_service.dart';
import 'package:xxread/services/core/online_font_models.dart';
import 'package:xxread/utils/font_catalog_helper.dart';
import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/widgets/side_toast.dart';

class FontSelectionSheet extends StatefulWidget {
  const FontSelectionSheet({
    super.key,
    required this.settings,
    required this.domain,
    required this.title,
    required this.description,
  });

  final AppSettingsNotifier settings;
  final FontDomain domain;
  final String title;
  final String description;

  @override
  State<FontSelectionSheet> createState() => _FontSelectionSheetState();
}

class _FontSelectionSheetState extends State<FontSelectionSheet> {
  bool _importing = false;

  AppSettingsNotifier get _settings => widget.settings;

  List<FontOption> get _builtInOptions => widget.domain == FontDomain.app
      ? FontCatalog.appFonts
      : FontCatalog.readerFonts;

  String get _selectedId => widget.domain == FontDomain.app
      ? _settings.appFontId
      : _settings.readerFontId;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_handleSettingsChanged);
  }

  @override
  void didUpdateWidget(covariant FontSelectionSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings == widget.settings) return;
    oldWidget.settings.removeListener(_handleSettingsChanged);
    _settings.addListener(_handleSettingsChanged);
  }

  void _handleSettingsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _settings.removeListener(_handleSettingsChanged);
    super.dispose();
  }

  Future<void> _importFont() async {
    setState(() => _importing = true);
    try {
      final result = await _settings.importCustomFont(widget.domain);
      if (!mounted) return;
      if (result.status == CustomFontImportStatus.cancelled) {
        setState(() => _importing = false);
        return;
      }
      Navigator.of(context).pop(result.status);
    } on CustomFontException catch (error) {
      if (!mounted) return;
      setState(() => _importing = false);
      showSideToast(
        context,
        _customFontErrorText(context, error),
        kind: SideToastKind.error,
      );
    }
  }

  Future<void> _selectFont(String id) async {
    if (widget.domain == FontDomain.app) {
      await _settings.setAppFontId(id);
    } else {
      await _settings.setReaderFontId(id);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final systemOptions = _builtInOptions
        .where((option) => !option.isOnline)
        .toList(growable: false);
    final onlineOptions = _builtInOptions
        .where((option) => option.isOnline)
        .toList(growable: false);
    final customOptions = _settings.availableCustomFonts;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 14),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurface.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 2, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.text_fields_rounded,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed:
                          _importing || !_settings.customFontImportSupported
                          ? null
                          : _importFont,
                      icon: _importing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_rounded),
                      label: Text(
                        _importing ? l10n.importingFont : l10n.importFont,
                      ),
                    ),
                  ),
                  if (!_settings.customFontImportSupported) ...[
                    const SizedBox(height: 6),
                    Text(
                      l10n.customFontImportUnsupported,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _SectionLabel(l10n.builtInFonts),
                  ...systemOptions.map(
                    (option) => _FontOptionTile(
                      settings: _settings,
                      domain: widget.domain,
                      option: option,
                      selected: option.id == _selectedId,
                      onSelect: _selectFont,
                    ),
                  ),
                  ListenableBuilder(
                    listenable: _settings.onlineFontProgressListenable,
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SectionLabel(l10n.onlineFonts),
                        ...onlineOptions.map(
                          (option) => _FontOptionTile(
                            settings: _settings,
                            domain: widget.domain,
                            option: option,
                            selected: option.id == _selectedId,
                            onSelect: _selectFont,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (customOptions.isNotEmpty) ...[
                    _SectionLabel(l10n.customFonts),
                    ...customOptions.map(
                      (option) => _FontOptionTile(
                        settings: _settings,
                        domain: widget.domain,
                        option: option,
                        selected: option.id == _selectedId,
                        onSelect: _selectFont,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _FontOptionTile extends StatelessWidget {
  const _FontOptionTile({
    required this.settings,
    required this.domain,
    required this.option,
    required this.selected,
    required this.onSelect,
  });

  final AppSettingsNotifier settings;
  final FontDomain domain;
  final FontOption option;
  final bool selected;
  final Future<void> Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colorScheme = Theme.of(context).colorScheme;
    final isDownloaded =
        !option.isOnline || settings.isOnlineFontDownloaded(option.id);
    final progress = option.isOnline
        ? settings.onlineFontProgress(option.id)
        : null;
    final isDownloading =
        progress != null &&
        (progress.status == OnlineFontDownloadStatus.downloading ||
            progress.status == OnlineFontDownloadStatus.verifying ||
            progress.status == OnlineFontDownloadStatus.registering);
    final isFailed = progress?.status == OnlineFontDownloadStatus.failed;
    final weightDescription = option.supportsVariableWeight
        ? l10n.fontVariableWeightRange(
            option.variableWeightMin!,
            option.variableWeightMax!,
          )
        : option.isOnline || option.isCustom
        ? l10n.fontStaticWeight
        : null;
    final description = _description(
      context,
      isDownloaded: isDownloaded,
      isDownloading: isDownloading,
      isFailed: isFailed,
      progress: progress,
      weightDescription: weightDescription,
    );

    Future<void> handleTap() async {
      if (option.isOnline && !isDownloaded && !isDownloading) {
        await settings.downloadOnlineFont(option.id, domain: domain);
        return;
      }
      if (!isDownloading) await onSelect(option.id);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('font-option-${option.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: handleTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? colorScheme.primary
                    : colorScheme.outline.withValues(alpha: 0.35),
                width: selected ? 1.6 : 1,
              ),
              color: selected
                  ? colorScheme.primary.withValues(alpha: 0.08)
                  : Colors.transparent,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        FontCatalog.labelFor(l10n, option),
                        style: TextStyle(
                          inherit: false,
                          fontFamily: option.family,
                          fontFamilyFallback: option.fallbackFamilies.isEmpty
                              ? null
                              : option.fallbackFamilies,
                          color: selected
                              ? colorScheme.primary
                              : colorScheme.onSurface,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (option.isOnline && !isDownloaded && !isDownloading)
                      _StatusBadge.download(l10n.fontDownload),
                    if (option.isOnline && isDownloaded && !selected)
                      _StatusBadge.downloaded(l10n.fontDownloaded),
                    if (isFailed) _StatusBadge.failed(l10n.fontDownloadFailed),
                    if (selected && isDownloaded)
                      Icon(Icons.check_circle, color: colorScheme.primary),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                if (isDownloading) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress.fraction,
                      minHeight: 4,
                      backgroundColor: colorScheme.outline.withValues(
                        alpha: 0.2,
                      ),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colorScheme.primary,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 7),
                Text(
                  l10n.fontPreviewText,
                  style: TextStyle(
                    inherit: false,
                    fontFamily: option.family,
                    fontFamilyFallback: option.fallbackFamilies.isEmpty
                        ? null
                        : option.fallbackFamilies,
                    color: colorScheme.onSurface,
                    fontSize: 15,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _description(
    BuildContext context, {
    required bool isDownloaded,
    required bool isDownloading,
    required bool isFailed,
    required OnlineFontDownloadProgress? progress,
    required String? weightDescription,
  }) {
    final l10n = context.l10n;
    final weightSuffix = weightDescription == null
        ? ''
        : ' · $weightDescription';
    if (option.isCustom) {
      return '${option.sourceFileName} · ${_formatFileSize(option.fileSize ?? 0)}$weightSuffix';
    }
    if (option.isOnline && !isDownloaded && !isDownloading && !isFailed) {
      return '${l10n.fontDownloadHint} · ${_formatFileSize(option.onlineTotalBytes)}$weightSuffix';
    }
    if (option.isOnline && isDownloading) {
      return '${l10n.fontDownloading} ${(progress!.fraction * 100).round()}%';
    }
    if (option.isOnline && isFailed) return l10n.fontDownloadFailed;
    return '${FontCatalog.descriptionFor(l10n, option)}$weightSuffix';
  }
}

enum _BadgeKind { download, downloaded, failed }

class _StatusBadge extends StatelessWidget {
  const _StatusBadge._(this.label, this.kind);

  const _StatusBadge.download(String label)
    : this._(label, _BadgeKind.download);
  const _StatusBadge.downloaded(String label)
    : this._(label, _BadgeKind.downloaded);
  const _StatusBadge.failed(String label) : this._(label, _BadgeKind.failed);

  final String label;
  final _BadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = switch (kind) {
      _BadgeKind.download => colors.primary,
      _BadgeKind.downloaded => colors.tertiary,
      _BadgeKind.failed => colors.error,
    };
    final icon = switch (kind) {
      _BadgeKind.download => Icons.cloud_download_outlined,
      _BadgeKind.downloaded => Icons.check_rounded,
      _BadgeKind.failed => Icons.error_outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: kind == _BadgeKind.download
            ? Border.all(color: color.withValues(alpha: 0.4), width: 0.8)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatFileSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

String _customFontErrorText(BuildContext context, CustomFontException error) {
  final l10n = context.l10n;
  return switch (error.code) {
    CustomFontErrorCode.unsupported => l10n.customFontImportUnsupported,
    CustomFontErrorCode.unsupportedFormat => l10n.customFontUnsupportedFormat,
    CustomFontErrorCode.invalidFont => l10n.customFontInvalid,
    CustomFontErrorCode.fileTooLarge => l10n.customFontTooLarge,
    CustomFontErrorCode.readFailed => l10n.customFontReadFailed,
    CustomFontErrorCode.loadFailed => l10n.customFontLoadFailed,
    CustomFontErrorCode.storageFailed => l10n.customFontStorageFailed,
  };
}
