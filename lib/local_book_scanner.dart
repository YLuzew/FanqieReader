import 'book_documents.dart';
import 'local_import_batch.dart';

/// 扫描并导入选中的本地书籍。
///
/// 当前构建保留完整签名；实际导入依赖原生批量能力，
/// 缺失时返回一份空报告而不是抛错，调用方提示「本次没有新增」。
Future<LocalScanResult> scanLocalBooks({
  required Object? documents,
  required BookScanSnapshot snapshot,
  required Set<String> selectedTokens,
  required bool linkText,
  required Future<LocalImportReport> Function(BookDocumentSelection source)
  importSource,
  required bool Function() current,
  void Function(int done, int total)? onProgress,
}) async {
  final result = LocalScanResult(
    report: const LocalImportReport(summary: '此构建未包含本地批量导入'),
    total: snapshot.total,
    unchanged: snapshot.unchanged,
    warnings: const ['此构建未包含本地批量导入'],
    pending: snapshot.books.length,
  );
  onProgress?.call(snapshot.books.length, snapshot.books.length);
  return result;
}
