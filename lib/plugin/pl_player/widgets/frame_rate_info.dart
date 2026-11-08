import 'dart:async' show Timer;
import 'dart:ui' as ui;

import 'package:PiliPlus/plugin/pl_player/models/frame_stats.dart';
import 'package:PiliPlus/plugin/pl_player/utils/refresh_rate_matcher.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

/// 播放信息里的「帧率」分组。
///
/// 每秒重新采样一次，可以在视频继续播放的情况下观察：
/// 片源帧率、mpv 输出帧率、Flutter 出帧率、屏幕刷新率、丢帧计数。
/// 点击任意一项可复制完整快照，方便贴到 issue 里。
class FrameRateTiles extends StatefulWidget {
  const FrameRateTiles({super.key, required this.player});

  final NativePlayer player;

  @override
  State<FrameRateTiles> createState() => _FrameRateTilesState();
}

class _FrameRateTilesState extends State<FrameRateTiles> {
  late final FrameStatsSampler _sampler = FrameStatsSampler(widget.player);
  Timer? _timer;
  FrameStats _stats = const FrameStats();

  /// Flutter 引擎上一秒实际出帧数
  int _frameCount = 0;
  int _lastFrameCount = 0;
  double _renderFps = 0;
  int _lastTickUs = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _lastTickUs = DateTime.now().microsecondsSinceEpoch;
    _stats = _sampler.sample(panelHz: _panelHz);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    _frameCount += timings.length;
  }

  void _tick() {
    if (!mounted) return;
    final nowUs = DateTime.now().microsecondsSinceEpoch;
    final seconds = (nowUs - _lastTickUs) / 1000000;
    final frames = _frameCount - _lastFrameCount;
    _lastTickUs = nowUs;
    _lastFrameCount = _frameCount;
    if (seconds > 0.2) {
      _renderFps = frames / seconds;
    }
    final stats = _sampler.sample(panelHz: _panelHz, renderFps: _renderFps);
    if (mounted) {
      setState(() => _stats = stats);
    }
  }

  /// 屏幕刷新率。
  ///
  /// 注意：这个值来自 `Display.getRefreshRate()`，在 LTPO 屏上它是「当前
  /// Display.Mode 的标称值」，面板在硬件层做无缝降频时不一定会跟着变，
  /// 所以要和 [FrameStats.renderFps] / `estimated-vf-fps` 一起看。
  static double get _panelHz {
    final dispatcher = ui.PlatformDispatcher.instance;
    final view =
        dispatcher.implicitView ??
        (dispatcher.views.isEmpty ? null : dispatcher.views.first);
    return view?.display.refreshRate ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    final content = stats.contentFps;
    final warnColor = Theme.of(context).colorScheme.error;
    final applied = RefreshRateMatcher.appliedMode;
    final copyText = applied == null
        ? stats.toCopyText()
        : '${stats.toCopyText()}\n已锁定刷新率: ${applied.refreshRate}Hz (mode #${applied.id})';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _tile(
          '视频帧率（容器）',
          stats.containerFps == null
              ? '未知'
              : FrameStats.formatFps(stats.containerFps),
          copyText,
        ),
        _tile('mpv 输出帧率', FrameStats.formatFps(stats.outputFps), copyText),
        _tile('Flutter 渲染帧率', FrameStats.formatFps(stats.renderFps), copyText),
        _tile(
          '屏幕刷新率',
          FrameStats.formatFps(stats.panelHz),
          copyText,
          color: stats.isDowngraded && stats.panelHz > 0 ? warnColor : null,
        ),
        if (applied != null)
          _tile(
            '已锁定刷新率',
            '${applied.refreshRate.toStringAsFixed(0)} Hz',
            copyText,
          ),
        _tile('mpv 屏幕帧率', FrameStats.formatFps(stats.displayFps), copyText),
        _tile(
          '丢帧 / 时序错误',
          '${stats.droppedFrames} / ${stats.mistimedFrames}',
          copyText,
        ),
        if (stats.isDowngraded)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '内容 $content fps，屏幕只有 ${stats.panelHz.toStringAsFixed(0)}Hz：'
              '每一帧内容只分到半个屏幕刷新周期，实际看到的是 '
              '${stats.panelHz.toStringAsFixed(0)}fps',
              style: TextStyle(color: warnColor, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _tile(
    String title,
    String value,
    String copyText, {
    Color? color,
  }) {
    return ListTile(
      dense: true,
      title: Text(title),
      subtitle: Text(value, style: TextStyle(color: color)),
      onTap: () {
        Utils.copyText(copyText);
      },
    );
  }
}
