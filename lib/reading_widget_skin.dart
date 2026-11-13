/// 阅读小组件皮肤。
enum ReadingWidgetSkin {
  original('original', '原版'),
  seasons('seasons', '四季');

  const ReadingWidgetSkin(this.id, this.label);

  final String id;
  final String label;

  static ReadingWidgetSkin fromId(String? value) {
    for (final skin in values) {
      if (skin.id == value) return skin;
    }
    return original;
  }
}

/// 未设置过时的默认每日阅读目标（分钟）。
const defaultReadingDailyGoalMinutes = 30;

/// 把存储里的原始值规整成可用的目标分钟数。
///
/// null（从未设置）落到默认值；0 表示「不设目标」；
/// 上限压到一天，避免脏数据把进度条撑坏。
int readingDailyGoal(int? stored) {
  if (stored == null) return defaultReadingDailyGoalMinutes;
  if (stored <= 0) return 0;
  if (stored > 24 * 60) return 24 * 60;
  return stored;
}

/// 阅读目标的一句话说明，例如「今日目标 30 分钟 · 已读 12 分钟（40%）」。
String readingGoalCaption(int minutes, int seconds) {
  if (minutes <= 0) return '按自己的节奏阅读';
  final done = seconds ~/ 60;
  final target = minutes * 60;
  final percent = target <= 0
      ? 0
      : ((seconds / target) * 100).clamp(0, 999).round();
  return '今日目标 $minutes 分钟 · 已读 $done 分钟（$percent%）';
}
