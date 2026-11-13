import 'package:flutter/widgets.dart';

import 'lan_reading_sync.dart';

/// 局域网续读页。由于 [LanSyncScope.maybeOf] 恒为 null，
/// 本页面不会被任何入口构建；保留类只是为了满足编译。
class LanReadingPage extends StatelessWidget {
  const LanReadingPage({
    super.key,
    required this.sync,
    this.reduceMotion = false,
  });

  final LanReadingSync sync;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
