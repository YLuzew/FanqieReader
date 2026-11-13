import 'package:flutter/widgets.dart';

import 'book_documents.dart';
import 'local_book_importer.dart';
import 'local_import_batch.dart';

/// 本地扫描页：扫描 → 勾选 → 导入。
///
/// 当前构建未包含原生批量导入，页面直接给出说明并允许返回。
class LocalScanPage extends StatelessWidget {
  const LocalScanPage({
    super.key,
    required this.documents,
    required this.changes,
    required this.isBusy,
    required this.progress,
    required this.result,
    required this.failure,
    required this.onScan,
  });

  final BookDocuments documents;
  final LocalBookImporter changes;
  final bool Function() isBusy;
  final (int, int)? Function() progress;
  final LocalScanResult? Function() result;
  final String? Function() failure;
  final void Function(BuildContext context) onScan;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
