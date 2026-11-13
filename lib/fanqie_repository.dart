import 'dart:async';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;

import 'catalog.dart';
import 'fanqie_api.dart';
import 'fanqie_font.dart';
import 'fanqie_ids.dart';
import 'publication_catalog.dart';
import 'tag_catalogue.dart';

// 番茄小说内容源。
//
// 把 LegacyWenkuRepository 的空桩换成这一层，UI / 阅读器 / 听书 / 缓存
// 全都不用动 —— 它们只认 NovelRepository 这套接口。
//
// 数据来自网页版（见 fanqie_api.dart 的说明）。一句话概括能力边界：
//   · 能读：任意公开书籍的详情、完整目录、正文章节（含字体混淆还原）。
//   · 不能搜：网页版搜索接口对未登录请求返回 200 + 空 body。
//   · 不能互动：段评、书评、书荒广场、阅读时长同步都需要登录态与番茄的签名。
//
// 搜索框仍然有用：粘贴番茄书籍链接或纯数字书号可以直接打开那本书。

/// 一个频道。对应 NovelRepository 之外的 PublicationCatalog。
class FanqieChannel {
  const FanqieChannel(this.id, this.name);
  final int id;
  final String name;
}

/// 番茄内容源。
class FanqieRepository extends NovelRepository
    implements PublicationCatalog, ProgressiveTagCatalogue {
  FanqieRepository({FanqieApi? api, FanqieIdMap? ids})
    : api = api ?? FanqieApi(),
      ids = ids ?? FanqieIdMap();

  /// 对外的 api 实例。账号层要往它的 cookie 字段写登录态，所以是公开的。
  final FanqieApi api;

  /// 远程 bookId ↔ 本地标识的映射。
  ///
  /// 番茄的 bookId 有 19 位，直接当 Novel.id 会被上游的 isLocalBook 当成
  /// 「没导入的本地书」而全线报错，细节见 fanqie_ids.dart。
  final FanqieIdMap ids;

  /// 详情缓存。find() 与 detail() 都从这里读，避免同一本书重复请求。
  final Map<int, Novel> _known = {};

  /// 目录缓存。
  final Map<int, List<NovelChapter>> _chapters = {};

  static const channels = <FanqieChannel>[
    FanqieChannel(1, '推荐'),
    FanqieChannel(2, '男生'),
    FanqieChannel(3, '女生'),
    FanqieChannel(4, '出版'),
  ];

  @override
  Future<List<Novel>> list() async => const [];

  @override
  Future<Novel?> find(int id) async {
    final cached = _known[id];
    if (cached != null) return cached;
    return _book(id);
  }

  /// 搜索。
  ///
  /// 番茄的网页版搜索对未登录请求返回空 body，所以这里只做一件事：
  /// 如果输入看起来是书号或书籍链接，直接把它当 id 打开。
  @override
  Future<List<Novel>> search(String query) async {
    final remote = _bookIdFromInput(query);
    if (remote == null) return const [];
    final key = '$remote';
    final localId = await ids.localIdFor(key);
    final novel = await _fetch(key, localId);
    return novel == null ? const [] : [novel];
  }

  @override
  Future<Novel> detail(Novel novel) async {
    final fresh = await _book(novel.id);
    return fresh ?? novel;
  }

  /// 取目录。
  ///
  /// 网页版的书页里已经带了完整目录（chapterListWithVolume），
  /// 所以这里不需要额外请求 —— 只在详情没缓存过时才打一次。
  @override
  Future<List<NovelChapter>> chapters(int id) async {
    final cached = _chapters[id];
    if (cached != null) return cached;
    await _book(id);
    return _chapters[id] ?? const [];
  }

  @override
  Future<String> chapterContent(int novelId, NovelChapter chapter) async {
    if (chapter.id == 0) {
      throw const FanqieException('这一章拿不到编号，试试退出重进这本书');
    }
    final data = await api.fetchChapter('${chapter.id}');
    final raw = data['content'];
    if (raw is! String || raw.trim().isEmpty) {
      // 少数章节的正文在 content 之外的键里，试一遍常见别名。
      final fallback = data['chapterContent'] ?? data['txt'] ?? data['text'];
      if (fallback is! String || fallback.trim().isEmpty) {
        throw const FanqieException('这一章取不到正文，可能需要在番茄里登录后阅读');
      }
      return decodeFanqieGlyphs(_toPlainText(fallback));
    }
    return decodeFanqieGlyphs(_toPlainText(raw));
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
  }) async => const NovelPage(items: [], page: 1);

  @override
  Future<NovelPage> tagPage(
    String tag, {
    int page = 1,
    bool refresh = false,
    bool Function()? current,
    TagProgressCallback? onProgress,
  }) async => const NovelPage(items: [], page: 1);

  /// 按本地标识取一本书的详情与目录，并写进缓存。
  ///
  /// 传进来的 `id` 是 Novel.id（本地标识），不是番茄的 bookId —— 两者的
  /// 区别见 fanqie_ids.dart。
  Future<Novel?> _book(int id) async {
    final remote = ids.remoteIdFor(id);
    if (remote == null) {
      // 没有映射：要么是上一版直接把原始 bookId 塞进 Novel.id 留下的旧记录，
      // 要么这个 id 根本不是番茄的书。按原始 id 试一次，不额外分配。
      return _fetch('$id', id);
    }
    return _fetch(remote, id);
  }

  /// 真正去抓书页并组装 Novel。
  Future<Novel?> _fetch(String remoteId, int localId) async {
    final raw = await api.fetchBookPage(remoteId);
    final book = FanqieBook.fromJson(raw);
    if (book == null) return null;
    final novel = _toNovel(book, localId);
    _known[localId] = novel;
    final chapters = _chaptersFrom(raw, localId);
    _chapters[localId] = chapters;
    if (chapters.isNotEmpty) {
      _known[localId] = _toNovel(book, localId, chapters: chapters);
    }
    return _known[localId];
  }

  /// 把 `chapterListWithVolume` 摊平成章节列表。
  ///
  /// 结构是「卷 → 章节数组」，每卷自己可能叫 item_list 或直接是数组。
  /// 卷名写进 volumeTitle，volumeId 用卷名的哈希保证同一卷内一致。
  List<NovelChapter> _chaptersFrom(Map<String, Object?> page, int novelId) {
    final raw = page['chapterListWithVolume'];
    if (raw is! List) return const [];
    final result = <NovelChapter>[];

    // 番茄的 chapterListWithVolume 有两种形态，都要认：
    //   1) List<List<章节>>                     —— 2026-11-13 实测，卷名挂在每章的
    //                                              volume_name 上，外层只是分组
    //   2) List<{volume_name, item_list}>       —— 老版/别的入口的写法
    // 之前只认第二种，导致整本目录被当成「不是 Map」全部跳过、目录永远是空的。
    void take(List<Object?> items, String fallbackVolume) {
      for (final item in items) {
        final parsed = FanqieTocItem.fromJson(item, volume: fallbackVolume);
        if (parsed == null) continue;
        final chapterId = int.tryParse(parsed.id) ?? 0;
        if (chapterId == 0) continue;
        final title = parsed.volume.isEmpty ? fallbackVolume : parsed.volume;
        result.add(
          NovelChapter(
            parsed.title,
            '',
            id: chapterId,
            volumeId: title.isEmpty ? 0 : title.hashCode,
            volumeTitle: title,
          ),
        );
      }
    }

    for (final volume in raw) {
      if (volume is List) {
        take(volume, '');
      } else if (volume is Map) {
        final volumeTitle = _text(volume['volume_name']) ?? '';
        final items =
            volume['item_list'] ?? volume['chapterList'] ?? volume['list'];
        if (items is List) take(items, volumeTitle);
      }
    }
    return result;
  }

  Novel _toNovel(
    FanqieBook book,
    int id, {
    List<NovelChapter> chapters = const [],
  }) => Novel(
    id: id,
    title: book.title,
    author: book.author,
    genre: book.category,
    summary: book.summary,
    colors: _colorsFor(id),
    chapters: chapters,
    isComplete: book.completed,
    coverUrl: book.coverUrl.isEmpty ? null : book.coverUrl,
    lastUpdate: book.lastChapterTitle.isEmpty ? null : book.lastChapterTitle,
    chapterCount: book.chapterCount,
  );

  /// 从用户输入里认出一个 bookId。
  ///
  /// 接受三种写法：
  ///   7280435908500324388
  ///   https://fanqienovel.com/page/7280435908500324388
  ///   fanqienovel.com/page/7280435908500324388?enter_from=search
  static int? _bookIdFromInput(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final digits = RegExp(r'\d{8,20}').firstMatch(trimmed);
    if (digits == null) return null;
    final value = int.tryParse(digits.group(0)!);
    if (value == null || value <= 0) return null;
    return value;
  }

  /// 封面还没加载时，用书号稳定地取两个色做占位底。
  static List<Color> _colorsFor(int id) {
    final hue = (id % 360).toDouble();
    return [
      HSLColor.fromAHSL(1, hue, 0.42, 0.58).toColor(),
      HSLColor.fromAHSL(1, (hue + 24) % 360, 0.38, 0.28).toColor(),
    ];
  }

  /// 番茄正文是 HTML 片段，阅读器要的是段落纯文本。
  ///
  /// 混淆码位已经由 decodeFanqieGlyphs 还原，这里只处理标签。
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

  static String? _text(Object? value) {
    if (value is String) return value.isEmpty ? null : value;
    if (value is num) return '$value';
    return null;
  }
}
