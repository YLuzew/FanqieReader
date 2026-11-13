import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// 番茄小说接口层。
//
// 这里的域名、路径与公共参数来自公开的社区实现，尚未在本机对线上接口逐条实测：
// 番茄的正文接口带 bdturing 滑块与设备指纹校验，服务端可以在任何时候改变要求。
// 因此每个请求失败都归一成 FanqieException，由上层转成可读提示；
// 协议一旦变动，只改本文件的 FanqieEndpoints 与 FanqieApi.headers 即可，
// Repository 与 UI 层无需改动。

/// 一次失败。message 面向用户，detail 面向日志。
class FanqieException implements Exception {
  const FanqieException(this.message, {this.code, this.detail});

  final String message;
  final int? code;
  final String? detail;

  @override
  String toString() =>
      'FanqieException(${code ?? '-'}): $message${detail == null ? '' : ' | $detail'}';
}

/// 接口地址与公共参数。协议变动时只改这一处。
abstract final class FanqieEndpoints {
  /// 主力线路。服务端按地域分流，另一条在 [alternateHost]。
  static const host = 'api5-normal-sinfonlineb.fqnovel.com';
  static const alternateHost = 'api5-normal-lf.fqnovel.com';

  /// 番茄读书的 App 标识。1967 是社区实现里长期在用的值。
  static const aid = 1967;
  static const appName = 'novelapp';
  static const channel = 'huawei_5140301';
  static const versionCode = 680;
  static const versionName = '6.8.0';

  /// 书籍详情（可批量）。
  static const bookDetail = '/reading/bookapi/multi-detail/v/';

  /// 目录。
  static const directory = '/reading/bookapi/directory/v/';

  /// 正文。这是风控最重的一条。
  static const content = '/reading/reader/full/v/';

  /// 搜索。
  static const search = '/reading/bookapi/search/page/v/';

  /// 书城频道列表（对应 PublicationCatalog）。
  static const channels = '/reading/bookapi/channel/v/';

  /// 频道下的书单。
  static const channelBooks = '/reading/bookapi/channel/books/v/';
}

/// 本机在番茄服务端眼中的身份。
///
/// 没有真实设备指纹，这里生成一组稳定的随机值并在整个进程内复用。
/// 之所以要稳定：服务端会把 device_id 与 install_id 和请求频次绑定，
/// 每次请求换新的比固定一个更容易触发风控。
class FanqieSession {
  FanqieSession({String? deviceId, String? installId})
    : deviceId = deviceId ?? _randomToken(20),
      installId = installId ?? _randomToken(11);

  final String deviceId;
  final String installId;

  static final _random = Random.secure();

  static String _randomToken(int length) {
    const alphabet = '0123456789abcdef';
    return String.fromCharCodes(
      List.generate(
        length,
        (_) => alphabet.codeUnitAt(_random.nextInt(alphabet.length)),
      ),
    );
  }

  /// 每次请求一个新值，用于 X-Request-Id。
  static String requestId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buffer.write('0123456789abcdef'[_random.nextInt(16)]);
    }
    return buffer.toString();
  }
}

/// 底层传输。只负责「发出去、拿回来、判断状态」，不解释业务字段。
class FanqieApi {
  FanqieApi({FanqieSession? session, Duration? timeout})
    : session = session ?? FanqieSession(),
      timeout = timeout ?? const Duration(seconds: 12);

  final FanqieSession session;
  final Duration timeout;
  HttpClient? _client;

  /// 登录态 Cookie（sessionid / sid_tt / passport_csrf_token 等）。
  /// null 表示游客：书库与搜索仍可用，正文与书架同步会被拦。
  /// 由 FanqieAccount 在登录成功或导入 Cookie 时写入。
  String? cookie;

  HttpClient get _http => _client ??= HttpClient()
    ..connectionTimeout = timeout
    ..userAgent = headers['User-Agent'];

  /// 番茄 App 的请求头。缺任何一条都可能被判定为非客户端流量。
  Map<String, String> get headers => {
    'User-Agent':
        'com.dragon.read/${FanqieEndpoints.versionName} (Linux; U; Android 13; zh_CN; '
        'Pixel 6; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296cf0 2024-01-01)',
    'Accept': 'application/json; charset=utf-8',
    'Accept-Encoding': 'gzip',
    'X-Fq-Device-Id': session.deviceId,
    'X-Request-Id': FanqieSession.requestId(),
    'Cookie': [
      'install_id=${session.installId}',
      'store-region=cn',
      if ((cookie ?? '').isNotEmpty) cookie!,
    ].join('; '),
  };

  /// 公共查询参数。番茄把设备信息放在 query 里而不是 body。
  Map<String, String> get commonQuery => {
    'aid': '${FanqieEndpoints.aid}',
    'app_name': FanqieEndpoints.appName,
    'channel': FanqieEndpoints.channel,
    'version_code': '${FanqieEndpoints.versionCode}',
    'device_id': session.deviceId,
    'iid': session.installId,
    'ac': 'wifi',
    'os': 'android',
  };

  /// 发一个 GET 并解出 `data` 字段。
  ///
  /// 番茄的成功响应形态是 `{"code":0,"message":"success","data":{...}}`；
  /// 风控拦截通常是 code 非 0 或直接返回 HTML，两种情况都在这里归一。
  Future<Map<String, Object?>> get(
    String path, {
    Map<String, String> query = const {},
    String? host,
  }) async {
    final uri = Uri.https(
      host ?? FanqieEndpoints.host,
      path,
      {...commonQuery, ...query},
    );
    HttpClientRequest request;
    try {
      request = await _http.getUrl(uri).timeout(timeout);
    } on TimeoutException {
      throw const FanqieException('连接番茄服务器超时，请检查网络');
    } on SocketException catch (error) {
      throw FanqieException('无法连接番茄服务器', detail: '$error');
    }
    headers.forEach(request.headers.set);
    HttpClientResponse response;
    try {
      response = await request.close().timeout(timeout);
    } on TimeoutException {
      throw const FanqieException('番茄服务器响应超时');
    } on SocketException catch (error) {
      throw FanqieException('番茄服务器连接中断', detail: '$error');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length > 12 * 1024 * 1024) {
        throw const FanqieException('番茄返回内容异常过大');
      }
    }
    final body = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    if (response.statusCode != 200) {
      throw FanqieException(
        '番茄服务器返回 ${response.statusCode}',
        code: response.statusCode,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      // 返回 HTML 通常意味着被风控挡在了网关层。
      throw FanqieException(
        '番茄返回了非预期内容，可能触发了访问校验',
        detail: body.length > 200 ? body.substring(0, 200) : body,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const FanqieException('番茄返回格式发生变化');
    }
    final code = decoded['code'];
    if (code is int && code != 0) {
      throw FanqieException(
        _messageFor(code),
        code: code,
        detail: '${decoded['message'] ?? ''}',
      );
    }
    final data = decoded['data'];
    if (data is Map<String, Object?>) return data;
    if (data is List) return {'list': data};
    return const {};
  }

  /// 把服务端 code 翻成人话。未知 code 保留原编号，方便日后比对。
  String _messageFor(int code) => switch (code) {
    1001 || 1002 => '番茄要求重新校验设备，请稍后重试',
    1004 => '登录状态已失效，请重新登录番茄账号',
    1005 => '该书籍在当前地区不可用',
    1009 => '访问过于频繁，番茄暂时限制了请求',
    _ => '番茄接口返回错误码 $code',
  };

  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

/// 书籍详情。
class FanqieBook {
  const FanqieBook({
    required this.bookId,
    required this.title,
    required this.author,
    required this.genre,
    required this.summary,
    required this.coverUrl,
    required this.wordCount,
    required this.chapterCount,
    required this.completed,
    required this.lastUpdate,
  });

  final int bookId;
  final String title;
  final String author;
  final String genre;
  final String summary;
  final String? coverUrl;
  final int wordCount;
  final int chapterCount;
  final bool completed;
  final String? lastUpdate;

  /// 从 multi-detail 的单条记录解析。
  ///
  /// 字段名以线上返回为准，未知字段一律忽略而不是抛错 —— 番茄改字段是常事，
  /// 多一个少一个不该让整个书库打不开。
  static FanqieBook? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _asInt(raw['book_id'] ?? raw['bookId']);
    if (id == null) return null;
    return FanqieBook(
      bookId: id,
      title: _asString(raw['book_name'] ?? raw['bookName']) ?? '未命名',
      author: _asString(raw['author'] ?? raw['author_name']) ?? '佚名',
      genre: _asString(raw['category'] ?? raw['tags']) ?? '',
      summary: _asString(raw['abstract'] ?? raw['description'] ?? raw['intro']) ?? '',
      coverUrl: _asString(raw['thumb_url'] ?? raw['cover_url']),
      wordCount: _asInt(raw['word_number'] ?? raw['word_count']) ?? 0,
      chapterCount: _asInt(raw['serial_count'] ?? raw['chapter_count']) ?? 0,
      completed: _asInt(raw['creation_status']) == 1 || raw['is_completed'] == true,
      lastUpdate: _asString(raw['last_chapter_title'] ?? raw['last_update_time']),
    );
  }
}

/// 目录条目。
class FanqieTocItem {
  const FanqieTocItem({
    required this.itemId,
    required this.title,
    this.volumeTitle = '',
    this.index = 0,
  });

  final int itemId;
  final String title;
  final String volumeTitle;
  final int index;

  static FanqieTocItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _asInt(raw['item_id'] ?? raw['itemId']);
    if (id == null) return null;
    return FanqieTocItem(
      itemId: id,
      title: _asString(raw['title']) ?? '无标题',
      volumeTitle: _asString(raw['volume_name']) ?? '',
      index: _asInt(raw['index']) ?? 0,
    );
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _asString(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is num) return '$value';
  return null;
}
