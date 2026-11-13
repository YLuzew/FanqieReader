import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'fanqie_sign.dart';

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
// 网页版只放前 10 章（第 11 章起 isChapterLock=true）。要拿全本得走 App 的
// reading.snssdk.com/reading/reader/full/v/ —— 它要 x-argus + x-ladon 签名，
// 签名算法在 fanqie_sign.dart（纯 Dart），正文还要用 registerkey 换来的
// secret key 做 AES-CBC 解密。所以 fetchChapter 现在的顺序是：
//   1) App 接口（全本）   2) 失败才回落网页版（只有前 10 章）
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

  /// 正文网关。和 api5-normal-* 不是一台机器：这边吃 x-argus + x-ladon，
  /// 那边吃 X-Helios + X-Medusa，算法完全不同。
  static const readingHost = 'reading.snssdk.com';
  static const readerFullPath = '/reading/reader/full/v/';
  static const registerKeyPath = '/reading/crypt/registerkey';

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
  static const categoryLanding = '/reading/bookapi/new_category/landing/v/';
  static const categoryList = '/reading/bookapi/category/list/v/';

  /// 书架/历史/进度走的是 api5-normal-*，不是正文那台网关。
  /// 路径取自 fqapp 的 account_library.rs（官方 App 的 RPC 反查）。
  static const shelfList = '/reading/bookapi/bookshelf/list/v1/';
  static const shelfInfo = '/reading/bookapi/bookshelf/info/v1/';
  static const readHistory = '/reading/bookapi/read_history/list/v1/';
  static const readProgress = '/reading/bookapi/read_progress/list/v1/';

  /// 书架接口要求的版本号，比正文网关的 66.9 新。签名会从 query 里取
  /// version_name 写进 x-argus，所以这几个值必须成套用，别单个换。
  static const shelfVersionCode = '73932';
  static const shelfVersionName = '7.3.9.32';
  static const shelfUserAgent =
      'com.dragon.read/73932 (Linux; U; Android 15; zh_CN; '
      'sdk_gphone64_arm64; Build/AP3A.241105.008)';

  /// 桌面浏览器 UA。移动端 UA 会拿到另一套页面结构，别换。
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// 从 Cookie 里取 csrf token 用的键。网页版没它也能读公开章节。
  static const csrfCookie = 'passport_csrf_token';

  /// App 正文接口认这个 UA。换成浏览器 UA 会掉回网页版那套限制。
  static const appUserAgent =
      'com.dragon.read/71332 (Linux; U; Android 15; zh_CN; '
      'sdk_gphone64_arm64; Build/AP3A.241105.008;tt-ok/3.12.13.20)';

  /// registerkey 只认裸 UA，带版本号那串会被拒。
  static const appShortUserAgent = 'com.dragon.read';
}

/// 设备侧的一次性标识。只有 App API 用得上，网页版不需要。
class FanqieSession {
  FanqieSession({String? deviceId, String? installId})
    : deviceId = deviceId ?? _randomDeviceId(),
      // 必须是 "0"：registerkey 会核对 iid，随便填一个会被判 verify fail。
      installId = installId ?? '0';

  final String deviceId;
  final String installId;

  static final _random = Random.secure();

  /// 番茄的真实设备号是 15~19 位十进制，首位 6~7。
  ///
  /// 别用 9 开头或 20 位：registerkey 要把设备号编进 u64 再签名，
  /// 超出 2^63 的值服务端直接回 `{"code":500002,"message":"verify fail"}`。
  static String _randomDeviceId() => '7${_randomDigits(18)}';

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
      timeout = timeout ?? const Duration(seconds: 35),
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

  /// 正文解密用的密钥。由 registerkey 按 device_id 下发，进程内缓存即可 ——
  /// 它跟设备绑定，不跟账号绑定，丢了重新注册一次就有。
  String? _secretKey;

  /// 正在注册时别的章节也来要 key，共用同一个请求，别各自发一遍。
  Future<String?>? _secretKeyPending;

  /// 服务端明确拒绝过（code != 0）才置位。网络抖动不算 —— 那种下次还能成。
  bool _secretKeyBroken = false;

  /// App 正文请求：`reading.snssdk.com/reading/reader/full/v/`。
  ///
  /// 返回 `{content, title}`，`content` 是已解密的 XHTML。拿不到就返回 null，
  /// 由调用方决定要不要回落。
  Future<Map<String, Object?>?> _fetchChapterViaApp(String itemId) async {
    final key = await _ensureSecretKey();
    if (key == null) return null;

    final query = 'aid=${FanqieEndpoints.aid}'
        '&app_name=${FanqieEndpoints.appName}'
        '&channel=0'
        '&device_platform=android'
        '&device_id=${session.deviceId}'
        '&device_type=Honor10'
        '&item_id=$itemId'
        '&os_version=0'
        '&version_code=66.9';

    final response = await _appGet(
      FanqieEndpoints.readerFullPath,
      query,
    );
    final body = utf8.decode(response, allowMalformed: true);
    if (body.trimLeft().startsWith('<')) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    if (decoded['code'] != 0) {
      throw FanqieException(
        '正文接口返回 ${decoded['code']}',
        detail: '${decoded['message'] ?? ''}',
      );
    }
    final data = decoded['data'];
    if (data is! Map) return null;
    final encrypted = data['content'];
    if (encrypted is! String || encrypted.isEmpty || encrypted == 'Invalid') {
      return null;
    }

    final plain = decryptUpstream(encrypted, key);
    final text = utf8.decode(plain, allowMalformed: true);
    final title = data['title'];
    return {
      'content': text,
      if (title is String && title.isNotEmpty) 'title': title,
      'itemId': itemId,
    };
  }

  /// 换 secret key。device_id 是随机会话号也能注册成功 —— 服务端不校验
  /// 这个号是否来自真实装机，只要求它是一个合法的数字 id。
  Future<String?> _ensureSecretKey() {
    if (_secretKey != null) return Future<String?>.value(_secretKey);
    if (_secretKeyBroken) return Future<String?>.value(null);
    return _secretKeyPending ??= _registerSecretKey().whenComplete(() {
      _secretKeyPending = null;
    });
  }

  Future<String?> _registerSecretKey() async {
    final content = encodeRegisterContent(session.deviceId);
    final payload = utf8.encode(jsonEncode({'content': content}));
    final compressed = gzip.encode(payload);

    // 这串必须按字母序拼：服务端拿它去核对签名，顺序错了签名就对不上。
    final query = [
      'aid=${FanqieEndpoints.aid}',
      'app_name=${FanqieEndpoints.appName}',
      'channel=0',
      'device_id=${session.deviceId}',
      'device_platform=android',
      'iid=${session.installId}',
      'os_version=0',
      'version_code=6.1.5.32',
      'version_name=6.1.5.32',
    ].join('&');

    final signature = fanqieSignHeaders(
      query: query,
      body: compressed,
      deviceId: session.deviceId,
      installId: session.installId,
    );

    final uri = Uri.parse(
      'https://${FanqieEndpoints.readingHost}'
      '${FanqieEndpoints.registerKeyPath}?$query',
    );
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.set('User-Agent', FanqieEndpoints.appShortUserAgent);
    request.headers.set('Content-Encoding', 'gzip');
    request.headers.contentType = ContentType.json;
    request.headers.set('Accept', 'application/json');
    signature.forEach(request.headers.set);
    request.add(compressed);

    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) {
        throw const FanqieException('registerkey 响应超过 12MB，已中断');
      }
    }
    if (response.statusCode != 200 || bytes.isEmpty) {
      throw FanqieException('registerkey 失败：HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return null;
    // code 500002 = verify fail，多半是 device_id 或 iid 不合规。
    // 这种换一个设备号还能成，但同一台设备号重试没用，所以只钉这一次。
    if (decoded['code'] != 0) {
      if (decoded['code'] == 500002) _secretKeyBroken = true;
      return null;
    }
    final data = decoded['data'];
    if (data is! Map) return null;
    final key = data['key'];
    if (key is! String || key.isEmpty) return null;
    return _secretKey = decryptRegisterKey(key);
  }

  /// 带签名的 App GET。签名绑 URL，所以 query 必须和这里拼的一字不差。
  ///
  /// [host] 换机器（正文是 reading.snssdk.com，书架是 api5-normal-*），
  /// [cookie] 只给要账号的接口用 —— 正文接口不认 Cookie，带上反而多一层校验。
  Future<Uint8List> _appGet(
    String path,
    String query, {
    String? host,
    String? cookie,
    String? userAgent,
  }) async {
    final signature = fanqieSignHeaders(
      query: query,
      deviceId: session.deviceId,
      installId: session.installId,
    );
    final uri = Uri.parse(
      'https://${host ?? FanqieEndpoints.readingHost}$path?$query',
    );
    final request = await _client.getUrl(uri).timeout(timeout);
    request.headers.set(
      'User-Agent',
      userAgent ?? FanqieEndpoints.appUserAgent,
    );
    request.headers.set('Accept', 'application/json');
    if (cookie != null && cookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookie);
    }
    signature.forEach(request.headers.set);
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) {
        throw const FanqieException('正文响应超过 12MB，已中断');
      }
    }
    if (response.statusCode != 200) {
      throw FanqieException('App 接口 HTTP ${response.statusCode}');
    }
    if (bytes.isEmpty) {
      throw const FanqieException('正文接口返回空响应，签名可能没对');
    }
    return Uint8List.fromList(bytes);
  }

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
    // 先试 App 网关。它没有 10 章限制，但要多两步：签名 + 解密。
    // 任何一步失败都当作"这条路不通"，回落到网页版，而不是把整本书卡死。
    // App 网关失败的原始原因。网页版也失败时一起报出来 —— 只显示
    // 「要付费或要登录」会把人引到错的方向，真正的原因可能在签名那一步。
    String appFailure = '没走到 App 网关';
    try {
      final viaApp = await _fetchChapterViaApp(itemId);
      if (viaApp != null) return viaApp;
      appFailure = 'App 网关没返回正文';
    } catch (error) {
      // 签名/解密失败不该盖住网页版能给的那 10 章，但要留下记录。
      appFailure = '$error';
      stderr.writeln('[fanqie] App 网关失败: $error');
    }

    try {
      return await _fetchChapterViaWeb(itemId);
    } on FanqieException catch (error) {
      throw FanqieException(
        error.message,
        code: error.code,
        detail: 'App 网关：$appFailure',
      );
    }
  }

  /// 网页版正文，只有前 10 章可用。
  Future<Map<String, Object?>> _fetchChapterViaWeb(String itemId) async {
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

  /// 拉书架。返回服务端原始 data，不做字段解读 —— 书架的书目结构和
  /// 网页版的 searchItem 不是一套，没实测之前不瞎映射。
  ///
  /// 注意：**未登录时也回 code:0**，data 里只有 `{is_all, server_time, limit}`，
  /// 没有 books。所以「成功但空」是没 Cookie，不是签名错了。
  /// 账号认的是 Cookie 里的 sessionid / sessionid_ss / sid_tt，
  /// device_id 只负责过签名。
  Future<Map<String, Object?>?> fetchShelf() async {
    final auth = cookie ?? '';
    if (auth.isEmpty) return null;
    final query = 'aid=${FanqieEndpoints.aid}'
        '&app_name=${FanqieEndpoints.appName}'
        '&device_platform=android'
        '&version_code=${FanqieEndpoints.shelfVersionCode}'
        '&version_name=${FanqieEndpoints.shelfVersionName}'
        '&device_id=${session.deviceId}'
        '&iid=${session.installId}'
        '&server_time=0';
    final bytes = await _appGet(
      FanqieEndpoints.shelfList,
      query,
      host: FanqieEndpoints.host,
      cookie: auth,
      userAgent: FanqieEndpoints.shelfUserAgent,
    );
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return null;
    if (decoded['code'] != 0) {
      throw FanqieException(
        '书架接口返回 ${decoded['code']}',
        detail: '${decoded['message'] ?? ''}',
      );
    }
    final data = decoded['data'];
    if (data is! Map) return null;
    return Map<String, Object?>.from(data);
  }

  /// 书名搜索。
  ///
  /// 网页版的 `/api/reader/*` 对未登录只回空 body，但 App 网关的
  /// `search/page/v/` 实测能出结果（不需要 Cookie，签名走 device_id）。
  /// 返回的是 cell 数组：每格 `book_data[0]` 才是书对象，`book_data` 为空
  /// 的格子是广告位或聚合卡片，直接跳过。
  ///
  /// 这几个参数看着怪但都是必需的：`device_type=Honor10`、`os_version=0`、
  /// `version_code=66.9` —— 换成新版号或真实机型会被判非法请求。
  Future<List<Map<String, Object?>>> searchBooks(
    String keyword, {
    int offset = 0,
    int count = 10,
  }) async {
    final word = keyword.trim();
    if (word.isEmpty) return const [];
    final query = 'query=${Uri.encodeQueryComponent(word)}'
        '&offset=$offset'
        '&count=$count'
        '&aid=${FanqieEndpoints.aid}'
        '&app_name=${FanqieEndpoints.appName}'
        '&channel=0'
        '&device_platform=android'
        '&device_id=${session.deviceId}'
        '&device_type=Honor10'
        '&os_version=0'
        '&version_code=66.9';
    final bytes = await _appGet(FanqieEndpoints.search, query);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return const [];
    final code = decoded['code'];
    if (code is int && code != 0) {
      throw FanqieException(
        '搜索接口返回 $code',
        detail: '${decoded['message'] ?? ''}',
      );
    }
    final data = decoded['data'];
    if (data is! List) return const [];
    final out = <Map<String, Object?>>[];
    for (final cell in data) {
      if (cell is! Map) continue;
      final books = cell['book_data'];
      if (books is! List || books.isEmpty) continue;
      final book = books.first;
      if (book is Map) out.add(Map<String, Object?>.from(book));
    }
    return out;
  }

  /// 题材大类。
  ///
  /// 只有一层，13 个，内容固定：现代都市 / 异世玄幻 / 官场职场 / 魔法奇幻 /
  /// 武侠世界 / 仙侠修真 / 历史穿越 / 军事战争 / 悬疑灵异 / 科幻末世 /
  /// 游戏电竞 / 体育竞技 / 二次元。没有子分类接口 —— 细分标签（法医、斩神
  /// 这种）是分类落地页 `data.category` 里的单项，不是一棵树。
  Future<List<FanqieCategory>> fetchCategoryList() async {
    final query = 'aid=${FanqieEndpoints.aid}'
        '&app_name=${FanqieEndpoints.appName}'
        '&channel=0'
        '&device_platform=android'
        '&device_id=${session.deviceId}'
        '&device_type=Honor10'
        '&os_version=0'
        '&version_code=69132'
        '&update_version_code=69132'
        '&manifest_version_code=69132'
        '&version_name=6.9.1.32';
    final bytes = await _appGet(FanqieEndpoints.categoryList, query);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return const [];
    final data = decoded['data'];
    if (data is! List) return const [];
    return [
      for (final entry in data)
        if (entry is Map)
          FanqieCategory(
            id: _int(entry['id']) ?? 0,
            name: _string(entry['name']) ?? '',
          ),
    ];
  }

  /// 分类落地页。
  ///
  /// 书目在 `data.book_info`（不是 book_list），筛选维度在 `data.rule`：
  ///   sort_by     综合 0 / 热门 24 / 最新 76 / 评分 12
  ///   word_type   全部 0 / 100 万字以下 1 / 100-300 万 2 / 300 万以上 3
  ///   book_status 全部 2 / 完结 0 / 连载中 1 / 今日更新 3
  /// [filters] 里的键直接拼进 query，签名会一起覆盖，不需要另做处理。
  Future<Map<String, Object?>> fetchCategory({
    required int categoryId,
    int gender = 0,
    int genreType = 0,
    int offset = 0,
    int limit = 100,
    Map<String, String> filters = const {},
  }) async {
    final extra = filters.entries.map((e) => '&${e.key}=${e.value}').join();
    final query = 'category_id=$categoryId'
        '&gender=$gender'
        '&genre_type=$genreType'
        '&offset=$offset'
        '&limit=$limit'
        '&page_version=1'
        '$extra'
        '&aid=${FanqieEndpoints.aid}'
        '&app_name=${FanqieEndpoints.appName}'
        '&channel=0'
        '&device_platform=android'
        '&device_id=${session.deviceId}'
        '&device_type=Honor10'
        '&os_version=0'
        '&version_code=69132'
        '&update_version_code=69132'
        '&manifest_version_code=69132'
        '&version_name=6.9.1.32';
    final bytes = await _appGet(FanqieEndpoints.categoryLanding, query);
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return const {};
    final code = decoded['code'];
    if (code is int && code != 0) {
      throw FanqieException(
        '分类接口返回 $code',
        detail: '${decoded['message'] ?? ''}',
      );
    }
    final data = decoded['data'];
    return data is Map ? Map<String, Object?>.from(data) : const {};
  }

  /// 取封面图。
  ///
  /// 番茄的封面是签名 URL（byteimg 的 CDN），直接 GET 就行，不需要 cookie
  /// 也不需要 Referer。任何失败都返回 null —— 封面加载不出来不该让整页报错。
  Future<Uint8List?> fetchCoverBytes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    try {
      final request = await _client.getUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        FanqieEndpoints.userAgent,
      );
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final collector = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in response) {
        total += chunk.length;
        // 封面不该有这么大，超过就是出了别的问题。
        if (total > 4 * 1024 * 1024) return null;
        collector.add(chunk);
      }
      final bytes = collector.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } on Exception {
      return null;
    }
  }

  /// 首页（发现页）的书单。
  ///
  /// 番茄首页的 SSR 里就带着几组推荐书单，不需要额外接口：
  ///   editorList 编辑推荐(9) / weekList 本周强推(8) / updateList 最近更新(20)
  /// boyList / girlList 在没有登录态时是 null，所以不指望它们。
  Future<List<Map<String, Object?>>> fetchHomeBooks() async {
    final html = await _fetchHtml(
      Uri.https(FanqieEndpoints.webHost, '/').toString(),
    );
    final state = _extractInitialState(html);
    final home = state['home'];
    if (home is! Map) {
      throw const FanqieException('首页里没找到书单数据，可能是页面结构变了');
    }
    final out = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final key in const ['editorList', 'weekList', 'updateList']) {
      final list = home[key];
      if (list is! List) continue;
      for (final item in list) {
        if (item is! Map) continue;
        final id = item['bookId'];
        // updateList 的项没有摘要，但 bookId/bookName/author 都有，够列表用。
        if (id is! String || !seen.add(id)) continue;
        out.add(Map<String, Object?>.from(item));
      }
    }
    if (out.isEmpty) {
      throw const FanqieException('首页书单是空的，可能触发了访问校验');
    }
    return out;
  }

  /// 读某本书的阅读进度。
  ///
  /// 番茄这批 `/api/reader/*` 有一个很好用的性质：**先校验登录，再管参数**。
  /// 没带 cookie 时无论参数写成什么样都只回「请先登录」，不会报参数错误 ——
  /// 说明参数格式可以等拿到登录态之后再校准，这里按最直觉的写法先接上。
  Future<Map<String, Object?>> fetchReadingProgress(String bookId) async =>
      _readerJson('/api/reader/book/progress', {'bookId': bookId});

  /// 读某本书已读章节列表。
  Future<Map<String, Object?>> fetchReadItemList(String bookId) async =>
      _readerJson('/api/reader/book/read_item_list', {'bookId': bookId});

  /// 上报阅读进度。多个章节一起上报走这个接口（单章上报没有独立路径，
  /// `POST /api/reader/book/progress` 是 404，只有 GET）。
  Future<Map<String, Object?>> pushReadingProgress({
    required String bookId,
    required String itemId,
    int progress = 0,
  }) async => _readerPost('/api/reader/book/batch_update_progress', {
    'bookId': bookId,
    'itemIds': [itemId],
    'progress': progress,
  });

  Future<Map<String, Object?>> _readerJson(
    String path,
    Map<String, String> query,
  ) async {
    final text = await _fetchHtml(
      'https://${FanqieEndpoints.webHost}$path?'
      '${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}',
      referer: 'https://${FanqieEndpoints.webHost}/',
    );
    final data = jsonDecode(text);
    if (data is! Map) throw const FanqieException('进度接口返回的不是对象');
    final map = Map<String, Object?>.from(data);
    final message = _string(map['message']);
    if (message != null && message.isNotEmpty) {
      throw FanqieException(message, code: map['code'] is int ? map['code'] as int : null);
    }
    return map;
  }

  Future<Map<String, Object?>> _readerPost(
    String path,
    Map<String, Object?> body,
  ) async {
    final uri = Uri.parse('https://${FanqieEndpoints.webHost}$path');
    final request = await _client.postUrl(uri).timeout(timeout);
    _webHeaders.forEach(request.headers.set);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) {
        throw const FanqieException('响应超过 12MB，已中断');
      }
    }
    final data = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (data is! Map) throw const FanqieException('进度接口返回的不是对象');
    final map = Map<String, Object?>.from(data);
    final message = _string(map['message']);
    if (message != null && message.isNotEmpty) {
      throw FanqieException(message, code: map['code'] is int ? map['code'] as int : null);
    }
    return map;
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
      // creationStatus：0 = 已完结，1 = 连载中（跟直觉相反，实测确认）。
      // 证据：十日终焉(1496章/末章「陈俊南（终）」)、娇养玫瑰(「全文完」)、
      // 莫若凌霄(「完结」) 全是 0；日更榜里 10~4970 章的在更书全是 1。
      // 同页的 status 字段恒为 1，没有区分度，别用它。
      completed: (_int(raw['creationStatus']) ?? 1) == 0,
      category: _string(raw['category']) ?? '',
      lastChapterTitle: _string(raw['lastChapterTitle']) ?? '',
    );
  }

  /// App 网关那一套接口（搜索 / 分类 / 书架）用的是 snake_case，
  /// 跟网页版 SSR 的 camelCase 不是一个命名，所以单独一支解析。
  static FanqieBook? fromAppJson(Object? raw) {
    if (raw is! Map) return null;
    final id = _string(raw['book_id']);
    final title = _string(raw['book_name']);
    if (id == null || title == null) return null;
    return FanqieBook(
      id: id,
      title: title,
      author: _string(raw['author']) ?? '佚名',
      summary: _string(raw['abstract']) ?? '',
      coverUrl: appCoverUrl(_string(raw['thumb_url'])),
      chapterCount: _int(raw['serial_count']) ?? 0,
      wordCount: _int(raw['word_number']) ?? 0,
      // 和网页版一致：0 = 已完结，1 = 连载中。
      completed: (_int(raw['creation_status']) ?? 1) == 0,
      category: _string(raw['category']) ?? '',
      lastChapterTitle:
          _string(raw['last_chapter_title']) ??
          _string(raw['first_chapter_title']) ??
          '',
    );
  }

  /// 把带签名、几小时就过期的封面地址换成长效的那条。
  ///
  /// 网关回的是
  /// `https://p3-reading-sign.fqnovelpic.com/novel-pic/<hash>~tplv-....image?x-signature=...`
  /// 去掉 `~` 之后的部分、换到 `p6-novel.byteimg.com/origin` 就是同一张图，
  /// 而且不带签名不会过期（实测两张都 200）。
  static String appCoverUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    final marker = url.indexOf('/novel-pic/');
    if (marker < 0) return url;
    final cut = url.indexOf('~', marker);
    final tail = url.substring(marker, cut < 0 ? url.length : cut);
    return 'https://p6-novel.byteimg.com/origin$tail';
  }
}

/// 一个题材大类。
class FanqieCategory {
  const FanqieCategory({required this.id, required this.name});

  final int id;
  final String name;
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
