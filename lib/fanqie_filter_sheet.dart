import 'dart:async';

import 'package:flutter/material.dart';

import 'app_language.dart';
import 'archive_design.dart';
import 'fanqie_api.dart';
import 'fanqie_repository.dart';

/// 用户在发现页选完的一组番茄筛选条件。
class FanqieFilterSelection {
  const FanqieFilterSelection({
    required this.categoryId,
    required this.categoryName,
    required this.sortBy,
    required this.bookStatus,
    required this.subCategory,
    required this.active,
  });

  final int categoryId;
  final String categoryName;
  final String sortBy;
  final String bookStatus;
  final String subCategory;

  /// 是否真的选了东西。全默认时让发现页回到推荐流。
  final bool active;
}

Future<FanqieFilterSelection?> showFanqieFilterSheet(
  BuildContext context,
  FanqieRepository repository,
) => showModalBottomSheet<FanqieFilterSelection>(
  context: context,
  isScrollControlled: true,
  showDragHandle: false,
  backgroundColor: Theme.of(context).colorScheme.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
  ),
  builder: (_) => FanqieFilterSheet(repository: repository),
);

/// 番茄自己的筛选面板。
///
/// 文库那套「榜单 / 标签 / 出版文库 / 屏蔽」在番茄这边没有对应物 ——
/// 番茄给的是排序（sort_by）、状态（book_status）、细分标签（sub_category），
/// 另外还有一组字数（word_type）暂时没接。这些只挂在分类落地页上，所以这里照着番茄的真实
/// 参数重做，不硬套文库的分类体系。
class FanqieFilterSheet extends StatefulWidget {
  const FanqieFilterSheet({super.key, required this.repository});

  final FanqieRepository repository;

  @override
  State<FanqieFilterSheet> createState() => _FanqieFilterSheetState();
}

class _FanqieFilterSheetState extends State<FanqieFilterSheet> {
  late int _categoryId = widget.repository.filterCategoryId;
  late String _categoryName = widget.repository.filterCategoryName;
  late String _sortBy = widget.repository.filterSortBy;
  late String _bookStatus = widget.repository.filterBookStatus;
  late String _subCategory = widget.repository.filterSubCategory;

  List<FanqieCategory> _categories = const [];
  Map<String, Object?> _facets = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final categories = _categories.isEmpty
          ? await widget.repository.api.fetchCategoryList()
          : _categories;
      final facets = await widget.repository.loadFilterFacets(_categoryId);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _facets = facets;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '筛选项没拿到：$error';
        _loading = false;
      });
    }
  }

  Future<void> _pickCategory(FanqieCategory category) async {
    if (category.id == _categoryId) return;
    setState(() {
      _categoryId = category.id;
      _categoryName = category.name;
      // 换了分类，细分标签必须清掉 —— 那几个 id 是上一个分类的。
      _subCategory = '0';
      _loading = true;
    });
    await _load();
  }

  List<({String value, String label})> _options(String key) {
    final raw = _facets[key];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          (
            value: '${item['value'] ?? ''}',
            label: '${item['name'] ?? ''}',
          ),
    ].where((e) => e.value.isNotEmpty).toList(growable: false);
  }

  bool get _active =>
      _sortBy != '0' || _bookStatus != '2' || _subCategory != '0';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * .84;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拖动条自己画 —— 系统那条是圆头浅灰，和这套方角档案线不搭。
          Center(
            child: Container(
              width: 34,
              height: 3,
              margin: const EdgeInsets.only(top: 8, bottom: 12),
              color: scheme.outlineVariant,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const ArchiveCode('FILTER / COLLECTION'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AppText(
                        _categoryName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 24,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.6,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(
                        context,
                        FanqieFilterSelection(
                          categoryId: _categoryId,
                          categoryName: _categoryName,
                          sortBy: '0',
                          bookStatus: '2',
                          subCategory: '0',
                          active: false,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: scheme.onSurfaceVariant,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 34),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('重置', style: TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: .8, thickness: .8, color: scheme.outlineVariant),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppText(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 14),
                          _ArchiveChip(label: '重试', onTap: _load),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
                    children: [
                      const _ArchiveGroup(code: 'FILTER / CATEGORY', title: '分类'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final category in _categories)
                            _ArchiveChip(
                              label: category.name,
                              selected: category.id == _categoryId,
                              onTap: () => _pickCategory(category),
                            ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const _ArchiveGroup(code: 'FILTER / SORT', title: '排序'),
                      _Chips(
                        options: _options('sort_by'),
                        selected: _sortBy,
                        onPick: (v) => setState(() => _sortBy = v),
                      ),
                      const SizedBox(height: 24),
                      const _ArchiveGroup(code: 'FILTER / STATUS', title: '状态'),
                      _Chips(
                        options: _options('book_status'),
                        selected: _bookStatus,
                        onPick: (v) => setState(() => _bookStatus = v),
                      ),
                      if (_options('sub_category').length > 1) ...[
                        const SizedBox(height: 24),
                        const _ArchiveGroup(code: 'FILTER / TAG', title: '标签'),
                        _Chips(
                          options: _options('sub_category'),
                          selected: _subCategory,
                          onPick: (v) => setState(() => _subCategory = v),
                        ),
                      ],
                      const SizedBox(height: 30),
                      _ArchiveChip(
                        label: '应用',
                        filled: true,
                        onTap: () => Navigator.pop(
                          context,
                          FanqieFilterSelection(
                            categoryId: _categoryId,
                            categoryName: _categoryName,
                            sortBy: _sortBy,
                            bookStatus: _bookStatus,
                            subCategory: _subCategory,
                            active: _active || _categoryId != 1,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 分组标题：等宽小字 + 细线 + 右端一个小方块，跟发现页那套档案头一致。
class _ArchiveGroup extends StatelessWidget {
  const _ArchiveGroup({required this.code, required this.title});
  final String code;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ArchiveCode(code),
              const SizedBox(width: 9),
              Expanded(
                child: Divider(
                  height: 1,
                  thickness: .6,
                  color: scheme.outlineVariant,
                ),
              ),
              const SizedBox(width: 5),
              SizedBox(
                width: 3,
                height: 3,
                child: ColoredBox(color: scheme.onSurface),
              ),
            ],
          ),
          const SizedBox(height: 6),
          AppText(
            title,
            style: const TextStyle(
              fontSize: 16,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: -.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// 方角细描边选择块 —— Material 那个圆头 ChoiceChip 和这套版式不是一路。
/// 选中时反色（黑底白字），跟发现页的书脊编号是同一个语汇。
class _ArchiveChip extends StatelessWidget {
  const _ArchiveChip({
    required this.label,
    this.selected = false,
    this.filled = false,
    required this.onTap,
  });

  final String label;
  final bool selected;

  /// 「应用」那种主按钮：整块实心，比普通选项厚一点。
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final solid = selected || filled;
    final radius = BorderRadius.circular(3);
    return Material(
      color: solid ? scheme.onSurface : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Container(
          width: filled ? double.infinity : null,
          padding: EdgeInsets.symmetric(
            horizontal: filled ? 16 : 13,
            vertical: filled ? 14 : 8,
          ),
          decoration: BoxDecoration(
            border: Border.all(
              color: solid ? scheme.onSurface : scheme.outlineVariant,
              width: .8,
            ),
            borderRadius: radius,
          ),
          child: AppText(
            label,
            textAlign: filled ? TextAlign.center : null,
            style: TextStyle(
              fontSize: filled ? 14 : 13,
              height: 1.15,
              letterSpacing: filled ? 1.6 : .2,
              fontWeight: solid ? FontWeight.w600 : FontWeight.w400,
              color: solid ? scheme.surface : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _Chips extends StatelessWidget {
  const _Chips({
    required this.options,
    required this.selected,
    required this.onPick,
  });

  final List<({String value, String label})> options;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final option in options)
        _ArchiveChip(
          label: option.label,
          selected: option.value == selected,
          onTap: () => onPick(option.value),
        ),
    ],
  );
}
