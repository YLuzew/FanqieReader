import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'fanqie_api.dart';
import 'fanqie_login.dart';
import 'online_component.dart';
import 'wenku_account.dart';

// 番茄账号。
//
// 番茄的手机号登录走 bdturing 滑块，客户端自己跑不完这套校验，
// 所以这里只做一条现实路径：**导入 Cookie**。
// 用户在浏览器或已登录的设备上复制 Cookie 串，粘进登录页，由本类校验并保存。
//
// 尚未接入（保持父类的「未包含在线组件」兜底）：
//   · 阅读时长同步 —— 需要番茄自己的上报签名与时间戳链路
//   · 段评 / 书评 —— 需要帖子接口与内容审核签名
//   · 书架云同步 —— 需要 shelf 接口与书籍映射
// 这三块的接口地址与签名算法都没有实测，不写假的实现。

/// 番茄账号。用 extends 而不是重写 WenkuAccount，是为了让 main.dart
/// 那处 `WenkuAccount?` 的声明不用改，同时保留源无关的展示接口。
class FanqieAccount extends WenkuAccount {
  FanqieAccount({required this.api, this.preferences});

  final FanqieApi api;
  SharedPreferences? preferences;

  static const _cookieKey = 'fanqie.cookie.v1';
  static const _profileKey = 'fanqie.profile.v1';

  /// 是否已经有一条可用的登录态。
  bool get hasSession => (api.cookie ?? '').isNotEmpty;

  @override
  Future<void> initialize() async {
    busy = true;
    notifyListeners();
    try {
      final prefs = preferences ??= await SharedPreferences.getInstance();
      final stored = prefs.getString(_cookieKey);
      if (stored != null && stored.isNotEmpty) {
        api.cookie = stored;
        authenticated = true;
        _restoreProfile(prefs.getString(_profileKey));
        // 有网络时顺手刷新一次；失败不回滚登录态，只是资料旧一点。
        await refreshProfile().catchError((Object _) {});
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 番茄没有面向第三方的密码登录。
  ///
  /// 账号栏留空 = 走 App 内的番茄登录页（推荐）。
  /// 账号栏贴了东西 = 当作 Cookie 串导入（老路径，保留）。
  @override
  Future<void> login(String username, String password) async {
    final raw = (username + (password.isEmpty ? '' : '; $password')).trim();
    if (raw.isEmpty) {
      await loginInWebView();
      return;
    }
    final failure = await importCookie(raw);
    if (failure != null) throw FanqieException(failure);
  }

  /// 开一个原生 WebView，让用户在番茄自己的页面上登录。
  ///
  /// 番茄的手机号登录带 bdturing 滑块，客户端自己跑不完；`sessionid` 又是
  /// HttpOnly，网页里的 JS 读不到。所以真正能走通的就是这条：
  /// 用户自己在番茄页面登，登完由 `CookieManager` 把 HttpOnly 的 cookie
  /// 一起读回来。用户取消登录就静默返回，不当错误。
  Future<void> loginInWebView() async {
    if (busy) return;
    // 这一步只在等用户操作，不占用 busy —— importCookie 会自己接管状态。
    final cookie = await FanqieLogin.open();
    // 用户在登录页点了返回，不算失败。
    if (cookie == null) return;
    final failure = await importCookie(cookie);
    if (failure != null) throw FanqieException(failure);
  }

  /// 导入一串 Cookie。返回 null 表示成功，否则是给用户看的失败原因。
  ///
  /// 接收任意形态：整条 `Cookie:` 头、分号分隔的键值对、或从 DevTools 复制的多行。
  /// 只要能抠出 sessionid / sid_tt 之一就认为有登录态。
  Future<String?> importCookie(String raw) async {
    busy = true;
    operation = '正在校验番茄登录态';
    error = null;
    notifyListeners();
    try {
      final parsed = parseCookieHeader(raw);
      if (parsed.isEmpty) {
        return '没解析出任何 Cookie 字段，请确认复制的是完整的 Cookie 串';
      }
      if (!parsed.containsKey('sessionid') &&
          !parsed.containsKey('sid_tt') &&
          !parsed.containsKey('passport_csrf_token')) {
        return '这条 Cookie 里没有登录凭证（sessionid / sid_tt），请确认已经登录番茄后复制';
      }
      api.cookie = parsed.entries.map((e) => '${e.key}=${e.value}').join('; ');
      final prefs = preferences ??= await SharedPreferences.getInstance();
      await prefs.setString(_cookieKey, api.cookie!);
      authenticated = true;
      // 拉一次资料，顺便验证这条 Cookie 到底算不算数。
      // 光是「拿到 sessionid」不算数 —— 服务端不认的时候资料接口会回 -1。
      await refreshProfile();
      if (!authenticated) {
        await _forgetSession();
        return error ?? '番茄没有认出这条登录态';
      }
      return null;
    } on FanqieException catch (failure) {
      error = failure.message;
      return failure.message;
    } catch (failure) {
      error = '导入失败：$failure';
      return error;
    } finally {
      operation = null;
      busy = false;
      notifyListeners();
    }
  }

  @override
  Future<void> refreshProfile() async {
    if (!hasSession) throw const OnlineAuthenticationRequired();
    final result = await FanqieLogin.profile(api.cookie!);
    switch (result.status) {
      case FanqieProfileStatus.ok:
        final web = result.profile!;
        final nickname = web.name.isEmpty ? '番茄用户' : web.name;
        profile = WenkuProfile(
          id: int.tryParse(web.uid) ?? 0,
          username: nickname,
          nickname: nickname,
          score: 0,
          experience: 0,
          rank: '',
        );
        final prefs = preferences ??= await SharedPreferences.getInstance();
        await prefs.setString(
          _profileKey,
          jsonEncode(_profileToJson(profile!)),
        );
        error = null;
        notifyListeners();
      case FanqieProfileStatus.unauthenticated:
        // 服务端明确说这条 Cookie 不算数了，才清本地态。
        await _forgetSession();
        error = '番茄不认这条登录态，请重新登录';
        notifyListeners();
      case FanqieProfileStatus.unavailable:
        // 网络问题。不动本地态，也不写 error —— 下次进来会再试。
        break;
    }
  }

  @override
  Future<void> logout() async {
    await FanqieLogin.logout();
    api.cookie = null;
    final prefs = preferences ??= await SharedPreferences.getInstance();
    await prefs.remove(_cookieKey);
    await prefs.remove(_profileKey);
    await super.logout();
  }

  /// 只清本地登录态，不碰 WebView 里的 cookie。
  ///
  /// `logout()` 会连原生 CookieManager 一起清；而这里要覆盖的场景是
  /// 「本地存的这条不算数了」，用户可能马上要换一条登进来，不该顺手把
  /// 浏览器里的登录也清掉。
  Future<void> _forgetSession() async {
    api.cookie = null;
    authenticated = false;
    profile = null;
    final prefs = preferences ??= await SharedPreferences.getInstance();
    await prefs.remove(_cookieKey);
    await prefs.remove(_profileKey);
  }

  void _restoreProfile(String? raw) {
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      profile = WenkuProfile(
        id: _intOf(decoded['id']) ?? 0,
        username: _stringOf(decoded['username']) ?? '',
        nickname: _stringOf(decoded['nickname']) ?? '',
        score: _intOf(decoded['score']) ?? 0,
        experience: _intOf(decoded['experience']) ?? 0,
        rank: _stringOf(decoded['rank']) ?? '',
      );
    } on FormatException {
      // 旧版本写坏的数据直接丢弃，下次登录会重写。
    }
  }

  static Map<String, Object?> _profileToJson(WenkuProfile profile) => {
    'id': profile.id,
    'username': profile.username,
    'nickname': profile.nickname,
    'score': profile.score,
    'experience': profile.experience,
    'rank': profile.rank,
  };

  /// 把任意形态的 Cookie 串拆成键值对。
  ///
  /// 容错点：带不带 `Cookie:` 前缀、有没有换行、值里带 `=`、末尾多分号。
  static Map<String, String> parseCookieHeader(String raw) {
    var text = raw.trim();
    if (text.toLowerCase().startsWith('cookie:')) {
      text = text.substring(7);
    }
    final result = <String, String>{};
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      for (final piece in line.split(';')) {
        final trimmed = piece.trim();
        if (trimmed.isEmpty) continue;
        final split = trimmed.indexOf('=');
        if (split <= 0) continue;
        final key = trimmed.substring(0, split).trim();
        final value = trimmed.substring(split + 1).trim();
        if (key.isEmpty) continue;
        result[key] = value;
      }
    }
    return result;
  }
}

int? _intOf(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

String? _stringOf(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is num) return '$value';
  return null;
}
