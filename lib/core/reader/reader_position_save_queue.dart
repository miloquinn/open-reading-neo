// 文件说明：阅读位置持久化串行队列，防止异步数据库写入乱序覆盖新进度。
// 技术要点：Future 串行化、退出前刷新。

import 'dart:async';

class ReaderPositionSaveQueue {
  ReaderPositionSaveQueue({this.onError});

  final void Function(Object error, StackTrace stackTrace)? onError;
  Future<void> _pending = Future<void>.value();

  Future<void> enqueue(Future<void> Function() write) {
    final next = _pending.then<void>((_) async {
      try {
        await write();
      } catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
    _pending = next;
    return next;
  }

  Future<void> flush() => _pending;
}
