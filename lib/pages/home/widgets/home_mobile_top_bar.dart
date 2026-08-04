// 文件说明：移动端首页顶部栏组件，承载品牌展示与顶部操作入口。
// 技术要点：Flutter UI、渲染层。

import 'package:flutter/material.dart';

import 'package:xxread/widgets/glass_top_bar.dart';

import '../home_mobile_chrome.dart';

/// 手机首页顶部毛玻璃标题栏。
///
/// 只负责显示标题和视觉样式，不处理页面业务逻辑。
class HomeMobileTopBar extends StatelessWidget {
  final String title;
  final Widget? leading;
  final Widget? trailing;
  final double titleFontSize;
  final FontWeight titleFontWeight;
  final double horizontalPadding;

  const HomeMobileTopBar({
    super.key,
    required this.title,
    this.leading,
    this.trailing,
    this.titleFontSize = 34,
    this.titleFontWeight = FontWeight.w700,
    this.horizontalPadding = 16,
  });

  @override
  Widget build(BuildContext context) => GlassTopBar(
    title: title,
    leading: leading,
    trailing: trailing,
    systemTopInset: HomeMobileChromeScope.of(context).systemTopInset,
    contentHeight: HomeMobileChromeScope.of(context).topBarContentHeight,
    titleFontSize: titleFontSize,
    titleFontWeight: titleFontWeight,
    horizontalPadding: horizontalPadding,
  );
}
