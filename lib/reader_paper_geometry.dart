import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// 一张纸的三角形网格：位置、法线、索引、纹理坐标、外轮廓。
///
/// 坐标是相对页面左上角的像素坐标，直接喂给 [ui.Vertices.raw]。
class ReaderPaperMesh {
  const ReaderPaperMesh({
    required this.positions,
    required this.normals,
    required this.indices,
    required this.uv,
    required this.outline,
  });

  /// 顶点坐标，x、y 交替，长度 = 顶点数 × 2。
  final Float32List positions;

  /// 每个顶点一个法线分量，`abs()` 参与明暗计算。
  final List<double> normals;

  /// 三角形索引。
  final Uint16List indices;

  /// 纹理坐标，像素坐标（0..size），与 [positions] 一一对应。
  final Float32List uv;

  /// 外轮廓，用于裁剪与投影。
  final Path outline;

  static ReaderPaperMesh empty() => ReaderPaperMesh(
    positions: Float32List(0),
    normals: const [],
    indices: Uint16List(0),
    uv: Float32List(0),
    outline: Path(),
  );
}

/// 一次翻页的几何：纸绕书脊转动，投影宽度随角度收缩。
///
/// [progress] 从 0 到 1：纸由整页摊平，转到完全立起（投影宽度为 0），
/// 再落到另一侧。[touchY] 是折角在竖直方向的位置（0 上、1 下），
/// 用来让折线略微倾斜，避免死板的水平折。<br>
/// 所有网格都在构造时算好，动画帧里只做绘制，不重建、不排版。
class ReaderPaperGeometry {
  ReaderPaperGeometry({
    required this.size,
    required this.gap,
    required double progress,
    required double touchY,
  }) : progress = progress.clamp(0.0, 1.0),
       touchY = touchY.clamp(0.0, 1.0) {
    _build();
  }

  final Size size;
  final double gap;
  final double progress;
  final double touchY;

  /// 翻起的纸面（含折线），用于遮挡下层内容。
  late final Path sheet;

  /// 正面网格。
  late final ReaderPaperMesh front;

  /// 背面网格。
  late final ReaderPaperMesh back;

  /// 正面的墨迹网格（只承载文字贴图）。
  late final ReaderPaperMesh frontInk;

  /// 背面的墨迹网格。
  late final ReaderPaperMesh backInk;

  /// 纸面抬起的程度 0..1，用于投影与明暗。
  late final double lift;

  /// 折线的水平位置（像素）。
  late final double fold;

  /// 当前可见纸面的宽度（像素）。
  late final double extent;

  /// 折线在竖直方向上的偏移比例，让折角略微倾斜。
  double get tilt => (touchY - 0.5) * 0.18;

  void _build() {
    final width = size.width;
    final height = size.height;
    final angle = progress * math.pi;
    final cosine = math.cos(angle);

    lift = math.sin(angle).clamp(0.0, 1.0);

    // 折线从右边缘移到左边缘；可见宽度是投影后的宽度。
    fold = width * cosine;
    extent = fold.abs();
    final left = math.min(0.0, fold);
    final right = math.max(0.0, fold);

    // 折角倾斜：下沿比上沿多偏一点，翻页看起来不是一块硬板。
    final skew = tilt * height;

    Path quad(double x0, double x1, {bool mirrored = false}) {
      final path = Path()
        ..moveTo(x0, 0)
        ..lineTo(x1, skew)
        ..lineTo(x1, height + skew)
        ..lineTo(x0, height)
        ..close();
      return mirrored ? path : path;
    }

    ReaderPaperMesh mesh(double x0, double x1, {required bool ink}) {
      if (extent < 0.5) return ReaderPaperMesh.empty();
      final positions = Float32List.fromList([
        x0,
        0,
        x1,
        skew,
        x1,
        height + skew,
        x0,
        height,
      ]);
      final uvs = Float32List.fromList([
        x0,
        0,
        x1,
        skew,
        x1,
        height + skew,
        x0,
        height,
      ]);
      return ReaderPaperMesh(
        positions: positions,
        normals: const [1, 1, 1, 1],
        indices: Uint16List.fromList([0, 1, 2, 0, 2, 3]),
        uv: uvs,
        outline: quad(x0, x1),
      );
    }

    // 未翻到一半时，纸在书脊右侧；过半后落到左侧。
    final faceLeft = progress <= 0.5 ? left : left;
    final faceRight = progress <= 0.5 ? right : right;
    front = mesh(faceLeft, faceRight, ink: false);
    // 背面是与正面重合的镜像面，用来画纸背的文字（反字）。
    back = mesh(faceLeft, faceRight, ink: false);
    frontInk = mesh(faceLeft, faceRight, ink: true);
    backInk = mesh(faceLeft, faceRight, ink: true);

    sheet = extent < 0.5
        ? Path()
        : quad(faceLeft, faceRight);
  }
}
