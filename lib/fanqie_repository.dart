import 'dart:async';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

import 'catalog.dart';
import 'fanqie_api.dart';
import 'publication_catalog.dart';
import 'tag_catalogue.dart';

// 番茄小说内容源。
//
// 把 LegacyWenkuRepository 的那个空桩换成这一层，UI / 阅读器 / 听书 / 缓存
// 全都不用动 —— 它们只认 NovelRepository 这套接口。
//
// 已知边界（README 里也写了）：
//   · 正文接口带 bdturing 滑块，未登录 + 无真实设备指纹时大概率被拦。
//   · 阅读时长同步、段评、书评需要登录态与番茄自己的签名，不在本文件里。
//   · 频道 / 分类的书单接口尚未实测，这里用的路径可能随时失效。

/// 一个频道。对应 NovelRepository 之外的 PublicationCatalog。
class FanqieChannel {
  const FanqieChannel(this.id, this.name);
  final int id;
  final String name;
}

/// 番茄内容源。
class FanqieRepository extends NovelRepository
    implements PublicationCatalog, ProgressiveTagCatalogue {
  FanqieRepository({FanqieApi? api}) : _api = api ?? FanqieApi();

  final FanqieApi _api;

  /// 详情缓存。find() 与 detail() 都从这里读，避免同一本书重复请求。
  final Map<int, Novel> _known = {};

  /// 目录缓存。章节列表在详情补全时一并写入。
  final Map<int, List<NovelChapter>> _chapters = {};

  /// 频道表。番茄的频道是固定大类，id 用本地序号，避免依赖服务端字段。
  static const channels = <FanqieChannel>[
    FanqieChannel(1, '推荐'),
    FanqieChannel(2, '男生'),
    FanqieChannel(3, '女生'),
    FanqieChannel(4, '出版'),
  ];

  @override
  Future<List<Novel>> list() async => (await browse()).items;

  @override
  Future<Novel?> find(int id) async {
    final cached = _known[id];
    if (cached != null) return cached;
    final book = await _book(id);
    return book;
  }

  @override
  Future<List<Novel>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final data = await _api.get(
      FanqieEndpoints.search,
      query: {'query': trimmed, 'query_type': '0', 'page_count': '20'},
    );
    return _novelsFrom(data);
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final fresh = await _book(novel.id);
    return fresh ?? novel;
  }

  @override
  Future<List<NovelChapter>> chapters(int id) async {
    final cached = _chapters[id];
    if (cached != null) return cached;
    final data = await _api.get(
      FanqieEndpoints.directory,
      query: {'book_id': '$id'},
    );
    final raw = data['chapterListWithVolume'] ?? data['item_data_list'] ?? data['catalog_data'];
    final items = <FanqieTocItem>[];
    if (raw is List) {
      for (final entry in raw) {
        // 有的返回把一卷的章节放在 item_list 里。
        if (entry is Map && entry['item_list'] is List) {
          final volume = entry['volume_name'];
          for (final item in entry['item_list'] as List) {
            final parsed = FanqieTocItem.fromJson(item);
            if (parsed == null) continue;
            items.add(
              FanqieTocItem(
                itemId: parsed.itemId,
                title: parsed.title,
                volumeTitle: volume is String ? volume : '',
                index: parsed.index,
              ),
            );
          }
          continue;
        }
        final parsed = FanqieTocItem.fromJson(entry);
        if (parsed != null) items.add(parsed);
      }
    }
    final chapters = [
      for (final (i, item) in items.indexed)
        NovelChapter(
          item.title,
          '',
          id: item.itemId,
          volumeTitle: item.volumeTitle,
          volumeId: item.volumeTitle.hashCode,
        ),
    ];
    _chapters[id] = chapters;
    return chapters;
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    final data = await _api.get(
      FanqieEndpoints.content,
      query: {'item_id': '${chapter.id}', 'book_id': '$novelId'},
    );
    final raw = data['content'] ?? data['chapter_content'] ?? '';
    if (raw is! String || raw.trim().isEmpty) {
      throw const FanqieException('这一章暂时取不到正文，可能需要在番茄 App 内解锁');
    }
    return _toPlainText(raw);
  }

  @override
  Future<List<PublicationLibrary>> publicationLibraries({
    bool refresh = false,
  }) async => [
    for (final channel in channels) PublicationLibrary(channel.id, channel.name),
  ];

  @override
  Future<NovelPage> browsePublication(
    int libraryId, {
    int page = 1,
    bool refresh = false,
  }) async {
    final data = await _api.get(
      FanqieEndpoints.channelBooks,
      query: {
        'channel_id': '$libraryId',
        'page_index': '$page',
        'page_count': '20',
      },
    );
    return NovelPage(items: _novelsFrom(data), page: page);
  }

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
    TagProgressCallback? onProgress,
  }) async {
    // 番茄没有独立的标签接口，用搜索再按分类/标签字段过滤。
    // current 用于分页过程中判断宿主页面是否还有效。
    final terms = tagSearchTerms(tag);
    if (terms.isEmpty) return const NovelPage(items: [], page: 1);
    final collected = <Novel>[];
    for (final term in terms) {
      if (current != null && !current()) break;
      final data = await _api.get(
        FanqieEndpoints.search,
        query: {'query': term, 'query_type': '0', 'page_count': '20'},
      );
      collected.addAll(_novelsFrom(data));
      onProgress?.call(
        TagSearchProgress(
          items: List.unmodifiable(collected),
          scannedPages: 1,
          totalPages: 1,
        ),
      );
    }
    return NovelPage(items: collected, page: page);
  }

  /// 取一本书的详情并写进缓存。
  Future<Novel?> _book(int id) async {
    final data = await _api.get(
      FanqieEndpoints.bookDetail,
      query: {'book_id_list': '$id'},
    );
    final list = data['book_info'] ?? data['book_data'] ?? data['list'];
    if (list is List) {
      for (final raw in list) {
        final parsed = FanqieBook.fromJson(raw);
        if (parsed == null || parsed.bookId != id) continue;
        final novel = _toNovel(parsed);
        _known[id] = novel;
        return novel;
      }
    }
    final single = FanqieBook.fromJson(data);
    if (single != null) {
      final novel = _toNovel(single);
      _known[id] = novel;
      return novel;
    }
    return null;
  }

  /// 从任意带书单的响应里抽出书籍。
  List<Novel> _novelsFrom(Map<String, Object?> data) {
    for (final key in const [
      'book_list',
      'book_data',
      'books',
      'item_data_list',
      'list',
    ]) {
      final raw = data[key];
      if (raw is! List) continue;
      final result = <Novel>[];
      for (final entry in raw) {
        final parsed = FanqieBook.fromJson(entry);
        if (parsed == null) continue;
        final novel = _toNovel(parsed);
        _known[parsed.bookId] = novel;
        result.add(novel);
      }
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  Novel _toNovel(FanqieBook book) => Novel(
    id: book.bookId,
    title: book.title,
    author: book.author,
    genre: book.genre,
    summary: book.summary,
    colors: _colorsFor(book.bookId),
    chapters: _chapters[book.bookId] ?? const [],
    isComplete: book.completed,
    coverUrl: book.coverUrl,
    lastUpdate: book.lastUpdate,
    chapterCount: book.chapterCount,
  );

  /// 封面还没加载时，用书号稳定地取两个色做占位底。
  /// 同一个 id 每次都得到同一对颜色，不会因为刷新而跳。
  static List<Color> _colorsFor(int id) {
    final hue = (id % 360).toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.42, 0.58).toColor(),
      HSLColor.fromAHSL(1, (hue + 24) % 360, 0.38, 0.28).toColor(),
    ];
  }

  /// 番茄正文是 HTML 片段，阅读器要的是段落纯文本。
  static String _toPlainText(String raw) {
    if (!raw.contains('<')) return raw.trim();
    final document = html_parser.parse(raw);
    for (final node in document.querySelectorAll('script, style')) {
      node.remove();
    }
    final blocks = document.querySelectorAll('p');
    if (blocks.isEmpty) {
      return document.body?.text.trim() ?? raw.trim();
    }
    return blocks
        .map((element) => element.text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n\n');
  }
}
