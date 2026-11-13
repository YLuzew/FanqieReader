import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import 'reading_widget_reference.dart';
import 'reading_widget_snapshot.dart';

/// 预加载小组件所需的图片素材。
///
/// 当前构建未包含原生渲染管线，这里直接返回，不产生任何请求。
Future<void> warmReadingDesktopImages(Object? snapshot) async {}

/// 把某个快照渲染成 PNG 字节。
///
/// 当前构建返回空数据：卡片会显示为空白，但不会让批量渲染流程抛错。
Future<Uint8List> renderReadingDesktopCard(
  Object? snapshot,
  ReadingDesktopSize size, {
  required Brightness brightness,
  bool paintQuote = true,
}) async => Uint8List(0);

/// 把一个快照渲染成多张桌面卡片。
///
/// 返回 文件名（不含扩展名）→ PNG 字节。调用方会写成
/// `<temp>/reading-desktop-*/<key>.png` 后交给原生落盘。
/// 当前构建没有渲染管线，返回空表，发布流程会跳过图片。
Future<Map<String, Uint8List>> renderReadingDesktopCards(
  ReadingWidgetSnapshot value,
) async => const <String, Uint8List>{};
