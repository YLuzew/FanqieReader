import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'fanqie_api.dart';
import 'feature_pages.dart';

/// 某一段被划线的正文下面那串评论。
///
/// 入口在段评面板：点「第 N 段 · M 条」进来。走
/// `comment/list` 的 `comment_type=2` 那一支，`para_index` 就是段落序号。
class FanqieParagraphCommentsPage extends StatefulWidget {
  const FanqieParagraphCommentsPage({
    super.key,
    required this.api,
    required this.bookId,
    required this.bookTitle,
    required this.paragraphIndex,
    required this.quote,
    this.initialCount = 0,
  });

  final FanqieApi api;
  final String bookId;
  final String bookTitle;
  final int paragraphIndex;
  final String quote;
  final int initialCount;

  @override
  State<FanqieParagraphCommentsPage> createState() =>
      _FanqieParagraphCommentsPageState();
}

class _FanqieParagraphCommentsPageState
    extends State<FanqieParagraphCommentsPage> {
  final _reviews = <FanqieReview>[];
  String _cursor = '';
  bool _loading = true;
  bool _more = false;
  String? _error;
  int _generation = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      _reviews.clear();
      _cursor = '';
      _total = 0;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.api.fetchParagraphComments(
        widget.bookId,
        paragraphIndex: widget.paragraphIndex,
        cursor: _cursor,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _reviews.addAll(page.reviews);
        _cursor = page.cursor;
        _more = page.hasMore;
        _total = page.total;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ArchiveFeaturePage(
      title: '段评',
      code: 'CHAPTER / NOTES',
      child: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (notification) {
            if (_more && !_loading && (notification.metrics.extentAfter < 420)) {
              unawaited(_load());
            }
            return false;
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
            itemCount: _reviews.length + 2,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ArchiveSection(
                        title: widget.bookTitle,
                        code: 'PARAGRAPH ${widget.paragraphIndex + 1}',
                        subtitle: _subtitle,
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: scheme.surfaceContainerHighest.withValues(
                            alpha: .35,
                          ),
                        ),
                        child: AppText(
                          widget.quote.isEmpty ? '（这段没有留原文）' : widget.quote,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.7,
                            color: scheme.onSurfaceVariant,
                          ),
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              }
              if (index > _reviews.length) return _footer(scheme);
              return _CommentTile(review: _reviews[index - 1]);
            },
          ),
        ),
      ),
    );
  }

  String get _subtitle {
    final base = widget.initialCount > 0 ? widget.initialCount : _total;
    return base > 0 ? '$base 条想法' : '还没有人说话';
  }

  Widget _footer(ColorScheme scheme) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          children: [
            AppText(
              _error!,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            GlassTextButton(
              key: const ValueKey('fanqie-notes-retry'),
              onPressed: () => _load(),
              child: const AppText('重试'),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(child: CupertinoActivityIndicator(radius: 12)),
      );
    }
    if (_reviews.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: AppText(
            '这一段还没有人留言',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.review});

  final FanqieReview review;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Bubble(seed: review.userName, url: review.avatarUrl),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: AppText(
                        review.userName.isEmpty ? '匿名读者' : review.userName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (review.isAuthor) ...[
                      const SizedBox(width: 6),
                      _Badge(text: '作者'),
                    ],
                    const SizedBox(width: 6),
                    AppText(
                      _ago(review.createdAt),
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                AppText(
                  review.text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.7,
                    color: scheme.onSurface,
                  ),
                ),
                if (review.likes > 0) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        CupertinoIcons.heart,
                        size: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      AppText(
                        '${review.likes}',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _ago(DateTime? at) {
    if (at == null) return '';
    final date = at;
    final delta = DateTime.now().difference(date);
    if (delta.inMinutes < 1) return '刚刚';
    if (delta.inHours < 1) return '${delta.inMinutes} 分钟前';
    if (delta.inDays < 1) return '${delta.inHours} 小时前';
    if (delta.inDays < 30) return '${delta.inDays} 天前';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: scheme.primary.withValues(alpha: .14),
      ),
      child: AppText(
        text,
        style: TextStyle(fontSize: 9, color: scheme.primary),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.seed, this.url});

  final String seed;
  final String? url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = seed.isEmpty
        ? '读'
        : String.fromCharCodes(seed.runes.take(1));
    final fallback = Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.primary.withValues(alpha: .16),
      ),
      child: AppText(
        initial,
        style: TextStyle(fontSize: 12, color: scheme.primary),
      ),
    );
    final link = url;
    if (link == null || link.isEmpty) return fallback;
    final hue = (seed.hashCode.abs() % 360).toDouble();
    return ClipOval(
      child: Image.network(
        FanqieBook.appCoverUrl(link),
        width: 30,
        height: 30,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : Container(
                width: 30,
                height: 30,
                color: HSVColor.fromAHSV(1, hue, .14, .92).toColor(),
              ),
      ),
    );
  }
}
