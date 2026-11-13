import 'package:flutter/widgets.dart';

import 'catalog.dart';
import 'library_state.dart';

/// 一条从另一台设备递过来的续读回执。
@immutable
class LanHandoffReceipt {
  const LanHandoffReceipt({this.online, this.bookId, this.chapter});

  /// 非空表示来自云端在线库，需要重新拉取。
  final Object? online;
  final int? bookId;
  final int? chapter;
}

/// 回执解析后的落点。
@immutable
class LanHandoffResolution {
  const LanHandoffResolution({required this.book, required this.position});

  final Novel book;
  final ReadingPosition position;
}

/// 续读提醒的持有者。
///
/// 本构建未包含局域网协议，[received] 恒为 null，
/// 因此提醒条不会出现；[resolveReceipt] 直接抛错，调用方会转成可见提示。
class LanReadingHandoff {
  LanHandoffReceipt? get received => null;

  Future<LanHandoffResolution> resolveReceipt(LanHandoffReceipt receipt) =>
      Future<LanHandoffResolution>.error(
        UnsupportedError('此构建未包含局域网续读'),
      );

  void dismissReceipt() {}
}

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

  /// 本地书库可用时非 null（决定本地书能否发起续读）。
  Object? get books => null;

  /// 在线库可用时非 null（决定在线书能否发起续读）。
  Object? get repository => null;

  LanReadingHandoff? get handoff => null;

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
