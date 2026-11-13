import 'package:flutter/widgets.dart';

/// 局域网续读在当前构建里被裁掉：符号保留，功能空转。
///
/// [LanSyncScope.maybeOf] 永远返回 null，页面里的入口会因此不渲染，
/// 不需要改动任何调用方（main.dart / pages.dart）。
class LanReadingSync {
  LanReadingSync({
    Object? state,
    Object? preferences,
    Object? books,
    Object? repository,
  });

  Object? get handoff => null;

  Future<void> initialize() async {}

  void dispose() {}
}

class LanSyncScope extends InheritedWidget {
  const LanSyncScope({super.key, required this.sync, required super.child});

  final LanReadingSync? sync;

  /// 恒为 null：所有「局域网续读」入口与页面因此不会被构建。
  static LanReadingSync? maybeOf(BuildContext context) => null;

  @override
  bool updateShouldNotify(LanSyncScope oldWidget) => false;
}
