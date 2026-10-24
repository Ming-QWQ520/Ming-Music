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
}
