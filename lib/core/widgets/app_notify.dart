/// 自定义应用内通知（需求第二十四批：不使用 Flutter 底部原生
/// SnackBar，全部改为品牌风格顶部浮层）。
///
/// 用法：任意位置 `AppNotify.show('文案')`（无需 BuildContext，
/// Provider/回调内也可用）；`AppNotify.success(...)` / `AppNotify.error(...)`
/// 带语义图标。
///
/// 设计：
///  - 挂载于 MaterialApp.builder 的全局 Stack 顶层（AppNotifyHost），
///    覆盖所有页面/弹层，不依赖 Overlay，无需 context；
///  - 顶部安全区下垂直排列；单卡下滑进场（easeOutCubic）、自动 2.8s
///    消失、同屏最多 3 条、点击立即关闭；
///  - 深色玻璃卡片 + 语义色描边图标（默认品牌红 / 成功绿 / 错误红）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/app_constants.dart';

/// 单条通知数据
class _Notice {
  _Notice(this.id, this.message, this.icon, this.tint);

  final int id;
  final String message;
  final IconData icon;

  /// 图标语义色（缺省品牌红）
  final Color tint;
}

/// 应用内通知中心（单例）
class AppNotify {
  AppNotify._();

  static final AppNotify instance = AppNotify._();

  final List<_Notice> _queue = <_Notice>[];
  int _seq = 0;
  void Function()? _onChange;

  /// 最大同屏条数（超出移除最旧）
  static const int _kMaxVisible = 3;

  static const Color _kSuccess = Color(0xFF4CC38A);

  /// 弹出一条应用内通知（替代 ScaffoldMessenger SnackBar）
  static void show(String message, {IconData? icon}) {
    instance._push(message, icon ?? Icons.info_outline_rounded,
        AppConstants.brandColor);
  }

  /// 成功语义（绿色对勾）
  static void success(String message) {
    instance._push(message, Icons.check_circle_outline_rounded, _kSuccess);
  }

  /// 错误语义（品牌红感叹号）
  static void error(String message) {
    instance._push(message, Icons.error_outline_rounded,
        AppConstants.brandColor);
  }

  void _push(String message, IconData icon, Color tint) {
    final _Notice n = _Notice(_seq++, message, icon, tint);
    _queue.add(n);
    while (_queue.length > _kMaxVisible) {
      _queue.removeAt(0);
    }
    _onChange?.call();
    // 自动消失
    Timer(const Duration(milliseconds: 2800), () => _remove(n.id));
  }

  void _remove(int id) {
    final int idx = _queue.indexWhere((_Notice n) => n.id == id);
    if (idx < 0) return;
    _queue.removeAt(idx);
    _onChange?.call();
  }

  void _bind(void Function()? cb) => _onChange = cb;
}

/// 全局通知宿主：挂在 MaterialApp.builder 最外层（覆盖 Navigator 与
/// 全部弹层）；顶部安全区下垂直排列，不挡下层手势（仅卡片可交互）。
class AppNotifyHost extends StatefulWidget {
  const AppNotifyHost({super.key, required this.child});

  final Widget child;

  @override
  State<AppNotifyHost> createState() => _AppNotifyHostState();
}

class _AppNotifyHostState extends State<AppNotifyHost> {
  @override
  void initState() {
    super.initState();
    AppNotify.instance._bind(_onChanged);
  }

  @override
  void dispose() {
    AppNotify.instance._bind(null);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<_Notice> queue = AppNotify.instance._queue;
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: queue.isEmpty,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final _Notice n in queue)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 5, 20, 5),
                    child: _NoticeCard(
                      key: ValueKey<int>(n.id),
                      notice: n,
                      onClose: () => AppNotify.instance._remove(n.id),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 单条通知卡片：深色玻璃 + 语义色图标 + 下滑淡入进场
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    super.key,
    required this.notice,
    required this.onClose,
  });

  final _Notice notice;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // 进场：-16px 下滑 + 0→1 淡入（easeOutCubic 300ms，切行平滑曲线同族）
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double t, Widget? child) {
        return Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, -16 * (1 - t)),
            child: child,
          ),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onClose,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xE61C1C1E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.10),
                width: 0.8,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(notice.icon, size: 18, color: notice.tint),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    notice.message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
