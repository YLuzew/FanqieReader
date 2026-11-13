import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// 番茄小说的传输层。
//
// 走的是**网页版**（fanqienovel.com），不是 App 的 API。
// 原因：App 的 api5-normal-*.fqnovel.com 需要一套签名（X-Fq-Device-Id、
// 各种 nonce 与时间戳），缺一个就返回 200 + 空 body —— 静默拒绝，
// 光看状态码发现不了。网页版不需要签名，缺点是正文有字体混淆，
// 由 fanqie_font.dart 的表还原。
//
// 已验证：
//   GET https://fanqienovel.com/page/{bookId}     -> window.__INITIAL_STATE__.page
//   GET https://fanqienovel.com/reader/{itemId}   -> window.__INITIAL_STATE__.reader.chapterData
// 两者都带 Referer 指向书页，4 秒内返回 600KB / 40KB。
//
// 未验证：搜索、频道、标签。网页版这几个入口要么是 POST，要么需要登录态，
// 下面保留了 App API 的路径常量与 get()，但都不保证能通。

/// 番茄接口抛出的异常。
class FanqieException implements Exception {
  const FanqieException(this.message, {this.code, this.detail});

  final String message;
  final int? code;
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message（$detail）';
}

/// 网页版的固定参数。
abstract final class FanqieEndpoints {
  /// 网页版主站。
  static const webHost = 'fanqienovel.com';

  /// App API 的域名。保留着，当前不用于正文。
  static const host = 'api5-normal-sinfonlineb.fqnovel.com';
  static const alternateHost = 'api5-normal-lf.fqnovel.com';

  /// App 侧的公共参数。抓包得来的，缺一个就静默返回空 body。
  static const aid = 1967;
  static const appName = 'novelapp';
  static const channel = 'huawei_5140301';
  static const versionCode = 680;
  static const versionName = '6.8.0';

  /// 网页版路径。
  static String bookPage(String bookId) => '/page/$bookId';
  static String readerPage(String itemId) => '/reader/$itemId';

  /// App 侧路径。未实测，留着备查。
  static const bookDetail = '/reading/bookapi/multi-detail/v/';
  static const directory = '/reading/bookapi/directory/v/';
  static const content = '/reading/reader/full/v/';
  static const search = '/reading/bookapi/search/page/v/';

  /// 桌面浏览器 UA。移动端 UA 会拿到另一套页面结构，别换。
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 从 Cookie 里取 csrf token 用的键。网页版没它也能读公开章节。
  static const csrfCookie = 'passport_csrf_token';
}

/// 设备侧的一次性标识。只有 App API 用得上，网页版不需要。
class FanqieSession {
  FanqieSession({String? deviceId, String? installId})
    : deviceId = deviceId ?? _randomDigits(20),
      installId = installId ?? _randomDigits(11);

  final String deviceId;
  final String installId;

  static final _random = Random.secure();

  static String _randomDigits(int length) {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i += 1) {
      buffer.write(_random.nextInt(10));
    }
    return buffer.toString();
  }

  static String requestId() {
    final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return '$seconds${_random.nextInt(900000) + 100000}';
  }
}

/// 番茄的 HTTP 客户端。
///
/// 只做两件事：取书页、取章节。两者都返回解码后的纯数据。
class FanqieApi {
  FanqieApi({FanqieSession? session, Duration? timeout})
    : session = session ?? FanqieSession(),
      timeout = timeout ?? const Duration(seconds: 20),
      _client = HttpClient() {
    _client.userAgent = FanqieEndpoints.userAgent;
    _client.connectionTimeout = this.timeout;
  }

  final FanqieSession session;
  final Duration timeout;
  final HttpClient _client;

  /// 登录态。有值时拼进 Cookie 头；网页版的公开章节不需要它。
  String? cookie;

  /// 单次响应的体积上限。正文页最大见过 700KB，12MB 足够。
  static const _maxBody = 12 * 1024 * 1024;

  Map<String, String> get _webHeaders => {
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9',
    if ((cookie ?? '').isNotEmpty) 'Cookie': cookie!,
  };

  Map<String, String> get _appHeaders => {
    'Accept': 'application/json',
    'X-Fq-Device-Id': session.deviceId,
    'X-Request-Id': FanqieSession.requestId(),
    if ((cookie ?? '').isNotEmpty) 'Cookie': cookie!,
  };

  Map<String, Object?> get _commonQuery => {
    'aid': FanqieEndpoints.aid,
    'app_name': FanqieEndpoints.appName,
    'channel': FanqieEndpoints.channel,
    'version_code': FanqieEndpoints.versionCode,
    'device_id': session.deviceId,
    'iid': session.installId,
    'ac': 'wifi',
    'os': 'android',
  };

  /// 取一本书的书页，返回 `window.__INITIAL_STATE__.page`。
  ///
  /// 这个对象里同时有书籍元信息和完整的章节目录（chapterListWithVolume），
  /// 所以详情页与目录页只需要一次请求。
  Future<Map<String, Object?>> fetchBookPage(String bookId) async {
    final html = await _fetchHtml(
      Uri.https(
        FanqieEndpoints.webHost,
        FanqieEndpoints.bookPage(bookId),
      ).toString(),
    );
    final state = _extractInitialState(html);
    final page = state['page'];
    if (page is! Map) {
      throw const FanqieException('书页里没找到书籍数据，可能是书籍不存在或页面结构变了');
    }
    return Map<String, Object?>.from(page);
  }

  /// 取一章，返回 `window.__INITIAL_STATE__.reader.chapterData`。
  ///
  /// `content` 字段里是带混淆码位的 HTML，本方法**不做解码**，
  /// 由调用方交给 decodeFanqieGlyphs 处理 —— 传输层不该知道字体的事。
  Future<Map<String, Object?>> fetchChapter(String itemId) async {
    final html = await _fetchHtml(
      Uri.https(
        FanqieEndpoints.webHost,
        FanqieEndpoints.readerPage(itemId),
      ).toString(),
      referer: Uri.https(
        FanqieEndpoints.webHost,
        FanqieEndpoints.bookPage(''),
      ).toString(),
    );
    final state = _extractInitialState(html);
    final reader = state['reader'];
    if (reader is! Map) {
      throw const FanqieException('章节页里没找到正文数据，可能这一章需要登录或已下架');
    }
    final chapter = reader['chapterData'];
    if (chapter is! Map) {
      throw const FanqieException('章节页里没有 chapterData，可能触发了访问校验');
    }
    final data = Map<String, Object?>.from(chapter);
    if (data['isChapterLock'] == true) {
      throw const FanqieException('这一章在番茄上要付费或要登录才能看');
    }
    return data;
  }

  /// 取一段网页 HTML。
  Future<String> _fetchHtml(String url, {String? referer}) async {
    final uri = Uri.parse(url);
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      _webHeaders.forEach(request.headers.set);
      if (referer != null) request.headers.set('Referer', referer);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        // 把体积读完，否则连接不会释放。
        await response.drain<void>();
        throw FanqieException(
          '番茄返回了 ${response.statusCode}',
          code: response.statusCode,
        );
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) {
          throw const FanqieException('响应超过 12MB，已中断');
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on SocketException catch (failure) {
      throw FanqieException('连不上番茄：${failure.message}');
    } on TimeoutException {
      throw const FanqieException('番茄响应超时，换个网络再试');
    } on HandshakeException {
      throw const FanqieException('和番茄的 HTTPS 握手失败');
    }
  }

  /// App API 的 GET。当前没有调用方，保留是因为搜索和频道可能还得走这条路。
  ///
  /// 注意：这个接口在参数不全时返回 200 + 空 body，不是错误码。
  Future<Map<String, Object?>> get(
    String path, {
    Map<String, Object?>? query,
    String? host,
  }) async {
    final uri = Uri.https(
      host ?? FanqieEndpoints.host,
      path,
      {for (final entry in _commonQuery.entries) entry.key: '${entry.value}'}
        ..addAll({
          for (final entry in (query ?? const {}).entries)
            if (entry.value != null) entry.key: '${entry.value}',
        }),
    );
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      _appHeaders.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) {
          throw const FanqieException('响应超过 12MB，已中断');
        }
      }
      if (bytes.isEmpty) {
        // 静默拒绝：状态码 200，body 长度 0。参数或签名不对时会出现。
        throw const FanqieException('番茄返回了空响应，通常是参数或签名不对');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trimLeft().startsWith('<')) {
        throw const FanqieException('番茄返回了 HTML，可能触发了访问校验');
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FanqieException('番茄返回的不是 JSON 对象');
      }
      final code = decoded['code'];
      if (code is int && code != 0) {
        throw FanqieException(
          _messageFor(code),
          code: code,
          detail: '${decoded['message'] ?? decoded['msg'] ?? ''}',
        );
      }
      final data = decoded['data'];
      if (data is Map) return Map<String, Object?>.from(data);
      if (data is List) return {'list': data};
      return const {};
    } on SocketException catch (failure) {
      throw FanqieException('连不上番茄：${failure.message}');
    } on TimeoutException {
      throw const FanqieException('番茄响应超时，换个网络再试');
    } on FormatException {
      throw const FanqieException('番茄返回的内容不是合法 JSON');
    }
  }

  static String _messageFor(int code) => switch (code) {
    1004 || 1005 => '登录状态失效，请重新导入 Cookie',
    1001 => '番茄说这个设备或账号被限制了',
    1002 => '这一章需要付费',
    _ => '番茄返回了错误码 $code',
  };

  /// 从 HTML 里抠出 `window.__INITIAL_STATE__` 这个 JSON 对象。
  ///
  /// 不能简单地找第一个 `}`：值里的字符串可能带花括号（比如正文）。
  /// 这里用括号计数 + 字符串/转义状态机。
  static Map<String, Object?> _extractInitialState(String html) {
    const marker = 'window.__INITIAL_STATE__=';
    final start = html.indexOf(marker);
    if (start < 0) {
      throw const FanqieException('页面里没有 __INITIAL_STATE__，番茄可能改版了');
    }
    var index = start + marker.length;
    if (index >= html.length || html[index] != '{') {
      throw const FanqieException('__INITIAL_STATE__ 后面不是对象，番茄可能改版了');
    }
    var depth = 0;
    var inString = false;
    var escaped = false;
    final buffer = StringBuffer();
    for (; index < html.length; index += 1) {
      final ch = html[index];
      buffer.write(ch);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth += 1;
      } else if (ch == '}') {
        depth -= 1;
        if (depth == 0) break;
      }
    }
    if (depth != 0) {
      throw const FanqieException('__INITIAL_STATE__ 的括号没有闭合，页面可能被截断了');
    }
    final raw = buffer.toString();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
      throw const FanqieException('__INITIAL_STATE__ 不是对象');
    } on FormatException catch (failure) {
      throw FanqieException('__INITIAL_STATE__ 解析失败', detail: failure.message);
    }
  }

  void close() => _client.close(force: true);
}

/// 一本书。字段对齐网页版 `page` 对象。
class FanqieBook {
  const FanqieBook({
    required this.id,
    required this.title,
    required this.author,
    required this.summary,
    required this.coverUrl,
    required this.chapterCount,
    required this.wordCount,
    required this.completed,
    required this.category,
    required this.lastChapterTitle,
  });

  final String id;
  final String title;
  final String author;
  final String summary;
  final String coverUrl;
  final int chapterCount;
  final int wordCount;
  final bool completed;
  final String category;
  final String lastChapterTitle;

  static FanqieBook? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _string(raw['bookId']);
    final title = _string(raw['bookName']);
    if (id == null || title == null) return null;
    return FanqieBook(
      id: id,
      title: title,
      author: _string(raw['author']) ?? '佚名',
      summary: _string(raw['abstract']) ?? '',
      coverUrl: _string(raw['thumbUri']) ?? '',
      chapterCount: _int(raw['chapterTotal']) ?? 0,
      wordCount: _int(raw['wordNumber']) ?? 0,
      // creationStatus: 0 连载中 / 1 已完结（抓到的两本都是 0）。
      completed: _int(raw['creationStatus']) == 1,
      category: _string(raw['category']) ?? '',
      lastChapterTitle: _string(raw['lastChapterTitle']) ?? '',
    );
  }
}

/// 目录里的一章。
class FanqieTocItem {
  const FanqieTocItem({
    required this.id,
    required this.title,
    required this.volume,
    required this.order,
    required this.locked,
  });

  final String id;
  final String title;
  final String volume;
  final int order;
  final bool locked;

  static FanqieTocItem? fromJson(Object? raw, {String volume = ''}) {
    if (raw is! Map) return null;
    final id = _string(raw['itemId']);
    final title = _string(raw['title']);
    if (id == null || title == null) return null;
    return FanqieTocItem(
      id: id,
      title: title,
      volume: _string(raw['volume_name']) ?? volume,
      order: _int(raw['realChapterOrder']) ?? _int(raw['order']) ?? 0,
      locked: raw['isChapterLock'] == true || _int(raw['needPay']) == 1,
    );
  }
}

String? _string(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is num) return '$value';
  return null;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
