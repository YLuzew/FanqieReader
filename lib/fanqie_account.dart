import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'fanqie_api.dart';
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

  /// 番茄的用户信息接口。未实测，失败时不影响已有登录态。
  static const _userInfoPath = '/reading/user/info/v/';

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
  /// 登录页沿用父类的「账号 / 密码」两栏，这里把它的语义改成：
  /// 账号栏粘贴 Cookie（或只看 Cookie 里的 sessionid），密码栏留空。
  /// 这样不用改页面结构，用户也能立刻用起来。
  @override
  Future<void> login(String username, String password) async {
    final raw = (username + (password.isEmpty ? '' : '; $password')).trim();
    if (raw.isEmpty) {
      throw const FanqieException('请把番茄的 Cookie 粘贴到账号栏');
    }
    final failure = await importCookie(raw);
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
      await refreshProfile();
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
    try {
      final data = await api.get(_userInfoPath);
      final id = _intOf(data['user_id'] ?? data['uid'] ?? data['id']) ?? 0;
      final nickname =
          _stringOf(data['user_name'] ?? data['nickname'] ?? data['name']) ??
          '番茄用户';
      profile = WenkuProfile(
        id: id,
        username: nickname,
        nickname: nickname,
        score: _intOf(data['score'] ?? data['coin']) ?? 0,
        experience: _intOf(data['experience'] ?? data['level']) ?? 0,
        rank: _stringOf(data['rank'] ?? data['user_rank']) ?? '',
      );
      final prefs = preferences ??= await SharedPreferences.getInstance();
      await prefs.setString(_profileKey, jsonEncode(_profileToJson(profile!)));
      notifyListeners();
    } on FanqieException catch (failure) {
      // 401/登录失效要清掉本地态，其它错误保留。
      if (failure.code == 1004) {
        await logout();
      }
      error = failure.message;
      notifyListeners();
    }
  }

  @override
  Future<void> logout() async {
    api.cookie = null;
    final prefs = preferences ??= await SharedPreferences.getInstance();
    await prefs.remove(_cookieKey);
    await prefs.remove(_profileKey);
    await super.logout();
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
