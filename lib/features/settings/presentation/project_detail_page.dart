/// 项目详情页（第十五批需求，对齐 kgka_Music_hl 关于页的版式）：
///
///  - **全部数据实时请求 GitHub API，无任何硬编码文案/数字**：
///    · GET /repos/{owner}/{repo}            → 名称/简介/Star/Fork/Watch/
///      Open Issues/主语言/开源协议/创建与推送时间/默认分支；
///    · GET /repos/{owner}/{repo}/releases/latest → 最新版本号/发布时间/发布说明；
///    · GET /repos/{owner}/{repo}/contributors    → 贡献者头像与提交数；
///  - 第十六批修复：项目详情打不开（GitHub API 404/网络不可达）——
///    · 直连失败自动改走 gh-proxy.com 镜像（`https://gh-proxy.com/<原URL>`），
///      覆盖 api.github.com 与 avatars.githubusercontent.com；
///    · 三个端点独立加载：仓库信息失败才报错；最新发布无 release 时
///      返回 404 属正常情况，不再拖垮整页；贡献者同理；
///  - 版式对齐 kgka：应用 Logo + 名称/版本头部 → 信息分组行（_InfoRow
///    同构：label 左 value 右）→ 统计宫格 → 贡献者头像列表 → 最新版本
///    可折叠卡片（Markdown 纯文本呈现 release body）；
///  - 仓库 slug 来自 AppConstants.repoUrl 解析（仓库唯一身份，其余全为
///    API 返回值）；加载失败给出重试卡；点击 GitHub 行跳转浏览器。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/utils/platform_actions.dart';

/// 从 repoUrl 解析 owner/repo（AppConstants 单一来源，不另写死）
(String, String) _parseRepoSlug() {
  final Uri u = Uri.parse(AppConstants.repoUrl);
  final List<String> seg =
      u.path.split('/').where((String s) => s.isNotEmpty).toList();
  if (seg.length >= 2) return (seg[0], seg[1]);
  return ('Ming-QWQ520', 'Ming-Music');
}

class GithubProjectPage extends StatefulWidget {
  const GithubProjectPage({super.key});

  @override
  State<GithubProjectPage> createState() => _GithubProjectPageState();
}

class _GithubProjectPageState extends State<GithubProjectPage> {
  static final (String, String) _slug = _parseRepoSlug();

  Map<String, Object?>? _repo;
  Map<String, Object?>? _release;
  List<Map<String, Object?>> _contributors = <Map<String, Object?>>[];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // 第十六批修复：三端点独立加载 —— /releases/latest 在仓库无任何
    // release 时返回 404（此前 Future.wait 全部失败，整页报
    // 「GitHub API 404」）；仓库信息为必要数据，其余失败静默降级。
    final Object? repo = await _getJson(
        'https://api.github.com/repos/${_slug.$1}/${_slug.$2}');
    final Object? release = await _getJson(
        'https://api.github.com/repos/${_slug.$1}/${_slug.$2}/releases/latest',
        optional: true);
    final Object? contributors = await _getJson(
        'https://api.github.com/repos/${_slug.$1}/${_slug.$2}/contributors?per_page=30',
        optional: true);
    if (!mounted) return;
    if (repo is! Map<String, Object?>) {
      setState(() {
        _error = repo is String ? repo : '仓库数据不可用';
        _loading = false;
      });
      return;
    }
    setState(() {
      _repo = repo;
      _release = release is Map<String, Object?> ? release : null;
      _contributors = contributors is List
          ? contributors
              .whereType<Map<String, Object?>>()
              .toList(growable: false)
          : const <Map<String, Object?>>[];
      _loading = false;
    });
  }

  /// GitHub API GET（自带 UA；无 token 匿名限额 60 次/时足够本页使用）。
  ///
  /// 第十六批：直连失败自动改走 gh-proxy.com 镜像；[optional] 为 true
  /// 时失败返回 null（不抛错），为 false 时返回错误描述字符串。
  static Future<Object?> _getJson(String url, {bool optional = false}) async {
    // 先直连，失败换镜像
    for (final String candidate in <String>[url, 'https://gh-proxy.com/$url']) {
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..userAgent = 'MingMusic-App';
      try {
        final HttpClientRequest req = await client.getUrl(Uri.parse(candidate));
        req.headers.set('Accept', 'application/vnd.github+json');
        final HttpClientResponse resp = await req.close().timeout(
              const Duration(seconds: 20),
            );
        if (resp.statusCode != 200) {
          // 404 等状态：直连与镜像结果一致，属数据本身缺失；镜像成功
          // 返回 200 则取镜像数据（直连被劫持/拦截的常见形态）
          if (resp.statusCode == 404 && identical(candidate, url)) {
            // 直连 404 仍尝试镜像（部分网络劫持会把 200 改写成 404）
            continue;
          }
          final Object? fail =
              optional ? null : 'GitHub API ${resp.statusCode}';
          return fail;
        }
        final String body = await utf8.decodeStream(resp);
        return jsonDecode(body);
      } catch (e) {
        if (identical(candidate, url)) {
          continue; // 直连异常 → 换镜像重试
        }
        return optional ? null : 'GitHub 请求失败：$e';
      } finally {
        client.close();
      }
    }
    return optional ? null : 'GitHub API 不可达';
  }

  static String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '未知';
    final DateTime? t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }

  static String _fmtCount(num? n) {
    if (n == null) return '0';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('项目详情')),
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.6),
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Icon(Icons.cloud_off_rounded,
                          size: 44, color: Colors.white24),
                      const SizedBox(height: 12),
                      Text('无法获取 GitHub 数据\n$_error',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.6,
                              color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 14),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final Map<String, Object?> repo = _repo!;
    final Map<String, Object?> owner =
        (repo['owner'] as Map<String, Object?>?) ?? const <String, Object?>{};
    final Map<String, Object?>? license =
        repo['license'] as Map<String, Object?>?;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        // ---- 头部：Logo + 名称 + 简介（kgka _AppLogo 同构）----
        Center(
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: theme.colorScheme.primary.withValues(alpha: 0.22),
                  blurRadius: 22,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: '${owner['avatar_url']}'.startsWith('http')
                  ? _GhImage(url: '${owner['avatar_url']}')
                  : _logoFallback(theme),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            '${repo['name'] ?? AppConstants.appName}',
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(height: 5),
        Center(
          child: Text(
            'v${AppConstants.appVersion}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if ((repo['description'] ?? '').toString().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                '${repo['description']}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.55,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),

        // ---- 统计宫格（全部来自 API）----
        Row(
          children: <Widget>[
            _StatCard(
                icon: Icons.star_rounded,
                label: 'Stars',
                value: _fmtCount(repo['stargazers_count'] as num?)),
            const SizedBox(width: 10),
            _StatCard(
                icon: Icons.call_split_rounded,
                label: 'Forks',
                value: _fmtCount(repo['forks_count'] as num?)),
            const SizedBox(width: 10),
            _StatCard(
                icon: Icons.bug_report_rounded,
                label: 'Issues',
                value: _fmtCount(repo['open_issues_count'] as num?)),
            const SizedBox(width: 10),
            _StatCard(
                icon: Icons.visibility_rounded,
                label: 'Watch',
                value: _fmtCount(repo['subscribers_count'] as num?)),
          ],
        ),
        const SizedBox(height: 16),

        // ---- 信息分组行（kgka _InfoSection/_InfoRow 同构）----
        _InfoSection(children: <Widget>[
          _InfoRow(label: '作者', value: '${owner['login'] ?? '未知'}'),
          _InfoRow(label: '主语言', value: '${repo['language'] ?? '未知'}'),
          _InfoRow(label: '开源协议', value: '${license?['spdx_id'] ?? '未声明'}'),
          _InfoRow(label: '默认分支', value: '${repo['default_branch'] ?? 'main'}'),
          _InfoRow(
              label: '创建时间', value: _fmtDate(repo['created_at'] as String?)),
          _InfoRow(
              label: '最近推送', value: _fmtDate(repo['pushed_at'] as String?)),
          if (_release != null && '$_release' != 'null')
            _InfoRow(
              label: '最新发布',
              value:
                  '${_release!['tag_name'] ?? '未知'} · ${_fmtDate(_release!['published_at'] as String?)}',
            ),
          _InfoLinkRow(
            label: 'GitHub 仓库',
            value: '${_slug.$1}/${_slug.$2}',
            onTap: () =>
                _openRepo('${repo['html_url'] ?? AppConstants.repoUrl}'),
          ),
        ]),

        // ---- 贡献者（API 列表）----
        if (_contributors.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          _SectionHeader(
              icon: Icons.groups_rounded, text: '贡献者（${_contributors.length}）'),
          const SizedBox(height: 8),
          _InfoSection(
            children: <Widget>[
              for (int i = 0; i < _contributors.length; i++)
                _ContributorRow(
                  login: '${_contributors[i]['login'] ?? '未知'}',
                  avatar: '${_contributors[i]['avatar_url'] ?? ''}',
                  commits:
                      (_contributors[i]['contributions'] as num?)?.toInt() ?? 0,
                ),
            ],
          ),
        ],

        // ---- 最新发布说明（可折叠卡片，kgka _VersionCard 同构）----
        if (_release != null &&
            (_release!['body'] ?? '').toString().trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          _SectionHeader(icon: Icons.history_rounded, text: '更新日志'),
          const SizedBox(height: 8),
          _ReleaseCard(
            tag: '${_release!['tag_name'] ?? ''}',
            date: _fmtDate(_release!['published_at'] as String?),
            body: '${_release!['body']}',
          ),
        ],
        const SizedBox(height: 12),
        Center(
          child: Text(
            '数据实时来自 GitHub API，下拉无刷新 · 点击仓库行可跳转浏览器',
            style: TextStyle(
                fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _logoFallback(ThemeData theme) => Container(
        color: theme.colorScheme.primaryContainer,
        child: Icon(Icons.music_note_rounded,
            size: 46, color: theme.colorScheme.primary),
      );

  /// 打开仓库（async gap 后仅用 State.context，并先判 State.mounted）
  Future<void> _openRepo(String url) async {
    final bool ok = await PlatformActions.openUrl(url);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法打开浏览器')));
    }
  }
}

/// GitHub 图片（第十六批）：直连失败自动改走 gh-proxy.com 镜像重试，
/// 再失败回退图标 —— avatars.githubusercontent.com 在部分网络下不可达
class _GhImage extends StatefulWidget {
  const _GhImage({required this.url, this.fallback});

  final String url;

  /// 两级加载都失败后的占位（不传则为中性人像图标）
  final Widget? fallback;

  @override
  State<_GhImage> createState() => _GhImageState();
}

class _GhImageState extends State<_GhImage> {
  /// 0 = 直连；1 = gh-proxy 镜像；2 = 全部失败
  int _stage = 0;

  @override
  void didUpdateWidget(_GhImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _stage = 0; // 换了数据源（重载后）重新直连
    }
  }

  void _advance() {
    if (!mounted) return;
    setState(() => _stage = _stage + 1);
  }

  @override
  Widget build(BuildContext context) {
    if (_stage >= 2 || !widget.url.startsWith('http')) {
      return widget.fallback ??
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Icon(Icons.person_rounded),
          );
    }
    final String src =
        _stage == 0 ? widget.url : 'https://gh-proxy.com/${widget.url}';
    return Image.network(
      src,
      fit: BoxFit.cover,
      // errorBuilder 在构建期回调：不能直接 setState，改用微任务
      // 推进到下一级（镜像 → 失败占位）触发重建
      errorBuilder: (_, __, ___) {
        scheduleMicrotask(_advance);
        return const SizedBox.expand();
      },
    );
  }
}

// ---------------------------------------------------------------- 子组件

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: <Widget>[
            Icon(icon, size: 19, color: theme.colorScheme.primary),
            const SizedBox(height: 5),
            Text(value,
                style: const TextStyle(
                    fontSize: 15.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 1),
            Text(label,
                style: TextStyle(
                    fontSize: 10.5, color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Icon(icon, size: 19, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
      ],
    );
  }
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(children: children),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLinkRow extends StatelessWidget {
  const _InfoLinkRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: <Widget>[
            Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.primary),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.open_in_new_rounded,
                size: 16, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _ContributorRow extends StatelessWidget {
  const _ContributorRow({
    required this.login,
    required this.avatar,
    required this.commits,
  });

  final String login;
  final String avatar;
  final int commits;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          // 第十六批：头像直连失败自动换 gh-proxy 镜像加载
          ClipOval(
            child: SizedBox(
              width: 30,
              height: 30,
              child: _GhImage(
                url: avatar,
                fallback: ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.person_rounded, size: 16),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(login,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
          Text('$commits 次提交',
              style: TextStyle(
                  fontSize: 11.5, color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 最新版本发布说明卡片（可折叠；正文为 GitHub release body 原文）
class _ReleaseCard extends StatefulWidget {
  const _ReleaseCard({
    required this.tag,
    required this.date,
    required this.body,
  });

  final String tag;
  final String date;
  final String body;

  @override
  State<_ReleaseCard> createState() => _ReleaseCardState();
}

class _ReleaseCardState extends State<_ReleaseCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.4),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.tag,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(widget.date,
                        style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.onSurfaceVariant)),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.0 : -0.25,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(Icons.expand_more_rounded,
                          size: 20, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
                AnimatedCrossFade(
                  firstChild: const SizedBox(width: double.infinity),
                  // GitHub release body 原文直接呈现（不引第三方 markdown
                  // 库，保留换行与项目符号，changelog 可读性足够）
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      widget.body,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  crossFadeState: _expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 220),
                  sizeCurve: Curves.easeOutCubic,
                ),
                if (!_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '点击展开发布说明',
                      style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant),
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
