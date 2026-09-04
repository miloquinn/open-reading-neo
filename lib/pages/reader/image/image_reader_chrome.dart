import 'dart:async';

import 'package:flutter/material.dart';

import 'package:xxread/utils/localization_extension.dart';
import 'package:xxread/utils/reader_themes.dart';
import 'package:xxread/widgets/reader_control_chrome.dart';

/// The single control overlay used by every comic reading direction.
class ImageReaderChrome extends StatelessWidget {
  const ImageReaderChrome({
    super.key,
    required this.palette,
    required this.visible,
    required this.title,
    required this.pageIndex,
    required this.pageCount,
    required this.directionIcon,
    required this.directionLabel,
    required this.onBack,
    required this.onPageSelected,
    required this.onDirection,
    required this.onSettings,
    this.onTableOfContents,
    this.directionKey,
    this.settingsKey,
  });

  final ReaderThemePalette palette;
  final bool visible;
  final String title;
  final int pageIndex;
  final int pageCount;
  final IconData directionIcon;
  final String directionLabel;
  final VoidCallback onBack;
  final ValueChanged<int> onPageSelected;
  final VoidCallback onDirection;
  final VoidCallback onSettings;
  final VoidCallback? onTableOfContents;
  final Key? directionKey;
  final Key? settingsKey;

  int get _displayPage =>
      pageCount > 0 ? pageIndex.clamp(0, pageCount - 1) + 1 : 0;

  Future<void> _showJumpDialog(BuildContext context) async {
    if (pageCount <= 0) return;
    final target = await showDialog<int>(
      context: context,
      builder: (dialogContext) => _ImageReaderJumpDialog(
        pageCount: pageCount,
        initialPage: _displayPage,
      ),
    );
    if (target != null) onPageSelected(target - 1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final safeTop = MediaQuery.paddingOf(context).top + 10;
    final safeBottom = MediaQuery.paddingOf(context).bottom + 16;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !visible,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: 20,
              right: 20,
              top: visible ? safeTop : -100,
              child: ReaderControlBar(
                palette: palette,
                isTopBar: true,
                child: SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      const SizedBox(width: 7),
                      ReaderControlIconButton(
                        palette: palette,
                        onPressed: onBack,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        icon: Icons.arrow_back_rounded,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () => unawaited(_showJumpDialog(context)),
                        borderRadius: BorderRadius.circular(99),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: palette.controlFill.withValues(alpha: 0.58),
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '$_displayPage / $pageCount',
                            style: TextStyle(
                              color: palette.secondaryText,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 9),
                    ],
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: 18,
              right: 18,
              bottom: visible ? safeBottom : -104,
              child: ReaderControlBar(
                palette: palette,
                isTopBar: false,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 7),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pageCount > 0)
                        SizedBox(
                          height: 30,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 38,
                                child: Semantics(
                                  label: '$_displayPage / $pageCount',
                                  excludeSemantics: true,
                                  child: Text(
                                    '$_displayPage',
                                    maxLines: 1,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: palette.accent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 6,
                                    activeTrackColor: palette.accent,
                                    inactiveTrackColor: palette.secondaryText
                                        .withValues(alpha: 0.22),
                                    thumbColor: Color.lerp(
                                      palette.accent,
                                      Colors.white,
                                      0.18,
                                    ),
                                    overlayColor: palette.accent.withValues(
                                      alpha: 0.14,
                                    ),
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7,
                                      elevation: 3,
                                      pressedElevation: 5,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 18,
                                    ),
                                    tickMarkShape:
                                        SliderTickMarkShape.noTickMark,
                                  ),
                                  child: Slider(
                                    value: _displayPage.toDouble(),
                                    min: 1,
                                    max: pageCount.toDouble().clamp(
                                      1,
                                      double.infinity,
                                    ),
                                    onChanged: (value) =>
                                        onPageSelected(value.round() - 1),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (onTableOfContents != null)
                            Expanded(
                              child: _ImageReaderChromeAction(
                                palette: palette,
                                icon: Icons.format_list_bulleted_rounded,
                                label: l10n.readerToolbarTOC,
                                onTap: onTableOfContents!,
                              ),
                            ),
                          Expanded(
                            child: _ImageReaderChromeAction(
                              key: directionKey,
                              palette: palette,
                              icon: directionIcon,
                              label: directionLabel,
                              onTap: onDirection,
                            ),
                          ),
                          Expanded(
                            child: _ImageReaderChromeAction(
                              palette: palette,
                              icon: Icons.numbers_rounded,
                              label: l10n.imageReaderJumpToPage,
                              onTap: () => unawaited(_showJumpDialog(context)),
                            ),
                          ),
                          Expanded(
                            child: _ImageReaderChromeAction(
                              key: settingsKey,
                              palette: palette,
                              icon: Icons.tune_rounded,
                              label: l10n.imageReaderSettings,
                              onTap: onSettings,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageReaderJumpDialog extends StatefulWidget {
  const _ImageReaderJumpDialog({
    required this.pageCount,
    required this.initialPage,
  });

  final int pageCount;
  final int initialPage;

  @override
  State<_ImageReaderJumpDialog> createState() => _ImageReaderJumpDialogState();
}

class _ImageReaderJumpDialogState extends State<_ImageReaderJumpDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: '${widget.initialPage}',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Theme(
      data: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.dark,
        ),
      ),
      child: AlertDialog(
        title: Text(l10n.imageReaderJumpToPage),
        content: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '1 - ${widget.pageCount}'),
          onSubmitted: (value) =>
              Navigator.of(context).pop(int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(_controller.text)),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
  }
}

class _ImageReaderChromeAction extends StatelessWidget {
  const _ImageReaderChromeAction({
    super.key,
    required this.palette,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final ReaderThemePalette palette;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 26,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: palette.text, size: 20),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.secondaryText,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
