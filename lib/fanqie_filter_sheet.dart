import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'fanqie_api.dart';
import 'fanqie_repository.dart';
import 'glass_choices.dart';

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
  FanqieRepository repository, {
  bool reduceMotion = false,
}) => showJellySheet<FanqieFilterSelection>(
  context: context,
  reduceMotion: reduceMotion,
  heightFactor: .75,
  builder: (_) => FanqieFilterSheet(repository: repository),
);

/// 番茄自己的筛选面板。
///
/// 文库那套「榜单 / 标签 / 出版文库 / 屏蔽」在番茄这边没有对应物 —— 番茄给的
/// 是排序（sort_by）、状态（book_status）、细分标签（sub_category），另外还有
/// 一组字数（word_type）暂时没接。这些只挂在分类落地页上，所以照着真实参数重做。
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
          (value: '${item['value'] ?? ''}', label: '${item['name'] ?? ''}'),
    ].where((e) => e.value.isNotEmpty).toList(growable: false);
  }

  bool get _active =>
      _sortBy != '0' || _bookStatus != '2' || _subCategory != '0';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ArchiveSection(
                  title: '筛选',
                  code: 'DISCOVER / TOMATO',
                  subtitle: _categoryName,
                ),
              ),
              GlassTextButton(
                key: const ValueKey('fanqie-filter-reset'),
                compact: true,
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
                child: const AppText('重置'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CupertinoActivityIndicator()),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(
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
                  const SizedBox(height: 12),
                  GlassTextButton(
                    key: const ValueKey('fanqie-filter-retry'),
                    compact: true,
                    onPressed: _load,
                    child: const AppText('重新加载'),
                  ),
                ],
              ),
            )
          else ...[
            GlassChoiceGroup<int>(
              name: 'fanqie-filter-category',
              label: '分类',
              value: _categoryId,
              columns: 3,
              options: {for (final c in _categories) c.id: c.name},
              optionName: (id) => '$id',
              onChanged: (id) {
                final picked = _categories.where((e) => e.id == id);
                if (picked.isNotEmpty) unawaited(_pickCategory(picked.first));
              },
            ),
            GlassChoiceGroup<String>(
              name: 'fanqie-filter-sort',
              label: '排序',
              value: _sortBy,
              columns: 4,
              options: {for (final o in _options('sort_by')) o.value: o.label},
              onChanged: (v) => setState(() => _sortBy = v),
            ),
            GlassChoiceGroup<String>(
              name: 'fanqie-filter-status',
              label: '状态',
              value: _bookStatus,
              columns: 4,
              options: {
                for (final o in _options('book_status')) o.value: o.label,
              },
              onChanged: (v) => setState(() => _bookStatus = v),
            ),
            if (_options('sub_category').length > 1)
              GlassChoiceGroup<String>(
                name: 'fanqie-filter-tag',
                label: '标签',
                value: _subCategory,
                columns: 3,
                options: {
                  for (final o in _options('sub_category')) o.value: o.label,
                },
                onChanged: (v) => setState(() => _subCategory = v),
              ),
            const SizedBox(height: 20),
            GlassTextButton(
              key: const ValueKey('fanqie-filter-apply'),
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
              child: const Center(child: AppText('应用')),
            ),
          ],
        ],
      ),
    );
  }
}
