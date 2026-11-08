import 'dart:io' show Platform;

import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter_displaymode/flutter_displaymode.dart';

/// 把「视频内容帧率」换算成「正确的屏幕刷新率」并钉住。
///
/// 为什么不能只「抬一档」：
/// LTPO 面板可以在 mode 不变的情况下把物理刷新率无缝降到同一个 group 里的
/// 备选档位（本机 120Hz 的 mode 带了 24/30/60 三个备选）。所以
/// `FlutterDisplayMode.active` 在掉到 30Hz 时**仍然返回 120**——
/// 拿它做比较，等于什么都没做。
///
/// 这里的做法是：不比较、直接按内容帧率算出一档「整数倍」刷新率钉住。
///
///   * 24fps  → 24Hz（1:1）
///   * 25fps  → 没有 50/100 时退到最接近的档位
///   * 30fps  → 30Hz（1:1），**绝不能是 24Hz**（30/24 = 1.25，cadence 不齐 → 卡顿）
///   * 60fps  → 60Hz（1:1），**绝不能是 30Hz**（会被抽掉一半的帧）
///
/// 只改窗口的 `preferredDisplayModeId`（`flutter_displaymode`），
/// 用户自己选过具体刷新率时不抢方向盘，退出播放时恢复。
abstract final class RefreshRateMatcher {
  static DisplayMode? _restoreTo;
  static double _appliedFor = 0;

  /// 当前已锁定的刷新率，供「播放信息」展示
  static DisplayMode? appliedMode;

  /// [videoFps] 为内容帧率（容器帧率）。重复调用是安全的。
  static Future<void> sync(double videoFps) async {
    if (!Platform.isAndroid) return;
    if (!Pref.matchVideoFrameRate) return;
    if (videoFps < 20 || videoFps > 200) return;
    if (_appliedFor == videoFps) return;
    // 用户在「屏幕帧率」里选过具体档位，尊重他的选择
    if (!_isAutoMode()) return;

    try {
      final modes = (await FlutterDisplayMode.supported)
          .where((mode) => mode != DisplayMode.auto && mode.refreshRate > 0)
          .toList();
      final target = pickMode(modes, videoFps);
      if (target == null) return;
      _restoreTo ??= await FlutterDisplayMode.preferred;
      await FlutterDisplayMode.setPreferredMode(target);
      appliedMode = target;
      _appliedFor = videoFps;
      if (kDebugMode) {
        debugPrint(
          'RefreshRateMatcher: ${videoFps.toStringAsFixed(2)}fps -> '
          '${target.refreshRate}Hz (mode #${target.id})',
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('RefreshRateMatcher.sync failed: $e');
    }
  }

  /// 恢复调用方原本的首选刷新率（可能是「自动」）。
  static Future<void> restore() async {
    final target = _restoreTo;
    if (target == null) return;
    _restoreTo = null;
    _appliedFor = 0;
    appliedMode = null;
    try {
      await FlutterDisplayMode.setPreferredMode(target);
      if (kDebugMode) debugPrint('RefreshRateMatcher: restored $target');
    } catch (e) {
      if (kDebugMode) debugPrint('RefreshRateMatcher.restore failed: $e');
    }
  }

  /// 用户设置里的「屏幕帧率」是否还是「自动」。
  static bool _isAutoMode() {
    final stored = GStorage.setting.get(SettingBoxKey.displayMode);
    return stored is! String || stored == DisplayMode.auto.toString();
  }

  /// 从可用档位里挑「和内容帧率成整数倍」的那一档。
  ///
  /// 依次尝试：完全相等 → 最小的整数倍 → cadence 误差最小的、且不低于内容帧率的档位。
  /// 只在最高分辨率的那一组里挑，避免选到小尺寸的模式。
  static DisplayMode? pickMode(List<DisplayMode> all, double fps) {
    if (all.isEmpty || fps <= 0) return null;

    final maxArea = all
        .map((mode) => mode.width * mode.height)
        .reduce((a, b) => a > b ? a : b);
    final modes = all
        .where((mode) => mode.width * mode.height == maxArea)
        .toList();
    if (modes.isEmpty) return null;

    // 1) 完全相等（59.94 对 60.000004 这种也算）
    DisplayMode? exact;
    for (final mode in modes) {
      if ((mode.refreshRate - fps).abs() <= 0.5) {
        if (exact == null || mode.refreshRate < exact.refreshRate) exact = mode;
      }
    }
    if (exact != null) return exact;

    // 2) 取最小的整数倍（1:1 已经在上一步排除，这里至少是 2 倍）
    DisplayMode? multiple;
    for (final mode in modes) {
      final rate = mode.refreshRate;
      if (rate < fps - 0.5) continue;
      final ratio = rate / fps;
      if ((ratio - ratio.roundToDouble()).abs() <= 0.02) {
        if (multiple == null || rate < multiple.refreshRate) multiple = mode;
      }
    }
    if (multiple != null) return multiple;

    // 3) 没有整数倍可用（例如 25fps）：退而求其次，误差最小、且不低于内容帧率
    DisplayMode? closest;
    var bestError = double.infinity;
    for (final mode in modes) {
      final rate = mode.refreshRate;
      if (rate < fps - 0.5) continue;
      final ratio = rate / fps;
      final error = (ratio - ratio.roundToDouble()).abs();
      if (error < bestError) {
        bestError = error;
        closest = mode;
      }
    }
    return closest;
  }
}
