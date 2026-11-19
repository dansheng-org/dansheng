// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dansheng_state.dart';
import '../../widgets/campus_account_actions.dart';
import '../campus_api.dart';
import 'fdurop_notice_detail_sheet.dart';
import 'fdurop_project_detail_sheet.dart';
import 'research_group_detail_sheet.dart';
import 'research_models.dart';
import 'research_news_detail_sheet.dart';
import 'research_service.dart';

/// Top-level Campus Research / 科研 Page.
/// Features:
/// 1. 科研动态 (Fudan research breakthroughs, NSFC project calls, recruitment notices)
/// 2. 课题组 (Labs & Research groups, with follow/unfollow and detailed profiles)
/// 3. 本科生科研 (FDUROP 望道/莙政/曦源/登峰 网站通知、开放科研项目、相关文件下载)
/// 4. 学术讲座 (Upcoming academic seminars and symposiums)
class ResearchPage extends StatefulWidget {
  final DanshengController controller;

  const ResearchPage({super.key, required this.controller});

  @override
  State<ResearchPage> createState() => _ResearchPageState();
}

class _ResearchPageState extends State<ResearchPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final ResearchService _service = ResearchService.instance;

  // Search and filter states
  final TextEditingController _newsSearchCtrl = TextEditingController();
  final TextEditingController _groupSearchCtrl = TextEditingController();
  final TextEditingController _fduropSearchCtrl = TextEditingController();
  final TextEditingController _lectureSearchCtrl = TextEditingController();

  String _selectedNewsCategory = '全部';
  final List<String> _newsCategories = ['全部', '科研突破', '项目申报', '招募招生', '学术讲座'];

  bool _groupFollowedOnly = false;
  String _selectedGroupDepartment = '全部';

  // Academic Lectures filter states
  String _selectedLectureCategory = '全部';
  bool _lectureBookmarkedOnly = false;

  // FDUROP Sub-tab state: 0: 开放课题, 1: 网站通知, 2: 文件下载
  int _fduropSubIndex = 0;
  String _selectedFduropSubject = '全部';
  String _selectedFduropTopicLabel = '全部';
  String _selectedFduropDocCategory = '全部';
  List<String> _fduropSubjectOptions = const ['全部'];
  List<String> _fduropLabelOptions = const ['全部'];

  List<ResearchNewsItem> _newsList = [];
  List<ResearchGroupItem> _groupList = [];
  List<ResearchLectureItem> _lectureList = [];
  List<FduropNoticeItem> _fduropNotices = [];
  bool _localReady = false;

  // Official FDUROP files from jwc.fudan.edu.cn, loaded when first shown.
  List<FduropDocumentItem>? _fduropDocuments;
  bool _fduropDocsLoading = false;
  String? _fduropDocsError;
  final Set<String> _fduropDocBusy = {};

  // FDUROP open topics, paged from paper.fudan.edu.cn or the offline seed.
  final List<FduropProjectItem> _fduropProjects = [];
  final Set<String> _fduropProjectIds = {};
  int _fduropTotal = 0;
  int _fduropPage = 0;
  bool _fduropHasMore = false;
  bool _fduropLoading = false;
  bool _fduropIsLive = false;
  String? _fduropLiveError;
  String? _fduropPageError;
  int _fduropGeneration = 0;
  Timer? _fduropSearchDebounce;

  static const _portalUrl =
      'https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index';

  @override
  void initState() {
    super.initState();
    _service.bindApi(CampusApi.forAccount(widget.controller));
    _tabController = TabController(length: 4, vsync: this);
    _service.addListener(_onServiceChanged);
    _fduropDocuments = _service.cachedFduropDocuments;
    _loadLocal();
    _loadFduropFilterOptions();
    _reloadFduropProjects();
  }

  @override
  void dispose() {
    _fduropSearchDebounce?.cancel();
    _service.removeListener(_onServiceChanged);
    _tabController.dispose();
    _newsSearchCtrl.dispose();
    _groupSearchCtrl.dispose();
    _fduropSearchCtrl.dispose();
    _lectureSearchCtrl.dispose();
    super.dispose();
  }

  /// Follow / bookmark / download toggles only change local state, so the
  /// in-memory lists are recomputed and no network request is made.
  void _onServiceChanged() {
    if (mounted) _loadLocal();
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _loadLocal(),
      _reloadFduropProjects(),
      if (_fduropDocuments != null || _fduropSubIndex == 2)
        _loadFduropDocuments(refresh: true),
    ]);
  }

  /// The official FDUROP files; signing in to jwc is handled by the host.
  Future<void> _loadFduropDocuments({bool refresh = false}) async {
    if (_fduropDocsLoading) return;
    setState(() {
      _fduropDocsLoading = true;
      _fduropDocsError = null;
    });
    try {
      final docs = await _service.fetchFduropDocuments(refresh: refresh);
      if (!mounted) return;
      setState(() => _fduropDocuments = docs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _fduropDocsError = campusError(e));
    } finally {
      if (mounted) setState(() => _fduropDocsLoading = false);
    }
  }

  Future<void> _runFduropDocument(
    FduropDocumentItem doc, {
    required bool save,
  }) async {
    if (!_fduropDocBusy.add(doc.id)) return;
    setState(() {});
    try {
      if (save) {
        await _service.saveFduropDocument(doc);
      } else {
        await _service.openFduropDocument(doc);
      }
      if (save && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已保存：${doc.fileName}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(e))));
      }
    } finally {
      if (mounted) setState(() => _fduropDocBusy.remove(doc.id));
    }
  }

  /// Recompute the bundled (in-memory) lists from the current filters.
  Future<void> _loadLocal() async {
    final news = await _service.getNews(
      category: _selectedNewsCategory,
      query: _newsSearchCtrl.text,
    );
    final groups = await _service.getGroups(
      followedOnly: _groupFollowedOnly,
      department: _selectedGroupDepartment,
      query: _groupSearchCtrl.text,
    );
    final lectures = await _service.getLectures(
      query: _lectureSearchCtrl.text,
      category: _selectedLectureCategory,
      bookmarkedOnly: _lectureBookmarkedOnly,
    );
    final notices = await _service.getFduropNotices();
    if (!mounted) return;
    setState(() {
      _newsList = news;
      _groupList = groups;
      _lectureList = lectures;
      _fduropNotices = notices;
      _localReady = true;
    });
  }

  Future<void> _loadFduropFilterOptions() async {
    final results = await Future.wait([
      _service.fduropSubjectKindOptions(),
      _service.fduropTopicLabelOptions(),
    ]);
    if (!mounted) return;
    setState(() {
      _fduropSubjectOptions = results[0];
      _fduropLabelOptions = results[1];
      if (!_fduropSubjectOptions.contains(_selectedFduropSubject)) {
        _selectedFduropSubject = '全部';
      }
      if (!_fduropLabelOptions.contains(_selectedFduropTopicLabel)) {
        _selectedFduropTopicLabel = '全部';
      }
    });
  }

  void _onFduropSearchChanged(String _) {
    setState(() {}); // Toggle the clear button.
    _fduropSearchDebounce?.cancel();
    _fduropSearchDebounce = Timer(
      const Duration(milliseconds: 400),
      _reloadFduropProjects,
    );
  }

  /// Restart the open-topic list from page 1 with the current filters.
  Future<void> _reloadFduropProjects() {
    _fduropSearchDebounce?.cancel();
    _fduropGeneration++;
    setState(() {
      _fduropProjects.clear();
      _fduropProjectIds.clear();
      _fduropPage = 0;
      _fduropTotal = 0;
      _fduropHasMore = true;
      _fduropLoading = false;
      _fduropPageError = null;
    });
    return _loadMoreFduropProjects();
  }

  /// Append the next page. Responses for an outdated query are dropped.
  Future<void> _loadMoreFduropProjects() async {
    if (_fduropLoading || !_fduropHasMore) return;
    final generation = _fduropGeneration;
    final nextPage = _fduropPage + 1;
    setState(() {
      _fduropLoading = true;
      _fduropPageError = null;
    });
    try {
      final page = await _service.fetchFduropProjectPage(
        page: nextPage,
        query: _fduropSearchCtrl.text,
        subjectKind: _selectedFduropSubject,
        topicLabel: _selectedFduropTopicLabel,
      );
      if (!mounted || generation != _fduropGeneration) return;
      // Page 2+ must come from the same source as page 1.
      if (nextPage > 1 && page.isLive != _fduropIsLive) {
        setState(() {
          _fduropLoading = false;
          _fduropPageError = page.liveError ?? '数据来源已变化，请下拉刷新';
        });
        return;
      }
      setState(() {
        for (final item in page.items) {
          if (_fduropProjectIds.add(item.id)) _fduropProjects.add(item);
        }
        _fduropPage = nextPage;
        _fduropTotal = page.total;
        _fduropHasMore = page.hasMore;
        _fduropIsLive = page.isLive;
        if (nextPage == 1) _fduropLiveError = page.liveError;
        _fduropLoading = false;
      });
    } catch (e) {
      if (!mounted || generation != _fduropGeneration) return;
      setState(() {
        _fduropLoading = false;
        _fduropPageError = campusError(e);
      });
    }
  }

  bool _onFduropScroll(ScrollNotification notification) {
    if (_fduropSubIndex == 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification.metrics.extentAfter < 600) {
      _loadMoreFduropProjects();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final followedCount = _service.followedGroupIds.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('科研'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAll,
          ),
          CampusAccountActions(controller: widget.controller),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            const Tab(text: '科研动态'),
            Tab(text: followedCount > 0 ? '课题组 ($followedCount)' : '课题组'),
            const Tab(text: '本科生科研 (FDUROP)'),
            const Tab(text: '学术讲座'),
          ],
        ),
      ),
      body: !_localReady
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildNewsTab(theme, colorScheme),
                _buildGroupsTab(theme, colorScheme),
                _buildFduropTab(theme, colorScheme),
                _buildLecturesTab(theme, colorScheme),
              ],
            ),
    );
  }

  // -------------------------------------------------------------
  // TAB 1: 科研动态 (Research News)
  // -------------------------------------------------------------
  Widget _buildNewsTab(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadLocal,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Search input
          TextField(
            controller: _newsSearchCtrl,
            decoration: InputDecoration(
              hintText: '搜索科研消息、突破进展、基金申报...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _newsSearchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _newsSearchCtrl.clear();
                        _loadLocal();
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (_) => _loadLocal(),
          ),
          const SizedBox(height: 10),

          // Category filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final cat in _newsCategories) ...[
                  FilterChip(
                    label: Text(cat),
                    selected: _selectedNewsCategory == cat,
                    onSelected: (selected) {
                      setState(() {
                        _selectedNewsCategory = selected ? cat : '全部';
                      });
                      _loadLocal();
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // News list or empty
          if (_newsList.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Column(
                  children: [
                    Icon(
                      Icons.feed_outlined,
                      size: 48,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '暂无匹配的科研消息',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            for (final news in _newsList)
              _buildNewsCard(news, theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildNewsCard(
    ResearchNewsItem news,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      elevation: news.isPinned ? 2 : 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: news.isPinned
              ? colorScheme.primary.withAlpha(160)
              : colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: () => showResearchNewsDetailSheet(context, news),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top tags row
              Row(
                children: [
                  if (news.isPinned) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '置顶',
                        style: TextStyle(
                          color: colorScheme.onPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      news.category,
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      news.source,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    news.publishDate,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Title
              Text(
                news.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),

              // Summary
              Text(
                news.summary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),

              // Footer row
              Row(
                children: [
                  Text(
                    news.department,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.visibility_outlined,
                    size: 14,
                    color: colorScheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${news.readCount}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.outline,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: colorScheme.outline,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 2: 课题组 (Research Groups / Labs)
  // -------------------------------------------------------------
  Widget _buildGroupsTab(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadLocal,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Search input
          TextField(
            controller: _groupSearchCtrl,
            decoration: InputDecoration(
              hintText: '搜索课题组名称、导师姓名、研究方向...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _groupSearchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _groupSearchCtrl.clear();
                        _loadLocal();
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (_) => _loadLocal(),
          ),
          const SizedBox(height: 10),

          // Filter row: [全部 vs 已关注] and Department dropdown
          Row(
            children: [
              FilterChip(
                avatar: Icon(
                  _groupFollowedOnly ? Icons.star : Icons.star_border,
                  size: 16,
                ),
                label: const Text('已关注课题组'),
                selected: _groupFollowedOnly,
                onSelected: (val) {
                  setState(() => _groupFollowedOnly = val);
                  _loadLocal();
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedGroupDepartment,
                  isExpanded: true,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  items: [
                    for (final dept in _service.availableDepartments)
                      DropdownMenuItem(
                        value: dept,
                        child: Text(
                          dept == '全部' ? '全部院系' : dept,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                  onChanged: (dept) {
                    if (dept != null) {
                      setState(() => _selectedGroupDepartment = dept);
                      _loadLocal();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Group list
          if (_groupList.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Column(
                  children: [
                    Icon(
                      Icons.science_outlined,
                      size: 48,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _groupFollowedOnly
                          ? '暂未关注任何课题组，可在全部列表中点击「关注」'
                          : '暂无匹配的课题组',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            for (final group in _groupList)
              _buildGroupCard(group, theme, colorScheme),
        ],
      ),
    );
  }

  Widget _buildGroupCard(
    ResearchGroupItem group,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: group.isFollowed
              ? colorScheme.primary.withAlpha(120)
              : colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: () => showResearchGroupDetailSheet(context, group),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Group Name & Follow toggle button
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${group.leader} · ${group.leaderTitle}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      _service.toggleFollowGroup(group.id);
                    },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          group.isFollowed ? Icons.check : Icons.add,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(group.isFollowed ? '已关注' : '关注'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Badges: Department & Campus
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      group.department,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      group.campus,
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (group.websiteUrl.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.tertiaryContainer.withAlpha(140),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.language,
                            size: 11,
                            color: colorScheme.onTertiaryContainer,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '官网',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (group.recruitment != null) ...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '招生招募中',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),

              // Direction chips
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final dir in group.researchDirections.take(3))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer.withAlpha(100),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        dir,
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  if (group.researchDirections.length > 3)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text(
                        '+${group.researchDirections.length - 3}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------
  // TAB 3: 本科生科研 (FDUROP 开放课题/网站通知/文件下载)
  // -------------------------------------------------------------
  Widget _buildFduropTab(ThemeData theme, ColorScheme colorScheme) {
    const pad = EdgeInsets.symmetric(horizontal: 16);
    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onFduropScroll,
        child: CustomScrollView(
          key: const Key('fdurop-scroll'),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildFduropPortalCard(theme, colorScheme),
                    const SizedBox(height: 14),
                    SegmentedButton<int>(
                      segments: [
                        ButtonSegment(
                          value: 0,
                          label: Text('开放课题 ($_fduropTotal)'),
                          icon: const Icon(Icons.assignment_outlined),
                        ),
                        ButtonSegment(
                          value: 1,
                          label: Text('网站通知 (${_fduropNotices.length})'),
                          icon: const Icon(Icons.campaign_outlined),
                        ),
                        ButtonSegment(
                          value: 2,
                          label: Text(
                            _fduropDocuments == null
                                ? '文件下载'
                                : '文件下载 (${_fduropDocuments!.length})',
                          ),
                          icon: const Icon(Icons.download_outlined),
                        ),
                      ],
                      selected: {_fduropSubIndex},
                      onSelectionChanged: (set) {
                        setState(() => _fduropSubIndex = set.first);
                        if (set.first == 2 &&
                            _fduropDocuments == null &&
                            _fduropDocsError == null) {
                          _loadFduropDocuments();
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ),
            if (_fduropSubIndex == 0) ...[
              SliverPadding(
                padding: pad,
                sliver: SliverToBoxAdapter(
                  child: _buildFduropProjectFilters(theme, colorScheme),
                ),
              ),
              SliverPadding(
                padding: pad,
                sliver: SliverList.builder(
                  itemCount: _fduropProjects.length,
                  itemBuilder: (context, i) => _buildFduropProjectCard(
                    _fduropProjects[i],
                    theme,
                    colorScheme,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverToBoxAdapter(
                  child: _buildFduropProjectFooter(theme, colorScheme),
                ),
              ),
            ] else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverToBoxAdapter(
                  child: _fduropSubIndex == 1
                      ? _buildFduropNoticesSection(theme, colorScheme)
                      : _buildFduropDocumentsSection(theme, colorScheme),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One header for the programme and the open-topic system it links to.
  Widget _buildFduropPortalCard(ThemeData theme, ColorScheme colorScheme) {
    return Card(
      color: colorScheme.primaryContainer.withAlpha(80),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.primary.withAlpha(80)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.workspace_premium_outlined,
              size: 28,
              color: colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'FDUROP 教师开放课题系统',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '复旦大学本科生学术研究资助计划 · 望道/莙政/曦源/登峰\npaper.fudan.edu.cn/fdurop-pc',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: _portalUrl));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制 FDUROP 教师开放课题系统网址，可在浏览器中打开'),
                    duration: Duration(seconds: 3),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制网址'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFduropProjectFilters(ThemeData theme, ColorScheme colorScheme) {
    final query = _fduropSearchCtrl.text.trim();
    final String status;
    if (_fduropPage == 0 && _fduropLoading) {
      status = '正在查询开放课题…';
    } else if (_fduropIsLive) {
      final approx = query.isNotEmpty ? '约 ' : '';
      status =
          '实时数据 · 共 $approx$_fduropTotal 项 · 已加载 ${_fduropProjects.length} 项';
    } else {
      status =
          '离线示例数据 · 共 $_fduropTotal 项'
          '${_fduropLiveError == null ? '' : '（实时查询失败：$_fduropLiveError）'}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _fduropSearchCtrl,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索课题名称、导师姓名或工号...',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _fduropSearchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _fduropSearchCtrl.clear();
                      _reloadFduropProjects();
                    },
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: _onFduropSearchChanged,
          onSubmitted: (_) => _reloadFduropProjects(),
        ),
        const SizedBox(height: 10),
        _buildFduropChipRow(
          label: '学科门类',
          color: colorScheme.primary,
          background: colorScheme.primaryContainer.withAlpha(100),
          options: _fduropSubjectOptions,
          selected: _selectedFduropSubject,
          onSelected: (value) {
            setState(() => _selectedFduropSubject = value);
            _reloadFduropProjects();
          },
        ),
        const SizedBox(height: 8),
        _buildFduropChipRow(
          label: '课题标签',
          color: colorScheme.tertiary,
          background: colorScheme.tertiaryContainer.withAlpha(100),
          options: _fduropLabelOptions,
          selected: _selectedFduropTopicLabel,
          onSelected: (value) {
            setState(() => _selectedFduropTopicLabel = value);
            _reloadFduropProjects();
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(
              _fduropIsLive ? Icons.cloud_done_outlined : Icons.cloud_off,
              size: 16,
              color: _fduropIsLive ? colorScheme.primary : colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                status,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildFduropChipRow({
    required String label,
    required Color color,
    required Color background,
    required List<String> options,
    required String selected,
    required ValueChanged<String> onSelected,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          for (final option in options) ...[
            FilterChip(
              label: Text(option),
              selected: selected == option,
              onSelected: (on) => onSelected(on ? option : '全部'),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildFduropProjectFooter(ThemeData theme, ColorScheme colorScheme) {
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: colorScheme.outline,
    );
    final Widget child;
    if (_fduropLoading) {
      child = const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_fduropPageError != null) {
      child = Column(
        children: [
          Text('加载失败：$_fduropPageError', style: muted),
          TextButton(
            onPressed: _loadMoreFduropProjects,
            child: const Text('重试'),
          ),
        ],
      );
    } else if (_fduropProjects.isEmpty) {
      child = Text('暂无匹配的开放科研课题', style: muted);
    } else if (_fduropHasMore) {
      child = TextButton(
        onPressed: _loadMoreFduropProjects,
        child: const Text('加载更多'),
      );
    } else {
      child = Text(
        '已显示全部 ${_fduropProjects.length} 项',
        style: theme.textTheme.labelMedium?.copyWith(
          color: colorScheme.outline,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(child: child),
    );
  }

  Widget _buildFduropProjectCard(
    FduropProjectItem proj,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final bookmarked = _service.isFduropProjectBookmarked(proj.id);
    // Live rows derive `program` from their labels; show it only when it adds something.
    final showProgram =
        proj.program.isNotEmpty &&
        !proj.topicLabels.contains(proj.program) &&
        proj.program != proj.topicLabels.join(' / ') &&
        proj.program != proj.subjectKinds.join(' / ');
    final tags = {
      if (showProgram) proj.program,
      ...proj.subjectKinds,
      ...proj.topicLabels,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: bookmarked
              ? colorScheme.primary.withAlpha(140)
              : colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        onTap: () => showFduropProjectDetailSheet(context, proj),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (bookmarked) ...[
                    Icon(Icons.bookmark, size: 14, color: colorScheme.primary),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      proj.department,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      proj.quota > 0
                          ? '名额 ${proj.quota} 人 · ${proj.status}'
                          : proj.status,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                proj.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${proj.advisor} (${proj.advisorTitle})',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.primary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (proj.deadline.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.event_outlined,
                      size: 14,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '截止 ${proj.deadline}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
              if (proj.description.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  proj.description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final tag in tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: proj.subjectKinds.contains(tag)
                              ? colorScheme.tertiaryContainer.withAlpha(120)
                              : colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          tag,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: proj.subjectKinds.contains(tag)
                                ? colorScheme.onTertiaryContainer
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --- Sub-view 1: 网站通知 (FDUROP Notices) ---
  Widget _buildFduropNoticesSection(ThemeData theme, ColorScheme colorScheme) {
    if (_fduropNotices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 36),
          child: Text(
            '暂无FDUROP网站通知',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.outline,
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final notice in _fduropNotices)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.outlineVariant),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => showFduropNoticeDetailSheet(context, notice),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            notice.program,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onTertiaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            notice.source,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          notice.publishDate,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      notice.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      notice.summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  // --- Sub-view 2: 相关文件下载 (official forms on jwc.fudan.edu.cn) ---
  Widget _buildFduropDocumentsSection(
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final docs = _fduropDocuments;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final source = Text(
      '来源：教务处 · 常用文档 · 复芏计划（FDUROP）相关表格（需登录校园账号）',
      style: muted,
    );
    if (docs == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          source,
          const SizedBox(height: 32),
          if (_fduropDocsLoading)
            const Center(child: CircularProgressIndicator())
          else ...[
            Text(
              _fduropDocsError ?? '尚未加载文件列表',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _loadFduropDocuments(refresh: true),
                  child: const Text('重试'),
                ),
                OutlinedButton(
                  onPressed: _openFduropDocumentPage,
                  child: const Text('打开原网页'),
                ),
              ],
            ),
          ],
        ],
      );
    }
    final categories = [
      '全部',
      for (final c in FduropDocumentItem.categories)
        if (docs.any((d) => d.category == c)) c,
    ];
    final shown = [
      for (final d in docs)
        if (_selectedFduropDocCategory == '全部' ||
            d.category == _selectedFduropDocCategory)
          d,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        source,
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final cat in categories) ...[
                FilterChip(
                  label: Text(cat),
                  selected: _selectedFduropDocCategory == cat,
                  onSelected: (selected) => setState(
                    () => _selectedFduropDocCategory = selected ? cat : '全部',
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 36),
              child: Text(
                '暂无可下载文件',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.outline,
                ),
              ),
            ),
          )
        else
          for (final doc in shown)
            _buildFduropDocumentTile(doc, theme, colorScheme),
      ],
    );
  }

  Widget _buildFduropDocumentTile(
    FduropDocumentItem doc,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final busy = _fduropDocBusy.contains(doc.id);
    final cached = _service.isFduropDocumentDownloaded(doc.id);
    final (icon, tint) = switch (doc.fileFormat) {
      'PDF' => (Icons.picture_as_pdf, colorScheme.error),
      'XLS' || 'XLSX' => (Icons.table_chart_outlined, colorScheme.tertiary),
      'PPT' || 'PPTX' => (Icons.slideshow_outlined, colorScheme.secondary),
      _ => (Icons.description_outlined, colorScheme.primary),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: ListTile(
        onTap: busy ? null : () => _runFduropDocument(doc, save: false),
        leading: Icon(icon, color: tint),
        title: Text(
          doc.title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          [
            doc.category,
            if (doc.fileFormat.isNotEmpty) doc.fileFormat,
            if (cached) '已下载',
          ].join(' · '),
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: cached ? '打开文件' : '下载并打开',
                    icon: Icon(
                      cached ? Icons.open_in_new : Icons.download_rounded,
                    ),
                    onPressed: () => _runFduropDocument(doc, save: false),
                  ),
                  IconButton(
                    tooltip: '保存到手机',
                    icon: const Icon(Icons.save_alt),
                    onPressed: () => _runFduropDocument(doc, save: true),
                  ),
                ],
              ),
      ),
    );
  }

  Future<void> _openFduropDocumentPage() async {
    try {
      await CampusApi.forAccount(widget.controller).call('campus.openNotice', {
        'url': ResearchService.fduropDocumentPages.first,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(e))));
      }
    }
  }

  // -------------------------------------------------------------
  // TAB 4: 学术讲座 (Lectures & Seminars)
  // -------------------------------------------------------------
  Widget _buildLecturesTab(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadLocal,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // Search input
          TextField(
            controller: _lectureSearchCtrl,
            decoration: InputDecoration(
              hintText: '搜索讲座主题、主讲学者、报告地点或主办方...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _lectureSearchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _lectureSearchCtrl.clear();
                        _loadLocal();
                      },
                    )
                  : null,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (_) => _loadLocal(),
          ),
          const SizedBox(height: 10),

          // Filters: [已标想去] + Category Chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                FilterChip(
                  avatar: Icon(
                    _lectureBookmarkedOnly
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                    size: 16,
                  ),
                  label: const Text('已标想去'),
                  selected: _lectureBookmarkedOnly,
                  onSelected: (val) {
                    setState(() => _lectureBookmarkedOnly = val);
                    _loadLocal();
                  },
                ),
                const SizedBox(width: 8),
                for (final cat in _service.availableLectureCategories) ...[
                  FilterChip(
                    label: Text(cat),
                    selected: _selectedLectureCategory == cat,
                    onSelected: (selected) {
                      setState(() {
                        _selectedLectureCategory = selected ? cat : '全部';
                      });
                      _loadLocal();
                    },
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),

          if (_lectureList.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Column(
                  children: [
                    Icon(
                      Icons.event_busy_outlined,
                      size: 48,
                      color: colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _lectureBookmarkedOnly ? '暂未标记想去的讲座' : '暂无匹配的学术讲座与学术报告',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            for (final lec in _lectureList)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: lec.isBookmarked
                        ? colorScheme.primary.withAlpha(120)
                        : colorScheme.outlineVariant,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header Row: Category Badge & Bookmark
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              lec.category,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              lec.campus,
                              style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: lec.isBookmarked ? '取消想去' : '标记想去',
                            icon: Icon(
                              lec.isBookmarked
                                  ? Icons.bookmark
                                  : Icons.bookmark_border,
                              color: lec.isBookmarked
                                  ? colorScheme.primary
                                  : colorScheme.outline,
                            ),
                            onPressed: () {
                              _service.toggleBookmarkLecture(lec.id);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      Text(
                        lec.title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 8),

                      Row(
                        children: [
                          Icon(
                            Icons.person_outline,
                            size: 16,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${lec.speaker} (${lec.speakerTitle})',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      Row(
                        children: [
                          Icon(
                            Icons.schedule_outlined,
                            size: 16,
                            color: colorScheme.outline,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            lec.time,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),

                      Row(
                        children: [
                          Icon(
                            Icons.place_outlined,
                            size: 16,
                            color: colorScheme.outline,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              lec.venue,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),

                      Row(
                        children: [
                          Icon(
                            Icons.account_balance_outlined,
                            size: 16,
                            color: colorScheme.outline,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '主办：${lec.organizer}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest.withAlpha(
                            100,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          lec.description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
