import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

// 番茄书的 bookId 是 19 位数字（7.1e18），远大于上游预留的远程 id 上限。
//
// 上游用 `isLocalBook(id) => id >= 0x60000000` 判断「这是不是本地导入的书」，
// 另有多处 `id > 0x7fffffff` 的上限校验。把番茄原始 bookId 直接塞进 Novel.id，
// 结果就是：
//   · detail() / chapters() 走本地分支 → 抛「本地原书不存在，请重新导入」
//   · 书架加不进去（setShelfMembership 里 present = present && !isLocalBook(id)）
//   · 改阅读样式抛「书籍标识无效」（_setBookReaderStyle 里 id > 0x7fffffff）
//
// 所以每本书在 0x40000000..0x5FFFFFFF 之间分配一个本地标识：
//   · > 0                 —— 上游多处 `id <= 0` 会直接跳过
//   · < localBookIdStart  —— 不被 isLocalBook 命中
//   · <= 0x7fffffff       —— 满足所有上限校验
//   · 不在 local_books 的随机区间 0x60000000..0x7fffffff 内，不会撞本地书
//
// 映射持久化在 SharedPreferences，重启后保持不变；书架、进度、正文缓存
// 全靠它对应回真正的那本书。

const int fanqieLocalIdStart = 0x40000000;
const int fanqieLocalIdEnd = 0x5FFFFFFF;
const String fanqieIdMapKey = 'fanqie.idmap.v1';

class FanqieIdMap {
  FanqieIdMap({SharedPreferences? preferences}) : _preferences = preferences;

  SharedPreferences? _preferences;
  final Map<String, int> _remoteToLocal = {};
  final Map<int, String> _localToRemote = {};
  int _next = fanqieLocalIdStart;
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = _preferences ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(fanqieIdMapKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final remote = '${entry.key}';
        final local = entry.value;
        if (local is! int) continue;
        if (local < fanqieLocalIdStart || local > fanqieLocalIdEnd) continue;
        if (_localToRemote.containsKey(local)) continue;
        _remoteToLocal[remote] = local;
        _localToRemote[local] = remote;
        if (local >= _next) _next = local + 1;
      }
    } catch (_) {
      // 记录坏了就当没有：重新分配不会丢书，只是旧书架条目对不上。
      // 与其抛异常让整个阅读器起不来，不如让它自己长回来。
      _remoteToLocal.clear();
      _localToRemote.clear();
      _next = fanqieLocalIdStart;
    }
  }

  /// 这本书的本地标识；没有就分配一个并落盘。
  Future<int> localIdFor(String remoteId) async {
    await load();
    final existing = _remoteToLocal[remoteId];
    if (existing != null) return existing;
    if (_next > fanqieLocalIdEnd) {
      throw StateError('番茄书籍标识空间已用尽，请清理一次书架');
    }
    final local = _next++;
    _remoteToLocal[remoteId] = local;
    _localToRemote[local] = remoteId;
    await _flush();
    return local;
  }

  /// 反查真正的 bookId。查不到返回 null（说明这本书不是当前映射分配的）。
  String? remoteIdFor(int localId) => _localToRemote[localId];

  /// 已经分配过的本地标识数量，给诊断用。
  int get size => _remoteToLocal.length;

  Future<void> _flush() async {
    final prefs = _preferences ??= await SharedPreferences.getInstance();
    await prefs.setString(
      fanqieIdMapKey,
      jsonEncode({
        for (final entry in _remoteToLocal.entries) entry.key: entry.value,
      }),
    );
  }
}
