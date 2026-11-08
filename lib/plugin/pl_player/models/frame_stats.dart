import 'package:media_kit/media_kit.dart' show NativePlayer;

/// 一次「帧率快照」。
///
/// mpv 里有好几个互不相同的「帧率」，排查画面不流畅 / 屏幕降刷新率时必须分开看：
///
/// - [containerFps]    容器（DASH）声明的帧率，来自 `demux-fps`，静态值
/// - [containerFpsMpv] mpv 自己解析出的 `container-fps`
/// - [outputFps]       视频输出链路实际在跑的帧率，`estimated-vf-fps`
/// - [displayFps]      mpv 认为的屏幕刷新率，`display-fps`（Android 上常为 0）
/// - [panelHz]         Flutter 上报的屏幕刷新率（`Display.getRefreshRate()`）
/// - [renderFps]       Flutter 引擎实际出帧率（每秒 FrameTiming 条数）
/// - [droppedFrames]   `frame-drop-count`，VO 丢掉的帧
/// - [mistimedFrames]  `mistimed-frame-count`，VSync 对不齐的帧
///
/// [renderFps] 很关键：Android 的 SurfaceFlinger 是按「这个应用每秒真正提交了
/// 几帧」来给刷新率投票的。如果面板降到 30Hz，Flutter 的 vsync 也只剩 30Hz，
/// 应用就只能提交 30 帧/秒 —— 系统于是认为 30Hz 是「正确」的，形成自锁。
class FrameStats {
  const FrameStats({
    this.containerFps,
    this.containerFpsMpv = 0,
    this.outputFps = 0,
    this.displayFps = 0,
    this.panelHz = 0,
    this.renderFps = 0,
    this.droppedFrames = 0,
    this.mistimedFrames = 0,
  });

  final double? containerFps;
  final double containerFpsMpv;
  final double outputFps;
  final double displayFps;
  final double panelHz;
  final double renderFps;
  final int droppedFrames;
  final int mistimedFrames;

  /// 展示用的「内容帧率」：优先容器声明值，其次 mpv 的 container-fps。
  double get contentFps {
    final value = containerFps;
    if (value != null && value > 1) return value;
    return containerFpsMpv;
  }

  /// 内容帧率明显高于屏幕刷新率：面板一帧里塞了两帧内容，等于只显示一半。
  bool get isDowngraded =>
      contentFps > 1 && panelHz > 1 && panelHz + 0.5 < contentFps;

  String toCopyText() {
    return 'FPS\n'
        '容器帧率: ${formatFps(containerFps)}\n'
        'container-fps: ${formatFps(containerFpsMpv)}\n'
        'estimated-vf-fps: ${formatFps(outputFps)}\n'
        'Flutter 渲染帧率: ${formatFps(renderFps)}\n'
        '屏幕刷新率(Flutter): ${formatFps(panelHz)}\n'
        'display-fps(mpv): ${formatFps(displayFps)}\n'
        '丢帧: $droppedFrames / 时序错误: $mistimedFrames';
  }

  static String formatFps(double? value) {
    if (value == null || value <= 0) return '未知';
    // 29.97 这类 NTSC 帧率保留三位小数才不会看错
    return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 3)} fps';
  }
}

/// 从 mpv 抓取帧率快照。
///
/// [NativePlayer.getProperty] 是同步的 `mpv_get_property_string`，开销很低，
/// 但也不适合每帧调用；这里只按秒调用。
class FrameStatsSampler {
  FrameStatsSampler(this.player);

  final NativePlayer player;

  static const List<String> _properties = [
    'container-fps',
    'estimated-vf-fps',
    'display-fps',
    'frame-drop-count',
    'mistimed-frame-count',
  ];

  /// 采样一次。
  ///
  /// [panelHz] 与 [renderFps] 由调用方（Flutter 侧）传入。
  FrameStats sample({double panelHz = 0, double renderFps = 0}) {
    final values = <String, String>{};
    for (final property in _properties) {
      try {
        values[property] = player.getProperty(property);
      } catch (_) {
        // player 已 dispose 时会抛异常，忽略即可
        values[property] = '';
      }
    }

    double? trackFps;
    try {
      trackFps = player.state.track.video.fps;
    } catch (_) {
      trackFps = null;
    }

    return FrameStats(
      containerFps: trackFps,
      containerFpsMpv: _readDouble(values['container-fps']),
      outputFps: _readDouble(values['estimated-vf-fps']),
      displayFps: _readDouble(values['display-fps']),
      panelHz: panelHz,
      renderFps: renderFps,
      droppedFrames: _readInt(values['frame-drop-count']),
      mistimedFrames: _readInt(values['mistimed-frame-count']),
    );
  }

  static double _readDouble(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    return double.tryParse(raw) ?? 0;
  }

  static int _readInt(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    // mpv 的 int 属性以字符串返回，但个别版本会带上小数位
    final value = double.tryParse(raw);
    return value == null ? 0 : value.toInt();
  }
}
