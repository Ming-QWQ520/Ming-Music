/// 账户状态管理：
///
///  - 启动恢复：本地 userCookie → /login/status 校验 → 已登录/游客；
///  - 二维码登录：qrKey → qrCreate → 2s 轮询 qrCheck（800/801/802/803）；
///  - 手机登录：密码或验证码；
///  - 登录后加载：等级 / 听歌时长 / 网易云喜欢列表（ids）；
///  - 网易云喜欢 toggle（乐观更新 + 失败回滚 + 内存缓存）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/netease_api.dart';
import '../../../core/utils/platform_actions.dart';
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
    this.vip,
    this.qrStatus = QrStatus.idle,
    this.qrImage,
    this.qrMessage = '',
    this.likedIds = const <int>{},
    this.busy = false,
    this.statusCheckFailed = false,
  });

  final AuthStatus status;
  final NeteaseProfile? profile;

  /// 用户等级（异步加载，可能为 null）
  final NeteaseLevel? level;

  /// VIP 信息（/vip/info/v2，对齐 Zephyr）
  final NeteaseVipInfo? vip;

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

  /// 本地有 cookie 但 /login/status 网络校验失败（cookie 保留，可重试）
  final bool statusCheckFailed;

  bool get loggedIn => status == AuthStatus.loggedIn;

  AuthState copyWith({
    AuthStatus? status,
    NeteaseProfile? profile,
    bool clearProfile = false,
    NeteaseLevel? level,
    bool clearLevel = false,
    NeteaseVipInfo? vip,
    bool clearVip = false,
    int? listenSeconds,
    QrStatus? qrStatus,
    String? qrImage,
    bool clearQrImage = false,
    String? qrMessage,
    Set<int>? likedIds,
    bool? busy,
    bool? statusCheckFailed,
    bool clearStatusCheckFailed = false,
  }) {
    return AuthState(
      status: status ?? this.status,
      profile: clearProfile ? null : (profile ?? this.profile),
      level: clearLevel ? null : (level ?? this.level),
      vip: clearVip ? null : (vip ?? this.vip),
      listenSeconds: listenSeconds ?? this.listenSeconds,
      qrStatus: qrStatus ?? this.qrStatus,
      qrImage: clearQrImage ? null : (qrImage ?? this.qrImage),
      qrMessage: qrMessage ?? this.qrMessage,
      likedIds: likedIds ?? this.likedIds,
      busy: busy ?? this.busy,
      statusCheckFailed: clearStatusCheckFailed
          ? false
          : (statusCheckFailed ?? this.statusCheckFailed),
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

  /// 点赞进行中标记（避免 refreshLikeList 覆盖乐观更新）
  bool _likeToggling = false;

  @override
  AuthState build() {
    ref.onDispose(() {
      _disposed = true;
      _stopQrPolling();
      _api.onAuthLost = null;
    });
    // 需求第二十三批「被移除设备提示」：登录态下任何接口返回 301
    // （设备被移除/账号顶号下线，cookie 失效）→ 全局提示一次并回到未登录态
    _api.onAuthLost = _handleAuthLost;
    // 启动恢复（异步校验，不阻塞 UI）
    Future<void>.microtask(_restore);
    return const AuthState(status: AuthStatus.unknown);
  }

  /// 登录态失效（设备被移除/顶号下线）：清本地登录态 + 系统通知提示。
  /// 由 NeteaseApi 在收到 301 时触发（单次）；重新登录后重新武装。
  void _handleAuthLost() {
    if (_disposed) return;
    _api.clearUserCookie();
    state = state.copyWith(
      status: AuthStatus.guest,
      clearProfile: true,
      clearLevel: true,
      clearVip: true,
      likedIds: const <int>{},
    );
    // 系统通知（与欢迎通知同通道，Android 13+ 权限启动时已申请）
    unawaited(PlatformActions.postStatusNotice(
      title: 'MingMusic',
      text: '登录已失效：当前设备可能已被移除，请重新登录',
    ));
  }

  Future<void> _restore() async {
    final String? saved =
        ref.read(sharedPreferencesProvider).getString(PrefsKeys.userCookie);
    if (saved == null || saved.isEmpty) {
      state = state.copyWith(status: AuthStatus.guest);
      return;
    }
    _api.restoreUserCookie(saved);
    NeteaseProfile? profile;
    bool checkFailed = false;
    try {
      profile = await _repo.loginStatus();
    } catch (e) {
      debugPrint('login/status 校验失败: $e');
      checkFailed = true;
    }
    if (_disposed) return;
    // 设备被移除/账号顶号下线：login/status 返回 301 已触发
    // _handleAuthLost（清 cookie + 提示），此处保持 guest 不再回填登录态
    if (!_api.hasUserCookie) return;
    if (profile != null) {
      state = state.copyWith(
        status: AuthStatus.loggedIn,
        profile: profile,
        clearStatusCheckFailed: true,
      );
      _cacheProfile(profile);
      unawaited(_loadExtras(profile.userId));
    } else if (checkFailed) {
      // 网络校验失败绝不清除 cookie（服务端偶发抖动/超时的根因）。
      // 需求：无网进入不丢弃登录态，只显示「当前无网络」——
      // 从本地资料缓存恢复已登录 UI，页面照常直显缓存的歌单/数据。
      final NeteaseProfile? cached = _cachedProfile();
      if (cached != null) {
        state = state.copyWith(
          status: AuthStatus.loggedIn,
          profile: cached,
          statusCheckFailed: true,
        );
      } else {
        state = state.copyWith(
          status: AuthStatus.unknown,
          statusCheckFailed: true,
        );
      }
    } else {
      // 服务端明确返回未登录 → cookie 确已失效
      _api.clearUserCookie();
      state = state.copyWith(status: AuthStatus.guest);
    }
  }

  /// 手动重试登录态校验（我的页「当前无网络」卡片点击）
  Future<void> recheckLogin() async {
    if (state.busy) return;
    state = state.copyWith(statusCheckFailed: false);
    await _restore();
  }

  /// 登录成功后的公共入口（对齐 Zephyr：完整 cookie 串持久化，
  /// 保留 __csrf_token 等字段供评论/点赞等写操作使用）
  Future<void> _onLoginSuccess(String cookie) async {
    _api.setUserCookie(cookie);
    NeteaseProfile? profile;
    try {
      profile = await _repo.loginStatus();
    } catch (e) {
      debugPrint('login/status 失败: $e');
    }
    if (_disposed) return;
    if (profile == null) {
      state = state.copyWith(
        status: AuthStatus.unknown,
        busy: false,
        statusCheckFailed: true,
        qrMessage: '登录成功但获取账号信息失败，请下拉重试',
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
      clearVip: true,
      listenSeconds: 0,
      likedIds: const <int>{},
      clearStatusCheckFailed: true,
    );
    _cacheProfile(profile);
    // 需求：每次登录成功后弹出系统通知「欢迎回来-用户名称」
    // （独立轻量通道，与媒体通知互不干扰；Android 13+ 权限在启动时申请）
    unawaited(PlatformActions.postStatusNotice(
      title: 'MingMusic',
      text: '欢迎回来-${profile.nickname}',
    ));
    unawaited(_loadExtras(profile.userId));
  }

  /// 便捷：读取本地资料缓存（离线恢复登录态）
  NeteaseProfile? _cachedProfile() {
    final String? raw =
        ref.read(sharedPreferencesProvider).getString(PrefsKeys.userProfileCache);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return NeteaseProfile.fromMap(decoded);
      if (decoded is Map) {
        return NeteaseProfile.fromMap(
          decoded.map<String, Object?>((k, v) => MapEntry(k.toString(), v)),
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 便捷：写入本地资料缓存（登录成功/校验成功时更新）
  void _cacheProfile(NeteaseProfile profile) {
    try {
      ref
          .read(sharedPreferencesProvider)
          .setString(PrefsKeys.userProfileCache, jsonEncode(profile.toMap()));
    } catch (_) {
      // 缓存失败不影响登录流程
    }
  }

  /// 加载等级 / VIP / 听歌时长 / 喜欢列表（失败静默，非关键数据）
  Future<void> _loadExtras(int uid) async {
    final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
      _repo.userLevel(),
      _repo.listenDataTotal(),
      _repo.likeList(uid),
      _repo.vipInfo(),
    ]);
    if (_disposed) return;
    state = state.copyWith(
      level: results[0] as NeteaseLevel?,
      listenSeconds: (results[1] as int?) ?? 0,
      likedIds: Set<int>.of((results[2] as List<int>?) ?? const <int>[]),
      vip: results[3] as NeteaseVipInfo?,
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
              // 对齐 Zephyr：保留完整 cookie 串（含 __csrf_token 等）
              await _onLoginSuccess(cookie);
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
        // 完整 cookie 串透传（与二维码登录一致）
        await _onLoginSuccess(cookie);
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
    // 我的页歌单缓存随登出一并清除（需求修复：未登录且有缓存只应
    // 出现在「离线 + 曾登录」场景 —— 登出后不得再直显旧账号歌单）
    try {
      await ref
          .read(sharedPreferencesProvider)
          .remove(PrefsKeys.libraryUserPlaylistsCache);
      await ref.read(sharedPreferencesProvider).remove(PrefsKeys.lastUserId);
      await ref
          .read(sharedPreferencesProvider)
          .remove(PrefsKeys.userProfileCache);
    } catch (_) {
      // 清理失败不影响登出流程
    }
    state = state.copyWith(
      status: AuthStatus.guest,
      clearProfile: true,
      clearLevel: true,
      clearVip: true,
      listenSeconds: 0,
      likedIds: const <int>{},
      busy: false,
      qrStatus: QrStatus.idle,
      qrMessage: '',
      clearQrImage: true,
      clearStatusCheckFailed: true,
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

  /// 刷新喜欢列表（切歌时节流触发，保障播放页红心点亮）。
  /// 点赞进行中或未登录时跳过；服务端拉取失败静默（保留本地状态）。
  Future<void> refreshLikeList() async {
    final int? uid = state.profile?.userId;
    if (uid == null || !state.loggedIn || _likeToggling) return;
    try {
      final List<int> ids = await _repo.likeList(uid);
      if (_disposed || _likeToggling) return;
      state = state.copyWith(likedIds: Set<int>.of(ids));
    } catch (_) {
      // 静默：保留本地喜欢状态
    }
  }

  /// 喜欢 / 取消喜欢（乐观更新 + 失败回滚）。返回错误文案（null 成功）
  Future<String?> toggleLikeSong(int neteaseId) async {
    if (!state.loggedIn) return '请先登录网易云音乐';
    _likeToggling = true;
    try {
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
    } finally {
      _likeToggling = false;
    }
  }
}
