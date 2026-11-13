import 'package:flutter/widgets.dart';

enum ReadingDesktopSize {
  small('小 2×2'),
  medium('中 4×2'),
  large('大 4×4');

  const ReadingDesktopSize(this.label);

  final String label;
}

/// 桌面小组件预览卡片。
///
/// 当前构建未包含原生渲染管线，卡片只画一块占位面板，
/// 不影响设置页的其余交互。
class ReadingDesktopCard extends StatelessWidget {
  const ReadingDesktopCard({
    super.key,
    required this.data,
    required this.size,
    required this.brightness,
    this.quoteText,
    this.quoteSource,
    this.quoteCount = 0,
  });

  final Object? data;
  final ReadingDesktopSize size;
  final Brightness brightness;
  final String? quoteText;
  final String? quoteSource;
  final int quoteCount;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
