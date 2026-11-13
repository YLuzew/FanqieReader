import 'package:flutter/widgets.dart';

import 'reading_widget_reference.dart';
import 'reading_widget_skin.dart';

/// 皮肤选择器：横排预览 + 名称。
///
/// 当前构建没有真实渲染管线，[previewBuilder] 仍会被调用一次，
/// 因此调用方传入的预览逻辑不受影响。
class ReadingWidgetSkinPicker extends StatelessWidget {
  const ReadingWidgetSkinPicker({
    super.key,
    required this.previewBuilder,
    required this.value,
    required this.size,
    this.snapshot,
    this.onChanged,
  });

  final Widget Function(ReadingWidgetSkin skin) previewBuilder;
  final ReadingWidgetSkin value;
  final ReadingDesktopSize size;
  final Object? snapshot;
  final ValueChanged<ReadingWidgetSkin>? onChanged;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
