import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'fanqie_api.dart';
import 'feature_pages.dart';

/// 番茄的小说书评页。
///
/// 数据来自 api3 的老接口（`/reading/ugc/novel_comment/book/v/`），
/// 一次 20 条，用返回的 `next_offset` 往下翻。
class FanqieReviewsPage extends StatefulWidget {
  const FanqieReviewsPage({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.api,
    this.initialScore,
    this.initialScoreCount,
  });

  final String bookId;
  final String bookTitle;
  final FanqieApi api;
  final double? initialScore;
  final int? initialScoreCount;

  @override
  State<FanqieReviewsPage> createState() => _FanqieReviewsPageState();
}

class _FanqieReviewsPageState extends State<FanqieReviewsPage>
    with AutomaticKeepAliveClientMixin {
  final List<FanqieReview> _reviews = [];
  int _offset = 0;
  int _scoreCount = 0;
  int _commentCount = 0;
  bool _hasMore = true;
  bool _loading = false;
  bool _firstLoaded = false;
  String? _error;
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scoreCount = widget.initialScoreCount ?? 0;
    unawaited(_load(refresh: true));
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    if (!refresh && !_hasMore) return;
    final generation = refresh ? ++_generation : _generation;
    setState(() {
      _loading = true;
      if (refresh) _error = null;
    });
    try {
      final page = await widget.api.fetchBookReviews(
        widget.bookId,
        offset: refresh ? 0 : _offset,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        if (refresh) _reviews.clear();
        _reviews.addAll(page.reviews);
        _offset = page.nextOffset ?? (_offset + page.reviews.length);
        _hasMore = page.hasMore && page.reviews.isNotEmpty;
        _scoreCount = page.scoreCount;
        _commentCount = page.commentCount;
        _loading = false;
        _firstLoaded = true;
      });
    } on Object catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = '$failure';
        _loading = false;
        _firstLoaded = true;
      });
    }
  }

  String get _countLine {
    final parts = <String>[];
    final score = widget.initialScore;
    if (score != null) parts.add('${score.toStringAsFixed(1)} 分');
    final count = _scoreCount > 0 ? _scoreCount : (widget.initialScoreCount ?? 0);
    if (count > 0) {
      parts.add(count >= 10000
          ? '${(count / 10000).toStringAsFixed(1)} 万人评分'
          : '$count 人评分');
    }
    if (_commentCount > 0) parts.add('$_commentCount 条书评');
    return parts.isEmpty ? '还没有人写书评' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return ArchiveFeaturePage(
      title: '书评',
      code: 'TOMATO / REVIEWS',
      child: RefreshIndicator(
        onRefresh: () => _load(refresh: true),
        child: NotificationListener<ScrollNotification>(
          onNotification: (notice) {
            if (notice.depth == 0 &&
                notice.metrics.extentAfter < 420 &&
                !_loading &&
                _hasMore &&
                _error == null) {
              unawaited(_load());
            }
            return false;
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            itemCount: _reviews.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ArchiveSection(
                        title: widget.bookTitle,
                        code: 'BOOK / REVIEWS',
                        subtitle: _countLine,
                      ),
                      if (!_firstLoaded)
                        const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: Center(
                            child: CupertinoActivityIndicator(),
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AppText(
                                '没拿到书评：$_error',
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.6,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 8),
                              GlassTextButton(
                                key: const ValueKey('fanqie-reviews-retry'),
                                compact: true,
                                onPressed: () => _load(refresh: true),
                                child: const AppText('重试'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              }
              final review = _reviews[index - 1];
              return _ReviewTile(review: review);
            },
          ),
        ),
      ),
    );
  }
}

class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.review});

  final FanqieReview review;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Avatar(url: review.avatarUrl, name: review.userName),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: AppText(
                            review.userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              height: 1.3,
                            ),
                          ),
                        ),
                        if (review.isAuthor) ...[
                          const SizedBox(width: 6),
                          AppText(
                            '作者',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    AppText(
                      _metaLine(review),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.4,
                        color: scheme.onSurfaceVariant.withValues(alpha: .8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AppText(
            review.text,
            style: const TextStyle(fontSize: 14, height: 1.68),
          ),
          if (review.imageUrls.isNotEmpty) ...[
            const SizedBox(height: 8),
            CommentImageStrip(urls: review.imageUrls),
          ],
          if (review.likes > 0 || review.replies > 0) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (review.likes > 0) ...[
                  Icon(
                    CupertinoIcons.hand_thumbsup,
                    size: 12,
                    color: scheme.onSurfaceVariant.withValues(alpha: .7),
                  ),
                  const SizedBox(width: 4),
                  AppText(
                    '${review.likes}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: .8),
                    ),
                  ),
                ],
                if (review.likes > 0 && review.replies > 0)
                  const SizedBox(width: 14),
                if (review.replies > 0) ...[
                  Icon(
                    CupertinoIcons.chat_bubble,
                    size: 12,
                    color: scheme.onSurfaceVariant.withValues(alpha: .7),
                  ),
                  const SizedBox(width: 4),
                  AppText(
                    '${review.replies}',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant.withValues(alpha: .8),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _metaLine(FanqieReview review) {
    final parts = <String>[];
    if (review.score != null && review.score! > 0) {
      parts.add('${review.score!.toStringAsFixed(1)} 分');
    }
    final at = review.createdAt;
    if (at != null) parts.add(_ago(at));
    if (review.readSeconds > 0) {
      final minutes = review.readSeconds ~/ 60;
      if (minutes > 0) parts.add('读了 $minutes 分钟');
    }
    return parts.join(' · ');
  }

  static String _ago(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 60) return '刚刚';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
    return '${diff.inDays ~/ 365} 年前';
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = name.isEmpty ? '?' : name.characters.first;
    final fallback = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHighest,
      ),
      alignment: Alignment.center,
      child: AppText(
        initial,
        style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
      ),
    );
    final src = url;
    if (src == null || src.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        FanqieBook.appCoverUrl(src),
        width: 34,
        height: 34,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}


/// 评论配图。一行最多三张，点开看大图。
class CommentImageStrip extends StatelessWidget {
  const CommentImageStrip({super.key, required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = urls.take(3).toList();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final url in shown)
          GestureDetector(
            onTap: () => showCupertinoDialog<void>(
              context: context,
              builder: (dialog) => GestureDetector(
                onTap: () => Navigator.of(dialog).pop(),
                child: Container(
                  color: const Color(0xEE000000),
                  alignment: Alignment.center,
                  child: InteractiveViewer(
                    minScale: .8,
                    maxScale: 3,
                    child: Image.network(url, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                url,
                width: 86,
                height: 86,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 86,
                  height: 86,
                  color: scheme.surfaceContainerHighest.withValues(alpha: .4),
                  child: Icon(
                    CupertinoIcons.photo,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        if (urls.length > shown.length)
          Container(
            width: 86,
            height: 86,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: scheme.surfaceContainerHighest.withValues(alpha: .4),
            ),
            child: AppText(
              '+${urls.length - shown.length}',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
