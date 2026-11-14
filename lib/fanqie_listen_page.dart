import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'app_language.dart';
import 'app_ui.dart';
import 'archive_design.dart';
import 'catalog.dart';
import 'fanqie_api.dart';
import 'feature_pages.dart';
import 'fanqie_repository.dart';

/// 番茄听书：一章一个 MP4，服务端是 CENC 加密的，拉下来解完再播。
///
/// 为什么不塞进 `lib/listening/`：那边是「按段落合成 TTS、再拼时间轴」
/// 的模型，一段一个音频文件；番茄这边是整章一个音轨、没有段落边界，
/// 硬接会把它拆成几百次下载。两套模型各自独立更干净。
class FanqieListenPage extends StatefulWidget {
  const FanqieListenPage({
    super.key,
    required this.book,
    required this.startChapter,
    required this.repository,
    this.reduceMotion = false,
  });

  final Novel book;
  final int startChapter;
  final FanqieRepository repository;
  final bool reduceMotion;

  @override
  State<FanqieListenPage> createState() => _FanqieListenPageState();
}

class _FanqieListenPageState extends State<FanqieListenPage> {
  final _player = AudioPlayer();
  late int _index = widget.startChapter.clamp(0, widget.book.chapters.length - 1);
  bool _loading = false;
  String? _error;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _generation = 0;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _posSub = _player.positionStream.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _stateSub = _player.playerStateStream.listen((value) {
      if (mounted) setState(() => _playing = value.playing);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  int get _chapterCount => widget.book.chapters.length;

  NovelChapter get _chapter => widget.book.chapters[_index];

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    try {
      final remote = widget.repository.ids.remoteIdFor(widget.book.id);
      if (remote == null) throw StateError('这本书没有番茄书号');
      final file = await widget.repository.api.fetchChapterAudio(
        remote,
        '${_chapter.id}',
      );
      if (!mounted || generation != _generation) return;
      if (file == null) throw StateError('这一章没拿到音频');
      final seconds = await _player.setFilePath(file.path);
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _duration = seconds ?? Duration.zero;
      });
      await _player.play();
    } on Object catch (failure) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _skip(int delta) async {
    final next = _index + delta;
    if (next < 0 || next >= _chapterCount) return;
    await _player.pause();
    setState(() => _index = next);
    await _load();
  }

  String get _timeLabel {
    String fmt(Duration d) {
      final m = d.inMinutes;
      final s = d.inSeconds % 60;
      return '$m:${s.toString().padLeft(2, '0')}';
    }

    return '${fmt(_position)} / ${fmt(_duration)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ArchiveFeaturePage(
      title: '听书',
      code: 'TOMATO / AUDIO',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
            child: ArchiveSection(
              title: widget.book.title,
              code: 'NOW PLAYING',
              subtitle: '第 ${_index + 1} 章 · ${_chapter.title}',
            ),
          ),
          Expanded(
            child: Center(
              child: _loading
                  ? const CupertinoActivityIndicator(radius: 16)
                  : _error != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppText(
                            '这一章没读出来',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          AppText(
                            _error!,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: scheme.onSurfaceVariant,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 14),
                          GlassTextButton(
                            key: const ValueKey('fanqie-audio-retry'),
                            onPressed: _load,
                            child: const AppText('重试'),
                          ),
                        ],
                      ),
                    )
                  : Icon(
                      CupertinoIcons.waveform,
                      size: 64,
                      color: scheme.onSurfaceVariant.withValues(alpha: .5),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Slider(
                  value: _duration.inMilliseconds == 0
                      ? 0
                      : (_position.inMilliseconds / _duration.inMilliseconds)
                            .clamp(0.0, 1.0),
                  onChanged: (value) {
                    final target = Duration(
                      milliseconds: (value * _duration.inMilliseconds).round(),
                    );
                    unawaited(_player.seek(target));
                  },
                ),
                Row(
                  children: [
                    AppText(
                      _timeLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  key: const ValueKey('fanqie-audio-prev'),
                  onPressed: _index > 0 ? () => _skip(-1) : null,
                  icon: const ArchiveIcon(CupertinoIcons.backward_end, size: 24),
                ),
                IconButton(
                  key: const ValueKey('fanqie-audio-toggle'),
                  iconSize: 52,
                  onPressed: _loading
                      ? null
                      : () => _playing
                            ? _player.pause()
                            : _player.play(),
                  icon: ArchiveIcon(
                    _playing
                        ? CupertinoIcons.pause_circle_filled
                        : CupertinoIcons.play_circle_fill,
                    size: 52,
                  ),
                ),
                IconButton(
                  key: const ValueKey('fanqie-audio-next'),
                  onPressed: _index + 1 < _chapterCount
                      ? () => _skip(1)
                      : null,
                  icon: const ArchiveIcon(
                    CupertinoIcons.forward_end,
                    size: 24,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
