/// 账户状态管理：
///
///  - 启动恢复：本地 userCookie → /login/status 校验 → 已登录/游客；
///  - 二维码登录：qrKey → qrCreate → 2s 轮询 qrCheck（800/801/802/803）；
///  - 手机登录：密码或验证码；
///  - 登录后加载：等级 / 听歌时长 / 网易云喜欢列表（ids）；
///  - 网易云喜欢 toggle（乐观更新 + 失败回滚 + 内存缓存）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart';
import '../../discover/data/netease_providers.dart' show neteaseApiProvider;
import '../../settings/providers/settings_providers.dart'
    show PrefsKeys, sharedPreferencesProvider;
import '../data/netease_auth_repository.dart';

/// 账户状态
enum AuthStatus { unknown, guest, loggedIn }

class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.profile,
    this.level,
    this.listenSeconds = 0,
    this.qrStatus = QrStatus.idle,
    this.qrImage,
    this.qrMessage = '',
    this.likedIds = const <int>{},
    this.busy = false,
  });

  final AuthStatus status;
  final NeteaseProfile? profile;

  /// 用户等级（异步加载，可能为 null）
  final NeteaseLevel? level;

  /// 累计听歌秒数
  final int listenSeconds;

  // 二维码登录流程
  final QrStatus qrStatus;
  final String? qrImage;
  final String qrMessage;

  /// 网易云喜欢歌曲 id 集合（登录后可用）
  final Set<int> likedIds;

  /// 登录/登出进行中
  final bool busy;

  bool get loggedIn => status == AuthStatus.loggedIn;

  AuthState copyWith({
    AuthStatus? status,
    NeteaseProfile? profile,
    bool clearProfile = false,
    NeteaseLevel? level,
    bool clearLevel = false,
    int? listenSeconds,
    QrStatus? qrStatus,
    String? qrImage,
    bool clearQrImage = false,
    String? qrMessage,
    Set<int>? likedIds,
    bool? busy,
  }) {
    return AuthState(
      status: status ?? this.status,
      profile: clearProfile ? null : (profile ?? this.profile),
      level: clearLevel ? null : (level ?? this.level),
      listenSeconds: listenSeconds ?? this.listenSeconds,
      qrStatus: qrStatus ?? this.qrStatus,
      qrImage: clearQrImage ? null : (qrImage ?? this.qrImage),
      qrMessage: qrMessage ?? this.qrMessage,
      likedIds: likedIds ?? this.likedIds,
      busy: busy ?? this.busy,
    );
  }
}

final NotifierProvider<AuthNotifier, AuthState> authProvider =
    NotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);

/// 网易云账号仓库
final Provider<NeteaseAuthRepository> neteaseAuthRepositoryProvider =
    Provider<NeteaseAuthRepository>(
  (Ref ref) => NeteaseAuthRepository(ref.watch(neteaseApiProvider)),
);

class AuthNotifier extends Notifier<AuthState> {
  NeteaseAuthRepository get _repo => ref.read(neteaseAuthRepositoryProvider);
  NeteaseApi get _api => ref.read(neteaseApiProvider);

  Timer? _qrTimer;
  String _qrKey = '';
  bool _disposed = false;

  @override
  AuthState build() {
    ref.onDispose(() {
      _disposed = true;
      _stopQrPolling();
    });
    // 启动恢复（异步校验，不阻塞 UI）
    Future<void>.microtask(_restore);
    return const AuthState(status: AuthStatus.unknown);
  }

  Future<void> _restore() async {
    final String? saved =
        ref.read(sharedPreferencesProvider).getString(PrefsKeys.userCookie);
    if (saved == null || saved.isEmpty) {
      state = state.copyWith(status: AuthStatus.guest);
      return;
    }
    _api.restoreUserCookie(saved);
    final NeteaseProfile? profile = await _safeStatus();
    if (profile != null) {
      state = state.copyWith(
        status: AuthStatus.loggedIn,
        profile: profile,
      );
      unawaited(_loadExtras(profile.userId));
    } else {
      // cookie 失效
      _api.clearUserCookie();
      state = state.copyWith(status: AuthStatus.guest);
    }
  }

  Future<NeteaseProfile?> _safeStatus() async {
    try {
      return await _repo.loginStatus();
    } catch (e) {
      debugPrint('login/status 失败: $e');
      return null;
    }
  }

  /// 登录成功后的公共入口
  Future<void> _onLoginSuccess(String cookie) async {
    _api.setUserCookie(cookie);
    final NeteaseProfile? profile = await _safeStatus();
    if (profile == null) {
      state = state.copyWith(
        status: AuthStatus.guest,
        busy: false,
        qrMessage: '登录成功但获取账号信息失败',
      );
      return;
    }
    state = state.copyWith(
      status: AuthStatus.loggedIn,
      profile: profile,
      busy: false,
      qrStatus: QrStatus.success,
      qrMessage: '登录成功',
      clearLevel: true,
      listenSeconds: 0,
      likedIds: const <int>{},
    );
    unawaited(_loadExtras(profile.userId));
  }

  /// 加载等级 / 听歌时长 / 喜欢列表（失败静默，非关键数据）
  Future<void> _loadExtras(int uid) async {
    final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
      _repo.userLevel(),
      _repo.listenDataTotal(),
      _repo.likeList(uid),
    ]);
    if (_disposed) return;
    state = state.copyWith(
      level: results[0] as NeteaseLevel?,
      listenSeconds: (results[1] as int?) ?? 0,
      likedIds: Set<int>.of((results[2] as List<int>?) ?? const <int>[]),
    );
  }

  // ------------------------------------------------------------ QR login

  /// 启动二维码登录流程
  Future<void> startQrLogin() async {
    _stopQrPolling();
    state = state.copyWith(
      qrStatus: QrStatus.loading,
      qrMessage: '正在生成二维码…',
      clearQrImage: true,
    );
    try {
      _qrKey = await _repo.qrKey();
      final String img = await _repo.qrCreate(_qrKey);
      state = state.copyWith(
        qrStatus: QrStatus.waiting,
        qrImage: img,
        qrMessage: '请使用网易云音乐 App 扫码登录',
      );
      _startQrPolling();
    } catch (_) {
      state = state.copyWith(
        qrStatus: QrStatus.idle,
        qrMessage: '二维码生成失败，请点击重试',
      );
    }
  }

  void _startQrPolling() {
    _stopQrPolling();
    _qrTimer = Timer.periodic(const Duration(seconds: 2), (Timer t) async {
      if (_qrKey.isEmpty) return;
      try {
        final (int code, _, String? cookie) = await _repo.qrCheck(_qrKey);
        switch (code) {
          case 800:
            _stopQrPolling();
            state = state.copyWith(
              qrStatus: QrStatus.expired,
              qrMessage: '二维码已过期，请点击刷新',
            );
          case 802:
            state = state.copyWith(
              qrStatus: QrStatus.scanned,
              qrMessage: '已扫码，请在手机上确认',
            );
          case 803:
            _stopQrPolling();
            if (cookie != null && cookie.isNotEmpty) {
              final String? musicU = _extractMusicU(cookie);
              if (musicU != null) {
                await _onLoginSuccess(musicU);
              } else {
                state = state.copyWith(
                  qrStatus: QrStatus.expired,
                  qrMessage: '登录凭证解析失败，请重试',
                );
              }
            }
          case 801:
          default:
            break; // 继续等待
        }
      } catch (_) {
        // 抖动忽略，下轮继续
      }
    });
  }

  void _stopQrPolling() {
    _qrTimer?.cancel();
    _qrTimer = null;
  }

  /// 关闭登录界面时调用（停止轮询，重置二维码状态）
  void closeLoginFlow() {
    _stopQrPolling();
    _qrKey = '';
    state = state.copyWith(
      qrStatus: QrStatus.idle,
      qrMessage: '',
      clearQrImage: true,
    );
  }

  void refreshQr() => startQrLogin();

  // ------------------------------------------------------ cellphone login

  Future<String?> phoneLogin({
    required String phone,
    String? password,
    String? countrycode,
    String? captcha,
  }) async {
    state = state.copyWith(busy: true);
    try {
      final (int code, String msg, String? cookie) = await _repo.loginCellphone(
        phone: phone,
        password: password,
        countrycode: countrycode,
        captcha: captcha,
      );
      if (code == 200 && cookie != null && cookie.isNotEmpty) {
        final String musicU = _extractMusicU(cookie) ?? cookie;
        await _onLoginSuccess(musicU);
        return null;
      }
      return msg.isEmpty ? '登录失败 (code: $code)' : msg;
    } on ApiException catch (e) {
      return e.message;
    } catch (e) {
      return '网络异常：$e';
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<bool> sendCaptcha(String phone, {String? countrycode}) async {
    try {
      await _repo.captchaSent(phone, countrycode: countrycode);
      return true;
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------------- logout

  Future<void> logout() async {
    state = state.copyWith(busy: true);
    await _repo.logout();
    _api.clearUserCookie();
    state = state.copyWith(
      status: AuthStatus.guest,
      clearProfile: true,
      clearLevel: true,
      listenSeconds: 0,
      likedIds: const <int>{},
      busy: false,
      qrStatus: QrStatus.idle,
      qrMessage: '',
      clearQrImage: true,
    );
  }

  /// 刷新用户附加信息（下拉刷新场景）
  Future<void> refreshExtras() async {
    final int? uid = state.profile?.userId;
    if (uid != null) await _loadExtras(uid);
  }

  // ----------------------------------------------------------- netease like

  /// 是否已喜欢（网易云侧）
  bool isLiked(int? neteaseId) =>
      neteaseId != null && state.likedIds.contains(neteaseId);

  /// 喜欢 / 取消喜欢（乐观更新 + 失败回滚）。返回错误文案（null 成功）
  Future<String?> toggleLikeSong(int neteaseId) async {
    if (!state.loggedIn) return '请先登录网易云音乐';
    final bool wasLiked = state.likedIds.contains(neteaseId);
    final Set<int> next = Set<int>.of(state.likedIds);
    if (wasLiked) {
      next.remove(neteaseId);
    } else {
      next.add(neteaseId);
    }
    state = state.copyWith(likedIds: next);
    try {
      final bool ok = await _repo.likeSong(neteaseId, like: !wasLiked);
      if (!ok) {
        state = state.copyWith(likedIds: Set<int>.of(state.likedIds));
        // 回滚
        final Set<int> rollback = Set<int>.of(state.likedIds);
        if (wasLiked) {
          rollback.add(neteaseId);
        } else {
          rollback.remove(neteaseId);
        }
        state = state.copyWith(likedIds: rollback);
        return '操作失败，请稍后重试';
      }
      return null;
    } catch (e) {
      final Set<int> rollback = Set<int>.of(state.likedIds);
      if (wasLiked) {
        rollback.add(neteaseId);
      } else {
        rollback.remove(neteaseId);
      }
      state = state.copyWith(likedIds: rollback);
      return '网络异常：$e';
    }
  }

  /// set-cookie 串提取 MUSIC_U
  static String? _extractMusicU(String raw) {
    final RegExpMatch? m = RegExp(r'MUSIC_U=([^;]+)').firstMatch(raw);
    return m == null ? null : 'MUSIC_U=${m.group(1)!}';
  }
}
