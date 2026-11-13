import 'package:flutter/widgets.dart';

import 'lan_reading_sync.dart';

/// 续读提醒条。当前构建不会收到任何回执，因此永远不显示。
class LanHandoffMonitor extends StatelessWidget {
  const LanHandoffMonitor({
    super.key,
    this.handoff,
    this.onContinue,
    this.reduceMotion = false,
    this.noticeWrapper,
    required this.child,
  });

  final LanReadingHandoff? handoff;

  /// 回执被点开时回调。
  final Future<void> Function(LanHandoffReceipt receipt)? onContinue;

  final bool reduceMotion;

  /// 包在提醒条外面的一层装饰（main.dart 用来加圆角与投影）。
  final Widget Function(Widget notice)? noticeWrapper;

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 把一本书连同进度递给附近设备。
///
/// 当前构建未包含局域网协议，弹出后只有一行说明。
class LanSendBookSheet extends StatelessWidget {
  const LanSendBookSheet({
    super.key,
    required this.sync,
    this.book,
    this.position,
    this.reduceMotion = false,
  });

  final LanReadingSync sync;
  final Object? book;
  final Object? position;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
