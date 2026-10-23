/// 网易云评论 / 点赞 API（参考 Zephyr-Music api/netease/comment.ts）。
///
///  - /comment/new：新版评论（sortType 1=推荐 2=热度 3=时间，cursor 翻页）；
///  - POST /comment：发送(t=1)/回复(t=2)/删除(t=0)，os=android 绕风控；
///  - POST /comment/like：评论点赞（需登录）。
library;

import '../../../core/api/netease_api.dart';

/// 评论条目
class CommentItem {
  const CommentItem({
    required this.commentId,
    required this.content,
    required this.time,
    required this.likedCount,
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
    this.ipLocation = '',
    this.isVipUser = false,
  });

  final int commentId;
  final String content;

  /// 发表时间（毫秒时间戳）
  final int time;
  final int likedCount;
  final int userId;
  final String nickname;
  final String avatarUrl;
  final String ipLocation;

  /// 评论者为黑胶 VIP（昵称后金徽章，仿网易云）
  final bool isVipUser;

  static CommentItem fromMap(Map<String, Object?> c) {
    final Object? userRaw = c['user'];
    final Map<String, Object?> user =
        userRaw is Map<String, Object?> ? userRaw : const <String, Object?>{};
    final Object? ipRaw = c['ipLocation'];
    String ip = '';
    if (ipRaw is Map<String, Object?>) {
      ip = (ipRaw['location'] as String?) ?? '';
    } else if (ipRaw is String) {
      ip = ipRaw;
    }
    ip = ip.isEmpty
        ? ((user['locationInfo'] is Map<String, Object?>
                ? (user['locationInfo']! as Map<String, Object?>)['location']
                : null) as String?) ??
            ''
        : ip;
    // VIP 判定：vipRights.redVipLevel / associator.vipLevel > 0
    final Map<String, Object?>? vipRights =
        user['vipRights'] as Map<String, Object?>?;
    final int redVipLevel = safeIntOf(vipRights?['redVipLevel']) ?? 0;
    final int associatorLevel = safeIntOf(
            (vipRights?['associator'] as Map<String, Object?>?)?['vipLevel']) ??
        0;
    return CommentItem(
      commentId: safeIntOf(c['commentId']) ?? 0,
      content: (c['content'] as String?) ?? '',
      time: safeIntOf(c['time']) ?? 0,
      likedCount: safeIntOf(c['likedCount']) ?? 0,
      userId: safeIntOf(user['userId']) ?? 0,
      nickname: (user['nickname'] as String?) ?? '未知用户',
      avatarUrl: normalizeNeteaseUrl(user['avatarUrl'] as String?),
      ipLocation: ip,
      isVipUser: redVipLevel > 0 || associatorLevel > 0,
    );
  }
}

/// 安全整数解析：网易云部分接口会把数字字段返回为字符串
/// （如 totalCount: "4682"），直接 as num? 会抛 TypeError。
int? safeIntOf(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

/// 评论分页结果
class CommentPage {
  const CommentPage({
    required this.comments,
    required this.totalCount,
    required this.hasMore,
    this.cursor,
  });

  final List<CommentItem> comments;
  final int totalCount;
  final bool hasMore;
  final int? cursor;
}

class CommentsRepository {
  CommentsRepository(this._api);

  final NeteaseApi _api;

  /// 拉取评论（subjectType：0 歌曲 / 2 歌单 / 4 专辑 / 6 MV）
  Future<CommentPage> fetchComments(
    int songId, {
    int sortType = 1,
    int pageNo = 1,
    int pageSize = 20,
    int? cursor,
    String subjectType = '0',
  }) async {
    final Map<String, String> params = <String, String>{
      'id': '$songId',
      'type': subjectType,
      'sortType': '$sortType',
      'pageNo': '$pageNo',
      'pageSize': '$pageSize',
    };
    if (cursor != null && sortType == 3) params['cursor'] = '$cursor';
    final Map<String, Object?> res = await _api.get(
      '/comment/new',
      params,
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    final Object? list = payload['comments'];
    final List<CommentItem> comments = list is List<Object?>
        ? list
            .whereType<Map<String, Object?>>()
            .map(CommentItem.fromMap)
            .toList(growable: false)
        : const <CommentItem>[];
    return CommentPage(
      comments: comments,
      // totalCount 实测可能为 String（线上崩溃：type 'String' is not a subtype of type 'num?'）
      totalCount: safeIntOf(payload['totalCount']) ?? 0,
      hasMore: payload['hasMore'] == true || payload['hasMore'] == 'true',
      cursor: safeIntOf(payload['cursor']),
    );
  }

  /// 发送/回复/删除评论。返回 (code, message)
  Future<(int, String)> action({
    required int t,
    required int songId,
    String? content,
    int? commentId,
    String subjectType = '0',
  }) async {
    final Map<String, String> params = <String, String>{
      't': '$t',
      'type': subjectType,
      'id': '$songId',
      // 网易云评论接口风控：os=android 模拟移动端绕过「请切换至移动端」
      'os': 'android',
    };
    if (content != null && content.isNotEmpty) params['content'] = content;
    if (commentId != null) params['commentId'] = '$commentId';
    final Map<String, Object?> res =
        await _api.post('/comment', params, throwOnCode: false);
    final Map<String, Object?> payload = apiPayload(res);
    return (
      safeIntOf(payload['code']) ?? 0,
      (payload['message'] as String?) ?? (payload['msg'] as String?) ?? ''
    );
  }

  /// 评论点赞 / 取消点赞（需登录）。返回 (code, message)
  Future<(int, String)> like({
    required int songId,
    required int commentId,
    required bool like,
    String subjectType = '0',
  }) async {
    final Map<String, Object?> res = await _api.post(
      '/comment/like',
      <String, String>{
        'id': '$songId',
        'cid': '$commentId',
        't': like ? '1' : '0',
        'type': subjectType,
      },
      throwOnCode: false,
    );
    final Map<String, Object?> payload = apiPayload(res);
    return (
      safeIntOf(payload['code']) ?? 0,
      (payload['message'] as String?) ?? (payload['msg'] as String?) ?? ''
    );
  }
}
