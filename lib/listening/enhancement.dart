import 'package:flutter/foundation.dart';

/// 声音增强偏好。当前构建一律视为关闭，不做任何增益处理。
@immutable
class ListeningEnhancementPreference {
  const ListeningEnhancementPreference({this.enabled = false});

  final bool enabled;

  ListeningEnhancementPreference copyWith({bool? enabled}) =>
      ListeningEnhancementPreference(enabled: enabled ?? this.enabled);

  Map<String, Object?> toJson() => {'enabled': enabled};

  static ListeningEnhancementPreference fromJson(Map<dynamic, dynamic> json) =>
      ListeningEnhancementPreference(enabled: json['enabled'] == true);

  @override
  bool operator ==(Object other) =>
      other is ListeningEnhancementPreference && other.enabled == enabled;

  @override
  int get hashCode => enabled.hashCode;
}

/// 声音增强处理器。本构建为空实现：调用不改变任何音频输出。
class ListeningEnhancement {
  ListeningEnhancement();

  ListeningEnhancementPreference preference =
      const ListeningEnhancementPreference();

  bool get active => false;

  Future<void> configure(ListeningEnhancementPreference value) async {
    preference = value;
  }

  Future<void> setPreference(ListeningEnhancementPreference value) async {
    preference = value;
  }

  Future<void> dispose() async {}
}
