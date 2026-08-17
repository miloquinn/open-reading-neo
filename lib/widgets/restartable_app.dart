// 文件说明：应用子树重建边界，供启动入口和需要应用设置即时重载的页面共享。
// 技术要点：StatefulWidget、祖先状态查找、KeyedSubtree。

import 'package:flutter/widgets.dart';

class RestartableApp extends StatefulWidget {
  const RestartableApp({super.key, required this.child});

  final Widget child;

  static void restart(BuildContext context) {
    final state = context.findAncestorStateOfType<_RestartableAppState>();
    state?.restartApp();
  }

  @override
  State<RestartableApp> createState() => _RestartableAppState();
}

class _RestartableAppState extends State<RestartableApp> {
  Key _subtreeKey = UniqueKey();

  void restartApp() {
    setState(() => _subtreeKey = UniqueKey());
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _subtreeKey, child: widget.child);
  }
}
