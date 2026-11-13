import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// 番茄登录。
///
/// 番茄的手机号登录带 bdturing 滑块，客户端自己跑不完；而 `sessionid` 是
/// HttpOnly 的，网页里的 JavaScript 读不到。所以走这条路：开一个原生
/// WebView 让用户在番茄自己的页面上登录，登录完成后由
/// `android.webkit.CookieManager` 把 cookie 串（含 HttpOnly）读回来。
///
/// 平台侧实现见 `FanqieLoginPlugin.kt`。
class FanqieLogin {
  static const _channel = MethodChannel('org.mewx.wenku8/fanqie_login');

  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  /// 打开登录页。用户登完点「完成」返回 cookie 串，取消返回 null。
  static Future<String?> open() async {
    try {
      final raw = await _channel.invokeMethod<String>('login');
      return (raw == null || raw.trim().isEmpty) ? null : raw.trim();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // 非 Android 端没有这条通道，交给调用方提示。
      return null;
    }
  }

  /// 直接读当前 WebView 里的 cookie（用户之前在别处登过的话）。
  static Future<String?> cookies() async {
    try {
      final raw = await _channel.invokeMethod<String>('cookies');
      return (raw == null || raw.trim().isEmpty) ? null : raw.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<void> logout() async {
    try {
      await _channel.invokeMethod<void>('logout');
    } catch (_) {
      // 原生侧没装通道时不算失败 —— 本地态照样要清。
    }
  }

  /// 拿 cookie 打一次网页版资料接口，确认这条登录态是真能用的。
  ///
  /// 未登录时番茄回的是 `{"code":-1,"message":"请先登录"}`，HTTP 仍是 200，
  /// 所以只认 `code == 0` 且有 `data`。三种结果必须分开：把「网断了」当成
  /// 「登录失效」会把用户已经登好的 sessionid 白扔掉。
  static Future<FanqieProfileResult> profile(String cookie) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(Uri.parse('https://fanqienovel.com/api/user/info/v2'))
          .timeout(const Duration(seconds: 20));
      request.headers.set('Cookie', cookie);
      request.headers.set('User-Agent', _userAgent);
      request.headers.set('Accept', 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return const FanqieProfileResult(FanqieProfileStatus.unavailable);
      }
      if ((decoded['code'] as num?)?.toInt() != 0) {
        return const FanqieProfileResult(FanqieProfileStatus.unauthenticated);
      }
      final data = decoded['data'];
      if (data is! Map || data.isEmpty) {
        return const FanqieProfileResult(FanqieProfileStatus.unauthenticated);
      }
      return FanqieProfileResult(
        FanqieProfileStatus.ok,
        FanqieWebProfile.fromJson(Map<String, Object?>.from(data)),
      );
    } catch (_) {
      return const FanqieProfileResult(FanqieProfileStatus.unavailable);
    } finally {
      client.close(force: true);
    }
  }
}

/// 资料接口的三种结局：拿到了 / 明确未登录 / 这次问不通。
enum FanqieProfileStatus { ok, unauthenticated, unavailable }

class FanqieProfileResult {
  const FanqieProfileResult(this.status, [this.profile]);

  final FanqieProfileStatus status;
  final FanqieWebProfile? profile;

  bool get isOk => status == FanqieProfileStatus.ok;
  bool get isUnauthenticated =>
      status == FanqieProfileStatus.unauthenticated;
}

/// 网页版 `user/info/v2` 里我们真正会用到的那几个字段。
class FanqieWebProfile {
  const FanqieWebProfile({
    required this.name,
    required this.uid,
    this.avatarUrl,
    this.description,
  });

  final String name;
  final String uid;
  final String? avatarUrl;
  final String? description;

  static FanqieWebProfile fromJson(Map<String, Object?> raw) {
    String pick(List<String> keys) {
      for (final key in keys) {
        final value = raw[key];
        if (value is String && value.isNotEmpty) return value;
        if (value is num) return '$value';
      }
      return '';
    }

    return FanqieWebProfile(
      name: pick(const ['name', 'user_name', 'nickname']),
      uid: pick(const ['uid', 'user_id', 'id']),
      avatarUrl: pick(const ['avatar_url', 'avatar', 'avatar_uri']),
      description: pick(const ['description', 'desc', 'signature']),
    );
  }
}
