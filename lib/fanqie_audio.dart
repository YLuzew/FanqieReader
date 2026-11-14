library fanqie_audio;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// 番茄听书音轨的解密器。
///
/// 服务端给的是标准 MP4，音轨用 `cenc-aes-ctr` 加密（`enca` + `sinf` +
/// `tenc` 那一套），每个 sample 一条 8 字节 IV，key 由 `spade_a` 派生。
/// 这里不解容器、不重编码 —— 只把 `mdat` 里的 sample 原地换成明文，
/// `moov` 一个字节都不动，所以解完仍是一个正常的 MP4，播放器直接吃。
///
/// 为什么不用「一边解一边喂给播放器」：`just_audio` 要的是 URL 或本地
/// 文件，喂流得自己写 `StreamAudioSource`，而一本书一章也就 7MB 上下，
/// 整份解完落盘更省事，也方便缓存复用。
class FanqieAudioCipher {
  const FanqieAudioCipher._();

  /// `spade_a` → 16 字节内容密钥。
  ///
  /// 这是按 fqapp `derive_spade_content_key` 逐句搬过来的：先用
  /// `raw[0]^raw[1]^raw[2]` 反推出有效长度，再走一串 ARX 把字节洗一遍，
  /// 洗出来的 `[1..33]` 是 32 个 hex 字符。长度对不上就直接给空 ——
  /// 宁可失败也不要拿半截 key 去解出一堆噪声。
  static Uint8List deriveContentKey(String spadeA) {
    final raw = _b64(spadeA);
    if (raw.length < 3) return Uint8List(0);
    final outLen = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 0x2F;
    if (outLen < 33 || outLen + 1 > raw.length) return Uint8List(0);
    final buf = Uint8List.fromList(raw.sublist(1, 1 + outLen));
    final src = Uint8List.fromList(buf);
    var prevA = 0x55;
    var prevB = 0xF6;
    for (var i = 0; i < src.length; i++) {
      final cur = src[i];
      final int keep;
      if (i & 1 == 1) {
        keep = cur;
      } else {
        keep = prevA;
        prevA = prevB;
        prevB = cur;
      }
      buf[i] = ((prevA ^ cur) - _popCount(i) - 0x15) & 0xFF;
      prevA = keep;
    }
    final hex = ascii.decode(buf.sublist(1, 33), allowInvalid: true);
    if (hex.length != 32) return Uint8List(0);
    try {
      return Uint8List.fromList(_hexDecode(hex));
    } on FormatException {
      return Uint8List(0);
    }
  }

  /// 把一个加密的 MP4 解成可播的 MP4。失败时返回 null。
  ///
  /// 只改 `mdat` 里的 sample 字节；`moov` 里的 `enca`/`senc` 保持原样 ——
  /// 实测 ExoPlayer / ffmpeg 在 `senc` 与 `mdat` 对不上时会忽略前者而按
  /// `stsd` 里的 `enca` 走，而 `enca` 的 sample entry 本身是 `mp4a`，
  /// 所以改完能正常出声。真遇到挑剔的播放器，再补一步重建 `moov`。
  static Future<Uint8List?> decrypt({
    required Uint8List encrypted,
    required String spadeA,
  }) async {
    final key = deriveContentKey(spadeA);
    if (key.length != 16) return null;
    final layout = _Mp4Layout.parse(encrypted);
    if (layout == null || layout.sampleCount == 0) return null;
    if (layout.sampleCount != layout.ivs.length) return null;

    final out = Uint8List.fromList(encrypted);
    final boxes = <Uint8List>[];
    final offsets = <int>[];
    var index = 0;
    for (var c = 0; c < layout.chunkOffsets.length; c++) {
      final start = layout.chunkOffsets[c];
      final end = c + 1 < layout.chunkOffsets.length
          ? layout.chunkOffsets[c + 1]
          : encrypted.length;
      var p = start;
      while (p < end && index < layout.sampleCount) {
        final size = layout.sampleSizes[index];
        if (p + size > encrypted.length) break;
        boxes.add(Uint8List.sublistView(out, p, p + size));
        offsets.add(p);
        p += size;
        index++;
      }
    }
    if (index == 0) return null;

    // 一条样本一条 IV，counter 从 IV 起、后 8 字节从 0 递增。所有样本的
    // counter 拼成一个大数组一次性 ECB 加密，比逐样本各建一个 cipher
    // 快得多（一本书一章两万多个样本，逐条 await 会卡住 UI 线程）。
    final counters = <int>[];
    var totalBlocks = 0;
    for (var i = 0; i < boxes.length; i++) {
      final blocks = (boxes[i].length + 15) ~/ 16;
      totalBlocks += blocks;
    }
    final plainCounters = Uint8List(totalBlocks * 16);
    var w = 0;
    for (var i = 0; i < boxes.length; i++) {
      final iv = layout.ivs[i];
      final blocks = (boxes[i].length + 15) ~/ 16;
      for (var b = 0; b < blocks; b++) {
        plainCounters.setRange(w, w + 8, iv);
        // 后 8 字节大端计块号。
        var n = b;
        for (var k = 15; k >= 8; k--) {
          plainCounters[w + k] = n & 0xFF;
          n >>= 8;
        }
        w += 16;
      }
    }
    final ecb = AesEcb(SecretKey(key));
    final stream = await ecb.encrypt(plainCounters);

    var so = 0;
    for (var i = 0; i < boxes.length; i++) {
      final box = boxes[i];
      final at = offsets[i];
      for (var j = 0; j < box.length; j++) {
        out[at + j] = box[j] ^ stream[so + j];
      }
      so += (box.length + 15) ~/ 16 * 16;
    }
    return out;
  }

  static Uint8List _b64(String value) {
    final trimmed = value.trim();
    final pad = (4 - trimmed.length % 4) % 4;
    try {
      return base64Decode(trimmed + '=' * pad);
    } on FormatException {
      return Uint8List(0);
    }
  }

  static int _popCount(int value) {
    var v = value;
    var count = 0;
    while (v != 0) {
      count += v & 1;
      v >>= 1;
    }
    return count;
  }

  static List<int> _hexDecode(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }
}

class _Mp4Layout {
  const _Mp4Layout({
    required this.sampleSizes,
    required this.chunkOffsets,
    required this.ivs,
  });

  final List<int> sampleSizes;
  final List<int> chunkOffsets;
  final List<Uint8List> ivs;

  int get sampleCount => sampleSizes.length;

  static _Mp4Layout? parse(Uint8List bytes) {
    final boxes = <String, ({int start, int size})>{};
    void walk(int start, int end) {
      var i = start;
      while (i + 8 <= end) {
        var size = _u32(bytes, i);
        final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
        var header = 8;
        if (size == 1) {
          if (i + 16 > end) return;
          size = _u64(bytes, i + 8);
          header = 16;
        } else if (size == 0) {
          size = end - i;
        }
        if (size < header || i + size > end) return;
        boxes.putIfAbsent(type, () => (start: i + header, size: size - header));
        if (const {
          'moov',
          'trak',
          'mdia',
          'minf',
          'stbl',
          'stsd',
          'enca',
          'sinf',
          'schi',
        }.contains(type)) {
          walk(i + header, i + size);
        }
        i += size;
      }
    }

    walk(0, bytes.length);
    final stsz = boxes['stsz'];
    final stco = boxes['stco'];
    final senc = boxes['senc'];
    if (stsz == null || stco == null || senc == null) return null;

    final count = _u32(bytes, stsz.start + 8);
    if (count <= 0 || count > 200000) return null;
    final sizes = <int>[];
    final uniform = _u32(bytes, stsz.start + 4);
    for (var i = 0; i < count; i++) {
      sizes.add(uniform != 0 ? uniform : _u32(bytes, stsz.start + 12 + i * 4));
    }

    final chunkCount = _u32(bytes, stco.start + 4);
    final chunks = <int>[];
    for (var i = 0; i < chunkCount; i++) {
      chunks.add(_u32(bytes, stco.start + 8 + i * 4));
    }

    // senc: version/flags(4) + sample_count(4) + IV(8/16) 每条。
    final ivCount = _u32(bytes, senc.start + 4);
    final payload = senc.size - 8;
    if (ivCount <= 0 || payload % ivCount != 0) return null;
    final ivSize = payload ~/ ivCount;
    if (ivSize != 8 && ivSize != 16) return null;
    final ivs = <Uint8List>[];
    for (var i = 0; i < ivCount; i++) {
      final at = senc.start + 8 + i * ivSize;
      final iv = Uint8List(ivSize);
      iv.setRange(0, ivSize, bytes.sublist(at, at + ivSize));
      ivs.add(iv);
    }
    return _Mp4Layout(sampleSizes: sizes, chunkOffsets: chunks, ivs: ivs);
  }

  static int _u32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _u64(Uint8List b, int o) =>
      (_u32(b, o) << 32) | _u32(b, o + 4);
}
