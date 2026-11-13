import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'custom_tts.dart';

/// 自定义语音接口设置页。当前构建不支持该接口，页面直接给出说明。
class CustomSpeechPage extends StatelessWidget {
  const CustomSpeechPage({
    super.key,
    required this.settings,
    required this.controller,
  });

  final CustomSpeechSettings settings;
  final ListeningController controller;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
