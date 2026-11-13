import 'dart:async';

import 'package:flutter/material.dart';

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
  showDragHandle: true,
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
    final maxHeight = MediaQuery.sizeOf(context).height * .82;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '筛选 · $_categoryName',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
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
                  child: const Text('重置'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          FilledButton(onPressed: _load, child: const Text('重试')),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      _SectionTitle('分类'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final category in _categories)
                            ChoiceChip(
                              label: Text(category.name),
                              selected: category.id == _categoryId,
                              onSelected: (_) => _pickCategory(category),
                            ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _SectionTitle('排序'),
                      _Chips(
                        options: _options('sort_by'),
                        selected: _sortBy,
                        onPick: (v) => setState(() => _sortBy = v),
                      ),
                      const SizedBox(height: 20),
                      _SectionTitle('状态'),
                      _Chips(
                        options: _options('book_status'),
                        selected: _bookStatus,
                        onPick: (v) => setState(() => _bookStatus = v),
                      ),
                      if (_options('sub_category').length > 1) ...[
                        const SizedBox(height: 20),
                        _SectionTitle('标签'),
                        _Chips(
                          options: _options('sub_category'),
                          selected: _subCategory,
                          onPick: (v) => setState(() => _subCategory = v),
                        ),
                      ],
                      const SizedBox(height: 28),
                      FilledButton(
                        onPressed: () => Navigator.pop(
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
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46),
                          backgroundColor: scheme.primary,
                        ),
                        child: const Text('应用'),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: .5,
      ),
    ),
  );
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
        ChoiceChip(
          label: Text(option.label),
          selected: option.value == selected,
          onSelected: (_) => onPick(option.value),
        ),
    ],
  );
}
