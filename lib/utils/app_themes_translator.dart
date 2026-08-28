// 文件说明：AppTheme 和 GlassPreset 显示文案的 i18n 翻译器。
// 技术要点：Flutter 本地化。

import 'package:flutter/widgets.dart';
import '../utils/localization_extension.dart';

/// 翻译强调色 code 为用户可见名称。
String accentColorDisplayName(BuildContext context, String code) {
  final l10n = context.l10n;
  switch (code) {
    case 'blue':
      return l10n.themeBlue; // reuse theme display name
    case 'purple':
      return l10n.accentPurple;
    case 'green':
      return l10n.themeGreen;
    case 'orange':
      return l10n.themeOrange;
    case 'red':
      return l10n.themeRed;
    case 'pink':
      return l10n.accentPink;
    case 'cyan':
      return l10n.accentCyan;
    case 'teal':
      return l10n.accentCyan;
    case 'lightBlue':
      return l10n.themeBlue;
    case 'brown':
      return l10n.accentBrown;
    case 'grey':
      return l10n.accentGrey;
    case 'deepPurple':
      return l10n.accentDeepPurple;
    case 'amber':
      return l10n.accentAmber;
    case 'ochre':
      return l10n.accentAmber;
    case 'lightGreen':
      return l10n.accentLightGreen;
    case 'yellow':
      return l10n.accentYellow;
    case 'neutralGrey':
      return l10n.accentNeutralGrey;
    case 'indigo':
      return l10n.accentIndigo;
    case 'deepOrange':
      return l10n.accentDeepOrange;
    case 'rosewood':
      return l10n.accentBrown;
    case 'custom':
      return l10n.themeCustom;
    default:
      return code;
  }
}
