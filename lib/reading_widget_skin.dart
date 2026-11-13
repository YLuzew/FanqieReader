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
