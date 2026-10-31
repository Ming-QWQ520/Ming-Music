/// 登录弹窗（仿网易云 App 登录页）：
///  - Tab1 扫码登录：二维码 + 状态文案（等待/已扫码/过期刷新/成功）；
///  - Tab2 手机登录：区号+手机号 + 密码/验证码切换 + 发送验证码倒计时。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../data/netease_auth_repository.dart' show QrStatus;
import '../providers/auth_providers.dart';
import '../../../core/widgets/sheet_host.dart' show showMingSheet;

import '../../../core/widgets/app_notify.dart';

/// 全局登录入口：弹出底部登录面板
Future<void> showLoginSheet(BuildContext context) {
  return showMingSheet<void>(
    context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: true,
    builder: (BuildContext ctx) => const LoginSheet(),
  );
}

class LoginSheet extends ConsumerStatefulWidget {
  const LoginSheet({super.key});

  @override
  ConsumerState<LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends ConsumerState<LoginSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  final TextEditingController _phone = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _captcha = TextEditingController();
  bool _useCaptcha = false;
  bool _obscure = true;
  int _countdown = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authProvider.notifier).startQrLogin();
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _phone.dispose();
    _password.dispose();
    _captcha.dispose();
    super.dispose();
  }

  Future<void> _sendCaptcha() async {
    if (_phone.text.trim().isEmpty || _countdown > 0) return;
    final bool ok =
        await ref.read(authProvider.notifier).sendCaptcha(_phone.text.trim());
    if (!mounted) return;
    if (ok) {
      setState(() => _countdown = 60);
      _tick();
    } else {
      _toast('验证码发送失败，请稍后重试');
    }
  }

  Future<void> _tick() async {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() => _countdown = _countdown - 1);
    if (_countdown > 0) _tick();
  }

  Future<void> _phoneLogin() async {
    final String phone = _phone.text.trim();
    if (phone.isEmpty) {
      _toast('请输入手机号');
      return;
    }
    if (_useCaptcha && _captcha.text.trim().isEmpty) {
      _toast('请输入验证码');
      return;
    }
    if (!_useCaptcha && _password.text.isEmpty) {
      _toast('请输入密码');
      return;
    }
    final String? error = await ref.read(authProvider.notifier).phoneLogin(
          phone: phone,
          password: _useCaptcha ? null : _password.text,
          captcha: _useCaptcha ? _captcha.text.trim() : null,
        );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
    } else {
      _toast(error);
    }
  }

  void _toast(String msg) {
    AppNotify.show(msg);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authProvider, (AuthState? prev, AuthState next) {
      if (prev?.status != AuthStatus.loggedIn &&
          next.status == AuthStatus.loggedIn &&
          mounted) {
        Navigator.of(context).pop();
      }
    });

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E22),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 顶部把手 + 标题
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Row(
                  children: <Widget>[
                    const Text(
                      '登录网易云音乐',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        ref.read(authProvider.notifier).closeLoginFlow();
                        Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.close_rounded,
                          color: Colors.white60, size: 22),
                    ),
                  ],
                ),
              ),
              TabBar(
                controller: _tab,
                indicatorColor: AppConstants.brandColor,
                indicatorSize: TabBarIndicatorSize.label,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white38,
                tabs: const <Widget>[
                  Tab(text: '扫码登录'),
                  Tab(text: '手机登录'),
                ],
              ),
              SizedBox(
                height: 430,
                child: TabBarView(
                  controller: _tab,
                  children: <Widget>[
                    _buildQrPane(),
                    _buildPhonePane(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- QR pane

  Widget _buildQrPane() {
    final AuthState auth = ref.watch(authProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: Column(
        children: <Widget>[
          // 二维码卡片（白底便于扫码识别）
          GestureDetector(
            onTap: auth.qrStatus == QrStatus.expired ||
                    auth.qrStatus == QrStatus.idle
                ? () => ref.read(authProvider.notifier).refreshQr()
                : null,
            child: Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              padding: const EdgeInsets.all(10),
              child: Center(
                child: _qrInner(auth),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            auth.qrMessage.isEmpty ? ' ' : auth.qrMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: auth.qrStatus == QrStatus.expired ||
                      auth.qrStatus == QrStatus.idle
                  ? AppConstants.brandColor
                  : Colors.white70,
              fontSize: 13.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '扫描二维码即可安全登录，本应用不保存密码',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.35), fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _qrInner(AuthState auth) {
    switch (auth.qrStatus) {
      case QrStatus.loading:
      case QrStatus.idle:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (auth.qrStatus == QrStatus.loading)
              const CircularProgressIndicator(
                  strokeWidth: 2.4, color: AppConstants.brandColor)
            else
              const Icon(Icons.refresh_rounded,
                  size: 40, color: Colors.black45),
            const SizedBox(height: 8),
            Text(
              auth.qrStatus == QrStatus.loading ? '生成中…' : '点击刷新',
              style: const TextStyle(color: Colors.black54, fontSize: 12),
            ),
          ],
        );
      case QrStatus.expired:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Icon(Icons.timer_off_rounded,
                size: 40, color: Colors.black45),
            const SizedBox(height: 8),
            const Text('二维码已过期',
                style: TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 4),
            Text('点击刷新',
                style: TextStyle(
                    color: AppConstants.brandColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ],
        );
      default:
        final String data = auth.qrImage ?? '';
        final String base64Part =
            data.contains(',') ? data.substring(data.indexOf(',') + 1) : data;
        if (base64Part.isEmpty) {
          return const Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: AppConstants.brandColor));
        }
        return Image.memory(
          base64Decode(base64Part),
          fit: BoxFit.contain,
          gaplessPlayback: true,
        );
    }
  }

  // ------------------------------------------------------------- phone pane

  Widget _buildPhonePane() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text('+86',
                  style: TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  decoration: _inputDecoration('手机号'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_useCaptcha)
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _captcha,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: _inputDecoration('验证码'),
                  ),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _countdown > 0 ? null : _sendCaptcha,
                  child: Text(
                    _countdown > 0 ? '${_countdown}s' : '发送验证码',
                    style: TextStyle(
                      color: _countdown > 0
                          ? Colors.white30
                          : AppConstants.brandColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            )
          else
            TextField(
              controller: _password,
              obscureText: _obscure,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: _inputDecoration('密码').copyWith(
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: Colors.white30,
                    size: 20,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() {
                _useCaptcha = !_useCaptcha;
              }),
              child: Text(
                _useCaptcha ? '使用密码登录' : '使用验证码登录',
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 46,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.brandColor,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23)),
              ),
              onPressed: ref.watch(authProvider.select((AuthState s) => s.busy))
                  ? null
                  : _phoneLogin,
              child: const Text('登 录',
                  style:
                      TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '登录后可使用喜欢歌曲、评论点赞、我的歌单等功能',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3), fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      counterText: '',
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24, fontSize: 14),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }
}
