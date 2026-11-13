import 'package:flutter/widgets.dart';

import 'book_documents.dart';

/// 扫描到的书籍选择页：勾选要导入的文件。
///
/// 当前构建不提供该页面（原生批量导入未包含），
/// 打开即返回 null，调用方会走「未选择」分支。
class LocalScanSelection extends StatelessWidget {
  const LocalScanSelection({super.key, required this.snapshot});

  final BookScanSnapshot snapshot;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
