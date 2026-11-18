// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../../widgets/campus_account_actions.dart';
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

  String _selectedNewsCategory = '全部';
  final List<String> _newsCategories = ['全部', '科研突破', '项目申报', '招募招生', '学术讲座'];

  bool _groupFollowedOnly = false;
  String _selectedGroupDepartment = '全部';

  // FDUROP Sub-tab state: 0: 开放科研项目, 1: 网站通知, 2: 常用文件下载
  int _fduropSubIndex = 0;
  String _selectedFduropProgram = '全部';
  String _selectedFduropDocCategory = '全部';

  List<ResearchNewsItem> _newsList = [];
  List<ResearchGroupItem> _groupList = [];
  List<ResearchLectureItem> _lectureList = [];
  List<FduropProjectItem> _fduropProjects = [];
  List<FduropNoticeItem> _fduropNotices = [];
  List<FduropDocumentItem> _fduropDocuments = [];

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _service.addListener(_onServiceChanged);
    _loadData();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    _tabController.dispose();
    _newsSearchCtrl.dispose();
    _groupSearchCtrl.dispose();
    _fduropSearchCtrl.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) {
      _loadData();
    }
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final news = await _service.getNews(
      category: _selectedNewsCategory,
      query: _newsSearchCtrl.text,
    );
    final groups = await _service.getGroups(
      followedOnly: _groupFollowedOnly,
      department: _selectedGroupDepartment,
      query: _groupSearchCtrl.text,
    );
    final lectures = await _service.getLectures();
    final fduropProjects = await _service.getFduropProjects(
      program: _selectedFduropProgram,
      query: _fduropSearchCtrl.text,
    );
    final fduropNotices = await _service.getFduropNotices(
      program: _selectedFduropProgram,
      query: _fduropSearchCtrl.text,
    );
    final fduropDocuments = await _service.getFduropDocuments(
      category: _selectedFduropDocCategory,
      query: _fduropSearchCtrl.text,
    );

    if (mounted) {
      setState(() {
        _newsList = news;
        _groupList = groups;
        _lectureList = lectures;
        _fduropProjects = fduropProjects;
        _fduropNotices = fduropNotices;
        _fduropDocuments = fduropDocuments;
        _loading = false;
      });
    }
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
            onPressed: _loadData,
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
      body:
          _loading &&
              _newsList.isEmpty &&
              _groupList.isEmpty &&
              _fduropProjects.isEmpty
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
      onRefresh: _loadData,
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
                        _loadData();
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
            onChanged: (_) => _loadData(),
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
                      _loadData();
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
      onRefresh: _loadData,
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
                        _loadData();
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
            onChanged: (_) => _loadData(),
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
                  _loadData();
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
                      _loadData();
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
  // TAB 3: 本科生科研 (FDUROP 望道/莙政/开放课题/文件下载)
  // -------------------------------------------------------------
  Widget _buildFduropTab(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // FDUROP Banner Card
          Card(
            color: colorScheme.primaryContainer.withAlpha(80),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: colorScheme.primary.withAlpha(80)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(
                    Icons.workspace_premium_outlined,
                    size: 32,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '复旦大学本科生学术研究资助计划（FDUROP）',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '包含望道学者、莙政学者、曦源项目与登峰计划，支持本科生进组开展高水平原创研究。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Sub-switcher Segmented Button
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(
                  value: 0,
                  label: Text('开放课题 (${_fduropProjects.length})'),
                  icon: const Icon(Icons.assignment_outlined),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('网站通知 (${_fduropNotices.length})'),
                  icon: const Icon(Icons.campaign_outlined),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text('文件下载 (${_fduropDocuments.length})'),
                  icon: const Icon(Icons.download_outlined),
                ),
              ],
              selected: {_fduropSubIndex},
              onSelectionChanged: (set) {
                setState(() => _fduropSubIndex = set.first);
              },
            ),
          ),
          const SizedBox(height: 14),

          // Dynamic Sub-view
          if (_fduropSubIndex == 0)
            _buildFduropProjectsSection(theme, colorScheme)
          else if (_fduropSubIndex == 1)
            _buildFduropNoticesSection(theme, colorScheme)
          else
            _buildFduropDocumentsSection(theme, colorScheme),
        ],
      ),
    );
  }

  // --- Sub-view 0: 开放科研项目 (Open Research Projects) ---
  Widget _buildFduropProjectsSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search & Program Filter
        TextField(
          controller: _fduropSearchCtrl,
          decoration: InputDecoration(
            hintText: '搜索开放课题、指导老师、院系...',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _fduropSearchCtrl.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _fduropSearchCtrl.clear();
                      _loadData();
                    },
                  )
                : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: (_) => _loadData(),
        ),
        const SizedBox(height: 10),

        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final prog in _service.availableFduropPrograms) ...[
                FilterChip(
                  label: Text(prog),
                  selected: _selectedFduropProgram == prog,
                  onSelected: (selected) {
                    setState(() {
                      _selectedFduropProgram = selected ? prog : '全部';
                    });
                    _loadData();
                  },
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        if (_fduropProjects.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 36),
              child: Text(
                '暂无匹配的开放科研课题',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.outline,
                ),
              ),
            ),
          )
        else
          for (final proj in _fduropProjects)
            _buildFduropProjectCard(proj, theme, colorScheme),
      ],
    );
  }

  Widget _buildFduropProjectCard(
    FduropProjectItem proj,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: proj.isBookmarked
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
              // Top tags row
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
                      proj.program,
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    proj.department,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
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
                      '名额 ${proj.quota} 人 · ${proj.status}',
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

              // Title
              Text(
                proj.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 6),

              // Mentor & Grade
              Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 14,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${proj.advisor} (${proj.advisorTitle})',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
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
              ),
              const SizedBox(height: 6),

              // Description preview
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

  // --- Sub-view 2: 相关文件下载 (Document Downloads) ---
  Widget _buildFduropDocumentsSection(
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final cat in _service.availableFduropDocCategories) ...[
                FilterChip(
                  label: Text(cat),
                  selected: _selectedFduropDocCategory == cat,
                  onSelected: (selected) {
                    setState(() {
                      _selectedFduropDocCategory = selected ? cat : '全部';
                    });
                    _loadData();
                  },
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),

        if (_fduropDocuments.isEmpty)
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
          for (final doc in _fduropDocuments)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: doc.fileFormat == 'PDF'
                      ? colorScheme.errorContainer
                      : colorScheme.primaryContainer,
                  child: Icon(
                    doc.fileFormat == 'PDF'
                        ? Icons.picture_as_pdf
                        : Icons.description,
                    color: doc.fileFormat == 'PDF'
                        ? colorScheme.error
                        : colorScheme.primary,
                    size: 20,
                  ),
                ),
                title: Text(
                  doc.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${doc.category} · ${doc.fileSize} · 更新于 ${doc.updateDate}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                trailing: IconButton(
                  tooltip: doc.isDownloaded ? '已下载' : '下载文件',
                  icon: Icon(
                    doc.isDownloaded
                        ? Icons.check_circle
                        : Icons.download_rounded,
                    color: doc.isDownloaded
                        ? colorScheme.primary
                        : colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () async {
                    await _service.downloadFduropDocument(doc.id);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            '已成功下载：${doc.title}（保存在 Download/旦生/FDUROP/）',
                          ),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
      ],
    );
  }

  // -------------------------------------------------------------
  // TAB 4: 学术讲座 (Lectures & Seminars)
  // -------------------------------------------------------------
  Widget _buildLecturesTab(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          for (final lec in _lectureList)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            lec.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                            ),
                          ),
                        ),
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
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
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
