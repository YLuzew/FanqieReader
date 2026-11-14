import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_haptics.dart';
import 'app_interactions.dart';
import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'catalog.dart';
import 'fanqie_api.dart';
import 'fanqie_repository.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'pages.dart';

/// 番茄账号「最近读过」。
///
/// 只搬过来了能确认的字段：书号、书名、封面、读过的时间。番茄的历史接口
/// **不吐章节位置**，所以这里点进去是书详情，不是「接着上次那一章读」——
/// 装作能恢复进度比不做更糟。
class FanqieHistoryPage extends StatefulWidget {
  const FanqieHistoryPage({
    super.key,
    required this.api,
    required this.state,
    required this.repository,
  });

  final FanqieApi api;
  final LibraryState state;
  final NovelRepository repository;

  @override
  State<FanqieHistoryPage> createState() => _FanqieHistoryPageState();
}

class _FanqieHistoryPageState extends State<FanqieHistoryPage> {
  List<FanqieHistoryEntry>? _entries;
  String? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.api.fetchRecentReads();
      if (!mounted || generation != _generation) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on Object catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _open(FanqieHistoryEntry entry) async {
    try {
      final hits = await widget.repository.search(entry.bookId);
      if (!mounted) return;
      if (hits.isEmpty) {
        showNovelFeedback(context, '这本书在番茄上找不到了');
        return;
      }
      openDetail(context, hits.first, widget.state, widget.repository);
    } on Object catch (failure) {
      if (!mounted) return;
      showNovelFeedback(context, '打不开：$failure', haptic: HapticCue.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _entries;
    return ArchiveFeaturePage(
      title: '最近读过',
      code: 'TOMATO / HISTORY',
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
          children: [
            ArchiveSection(
              title: '番茄阅读历史',
              code: 'ACCOUNT / RECENT',
              subtitle: entries == null
                  ? '正在读账号'
                  : entries.isEmpty
                  ? '账号里还没有读完的记录'
                  : '${entries.length} 本 · 点开回到书',
            ),
            const SizedBox(height: 12),
            if (_loading && entries == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CupertinoActivityIndicator(radius: 13)),
              )
            else if (_error != null)
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: AppText(
                      _error!,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.7,
                        color: scheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  GlassTextButton(
                    key: const ValueKey('fanqie-history-retry'),
                    onPressed: _load,
                    child: const AppText('重试'),
                  ),
                ],
              )
            else if (entries != null)
              for (final entry in entries)
                _HistoryRow(entry: entry, onTap: () => _open(entry)),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onTap});

  final FanqieHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: JellyTapSurface(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 44,
                  height: 60,
                  child: (entry.coverUrl ?? '').isEmpty
                      ? Container(
                          color: scheme.surfaceContainerHighest.withValues(
                            alpha: .5,
                          ),
                          child: Icon(
                            CupertinoIcons.book,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      : Image.network(
                          entry.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: scheme.surfaceContainerHighest.withValues(
                              alpha: .5,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppText(
                      entry.title.isEmpty ? '未命名' : entry.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    AppText(
                      _ago(entry.readAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                CupertinoIcons.chevron_right,
                size: 13,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime at) {
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 1) return '刚刚读过';
    if (delta.inHours < 1) return '${delta.inMinutes} 分钟前读过';
    if (delta.inDays < 1) return '${delta.inHours} 小时前读过';
    if (delta.inDays < 30) return '${delta.inDays} 天前读过';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} 读过';
  }
}
