import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'fanqie_audio.dart';
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
  /// 老的搜索入口，一次最多 10 条、`count` 传大也没用。
  static const search = '/reading/bookapi/search/page/v/';

  /// 真正的搜索结果页：分 tab，`tab_type` 3 = 书籍、1 = 综合（作者卡混在里面）。
  /// 一次能拿 99 条，`offset` 用返回的 `next_offset` 往下翻。
  static const searchTab = '/reading/bookapi/search/tab/v';

  /// `searchTab` 只在 api5-normal-sinfonlineb 上，别的 host 会 404。
  /// 注意这里是**不带 scheme 的主机名** —— `_appGet` 自己拼 `https://`，
  /// 多写一个 `https://` 会拼成 `https://https://...`，报
  /// `Failed host lookup: 'https'`。
  static const shelfHost = 'api5-normal-sinfonlineb.fqnovel.com';
  static const categoryLanding = '/reading/bookapi/new_category/landing/v/';
  static const categoryList = '/reading/bookapi/category/list/v/';

  /// 商城首页（发现页）的推荐流。
  ///
  /// 响应的 `data.tab_item` 是一排 tab，只有 `tab_type=2` 那个带 `cell_data`；
  /// 区块再套区块，最里层才挂 `book_data[0]`。中间那些 `show_type` 100/339
  /// 的格子是 banner 和「书荒广场」入口，没有书。
  static const homeTab = '/reading/bookapi/bookmall/tab/v';

  /// 同一个区块往下翻。`cell_id` 与 `session_id` 都由服务端签发，
  /// 必须从上一页的响应里取，自己编一个会拿到空列表。
  static const homeFeed = '/reading/bookapi/bookmall/cell/change/v';

  /// 书评（长评）走的是 api3 —— 这是老版本 5.1.5.32 的接口，反而比现在的
  /// `/novel/commentapi/comment/list/{id}/v1` 好使：新接口对 body 命名极挑，
  /// snake_case 回 `lack book_id`、camelCase 回 `cannot found handler key`，
  /// `source`/`channel` 传哪都不认。这条老接口一次 20 条，`offset` 翻页。
  static const commentHost = 'api3-normal-sinfonlineb.fqnovel.com';
  static const bookReviews = '/reading/ugc/novel_comment/book/v/';

  /// 段评（被人划线的那几段）。只回「哪段有划线 + 那段原文」，
  /// 具体评论不在这条接口里。
  static const chapterSummaries = '/reading/reader/item_summary/mget/v';

  /// 听书的 TTS 播放地址。`tone_id` 默认 74，填 0 会 `NO_THIS_TONE`。
  static const audioPlayInfo = '/reading/reader/audio/playinfo/';
  /// 听书走 api5 这台，`readingHost` 上没有这个接口。
  static const audioHost = 'api5-normal-sinfonlineb.fqnovel.com';

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

  /// `_appGet` 的 JSON 版：顺手做掉解码与 `code != 0` 的判定。
  ///
  /// 这类接口出错时会回一整页 HTML（状态码还是 200），直接 `jsonDecode`
  /// 抛的是 `FormatException`，看不出是哪个接口 —— 所以先看一眼开头。
  /// App 网关的 POST。签名要用**原始 body 字节**算 x-ss-stub，
  /// 所以这里收 `List<int>` 而不是先编码再传——编码一次、签一次，
  /// 两边不一致就会被判签名错。
  Future<Uint8List> _appPost(
    String path,
    String query,
    List<int> body, {
    String? host,
    String? cookie,
    String? userAgent,
  }) async {
    final signature = fanqieSignHeaders(
      query: query,
      body: body,
      deviceId: session.deviceId,
      installId: session.installId,
    );
    final uri = Uri.parse(
      'https://${host ?? FanqieEndpoints.readingHost}$path?$query',
    );
    final request = await _client.postUrl(uri).timeout(timeout);
    request.headers.set(
      'User-Agent',
      userAgent ?? FanqieEndpoints.appUserAgent,
    );
    request.headers.set('Accept', 'application/json');
    request.headers.contentType = ContentType.json;
    if (cookie != null && cookie.isNotEmpty) {
      request.headers.set(HttpHeaders.cookieHeader, cookie);
    }
    signature.forEach(request.headers.set);
    request.add(body);
    final response = await request.close().timeout(timeout);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBody) {
        throw const FanqieException('响应超过 12MB，已中断');
      }
    }
    if (response.statusCode != 200) {
      throw FanqieException('App 接口 HTTP ${response.statusCode}');
    }
    return Uint8List.fromList(bytes);
  }

  Future<Map<String, Object?>> _appJson(
    String path,
    String query, {
    String? host,
    String? cookie,
    String? userAgent,
  }) async {
    final bytes = await _appGet(
      path,
      query,
      host: host,
      cookie: cookie,
      userAgent: userAgent,
    );
    final text = utf8.decode(bytes, allowMalformed: true);
    if (text.trimLeft().startsWith('<')) {
      throw const FanqieException('接口返回的是网页，不是 JSON');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw const FanqieException('接口返回的不是对象');
    final code = decoded['code'];
    if (code != 0) {
      throw FanqieException(
        '接口返回 $code',
        detail: '${decoded['message'] ?? ''}',
      );
    }
    return Map<String, Object?>.from(decoded);
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

  /// 阅读历史，服务端按最近读过排。
  ///
  /// 参数取自 fqapp 的 `account_history.rs`：`limit=0` 表示「全给我」，
  /// `offset` 用响应里的 `next_offset` 往下翻。`last_min_read_timestamp_ms`
  /// 和 `is_first_load` 是官方 SDK 的默认值，漏了会被判参数错误。
  ///
  /// `full_field` 官方写死 `false` —— 传 `true` 服务端会当非法参数。
  Future<Map<String, Object?>?> fetchReadHistory({
    int offset = 0,
    bool isFirstLoad = true,
  }) async {
    final auth = cookie ?? '';
    if (auth.isEmpty) return null;
    final query =
        'aid=${FanqieEndpoints.aid}'
        '&app_name=${FanqieEndpoints.appName}'
        '&device_platform=android'
        '&version_code=${FanqieEndpoints.shelfVersionCode}'
        '&version_name=${FanqieEndpoints.shelfVersionName}'
        '&device_id=${session.deviceId}'
        '&iid=${session.installId}'
        '&book_type=0'
        '&limit=0'
        '&offset=$offset'
        '&last_min_read_timestamp_ms=0'
        '&full_field=false'
        '&is_first_load=$isFirstLoad'
        '&query_soft_deleted=false';
    final decoded = await _appJson(
      FanqieEndpoints.readHistory,
      query,
      host: FanqieEndpoints.host,
      cookie: auth,
      userAgent: FanqieEndpoints.shelfUserAgent,
    );
    final data = decoded['data'];
    return data is Map ? Map<String, Object?>.from(data) : null;
  }
  /// 一章的听书音轨信息。番茄给的是**加密**的 MP4，光有 URL 播不了。
  Future<FanqieAudioTrack?> fetchAudioTrack(
    String bookId,
    String itemId, {
    int toneId = 74,
  }) async {
    final query =
        'book_id=$bookId&item_ids=$itemId&tone_id=$toneId'
        '&req_type=0&is_local_book=false&$_homeBaseQuery';
    final payload = await _appJson(
      FanqieEndpoints.audioPlayInfo,
      query,
      host: FanqieEndpoints.audioHost,
    );
    final data = payload['data'];
    if (data is! List || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;
    final map = first.cast<String, Object?>();
    final url = _string(map['main_url']) ?? _string(map['backup_url']);
    if (url == null || url.isEmpty) return null;
    var spadeA = '';
    final rawModel = _string(map['video_model']);
    if (rawModel != null && rawModel.isNotEmpty) {
      try {
        final model = jsonDecode(rawModel);
        if (model is Map) {
          final list = model['video_list'];
          if (list is List && list.isNotEmpty) {
            final variant = list.first;
            if (variant is Map) {
              final info = variant['encrypt_info'];
              if (info is Map) spadeA = _string(info['spade_a']) ?? '';
            }
          }
        }
      } on FormatException {
        // 结构不认识就当没加密信息，后面按明文播。
      }
    }
    return FanqieAudioTrack(
      url: url,
      spadeA: spadeA,
      encrypted: map['is_encrypt'] == true,
      quality: _int(map['quality']) ?? 128,
    );
  }

  /// 下一章听书音频，解好密落到磁盘，返回可以直接喂给播放器的文件。
  ///
  /// 缓存按 `bookId/itemId-tone.mp4` 存，同一个音色第二次点开是秒开。
  Future<File?> fetchChapterAudio(
    String bookId,
    String itemId, {
    int toneId = 74,
    Directory? cacheDirectory,
  }) async {
    final track = await fetchAudioTrack(bookId, itemId, toneId: toneId);
    if (track == null) return null;
    final root =
        cacheDirectory ??
        Directory('${(await getApplicationSupportDirectory()).path}/fanqie-audio');
    final file = File('${root.path}/$bookId-$itemId-$toneId.mp4');
    if (await file.exists() && await file.length() > 1024) return file;
    final response = await _client
        .getUrl(Uri.parse(track.url))
        .timeout(const Duration(seconds: 60));
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    final bytes = builder;
    var data = bytes.takeBytes();
    if (data.length < 4096) return null;
    if (track.encrypted) {
      final decrypted = await FanqieAudioCipher.decrypt(
        encrypted: data,
        spadeA: track.spadeA,
      );
      if (decrypted == null) return null;
      data = decrypted;
    }
    await root.create(recursive: true);
    await file.writeAsBytes(data, flush: true);
    return file;
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
    int count = 19,
  }) async {
    final tab = await _searchTab(keyword, tabType: 3, offset: offset, count: count);
    final out = <Map<String, Object?>>[];
    for (final cell in tab.data) {
      final books = cell['book_data'];
      if (books is! List || books.isEmpty) continue;
      final book = books.first;
      if (book is Map) out.add(Map<String, Object?>.from(book));
    }
    return out;
  }

  /// 综合 tab 里的作者卡。搜「金色米粒」时第一条就是作者本身，
  /// 以前只解析 `book_data` 会把它当广告位丢掉，于是看起来「搜作者出来的全是书」。
  Future<List<FanqieAuthor>> searchAuthors(
    String keyword, {
    int count = 10,
  }) async {
    final tab = await _searchTab(keyword, tabType: 1, offset: 0, count: count);
    final out = <FanqieAuthor>[];
    for (final cell in tab.data) {
      if (cell['show_type'] != 132) continue;
      final name = cell['cell_name'];
      if (name is! String || name.trim().isEmpty) continue;
      final users = cell['search_user_data'];
      String userId = '';
      String? avatar;
      if (users is List && users.isNotEmpty && users.first is Map) {
        final user = users.first as Map;
        userId = '${user['user_id'] ?? ''}';
        final pic = user['user_avatar'];
        if (pic is String && pic.isNotEmpty) avatar = pic;
      }
      out.add(FanqieAuthor(name: name.trim(), userId: userId, avatarUrl: avatar));
    }
    return out;
  }

  Future<_FanqieSearchTab> _searchTab(
    String keyword, {
    required int tabType,
    required int offset,
    required int count,
  }) async {
    final word = keyword.trim();
    if (word.isEmpty) return const _FanqieSearchTab.empty();
    final query =
        'bookshelf_search_plan=4'
        '&offset=$offset'
        '&user_is_login=1'
        '&bookstore_tab=2'
        '&passback='
        '&query=${Uri.encodeQueryComponent(word)}'
        '&count=$count'
        '&search_source=1'
        '&clicked_content=search_history'
        '&use_lynx=false'
        '&use_correct=true'
        '&tab_type=$tabType'
        '&tab_name=store'
        '&pad_column_cover=0'
        '&is_first_enter_search=false'
        '&iid=${session.installId}'
        '&device_id=${session.deviceId}'
        '&ac=wifi'
        '&channel=xiaomi_1967_64'
        '&aid=${FanqieEndpoints.aid}'
        '&app_name=novelapp'
        '&version_code=65132'
        '&version_name=6.5.1.32'
        '&device_platform=android'
        '&os=android'
        '&ssmix=a'
        '&device_type=FRD-AL10'
        '&device_brand=honor'
        '&language=zh'
        '&os_api=28'
        '&os_version=9'
        '&manifest_version_code=65132'
        '&resolution=1080%2A1920'
        '&dpi=480'
        '&update_version_code=65132'
        '&pv_player=65132'
        '&gender=2'
        '&need_personal_recommend=1'
        '&player_so_load=1'
        '&is_android_pad_screen=0'
        '&host_abi=arm64-v8a'
        '&dragon_device_type=phone'
        '&compliance_status=0';
    final bytes = await _appGet(
      FanqieEndpoints.searchTab,
      query,
      host: FanqieEndpoints.shelfHost,
    );
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return const _FanqieSearchTab.empty();
    final code = decoded['code'];
    if (code is int && code != 0) {
      throw FanqieException(
        '搜索接口返回 $code',
        detail: '${decoded['message'] ?? ''}',
      );
    }
    final tabs = decoded['search_tabs'];
    if (tabs is! List) return const _FanqieSearchTab.empty();
    for (final entry in tabs) {
      if (entry is! Map) continue;
      if (entry['tab_type'] != tabType) continue;
      final data = entry['data'];
      final cells = <Map<String, Object?>>[
        if (data is List)
          for (final cell in data)
            if (cell is Map) Map<String, Object?>.from(cell),
      ];
      return _FanqieSearchTab(
        cells,
        hasMore: entry['has_more'] == true,
        nextOffset: entry['next_offset'] is num
            ? (entry['next_offset'] as num).toInt()
            : null,
      );
    }
    return const _FanqieSearchTab.empty();
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

  /// 发现页的书流，一页 12 本，能一直往下翻。
  ///
  /// 旧实现抓网页版首页的 SSR，只有编辑力荐 4 + 本周推荐 4 + 一批更新列表，
  /// 而且更新列表那批不带封面，界面上就是一排黑块。换商城 tab 接口之后
  /// 一页 12 本、封面齐全，翻页也不再是空页。
  Future<FanqieHomeFeed> fetchHomeFeed({int page = 1}) async {
    final offset = (page - 1) * _homePageSize;
    final wantFirst = offset == 0 || _homeCellId == null || _homeSessionId == null;
    final query = wantFirst
        ? '$_homeBaseQuery&tab_type=2&tab_index=0&last_tab_index=0&offset=0'
        : '$_homeBaseQuery&cell_id=$_homeCellId&offset=$offset&tab_type=2'
              '&tab_index=0&session_id=$_homeSessionId';
    final decoded = await _appJson(
      wantFirst ? FanqieEndpoints.homeTab : FanqieEndpoints.homeFeed,
      query,
      host: FanqieEndpoints.shelfHost,
      // 登录了就带上，推荐会从「路人热榜」变成「按你读过什么推」；
      // 没登录时 cookie 是空串，_appGet 会自己忽略。
      cookie: cookie,
    );
    final data = decoded['data'];
    if (data is! Map) throw const FanqieException('发现页没有拿到书流');
    _rememberHomeCursor(data);
    final books = <Map<String, Object?>>[];
    _collectHomeBooks(data, books, 0);
    return FanqieHomeFeed(books: books, hasMore: books.isNotEmpty);
  }

  /// 发现页一页多少本。`cell/change/v` 一次固定回 12 条，翻了也只是换一批。
  static const _homePageSize = 12;

  /// 翻页游标，跟着响应走。换书源、重开 App 都重新取。
  String? _homeCellId;
  String? _homeSessionId;

  /// 商城接口那一套版本号。签名会把 `version_name` 写进 x-argus，
  /// 所以这几个值必须成套，别跟正文网关那套 66.9 混着用。
  String get _homeBaseQuery =>
      'iid=${session.installId}'
      '&device_id=${session.deviceId}'
      '&ac=wifi'
      '&channel=xiaomi_1967_64'
      '&aid=${FanqieEndpoints.aid}'
      '&app_name=novelapp'
      '&version_code=72432'
      '&version_name=7.2.4.32'
      '&device_platform=android'
      '&os=android'
      '&ssmix=a'
      '&device_type=25053RT47C'
      '&device_brand=Redmi'
      '&language=zh'
      '&os_api=36'
      '&os_version=16'
      '&manifest_version_code=72432'
      '&resolution=1280%2A2620'
      '&dpi=520'
      '&update_version_code=72432'
      '&host_abi=arm64-v8a'
      '&dragon_device_type=phone'
      '&pv_player=72432'
      '&compliance_status=0'
      '&need_personal_recommend=1'
      '&player_so_load=1'
      '&is_android_pad_screen=0'
      '&client_req_type=1'
      '&client_template=0';

  /// 从响应里挑第一个有 `cell_id` 的区块当翻页游标。
  ///
  /// 首页那次返回的 `tab_item` 里只有被选中的 tab 带 `cell_data`，
  /// 所以扫到第一个就收手，不往下找。
  void _rememberHomeCursor(Map<Object?, Object?> data) {
    final tabs = data['tab_item'];
    if (tabs is! List) return;
    for (final tab in tabs) {
      if (tab is! Map) continue;
      final cells = tab['cell_data'];
      if (cells is! List || cells.isEmpty) continue;
      for (final cell in cells) {
        if (cell is! Map) continue;
        final id = cell['cell_id_str'] ?? cell['cell_id'];
        if (id != null && '$id' != '0') _homeCellId = '$id';
        final sid = cell['session_id'] ?? tab['session_id'];
        if (sid is String && sid.isNotEmpty) _homeSessionId = sid;
        if (_homeCellId != null) return;
      }
    }
  }

  /// 递归把 `book_data[0]` 全部捞出来。
  ///
  /// 区块嵌套层数不固定（推荐流是三层），所以不写死路径；遇到 banner 那种
  /// 没有 `book_data` 的格子就继续往下钻，遇到书就收下并停止下钻。同一本书
  /// 在推荐流里可能重复出现，按 `book_id` 去重。
  void _collectHomeBooks(
    Object? node,
    List<Map<String, Object?>> out,
    int depth,
  ) {
    if (depth > 6) return;
    if (node is List) {
      for (final item in node) {
        _collectHomeBooks(item, out, depth + 1);
      }
      return;
    }
    if (node is! Map) return;
    final books = node['book_data'];
    if (books is List && books.isNotEmpty) {
      final book = books.first;
      if (book is Map) {
        final id = book['book_id'];
        if (id != null && out.every((e) => '${e['book_id']}' != '$id')) {
          out.add(Map<String, Object?>.from(book));
        }
      }
      return;
    }
    for (final value in node.values) {
      _collectHomeBooks(value, out, depth + 1);
    }
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

  /// 一章的段评计数。
  ///
  /// 返回 `{段落索引: 条数}`。番茄的段评是按「第几段」挂的，段落切分
  /// 用的是它自己的规则；我们这边的段落切分跟它不完全一致，所以这个
  /// 数字只当热度提示用，别拿来找对应文字。
  ///
  /// 接口只给计数（`count`），具体评论要另走 comment/list —— 那条对
  /// body 极挑，`group_id` 填 item_id 也回「参数错误」，暂时不动。
  Future<Map<int, int>> fetchChapterCommentCounts(
    String bookId,
    String itemId,
  ) async {
    final query =
        'iid=${session.installId}&device_id=${session.deviceId}'
        '&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp'
        '&version_code=72432&version_name=7.2.4.32&device_platform=android'
        '&os=android&ssmix=a&device_type=25053RT47C&device_brand=Redmi'
        '&language=zh&os_api=36&os_version=16&manifest_version_code=72432'
        '&resolution=1280%2A2620&dpi=520&update_version_code=72432'
        '&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=72432'
        '&compliance_status=0&need_personal_recommend=1&player_so_load=1'
        '&is_android_pad_screen=0';
    final body = jsonEncode({
      'comment_source': 3,
      'compliance_status': 0,
      'item_id': itemId,
      'item_version': '',
      'server_channel': 7,
    });
    final bytes = await _appPost(
      '/novel/commentapi/idea/list/$itemId/v1/',
      query,
      utf8.encode(body),
      host: FanqieEndpoints.shelfHost,
    );
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return const {};
    final data = decoded['data'];
    if (data is! Map) return const {};
    final table = data['data'];
    if (table is! Map) return const {};
    final out = <int, int>{};
    for (final entry in table.entries) {
      final index = int.tryParse('${entry.key}');
      final row = entry.value;
      if (index == null || row is! Map) continue;
      final count = _int(row['count']) ?? 0;
      if (count > 0) out[index] = count;
    }
    return out;
  }

  /// 某一段的段评正文。
  ///
  /// 和书评同一个网关、同一个 body 骨架，区别在三处：`group_id` 用书号
  /// （不是章节 id）、`comment_type=2`（填 0/1 会回 `comment_type invalid`）、
  /// `para_index` 指段落序号。翻页靠 `common_list_info.cursor`，把那一串
  /// 原样塞回 body 的 `cursor` 字段即可。
  Future<FanqieParagraphComments> fetchParagraphComments(
    String bookId, {
    required int paragraphIndex,
    String cursor = '',
    int count = 20,
  }) async {
    final query =
        'iid=${session.installId}&device_id=${session.deviceId}'
        '&ac=wifi&channel=xiaomi_1967_64&aid=1967&app_name=novelapp'
        '&version_code=72432&version_name=7.2.4.32&device_platform=android'
        '&os=android&ssmix=a&device_type=25053RT47C&device_brand=Redmi'
        '&language=zh&os_api=36&os_version=16&manifest_version_code=72432'
        '&resolution=1280%2A2620&dpi=520&update_version_code=72432'
        '&host_abi=arm64-v8a&dragon_device_type=phone&pv_player=72432'
        '&compliance_status=0&need_personal_recommend=1&player_so_load=1'
        '&is_android_pad_screen=0';
    final body = <String, Object?>{
      'business_param': {
        'book_id': bookId,
        'comment_sort_debug': false,
        'end_offset_time': 0,
        'fold_type': 0,
        'item_count': 0,
        'item_version': '',
        'max_item_count': 0,
        'need_danmaku_occlusion_face_data': false,
        'para_index': paragraphIndex,
        'playlet_item_duration': 0,
        'read_item_count': 0,
        'req_type': 0,
        'start_offset_time': 0,
        'need_count': cursor.isEmpty,
      },
      'comment_source': 1,
      'comment_type': 2,
      'count': count,
      'group_id': bookId,
      'group_type': 1,
      'server_channel': 7,
      'sort': 1,
    };
    if (cursor.isNotEmpty) body['cursor'] = cursor;
    final bytes = await _appPost(
      '/novel/commentapi/comment/list/$bookId/v1/',
      query,
      utf8.encode(jsonEncode(body)),
      host: FanqieEndpoints.shelfHost,
    );
    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map) return const FanqieParagraphComments(reviews: []);
    final data = decoded['data'];
    if (data is! Map) return const FanqieParagraphComments(reviews: []);
    final list = data['data_list'];
    final reviews = <FanqieReview>[];
    if (list is List) {
      for (final item in list) {
        if (item is! Map) continue;
        final inner = item['comment'];
        final review = FanqieReview.fromJson(inner is Map ? inner : item);
        if (review != null) reviews.add(review);
      }
    }
    final info = data['common_list_info'];
    var hasMore = false;
    var next = '';
    var total = 0;
    if (info is Map) {
      hasMore = info['has_more'] == true;
      next = _string(info['cursor']) ?? '';
      total = _int(info['total']) ?? 0;
    }
    return FanqieParagraphComments(
      reviews: reviews,
      hasMore: hasMore,
      cursor: next,
      total: total,
    );
  }

  /// 一本书的书评列表。
  ///
  /// 走 api3 的老接口（版本号填 5.1.5.32、`version_code=515` 那套），
  /// 这是实测唯一能通的一条：新接口对 body 命名极度挑剔，怎么拼都
  /// 只回 `lack book_id` 或 `cannot found handler key`。
  Future<FanqieReviewPage> fetchBookReviews(
    String bookId, {
    int offset = 0,
    int count = 20,
  }) async {
    final query =
        'app_name=novelapp&channel=0&book_id=$bookId&device_type=Honor10'
        '&aid=1967&version_name=5.1.5.32&count=$count&os_version=9.3.5'
        '&device_platform=android&version_code=515'
        '&device_id=${session.deviceId}&offset=$offset';
    final payload = await _appJson(
      FanqieEndpoints.bookReviews,
      query,
      host: FanqieEndpoints.commentHost,
    );
    final data = payload['data'];
    final map = data is Map ? data : const <String, Object?>{};
    final raw = map['comment'];
    final reviews = <FanqieReview>[
      if (raw is List)
        for (final item in raw)
          if (FanqieReview.fromJson(item) case final review?) review,
    ];
    return FanqieReviewPage(
      reviews: reviews,
      hasMore: map['has_more'] == true,
      nextOffset: _int(map['next_offset']),
      scoreCount: _int(map['score_cnt']) ?? 0,
      commentCount: _int(map['comment_cnt']) ?? 0,
    );
  }

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
    this.score,
    this.reviewCount,
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

  /// 番茄自己的评分（`score`，0~10，一位小数）。没评分的老书会是 null。
  final double? score;

  /// 参与评分的人数，番茄叫 `score_count`。
  final int? reviewCount;

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
      score: _double(raw['score']),
      reviewCount: _int(raw['scoreNum']) ?? _int(raw['score_num']),
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
      score: _double(raw['score']),
      reviewCount: _int(raw['score_count']) ?? _int(raw['score_num']),
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
class _FanqieSearchTab {
  const _FanqieSearchTab(this.cells, {this.hasMore = false, this.nextOffset});
  const _FanqieSearchTab.empty()
    : cells = const [],
      hasMore = false,
      nextOffset = null;

  final List<Map<String, Object?>> cells;
  final bool hasMore;
  final int? nextOffset;

  List<Map<String, Object?>> get data => cells;
}

/// 搜索结果里的作者卡（综合 tab 里 `show_type == 132` 的那一条）。
class FanqieAuthor {
  const FanqieAuthor({
    required this.name,
    required this.userId,
    this.avatarUrl,
  });

  final String name;
  final String userId;
  final String? avatarUrl;
}

class FanqieCategory {
  const FanqieCategory({required this.id, required this.name});

  final int id;
  final String name;
}

/// 发现页一页的结果。
class FanqieHomeFeed {
  const FanqieHomeFeed({required this.books, required this.hasMore});

  /// 这一页的书，字段与搜索返回的 `book_data[0]` 一致（snake_case）。
  final List<Map<String, Object?>> books;

  /// 还有没有下一页。接口没有明确的结束标记，拿到空页就自然停了。
  final bool hasMore;
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

/// 评分是浮点（`8.8`），有时又会以字符串形式回来，所以单开一个。
double? _double(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

/// 一条书评。
class FanqieReview {
  const FanqieReview({
    required this.id,
    required this.text,
    required this.userName,
    this.avatarUrl,
    this.score,
    this.likes = 0,
    this.replies = 0,
    this.createdAt,
    this.isAuthor = false,
    this.readMinutes = 0,
  });

  final String id;
  final String text;
  final String userName;
  final String? avatarUrl;

  /// 这条书评自己打的星，0~10，可能没填。
  final double? score;
  final int likes;
  final int replies;
  final DateTime? createdAt;

  /// 作者本人下场写的（番茄会标出来）。
  final bool isAuthor;

  /// 评论者说自己的阅读时长，单位分钟。
  final int readMinutes;

  static FanqieReview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = _string(raw['text']);
    if (text == null) return null;
    final user = raw['user_info'];
    final info = user is Map ? user : const <String, Object?>{};
    final stamp = _int(raw['create_timestamp']);
    return FanqieReview(
      id: _string(raw['comment_id']) ?? '',
      text: text,
      userName:
          _string(info['user_name']) ?? _string(raw['user_name']) ?? '读者',
      avatarUrl: _string(info['user_avatar']),
      score: _double(raw['score']),
      likes: _int(raw['digg_count']) ?? 0,
      replies: _int(raw['reply_count']) ?? 0,
      createdAt: stamp == null || stamp <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(stamp * 1000),
      isAuthor: info['is_author'] == true,
      readMinutes: _int(raw['read_duration']) ?? 0,
    );
  }
}

/// 一页书评。
class FanqieReviewPage {
  const FanqieReviewPage({
    required this.reviews,
    required this.hasMore,
    this.nextOffset,
    this.scoreCount = 0,
    this.commentCount = 0,
  });

  final List<FanqieReview> reviews;
  final bool hasMore;
  final int? nextOffset;
  final int scoreCount;
  final int commentCount;
}

/// 听书音轨的元信息。
class FanqieAudioTrack {
  const FanqieAudioTrack({
    required this.url,
    required this.spadeA,
    required this.encrypted,
    required this.quality,
  });

  final String url;
  final String spadeA;
  final bool encrypted;
  final int quality;
}

/// 某一段的段评列表。`cursor` 是服务端签的一串 JSON，翻页时原样回传。
class FanqieParagraphComments {
  const FanqieParagraphComments({
    required this.reviews,
    this.hasMore = false,
    this.cursor = '',
    this.total = 0,
  });

  final List<FanqieReview> reviews;
  final bool hasMore;
  final String cursor;
  final int total;
}
