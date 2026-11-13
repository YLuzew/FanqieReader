import 'package:flutter/foundation.dart';

/// 导入过程中需要告知用户的一条说明（旧格式、缺封面等）。
typedef LocalImportNotice = ({String name, String message});

/// 一个没能导入的文件及其原因。
typedef LocalImportFailure = ({String name, String message});

/// 一次导入的结论：进了哪些书、新增多少、跳过多少、失败与提醒。
class LocalImportReport {
  const LocalImportReport({
    this.bookIds = const [],
    this.added = 0,
    this.existing = 0,
    this.failures = const [],
    this.notices = const [],
    this.summary = '',
  });

  final List<int> bookIds;
  final int added;
  final int existing;
  final List<LocalImportFailure> failures;
  final List<LocalImportNotice> notices;
  final String summary;

  bool get isEmpty => added == 0 && failures.isEmpty;
}

/// 一次本地扫描的汇总结果。
class LocalScanResult {
  const LocalScanResult({
    required this.report,
    this.total = 0,
    this.unchanged = 0,
    this.warnings = const [],
    this.pending = 0,
  });

  final Object? report;
  final int total;
  final int unchanged;
  final List<String> warnings;
  final int pending;

  bool get isEmpty => total == 0 && pending == 0;
}

/// 逐个文件导入的批次控制器。
///
/// 当前构建未包含原生批量导入实现，[run] 仅回放空结果，
/// 不会向书库写入任何条目。
class LocalImportBatch extends ChangeNotifier {
  LocalImportBatch({this.onProgress});

  final void Function(int done, int total)? onProgress;

  bool _cancelled = false;
  bool get cancelled => _cancelled;

  Future<Object?> run(List<String> tokens) async => null;

  void cancel() {
    _cancelled = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }
}

/// 批量导入的分组视图（按文件夹归并）。
class LocalImportGroup {
  const LocalImportGroup({
    required this.folder,
    this.tokens = const [],
    this.total = 0,
  });

  final String folder;
  final List<String> tokens;
  final int total;
}

List<LocalImportGroup> localImportGroups(
  Iterable<String> tokens, {
  String Function(String token)? folderOf,
}) {
  final grouped = <String, List<String>>{};
  for (final token in tokens) {
    final folder = folderOf?.call(token) ?? '';
    (grouped[folder] ??= <String>[]).add(token);
  }
  return [
    for (final entry in grouped.entries)
      LocalImportGroup(
        folder: entry.key,
        tokens: List.unmodifiable(entry.value),
        total: entry.value.length,
      ),
  ];
}
