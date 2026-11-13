library fanqie_sign;

import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show md5;

/// 番茄 App 侧请求签名（x-argus / x-ladon / x-khronos / x-ss-stub）。
///
/// 全部是纯算法：SM3、Simon 64/128、Ladon ARX、protobuf 编码、AES-128-CBC。
/// 没有 so、没有模拟器、没有服务端。
///
/// 算法口径对照 GodBook/fanqie-pure-reader（GPL-3.0）的 Rust 实现，
/// 并用真实接口回包验证过（第 11/12/101/701/1496 章均能解出正文）。

const int _m32 = 0xFFFFFFFF;

int _rotl64(int v, int n) {
  n &= 63;
  if (n == 0) return v;
  return ((v << n) | (v >>> (64 - n)));
}

int _rotr64(int v, int n) {
  n &= 63;
  if (n == 0) return v;
  return ((v >>> n) | (v << (64 - n)));
}

// ---------------------------------------------------------------------------
// SM3
// ---------------------------------------------------------------------------

const List<int> _sm3Iv = [
  0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, //
  0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
];

int _rotl32(int a, int k) {
  k &= 31;
  if (k == 0) return a & _m32;
  return ((a << k) | (a >>> (32 - k))) & _m32;
}

int _sm3P0(int x) => (x ^ _rotl32(x, 9) ^ _rotl32(x, 17)) & _m32;
int _sm3P1(int x) => (x ^ _rotl32(x, 15) ^ _rotl32(x, 23)) & _m32;
int _sm3Ff(int x, int y, int z, int j) =>
    j < 16 ? (x ^ y ^ z) & _m32 : ((x & y) | (x & z) | (y & z)) & _m32;
int _sm3Gg(int x, int y, int z, int j) =>
    j < 16 ? (x ^ y ^ z) & _m32 : ((x & y) | ((~x) & z)) & _m32;
int _sm3Tj(int j) => j < 16 ? 0x79cc4519 : 0x7a879d8a;

List<int> _sm3Compress(List<int> v, Uint8List block, int off) {
  final w = List<int>.filled(68, 0);
  for (var i = 0; i < 16; i++) {
    final o = off + i * 4;
    w[i] = (block[o] << 24) | (block[o + 1] << 16) | (block[o + 2] << 8) | block[o + 3];
  }
  for (var j = 16; j < 68; j++) {
    w[j] = (_sm3P1(w[j - 16] ^ w[j - 9] ^ _rotl32(w[j - 3], 15)) ^
            _rotl32(w[j - 13], 7) ^
            w[j - 6]) &
        _m32;
  }
  final w1 = List<int>.filled(64, 0);
  for (var j = 0; j < 64; j++) {
    w1[j] = (w[j] ^ w[j + 4]) & _m32;
  }

  var a = v[0], b = v[1], c = v[2], d = v[3];
  var e = v[4], f = v[5], g = v[6], h = v[7];

  for (var j = 0; j < 64; j++) {
    final ss1 = _rotl32(
      (_rotl32(a, 12) + e + _rotl32(_sm3Tj(j), j)) & _m32,
      7,
    );
    final ss2 = (ss1 ^ _rotl32(a, 12)) & _m32;
    final tt1 = (_sm3Ff(a, b, c, j) + d + ss2 + w1[j]) & _m32;
    final tt2 = (_sm3Gg(e, f, g, j) + h + ss1 + w[j]) & _m32;
    d = c;
    c = _rotl32(b, 9);
    b = a;
    a = tt1;
    h = g;
    g = _rotl32(f, 19);
    f = e;
    e = _sm3P0(tt2);
  }

  return [
    (a ^ v[0]) & _m32,
    (b ^ v[1]) & _m32,
    (c ^ v[2]) & _m32,
    (d ^ v[3]) & _m32,
    (e ^ v[4]) & _m32,
    (f ^ v[5]) & _m32,
    (g ^ v[6]) & _m32,
    (h ^ v[7]) & _m32,
  ];
}

/// 32 字节 SM3 摘要。
Uint8List sm3(List<int> message) {
  final origLen = message.length;
  final reserve = (origLen % 64) + 1;
  var rangeEnd = 56;
  if (rangeEnd < reserve) rangeEnd += 64;
  final total = origLen + 1 + (rangeEnd - reserve) + 8;
  final padded = Uint8List(total);
  padded.setRange(0, origLen, message);
  padded[origLen] = 0x80;
  final bitLen = origLen * 8;
  for (var i = 0; i < 8; i++) {
    padded[total - 1 - i] = (bitLen >>> (i * 8)) & 0xFF;
  }

  var v = List<int>.from(_sm3Iv);
  for (var i = 0; i < total ~/ 64; i++) {
    v = _sm3Compress(v, padded, i * 64);
  }
  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >>> 24) & 0xFF;
    out[i * 4 + 1] = (v[i] >>> 16) & 0xFF;
    out[i * 4 + 2] = (v[i] >>> 8) & 0xFF;
    out[i * 4 + 3] = v[i] & 0xFF;
  }
  return out;
}

// ---------------------------------------------------------------------------
// AES-128（同步实现，只用得到 CBC）
// ---------------------------------------------------------------------------

const List<int> _sbox = [
  0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
];

final List<int> _invSbox = () {
  final out = List<int>.filled(256, 0);
  for (var i = 0; i < 256; i++) {
    out[_sbox[i]] = i;
  }
  return out;
}();

int _xtime(int a) => ((a << 1) ^ ((a & 0x80) != 0 ? 0x1b : 0)) & 0xFF;

int _gmul(int a, int b) {
  var p = 0;
  for (var i = 0; i < 8; i++) {
    if ((b & 1) != 0) p ^= a;
    final hi = a & 0x80;
    a = (a << 1) & 0xFF;
    if (hi != 0) a ^= 0x1b;
    b >>= 1;
  }
  return p & 0xFF;
}

List<int> _expandKey(List<int> key) {
  final w = List<int>.filled(176, 0);
  w.setRange(0, 16, key);
  var rcon = 1;
  for (var i = 16; i < 176; i += 4) {
    var t0 = w[i - 4], t1 = w[i - 3], t2 = w[i - 2], t3 = w[i - 1];
    if (i % 16 == 0) {
      final tmp = t0;
      t0 = _sbox[t1] ^ rcon;
      t1 = _sbox[t2];
      t2 = _sbox[t3];
      t3 = _sbox[tmp];
      rcon = _xtime(rcon);
    }
    w[i] = w[i - 16] ^ t0;
    w[i + 1] = w[i - 15] ^ t1;
    w[i + 2] = w[i - 14] ^ t2;
    w[i + 3] = w[i - 13] ^ t3;
  }
  return w;
}

void _addRoundKey(List<int> s, List<int> w, int round) {
  for (var i = 0; i < 16; i++) {
    s[i] ^= w[round * 16 + i];
  }
}

void _subBytes(List<int> s) {
  for (var i = 0; i < 16; i++) {
    s[i] = _sbox[s[i]];
  }
}

void _invSubBytes(List<int> s) {
  for (var i = 0; i < 16; i++) {
    s[i] = _invSbox[s[i]];
  }
}

void _shiftRows(List<int> s) {
  var t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t;
  t = s[2]; s[2] = s[10]; s[10] = t;
  t = s[6]; s[6] = s[14]; s[14] = t;
  t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
}

void _invShiftRows(List<int> s) {
  var t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
  t = s[2]; s[2] = s[10]; s[10] = t;
  t = s[6]; s[6] = s[14]; s[14] = t;
  t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
}

void _mixColumns(List<int> s) {
  for (var c = 0; c < 16; c += 4) {
    final a0 = s[c], a1 = s[c + 1], a2 = s[c + 2], a3 = s[c + 3];
    s[c] = _gmul(a0, 2) ^ _gmul(a1, 3) ^ a2 ^ a3;
    s[c + 1] = a0 ^ _gmul(a1, 2) ^ _gmul(a2, 3) ^ a3;
    s[c + 2] = a0 ^ a1 ^ _gmul(a2, 2) ^ _gmul(a3, 3);
    s[c + 3] = _gmul(a0, 3) ^ a1 ^ a2 ^ _gmul(a3, 2);
  }
}

void _invMixColumns(List<int> s) {
  for (var c = 0; c < 16; c += 4) {
    final a0 = s[c], a1 = s[c + 1], a2 = s[c + 2], a3 = s[c + 3];
    s[c] = _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9);
    s[c + 1] = _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13);
    s[c + 2] = _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11);
    s[c + 3] = _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14);
  }
}

Uint8List aesEncryptBlock(List<int> key, List<int> block) {
  final w = _expandKey(key);
  final s = List<int>.from(block);
  _addRoundKey(s, w, 0);
  for (var r = 1; r <= 10; r++) {
    _subBytes(s);
    _shiftRows(s);
    if (r != 10) _mixColumns(s);
    _addRoundKey(s, w, r);
  }
  return Uint8List.fromList(s);
}

Uint8List aesDecryptBlock(List<int> key, List<int> block) {
  final w = _expandKey(key);
  final s = List<int>.from(block);
  _addRoundKey(s, w, 10);
  for (var r = 9; r >= 0; r--) {
    _invShiftRows(s);
    _invSubBytes(s);
    _addRoundKey(s, w, r);
    if (r != 0) _invMixColumns(s);
  }
  return Uint8List.fromList(s);
}

Uint8List aesCbcEncrypt(List<int> data, List<int> key, List<int> iv) {
  final out = Uint8List(data.length);
  var prev = List<int>.from(iv);
  for (var off = 0; off < data.length; off += 16) {
    final block = List<int>.generate(16, (i) => data[off + i] ^ prev[i]);
    final enc = aesEncryptBlock(key, block);
    out.setRange(off, off + 16, enc);
    prev = enc;
  }
  return out;
}

Uint8List aesCbcDecrypt(List<int> data, List<int> key, List<int> iv) {
  final out = Uint8List(data.length);
  var prev = List<int>.from(iv);
  for (var off = 0; off < data.length; off += 16) {
    final ct = data.sublist(off, off + 16);
    final dec = aesDecryptBlock(key, ct);
    for (var i = 0; i < 16; i++) {
      out[off + i] = dec[i] ^ prev[i];
    }
    prev = ct;
  }
  return out;
}

Uint8List pkcs7Pad(List<int> data, int block) {
  final n = block - (data.length % block);
  final out = Uint8List(data.length + n);
  out.setRange(0, data.length, data);
  for (var i = 0; i < n; i++) {
    out[data.length + i] = n;
  }
  return out;
}

Uint8List pkcs7Unpad(List<int> data, [int block = 16]) {
  if (data.isEmpty) return Uint8List(0);
  final n = data.last;
  if (n <= 0 || n > block) return Uint8List.fromList(data);
  return Uint8List.fromList(data.sublist(0, data.length - n));
}

// ---------------------------------------------------------------------------
// Simon 64/128，72 轮
// ---------------------------------------------------------------------------

const int _simonZ = 0x3DC94C3A046D678B;

List<int> simonEncrypt(List<int> pt, List<int> k) {
  final key = List<int>.filled(72, 0);
  key[0] = k[0];
  key[1] = k[1];
  key[2] = k[2];
  key[3] = k[3];
  for (var i = 4; i < 72; i++) {
    var tmp = _rotr64(key[i - 1], 3);
    tmp ^= key[i - 3];
    tmp ^= _rotr64(tmp, 1);
    final bit = (_simonZ >>> ((i - 4) % 62)) & 1;
    key[i] = (~key[i - 4]) ^ tmp ^ bit ^ 3;
  }
  var xi = pt[0];
  var xi1 = pt[1];
  for (var r = 0; r < 72; r++) {
    final tmp = xi1;
    final f = _rotl64(xi1, 1) & _rotl64(xi1, 8);
    xi1 = xi ^ f ^ _rotl64(xi1, 2) ^ key[r];
    xi = tmp;
  }
  return [xi, xi1];
}

// ---------------------------------------------------------------------------
// protobuf 编码（只写不读）
// ---------------------------------------------------------------------------

class ProtoBuf {
  final List<int> _fields = [];
  final List<int> _types = [];
  final List<Object> _values = [];

  void putVarint(int idx, int v) {
    _fields.add(idx);
    _types.add(0);
    _values.add(v);
  }

  void putBytes(int idx, List<int> data) {
    _fields.add(idx);
    _types.add(2);
    _values.add(Uint8List.fromList(data));
  }

  void putUtf8(int idx, String s) => putBytes(idx, utf8.encode(s));

  void putProto(int idx, ProtoBuf nested) => putBytes(idx, nested.toBuf());

  Uint8List toBuf() {
    final out = BytesBuilder();
    for (var i = 0; i < _fields.length; i++) {
      final typ = _types[i];
      out.add(_varint((_fields[i] << 3) | (typ & 7)));
      if (typ == 0) {
        out.add(_varint((_values[i] as int) & _m32));
      } else {
        final bytes = _values[i] as Uint8List;
        out.add(_varint(bytes.length));
        out.add(bytes);
      }
    }
    return out.toBytes();
  }
}

Uint8List _varint(int value) {
  var v = value & _m32;
  final out = <int>[];
  while (v >= 128) {
    out.add((v & 127) | 128);
    v = v >>> 7;
  }
  out.add(v & 127);
  return Uint8List.fromList(out);
}

// ---------------------------------------------------------------------------
// Ladon
// ---------------------------------------------------------------------------

Uint8List _ladonHashTable(String md5Hex) {
  final ht = Uint8List(288);
  final src = ascii.encode(md5Hex);
  ht.setRange(0, min(32, src.length), src);

  int load(int off) {
    var v = 0;
    for (var j = 0; j < 8; j++) {
      v |= ht[off + j] << (j * 8);
    }
    return v;
  }

  var temp = <int>[load(0), load(8), load(16), load(24)];
  var bufB0 = temp[0];
  var bufB8 = temp[1];
  temp = temp.sublist(2);

  for (var i = 0; i < 34; i++) {
    final x9 = bufB0;
    var x8 = _rotr64(bufB8, 8);
    x8 += x9;
    x8 ^= i;
    temp.add(x8);
    x8 ^= _rotl64(x9, 3);
    for (var j = 0; j < 8; j++) {
      ht[(i + 1) * 8 + j] = (x8 >>> (j * 8)) & 255;
    }
    bufB0 = x8;
    bufB8 = temp[0];
    temp.removeAt(0);
  }
  return ht;
}

Uint8List _ladonBlock(Uint8List ht, List<int> block, int off) {
  var d0 = 0;
  var d1 = 0;
  for (var i = 0; i < 8; i++) {
    d0 |= block[off + i] << (i * 8);
    d1 |= block[off + 8 + i] << (i * 8);
  }
  for (var i = 0; i < 34; i++) {
    var h = 0;
    for (var j = 0; j < 8; j++) {
      h |= ht[i * 8 + j] << (j * 8);
    }
    d1 = h ^ (d0 + _rotr64(d1, 8));
    d0 = d1 ^ _rotl64(d0, 3);
  }
  final out = Uint8List(16);
  for (var i = 0; i < 8; i++) {
    out[i] = (d0 >>> (i * 8)) & 255;
    out[8 + i] = (d1 >>> (i * 8)) & 255;
  }
  return out;
}

Uint8List _ladonRaw(String md5Hex, List<int> data) {
  final ht = _ladonHashTable(md5Hex);
  final size = data.length;
  final newSize = size + (16 - size % 16);
  final padVal = newSize - size;
  final input = Uint8List(newSize)..fillRange(size, newSize, padVal);
  input.setRange(0, size, data);
  final out = Uint8List(newSize);
  for (var i = 0; i < newSize ~/ 16; i++) {
    out.setRange(i * 16, i * 16 + 16, _ladonBlock(ht, input, i * 16));
  }
  return out;
}

String ladonEncrypt(int khronos, int lcId, int aid, List<int> randomBytes) {
  final data = utf8.encode('$khronos-$lcId-$aid');
  final keygen = <int>[...randomBytes, ...utf8.encode('$aid')];
  final md5Hex = _md5Hex(keygen);
  final enc = _ladonRaw(md5Hex, data);
  return base64Encode(Uint8List.fromList([...randomBytes, ...enc]));
}

// ---------------------------------------------------------------------------
// Argus
// ---------------------------------------------------------------------------

final Uint8List _argusSignKey = Uint8List.fromList([
  0xfc,0x78,0xe0,0xa9,0x65,0x7a,0x0c,0x74,0x8c,0xe5,0x15,0x59,0x90,0x3c,0xcf,0x03,
  0x51,0x0e,0x51,0xd3,0xcf,0xf2,0x32,0xd7,0x13,0x43,0xe8,0x8a,0x32,0x1c,0x53,0x04,
]);
final Uint8List _argusAesKey = Uint8List.fromList([
  0xd3,0x1e,0x37,0x18,0x28,0x8a,0x10,0x27,0xba,0xab,0x59,0xf1,0x46,0xa0,0x9a,0x9c,
]);
final Uint8List _argusAesIv = Uint8List.fromList([
  0xea,0x18,0x0a,0x03,0x36,0xed,0x35,0x2f,0xcd,0x24,0xe4,0xd5,0x00,0x18,0xae,0x54,
]);

const List<int> _prefix551 = [0xf2, 0x81];
const List<int> _magic8 = [0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff];
const List<int> _tail9 = [0xea, 0xfb, 0x2c, 0xfe, 0x85, 0x68, 0x51, 0x91, 0x54];

Uint8List _simonEncryptPadded(List<int> protobuf) {
  final key = List<int>.generate(4, (i) => _readU64Le(_argusSignKey, i * 8));
  final out = Uint8List(protobuf.length);
  for (var i = 0; i < protobuf.length ~/ 16; i++) {
    final a = _readU64Le(protobuf, i * 16);
    final b = _readU64Le(protobuf, i * 16 + 8);
    final ct = simonEncrypt([a, b], key);
    _writeU64Le(out, i * 16, ct[0]);
    _writeU64Le(out, i * 16 + 8, ct[1]);
  }
  return out;
}

int _readU64Le(List<int> data, int off) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v |= data[off + i] << (i * 8);
  }
  return v;
}

void _writeU64Le(Uint8List out, int off, int v) {
  for (var i = 0; i < 8; i++) {
    out[off + i] = (v >>> (i * 8)) & 0xFF;
  }
}

String _argusEncrypt551(ProtoBuf bean) {
  final padded = pkcs7Pad(bean.toBuf(), 16);
  final encPb = _simonEncryptPadded(padded);

  final un = <int>[..._magic8, ...encPb, ..._tail9];
  final buf = List<int>.filled(un.length, 0);
  buf.setRange(0, 8, _magic8);
  for (var i = 8; i < un.length; i++) {
    buf[i] = un[i] ^ _magic8[i % 8];
  }
  final reversed = <int>[...buf.reversed, 0x61, 0x6f]; // 'ao'
  final aligned = pkcs7Pad(reversed, 16);
  final ct = aesCbcEncrypt(aligned, _argusAesKey, _argusAesIv);
  return base64Encode(Uint8List.fromList([..._prefix551, ...ct]));
}

String _queryParam(String query, String name) {
  if (query.isEmpty) return '';
  for (final pair in Uri.splitQueryString(query).entries) {
    if (pair.key == name) return pair.value;
  }
  return '';
}

String _argusGetSign({
  required String queryString,
  required String stubHex,
  required int timestamp,
  required String deviceId,
  required String installId,
  required int randField,
  int aid = 1967,
  int licenseId = 1611921764,
}) {
  final bean = ProtoBuf();
  bean.putVarint(1, 1077940818);
  bean.putVarint(2, 2);
  bean.putVarint(3, randField);
  bean.putUtf8(4, '$aid');
  bean.putUtf8(5, deviceId);
  bean.putUtf8(6, '$licenseId');
  bean.putUtf8(7, _queryParam(queryString, 'version_name'));
  bean.putUtf8(8, 'v04.04.05-ov-android');
  bean.putVarint(9, 134744640);
  bean.putBytes(10, List<int>.filled(8, 0));
  bean.putVarint(11, 0);
  bean.putVarint(12, timestamp << 1);
  bean.putBytes(13, _argusBodyHash(stubHex));
  bean.putBytes(14, _argusQueryHash(queryString));

  final sub15 = ProtoBuf()
    ..putVarint(1, 1)
    ..putVarint(2, 1)
    ..putVarint(3, 1)
    ..putVarint(7, 0xC792ECCC);
  bean.putProto(15, sub15);
  bean.putUtf8(16, installId);
  bean.putUtf8(20, 'none');
  bean.putVarint(21, 738);

  final sub23 = ProtoBuf()
    ..putUtf8(1, 'NX551J')
    ..putVarint(2, 8196)
    ..putVarint(4, 0x80E0D800);
  bean.putProto(23, sub23);
  bean.putVarint(25, 2);

  return _argusEncrypt551(bean);
}

List<int> _argusBodyHash(String stubHex) {
  if (stubHex.isEmpty) return sm3(List<int>.filled(16, 0)).sublist(0, 6);
  return sm3(_hexToBytes(stubHex)).sublist(0, 6);
}

List<int> _argusQueryHash(String query) {
  if (query.isEmpty) return sm3(List<int>.filled(16, 0)).sublist(0, 6);
  return sm3(utf8.encode(query)).sublist(0, 6);
}

// ---------------------------------------------------------------------------
// 对外封装
// ---------------------------------------------------------------------------

final Random _rng = Random.secure();

/// 生成一次请求需要的签名头。
///
/// [query] 必须是真正发出去的那串查询参数（顺序、编码都要一致），
/// 签名绑 URL —— 复用到别的请求上一定失败。
Map<String, String> fanqieSignHeaders({
  required String query,
  List<int>? body,
  required String deviceId,
  required String installId,
  int? timestamp,
  int? argusRand,
}) {
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final stubHex = (body == null || body.isEmpty) ? '' : _md5Hex(body);
  final rnd = List<int>.generate(4, (_) => _rng.nextInt(256));
  final headers = <String, String>{
    'x-ss-req-ticket': '${ts * 1000}',
    'x-khronos': '$ts',
    'x-ladon': ladonEncrypt(ts, 1611921764, 1967, rnd),
    'x-argus': _argusGetSign(
      queryString: query,
      stubHex: stubHex,
      timestamp: ts,
      deviceId: deviceId,
      installId: installId,
      randField: argusRand ?? (_rng.nextInt(0x7FFFFFFE) + 1),
    ),
  };
  if (stubHex.isNotEmpty) headers['x-ss-stub'] = stubHex;
  return headers;
}

/// 解 registerkey 返回的 `data.key`，得到正文解密用的 secret key（hex）。
String decryptRegisterKey(String keyBase64) {
  final raw = base64Decode(keyBase64);
  if (raw.length < 32) throw const FormatException('registerkey 数据太短');
  final masterKey = _hexToBytes('ac25c67ddd8f38c1b37a2348828e222e');
  final pt = aesCbcDecrypt(raw.sublist(16), masterKey, raw.sublist(0, 16));
  return _bytesToHex(pkcs7Unpad(pt));
}

/// 构造 registerkey 的 `content`：base64(iv + AES-CBC(hex2bin(reverseHex(deviceId))))。
String encodeRegisterContent(String deviceId) {
  final reqKey = base64Decode('rCXGfd2POMGzeiNIgo4iLg==');
  final iv = List<int>.generate(16, (_) => _rng.nextInt(256));
  final raw = _hexToBytes(_reverseHex(deviceId));
  final ct = aesCbcEncrypt(pkcs7Pad(raw, 16), reqKey, iv);
  return base64Encode(Uint8List.fromList([...iv, ...ct]));
}

/// 解密上游正文：base64 → iv + AES-CBC → 去 padding →（可选）gzip。
Uint8List decryptUpstream(String encryptedBase64, String secretKeyHex) {
  final raw = base64Decode(encryptedBase64);
  if (raw.length < 32) throw const FormatException('正文密文太短');
  final key = _hexToBytes(secretKeyHex);
  if (key.length != 16) throw const FormatException('secret key 长度不对');
  final pt = pkcs7Unpad(aesCbcDecrypt(raw.sublist(16), key, raw.sublist(0, 16)));
  if (pt.length >= 2 && pt[0] == 0x1f && pt[1] == 0x8b) {
    return Uint8List.fromList(gzip.decode(pt));
  }
  return pt;
}

String _reverseHex(String deviceId) {
  // 20 位设备号会超过 2^63，Dart 的 int 装不下，必须走 BigInt。
  final n = BigInt.tryParse(deviceId);
  if (n == null || n.isNegative || n >= (BigInt.one << 64)) {
    throw FormatException('device_id 不是 64 位正整数：$deviceId');
  }
  final hex = n.toRadixString(16).padLeft(32, '0');
  final out = StringBuffer();
  for (var i = hex.length; i >= 2; i -= 2) {
    out.write(hex.substring(i - 2, i));
  }
  return out.toString();
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(List<int> bytes) {
  final out = StringBuffer();
  for (final b in bytes) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

String _md5Hex(List<int> data) => md5.convert(data).toString();
