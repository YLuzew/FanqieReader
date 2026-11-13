import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// 自定义语音接口的配置快照。
@immutable
class CustomSpeechConfig {
  const CustomSpeechConfig({
    this.namespace = '',
    this.voiceId = '',
    this.locale = '',
  });

  final String namespace;
  final String voiceId;
  final String locale;

  bool get isConfigured =>
      namespace.isNotEmpty && voiceId.isNotEmpty && locale.isNotEmpty;

  /// 这份配置对应的音色。
  ///
  /// 三项必须与缓存里的 voice 完全一致，否则缓存会被判为失效
  /// （listening/cache.dart:194-197 逐项比对 engine / id / locale）。
  SpeechVoice get voice => SpeechVoice(
    id: voiceId,
    label: voiceId.isEmpty ? '自定义语音' : voiceId,
    source: ListeningSource.custom,
    locale: locale.isEmpty ? 'zh-CN' : locale,
    engine: namespace.isEmpty ? null : namespace,
  );

  CustomSpeechConfig copyWith({
    String? namespace,
    String? voiceId,
    String? locale,
  }) => CustomSpeechConfig(
    namespace: namespace ?? this.namespace,
    voiceId: voiceId ?? this.voiceId,
    locale: locale ?? this.locale,
  );

  Map<String, Object?> toJson() => {
    'namespace': namespace,
    'voiceId': voiceId,
    'locale': locale,
  };

  static CustomSpeechConfig fromJson(Map<dynamic, dynamic> json) =>
      CustomSpeechConfig(
        namespace: '${json['namespace'] ?? ''}',
        voiceId: '${json['voiceId'] ?? ''}',
        locale: '${json['locale'] ?? ''}',
      );

  @override
  bool operator ==(Object other) =>
      other is CustomSpeechConfig &&
      other.namespace == namespace &&
      other.voiceId == voiceId &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(namespace, voiceId, locale);
}

/// 自定义语音接口设置。当前构建不持久化、不允许配置，
/// [config] 恒为 null，因此所有自定义音色都会走「请重新配置」的失败分支。
class CustomSpeechSettings extends ChangeNotifier {
  CustomSpeechSettings();

  CustomSpeechConfig? _config;

  CustomSpeechConfig? get config => _config;

  bool get supported => false;

  Future<void> load() async {}

  Future<void> save(CustomSpeechConfig? value) async {
    _config = value;
    notifyListeners();
  }

  Future<void> clear() async {
    _config = null;
    notifyListeners();
  }
}

/// Microsoft SSML 兼容服务的客户端。当前构建未包含实现，
/// 调用一律抛出，由上层转成可见的朗读失败提示。
class CustomSpeechClient {
  CustomSpeechClient();

  Future<Uint8List> synthesize(
    String text,
    CustomSpeechConfig config,
    SpeechCancellation cancellation,
  ) => Future<Uint8List>.error(
    UnsupportedError('此构建未包含自定义语音接口'),
  );
}
