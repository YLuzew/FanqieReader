import 'package:flutter/widgets.dart';

/// 批量导入进度页。当前构建未包含批量导入，直接返回。
class LocalBookBatchPage extends StatelessWidget {
  const LocalBookBatchPage({
    super.key,
    this.documents,
    this.library,
    this.tokens,
    this.onDone,
  });

  final Object? documents;
  final Object? library;
  final List<String>? tokens;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// 从书库页发起一次批量导入。
Future<void> openLocalBookBatch(
  BuildContext context, {
  Object? documents,
  Object? library,
  Object? selected,
}) async {}
