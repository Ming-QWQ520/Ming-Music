/// 网易云登录 / 用户信息 API（参考 Zephyr-Music api/netease/auth.ts + user.ts）。
///
/// 登录方式：
///  - 二维码：/login/qr/key → /login/qr/create → 轮询 /login/qr/check
///    （800=过期 801=等待扫码 802=待确认 803=授权成功返回 cookie）；
///  - 手机：POST /login/cellphone（密码或验证码，/captcha/sent 发送验证码）。
///
/// cookie 经 query 参数透传给 api-enhanced（服务端转发网易云）。
library;

import '../../../core/api/netease_api.dart';

/// VIP 信息（/vip/info/v2，对齐 Zephyr useNeteaseUser.loadVipAndListenData）
class NeteaseVipInfo {
  const NeteaseVipInfo({
    required this.isVip,
    this.redVipLevel = 0,
    this.expireText = '',
  });

  final bool isVip;

  /// 黑胶 VIP 等级（红心 POV 数）
  final int redVipLevel;
  final String expireText;

  static NeteaseVipInfo? fromMap(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final int associatorLevel =
        ((raw['associator'] as Map<String, Object?>?)?['vipLevel'] as num?)
                ?.toInt() ??
            0;
    final bool isVip = raw['isVip'] == true || associatorLevel > 0;
    if (!isVip) return null;
    final int redVipLevel =
        (raw['redVipLevel'] as num?)?.toInt() ?? 0;
    final Object? expire =
        (raw['associator'] as Map<String, Object?>?)?['expireTime'] ??
            (raw['musicPackage'] as Map<String, Object?>?)?['expireTime'];
    String expireText = '';
    if (expire is num && expire > 0) {
      final DateTime d = DateTime.fromMillisecondsSinceEpoch(expire.toInt());
      expireText =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    return NeteaseVipInfo(
        isVip: isVip, redVipLevel: redVipLevel, expireText: expireText);
  }
}

/// 二维码轮询状态
enum QrStatus { idle, loading, waiting, scanned, expired, success }

/// 用户公开资料（login/status → profile，对齐 Zephyr getCachedUser）
class NeteaseProfile {
  const NeteaseProfile({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
    this.signature = '',
    this.backgroundUrl = '',
    this.vipType = 0,
  });

  final int userId;
  final String nickname;
  final String avatarUrl;
  final String signature;
  final String backgroundUrl;

  /// vipType > 0 为 VIP
  final int vipType;

  bool get isVip => vipType > 0;

  static NeteaseProfile? fromMap(Object? raw, {Object? account}) {
    if (raw is! Map<String, Object?>) return null;
    // userId 兜底 account.id（对齐 Zephyr：p.userId || res.account?.id）
    int userId = (raw['userId'] as num?)?.toInt() ?? 0;
    if (userId == 0 && account is Map<String, Object?>) {
      userId = (account['id'] as num?)?.toInt() ?? 0;
    }
    if (userId == 0) return null;
    return NeteaseProfile(
      userId: userId,
      nickname: (raw['nickname'] as String?)?.isNotEmpty == true
          ? raw['nickname']! as String
          : '网易云用户',
      avatarUrl: normalizeNeteaseUrl(raw['avatarUrl'] as String?),
      signature: (raw['signature'] as String?) ?? '',
      backgroundUrl:
          normalizeNeteaseUrl(raw['backgroundUrl'] as String?),
      vipType: (raw['vipType'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 用户等级（/user/level）
class NeteaseLevel {
  const NeteaseLevel({required this.level, required this.progress});

  final int level;

  /// 升级进度百分比 0-100（服务端返回 0-1 小数时自动 ×100）
  final int progress;

  static NeteaseLevel? fromMap(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final int? level = (raw['level'] as num?)?.toInt();
    if (level == null) return null;
    final double p = (raw['progress'] as num?)?.toDouble() ?? 0;
    // 对齐 Zephyr：progress 为 0~1 小数需 ×100；部分版本直接返回 0~100
    final int percent = p > 0 && p <= 1 ? (p * 100).round() : p.round();
    return NeteaseLevel(level: level, progress: percent.clamp(0, 100));
  }
}

/// 歌单元信息（/user/playlist 列表项）
class NeteaseUserPlaylist {
  const NeteaseUserPlaylist({
    required this.id,
    required this.name,
    required this.coverUrl,
    required this.trackCount,
    this.creatorUserId = 0,
    this.playCount = 0,
    this.description = '',
  });

  final int id;
  final String name;
  final String coverUrl;
  final int trackCount;

  /// 创建者用户 id（区分「我创建的」/「我收藏的」）
  final int creatorUserId;
  final int playCount;
  final String description;

  static NeteaseUserPlaylist fromMap(Map<String, Object?> j) {
    return NeteaseUserPlaylist(
      id: (j['id'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? '',
      coverUrl: normalizeNeteaseUrl(
        (j['coverImgUrl'] as String?) ?? (j['picUrl'] as String?),
      ),
      trackCount: (j['trackCount'] as num?)?.toInt() ?? 0,
      creatorUserId: (j['userId'] as num?)?.toInt() ?? 0,
      playCount: (j['playCount'] as num?)?.toInt() ?? 0,
      description: (j['description'] as String?) ?? '',
    );
  }
}

class NeteaseAuthRepository {
  NeteaseAuthRepository(this._api);

  final NeteaseApi _api;

  // ------------------------------------------------------------- QR login

  /// 生成二维码 key
  Future<String> qrKey() async {
    final Map<String, Object?> res = await _api.get(
      '/login/qr/key',
      const <String, String>{},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final Object? data = payload['unikey'] ?? res['unikey'];
    if (data is String && data.isNotEmpty) return data;
    throw ApiException('二维码 key 获取失败');
  }

  /// 生成二维码 base64 PNG（data:image/png;base64,...）
  Future<String> qrCreate(String key) async {
    final Map<String, Object?> res = await _api.get(
      '/login/qr/create',
      <String, String>{'key': key, 'qrimg': 'true'},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final String? qrimg = (payload['qrimg'] ?? res['qrimg']) as String?;
    if (qrimg == null || qrimg.isEmpty) throw ApiException('二维码生成失败');
    return qrimg;
  }

  /// 轮询扫码状态。返回 (code, message, cookie)。
  Future<(int, String, String?)> qrCheck(String key) async {
    final Map<String, Object?> res = await _api.get(
      '/login/qr/check',
      <String, String>{'key': key},
      throwOnCode: false,
    );
    final int code = (res['code'] as num?)?.toInt() ?? 0;
    final String message = (res['message'] as String?) ?? '';
    // 803 时 cookie 在顶层（qr/check 无 data 包裹）
    final String? cookie = res['cookie'] as String?;
    return (code, message, cookie);
  }

  // -------------------------------------------------------- cellphone login

  /// 手机 + 密码/验证码登录。返回 (code, message, cookie)
  Future<(int, String, String?)> loginCellphone({
    required String phone,
    String? password,
    String? countrycode,
    String? captcha,
  }) async {
    final Map<String, String> params = <String, String>{'phone': phone};
    if (password != null && password.isNotEmpty) {
      params['password'] = password;
    }
    if (countrycode != null && countrycode.isNotEmpty) {
      params['countrycode'] = countrycode;
    }
    if (captcha != null && captcha.isNotEmpty) params['captcha'] = captcha;
    final Map<String, Object?> res = await _api.post(
      '/login/cellphone',
      params,
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final int code = (payload['code'] as num?)?.toInt() ?? 0;
    final String message =
        (payload['message'] as String?) ?? (payload['msg'] as String?) ?? '';
    final String? cookie = (payload['cookie'] ?? res['cookie']) as String?;
    return (code, message, cookie);
  }

  /// 发送验证码
  Future<void> captchaSent(String phone, {String? countrycode}) async {
    final Map<String, String> params = <String, String>{'phone': phone};
    if (countrycode != null && countrycode.isNotEmpty) {
      params['ctcode'] = countrycode;
    }
    await _api.get('/captcha/sent', params, throwOnCode: false);
  }

  // ------------------------------------------------------------ account info

  /// 当前登录状态（未登录时 profile 为 null）
  Future<NeteaseProfile?> loginStatus() async {
    final Map<String, Object?> res = await _api.get(
      '/login/status',
      const <String, String>{},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    return NeteaseProfile.fromMap(
      payload['profile'],
      account: payload['account'],
    );
  }

  /// 退出登录（服务端注销 + 清除本地 cookie 由 provider 负责）
  Future<void> logout() async {
    try {
      await _api.get('/logout', const <String, String>{}, throwOnCode: false);
    } catch (_) {
      // 服务端注销失败不阻塞本地登出
    }
  }

  /// 用户等级
  Future<NeteaseLevel?> userLevel() async {
    final Map<String, Object?> res = await _api.get(
      '/user/level',
      const <String, String>{},
      throwOnCode: false,
    );
    return NeteaseLevel.fromMap(apiPayload(res));
  }

  /// VIP 信息（/vip/info/v2）
  Future<NeteaseVipInfo?> vipInfo() async {
    final Map<String, Object?> res = await _api.get(
      '/vip/info/v2',
      const <String, String>{},
      throwOnCode: false,
    );
    return NeteaseVipInfo.fromMap(apiPayload(res)['data'] ?? apiPayload(res));
  }

  /// 累计听歌时长（秒）
  Future<int> listenDataTotal() async {
    final Map<String, Object?> res = await _api.get(
      '/listen/data/total',
      const <String, String>{},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final Object? data = payload['data'];
    int seconds = 0;
    if (data is Map<String, Object?>) {
      seconds = (data['totalDuration'] as num?)?.toInt() ?? 0;
    } else {
      seconds = (payload['totalDuration'] as num?)?.toInt() ?? 0;
    }
    return seconds;
  }

  /// 用户歌单（第一个通常是「我喜欢的音乐」）
  Future<List<NeteaseUserPlaylist>> userPlaylists(int uid) async {
    final Map<String, Object?> res = await _api.get(
      '/user/playlist',
      <String, String>{'uid': '$uid', 'limit': '50', 'offset': '0'},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final Object? list = payload['playlist'];
    if (list is! List<Object?>) return const <NeteaseUserPlaylist>[];
    return list
        .whereType<Map<String, Object?>>()
        .map(NeteaseUserPlaylist.fromMap)
        .where((NeteaseUserPlaylist p) => p.id != 0)
        .toList(growable: false);
  }

  // --------------------------------------------------------------- likes

  /// 喜欢歌曲 ID 列表
  Future<List<int>> likeList(int uid) async {
    final Map<String, Object?> res = await _api.get(
      '/likelist',
      <String, String>{'uid': '$uid'},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final Object? ids = payload['ids'];
    if (ids is! List<Object?>) return const <int>[];
    return ids
        .whereType<num>()
        .map((num e) => e.toInt())
        .toList(growable: false);
  }

  /// 喜欢 / 取消喜欢歌曲（需登录）
  Future<bool> likeSong(int id, {required bool like}) async {
    final Map<String, Object?> res = await _api.get(
      '/like',
      <String, String>{'id': '$id', 'like': like ? 'true' : 'false'},
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    return (payload['code'] ?? res['code']) == 200;
  }
}
