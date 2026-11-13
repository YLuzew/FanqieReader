import 'package:flutter/widgets.dart';

import 'catalog.dart';
import 'library_state.dart';
import 'reading_report_range.dart';

/// 阅读报告页（可导出的长图/文档视图）。
///
/// 当前构建未包含导出管线，页面给出说明并允许返回。
class ReadingReportPage extends StatelessWidget {
  const ReadingReportPage({
    super.key,
    required this.state,
    required this.repository,
    this.now,
    this.initialRange,
  });

  final ReaderState state;
  final NovelRepository repository;
  final DateTime? now;
  final ReadingReportRange? initialRange;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
