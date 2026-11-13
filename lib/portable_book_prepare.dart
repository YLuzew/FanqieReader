import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 由原生层返回的「可导入文档」条目。
typedef PreparedBookDocument = ({String name, String? path, String? error});

/// 便携文档转换通道。
///
/// 真正的转换在原生侧完成（EPUB/MOBI/PDF → 纯文本），本类只负责
/// 调度、并发上限与临时目录清理。当前构建保留完整签名，
/// 但 [prepare] 在缺少原生实现时会直接返回空列表，不会静默损坏文件。
class PortableBookPreparer {
  PortableBookPreparer({
    required this.directory,
    required this.textCodecToken,
    required this.decodeNames,
    required this.convert,
    required this.extractKindle,
    this.extractPdf,
  });

  final Directory directory;
  final RootIsolateToken textCodecToken;
  final Future<List<String>> Function(List<String> names) decodeNames;
  final Future<List<PreparedBookDocument>> Function(String name, String path)
  convert;
  final Future<int> Function(String source, String output) extractKindle;
  final Future<void> Function(String name, String source, String output)?
  extractPdf;

  /// 上一次运行残留的半成品目录，启动时清掉。
  static Future<void> clearPreviousRuns(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响导入，保留现场供下次重试。
    }
  }

  Future<List<PreparedBookDocument>> prepare(
    String name,
    String path, {
    void Function(int done, int total)? onProgress,
  }) async {
    onProgress?.call(0, 1);
    try {
      final docs = await convert(name, path);
      onProgress?.call(1, 1);
      return docs;
    } catch (error) {
      onProgress?.call(1, 1);
      return [(name: name, path: null, error: '$error')];
    }
  }

  /// 释放某个文档在这次运行里占用的临时路径。
  Future<void> releasePaths(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  static String _basename(String path) {
    final index = path.lastIndexOf(Platform.pathSeparator);
    return index < 0 ? path : path.substring(index + 1);
  }
}

/// 供原生侧回传的二进制片段。
typedef PreparedBytes = ({String name, Uint8List bytes});
