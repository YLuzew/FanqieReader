import 'package:flutter/foundation.dart';

import 'local_books.dart';

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

/// 一张「合订本里的某一卷」。
@immutable
class LocalImportVolume {
  const LocalImportVolume({
    required this.bookId,
    required this.title,
    this.chapterCount = 0,
  });

  final int bookId;
  final String title;
  final int chapterCount;
}

/// 一组合并候选：同一部作品拆成多卷的书。
@immutable
class LocalImportGroup {
  const LocalImportGroup({
    required this.seed,
    required this.title,
    required this.volumes,
    this.needsTarget = false,
    this.targetId,
  });

  /// 代表这本书的 id（也是 UI 里的选择键）。
  final int seed;
  final String title;
  final List<LocalImportVolume> volumes;

  /// 该组还不能直接合并，需要用户先指定目标合订本。
  final bool needsTarget;

  /// 已经归属的合订本 id；null 表示要新建一个。
  final int? targetId;
}

/// 把导入结果按「同系列」归并成合并候选。
///
/// 已经在某个系列里的书归到同组并带上 [LocalImportGroup.targetId]；
/// 其余每本单独成组，等待用户指定目标。
List<LocalImportGroup> localImportGroups(
  LocalBookStore books,
  List<int> bookIds,
) {
  final grouped = <int, List<int>>{};
  final standalone = <LocalImportGroup>[];

  for (final id in bookIds) {
    final book = books.book(id);
    if (book == null) continue;
    final series = books.seriesFor(id);
    if (series == null) {
      standalone.add(
        LocalImportGroup(
          seed: id,
          title: book.title,
          volumes: [
            LocalImportVolume(bookId: id, title: book.title),
          ],
          needsTarget: true,
        ),
      );
    } else {
      (grouped[series.id] ??= <int>[]).add(id);
    }
  }

  final result = <LocalImportGroup>[];
  for (final entry in grouped.entries) {
    final members = entry.value.map((id) => books.book(id)).whereType<Novel>();
    final list = members.toList();
    if (list.isEmpty) continue;
    result.add(
      LocalImportGroup(
        seed: entry.key,
        title: list.first.title,
        volumes: [
          for (final book in list)
            LocalImportVolume(bookId: book.id, title: book.title),
        ],
        targetId: entry.key,
      ),
    );
  }
  return [...result, ...standalone];
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

  final LocalImportReport report;
  final int total;
  final int unchanged;
  final List<String> warnings;
  final int pending;

  String get summary => report.summary.isNotEmpty
      ? report.summary
      : (report.added > 0
            ? '已导入 ${report.added} 本'
            : '本次没有新增书籍');

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

  Future<LocalImportReport?> run(List<String> tokens) async =>
      const LocalImportReport(summary: '此构建未包含批量导入');

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
