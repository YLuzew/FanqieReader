import 'package:flutter/widgets.dart';

import 'enhancement.dart';

/// 声音增强开关。当前构建不支持增强，控件显示为关闭且不可用。
class ListeningEnhancementSettings extends StatelessWidget {
  const ListeningEnhancementSettings({
    super.key,
    required this.enhancement,
    required this.onChanged,
  });

  final ListeningEnhancementPreference enhancement;
  final ValueChanged<ListeningEnhancementPreference> onChanged;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
