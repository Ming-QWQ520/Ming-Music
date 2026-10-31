/// SharedPreferences 键名注册表（跨 feature 共享，集中管理防漂移）。
library;

class PrefsKeys {
  PrefsKeys._();

  static const String background = 'settings.background';
  static const String layout = 'settings.layout';
  static const String glassPref = 'settings.glassPref';
  static const String themeMode = 'settings.themeMode';
  static const String favorites = 'library.favorites';
  static const String customTracks = 'library.customTracks';
  static const String anonCookie = 'netease.anonCookie';
  static const String audioQuality = 'netease.audioQuality';
  static const String userCookie = 'netease.userCookie';
  static const String likedComments = 'netease.likedComments';
  static const String npSettings = 'np.settings';

  /// 播放队列持久化（Track 列表 JSON + index + queueTitle + 播放器模式）
  static const String queueState = 'player.queueState';

  /// 播放队列历史快照（最多 3 个，json 数组）
  static const String queueHistory = 'player.queueHistory';

  /// 歌曲本机播放次数统计（json：neteaseId → count）
  static const String playStats = 'player.playStats';

  /// 边听边缓存（默认开启；缓存文件仅在设置中清理）
  static const String listenCache = 'player.listenCache';

  /// 预加载下一首（默认开启）
  static const String preloadNext = 'player.preloadNext';

  /// LRU 缓存容量上限（字节；需求：默认 3GB，缓存音乐页可改）
  static const String cacheMaxBytes = 'player.cacheMaxBytes';

  /// 应用图片背景（需求：除播放页外的全局图片背景）
  static const String appBackground = 'settings.appBackground';

  /// 搜索历史（json 数组，最多 20 条；需求：搜索页显示历史记录）
  static const String searchHistory = 'search.history';

  /// 发现页「榜单精选」自定义勾选（json：ToplistConf.id 有序数组）
  static const String discoverToplists = 'discover.toplists';

  /// 我的页歌单排列方式（grid=宫格 / list=列表；需求：默认宫格）
  static const String libraryPlaylistLayout = 'library.playlistLayout';

  /// 本地音乐歌曲总数（第十五批需求：进入本地音乐页授权扫描后记录，
  /// 我的页「本地音乐」tile 副标题显示总数）
  static const String localMusicCount = 'library.localMusicCount';

  /// 「添加到歌单」记忆（第十六批需求：记录上次添加成功的歌单 id，
  /// 下次打开弹窗置顶展示；仅本地显示顺序，不改云端真实歌单排序）
  static const String addToPlaylistLast = 'library.addToPlaylistLast';

  /// 我的页歌单列表缓存（第十七批需求：重启后创建/收藏歌单立即显示，
  /// 不再必须手动刷新；json = NeteaseUserPlaylist.toMap 数组）
  static const String libraryUserPlaylistsCache = 'library.userPlaylistsCache';

  /// 最近一次登录的用户 id（离线缓存直显场景：profile 校验失败时
  /// 无法从 authProvider 取 uid，用它把缓存歌单拆分为创建/收藏两组；
  /// 登出时随歌单缓存一并清除）
  static const String lastUserId = 'library.lastUserId';

  /// 应用内更新：跳过此版本（不再提示的版本号 tag，如 v1.1.1）
  static const String updaterSkippedVersion = 'updater.skippedVersion';

  /// 用户资料缓存（需求：无网进入不丢弃登录态 —— /login/status 网络校验
  /// 失败时从这里恢复已登录 UI，页面仅显示「当前无网络」提示；随登出清除）
  static const String userProfileCache = 'auth.userProfileCache';

  /// 播放页自定义默认值重置标记（需求第二十一批：设置默认值版本一次性
  /// 从 v6 回退 v1 —— 首次启动时把存量设置的存储版本降回 v1 重跑全部
  /// 默认值迁移（淡出 40%/模糊上限 1.5px/居中/亮屏/封面歌词两行等），
  /// 仅执行一次，避免每次启动覆盖用户后续手动调整）
  static const String npDefaultsReset = 'np.defaultsReset';
}
