import 'package:flutter/widgets.dart';

import 'lan_reading_sync.dart';

/// 跨设备接力回执。当前构建不产生任何回执，仅用于满足签名。
class LanHandoffReceipt {
  const LanHandoffReceipt();
}

/// 接力监听器：本构建为直通包装，不监听、不弹窗。
class LanHandoffMonitor extends StatelessWidget {
  const LanHandoffMonitor({
    super.key,
    this.handoff,
    this.onContinue,
    required this.reduceMotion,
    this.noticeWrapper,
    required this.child,
  });

  final Object? handoff;
  final Future<void> Function(LanHandoffReceipt receipt)? onContinue;
  final bool reduceMotion;
  final Widget Function(Widget notice)? noticeWrapper;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// 「发送到其他设备」底部面板。
///
/// 当前构建未包含局域网传输，面板打开即为空；由于
/// [LanSyncScope.maybeOf] 恒为 null，阅读器的入口不会真正触发它。
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
