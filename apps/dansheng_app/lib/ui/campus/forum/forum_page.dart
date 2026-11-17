// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_editor_dialog.dart';
import 'forum_filter_settings.dart';
import 'forum_mention_support.dart';
import 'forum_messages_page.dart';
import 'forum_models.dart';
import 'forum_pagination.dart';
import 'forum_search_page.dart';
import 'forum_service.dart';
import 'hole_card.dart';
import 'hole_detail_page.dart';

/// Main Forum tab/page providing DanXi-style OpenTreeHole campus community experience.
class ForumPage extends StatefulWidget {
  final DanshengController controller;
  final bool autoLoadOnScroll;

  const ForumPage({
    super.key,
    required this.controller,
    this.autoLoadOnScroll = true,
  });

  @override
  State<ForumPage> createState() => _ForumPageState();
}

class _ForumPageState extends State<ForumPage> {
  late final ForumService _service;

  List<TeaDivision> _divisions = [];
  int? _selectedDivisionId; // null = 全站 (all divisions)
  ForumSortOrder _sortOrder = ForumSortOrder.lastReplied;

  List<TeaHole> _holes = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _isLoggingIn = false;
  bool _hasMore = true;
  bool _showFavoritesOnly = false;
  String? _errorMessage;
  bool _authRequired = false;
  String? _activeTagFilter;
  final ScrollController _scrollController = ScrollController();

  static const int _pageSize = forumPageSize;

  @override
  void initState() {
    super.initState();
    _service = ForumService(CampusApi(widget.controller.client));
    _scrollController.addListener(_onScroll);
    _activeTagFilter = ForumPreferences.instance.selectedTagFilter;
    ForumPreferences.instance.addListener(_onPrefsChanged);
    _loadInitialData();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    ForumPreferences.instance.removeListener(_onPrefsChanged);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.autoLoadOnScroll || !_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (currentScroll > 0 && currentScroll >= maxScroll - 300) {
      if (!_isLoadingMore && _hasMore && !_isLoading && !_showFavoritesOnly) {
        _loadMoreHoles();
      }
    }
  }

  void _onPrefsChanged() {
    if (!mounted) return;
    final newTag = ForumPreferences.instance.selectedTagFilter;
    if (newTag != _activeTagFilter) {
      _activeTagFilter = newTag;
      _refreshHoles(showLoading: true);
    } else {
      setState(() {});
    }
  }

  /// Initial load: fetch divisions, then fetch holes.
  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _authRequired = false;
    });

    try {
      // 1. Load divisions
      final divisions = await _fetchDivisions();

      // 2. Load holes
      final holes = await _service.fetchHoles(
        divisionId: _selectedDivisionId,
        before: null,
        tag: _showFavoritesOnly ? null : _activeTagFilter,
        pageSize: _pageSize,
        order: _sortOrder,
      );

      if (mounted) {
        setState(() {
          if (divisions.isNotEmpty) _divisions = divisions;
          _holes = holes;
          _hasMore = holes.length >= _pageSize;
          _isLoading = false;
          _authRequired = false;
        });
        ForumFloorCache.instance.putHoles(holes);
        ForumFloorCache.instance.putHoles(_pinnedHoles);
        for (final h in holes) {
          ForumPreferences.instance.cacheFavoriteHole(h);
        }
      }
    } catch (e) {
      if (mounted) {
        final errText = campusError(e);
        setState(() {
          _isLoading = false;
          _errorMessage = errText;
          _authRequired =
              e.toString().contains('AuthenticationRequired') ||
              errText.contains('登录');
        });
      }
    }
  }

  /// The division list. A sign-in demand is passed on; any other failure
  /// falls back to the copy the host cached from the last successful read, so
  /// the division buttons do not vanish with one bad request.
  Future<List<TeaDivision>> _fetchDivisions() async {
    try {
      return await _service.fetchDivisions();
    } catch (e) {
      final code = e.toString();
      if (code.contains('ForumConsentRequired') ||
          code.contains('AuthenticationRequired') ||
          code.contains('AccountRequired')) {
        _authRequired = true;
        rethrow;
      }
      try {
        return await _service.fetchDivisions(cached: true);
      } catch (_) {
        return const [];
      }
    }
  }

  /// Refresh from the toolbar: the holes, and the divisions if they are missing.
  Future<void> _reload() async {
    if (_divisions.isEmpty) return _loadInitialData();
    return _refreshHoles(showLoading: true);
  }

  void _toggleFavorites() {
    setState(() => _showFavoritesOnly = !_showFavoritesOnly);
    if (_showFavoritesOnly) {
      _loadFavorites();
    } else {
      _refreshHoles(showLoading: true);
    }
  }

  /// Favourites live on the forum account, as in DanXi, so they are the same
  /// on every device. Offline, the copy stored on this device is shown.
  Future<void> _loadFavorites() async {
    final prefs = ForumPreferences.instance;
    try {
      final holes = await _service.fetchFavorites();
      if (!mounted || !_showFavoritesOnly) return;
      prefs.replaceFavorites(holes);
      return;
    } catch (e) {
      if (!mounted || !_showFavoritesOnly) return;
      final code = e.toString();
      if (code.contains('ForumConsentRequired') ||
          code.contains('AuthenticationRequired')) {
        setState(() => _authRequired = true);
        return;
      }
    }
    // A hole whose content is not stored yet is read once so it can be listed.
    for (final id in prefs.missingFavoriteIds) {
      try {
        final hole = await _service.fetchHole(id);
        if (hole != null) prefs.cacheFavoriteHole(hole);
      } catch (_) {
        // Left for the next visit; the rest of the list still shows.
      }
      if (!mounted || !_showFavoritesOnly) return;
    }
  }

  /// Refresh holes only (for division or sort change).
  Future<void> _refreshHoles({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final holes = await _service.fetchHoles(
        divisionId: _selectedDivisionId,
        before: null,
        tag: _showFavoritesOnly ? null : _activeTagFilter,
        pageSize: _pageSize,
        order: _sortOrder,
      );

      if (mounted) {
        setState(() {
          _holes = holes;
          _hasMore = holes.length >= _pageSize;
          _isLoading = false;
          _errorMessage = null;
          _authRequired = false;
        });
        ForumFloorCache.instance.putHoles(holes);
        ForumFloorCache.instance.putHoles(_pinnedHoles);
        for (final h in holes) {
          ForumPreferences.instance.cacheFavoriteHole(h);
        }
      }
    } catch (e) {
      if (mounted) {
        final errText = campusError(e);
        setState(() {
          _isLoading = false;
          _errorMessage = errText;
          _authRequired =
              e.toString().contains('AuthenticationRequired') ||
              errText.contains('登录');
        });
      }
    }
  }

  /// Load next page bounded by the last hole's timestamp cursor.
  Future<void> _loadMoreHoles() async {
    if (_isLoadingMore || !_hasMore || _holes.isEmpty) return;
    setState(() => _isLoadingMore = true);

    try {
      // Determine before timestamp cursor based on sort order
      final lastHole = _holes.last;
      final cursorTimeStr = _sortOrder == ForumSortOrder.lastCreated
          ? lastHole.timeCreated
          : (lastHole.timeUpdated ?? lastHole.timeCreated);
      final beforeDt = cursorTimeStr != null
          ? DateTime.tryParse(cursorTimeStr)
          : null;

      final nextHoles = await _service.fetchHoles(
        divisionId: _selectedDivisionId,
        before: beforeDt,
        tag: _showFavoritesOnly ? null : _activeTagFilter,
        pageSize: _pageSize,
        order: _sortOrder,
      );

      if (mounted) {
        setState(() {
          // Filter duplicates by holeId
          final existingIds = _holes.map((h) => h.holeId).toSet();
          final newItems = nextHoles
              .where((h) => !existingIds.contains(h.holeId))
              .toList();

          _holes.addAll(newItems);
          _hasMore = nextHoles.length >= _pageSize && newItems.isNotEmpty;
          _isLoadingMore = false;
        });
        ForumFloorCache.instance.putHoles(nextHoles);
        for (final h in nextHoles) {
          ForumPreferences.instance.cacheFavoriteHole(h);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载更多失败：${campusError(e)}')));
      }
    }
  }

  /// Trigger forum login flow via campus.login.
  Future<void> _handleLogin({bool replace = false}) async {
    if (_isLoggingIn) return;
    setState(() => _isLoggingIn = true);
    try {
      await _service.login(replace: replace);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已连接树洞账号')));
        await _loadInitialData();
      }
    } catch (e) {
      if (mounted && !e.toString().contains('Cancelled')) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('登录失败：${campusError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  /// Open publish dialog.
  Future<void> _openPublishDialog() async {
    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ForumPublishDialog(
        divisions: _divisions,
        initialDivisionId: _selectedDivisionId,
        onPublish: _service.publish,
        onReconcile: _service.reconcile,
      ),
    );

    if (result == 'reload_required' || result != null) {
      await _refreshHoles(showLoading: true);
      if (result != 'reload_required' && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('发布成功')));
      }
    }
  }

  /// Find division name by ID.
  String? _getDivisionName(int divisionId) {
    for (final d in _divisions) {
      if (d.divisionId == divisionId) return d.name;
    }
    return null;
  }

  /// Get pinned holes for the current division (never shown in 全站 or favorites mode).
  List<TeaHole> get _pinnedHoles {
    if (_showFavoritesOnly) return const [];
    if (_selectedDivisionId != null && _selectedDivisionId! > 0) {
      final div = _divisions.firstWhere(
        (d) => d.divisionId == _selectedDivisionId,
        orElse: () => TeaDivision(divisionId: _selectedDivisionId!, name: ''),
      );
      return div.pinned;
    } else {
      // 官方置顶的帖子不显示在全站而是只会显示在各个分区的置顶
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_showFavoritesOnly ? '我的收藏' : '复旦树洞'),
        leading: IconButton(
          tooltip: '消息通知',
          icon: const Icon(Icons.notifications_none_rounded),
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (ctx) =>
                    ForumMessagesPage(controller: widget.controller),
              ),
            );
          },
        ),
        // DanXi keeps three actions here: sort order, favourites and the rest.
        actions: [
          PopupMenuButton<ForumSortOrder>(
            tooltip: '排序：${_sortOrder.label}',
            icon: const Icon(Icons.sort_rounded),
            initialValue: _sortOrder,
            enabled: !_showFavoritesOnly,
            onSelected: (order) {
              if (order == _sortOrder) return;
              setState(() => _sortOrder = order);
              _refreshHoles(showLoading: true);
            },
            itemBuilder: (context) => [
              for (final order in ForumSortOrder.values)
                PopupMenuItem(value: order, child: Text(order.label)),
            ],
          ),
          IconButton(
            icon: Icon(
              _showFavoritesOnly
                  ? Icons.star_rounded
                  : Icons.star_outline_rounded,
              color: _showFavoritesOnly ? Colors.amber : null,
            ),
            tooltip: _showFavoritesOnly ? '查看全站帖子' : '收藏的帖子',
            onPressed: _toggleFavorites,
          ),
          PopupMenuButton<VoidCallback>(
            tooltip: '更多',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _reload,
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh_rounded),
                  title: Text('刷新'),
                ),
              ),
              PopupMenuItem(
                value: () => ForumFilterDialog.show(this.context),
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.tune_rounded),
                  title: Text('过滤与偏好设置'),
                ),
              ),
              PopupMenuItem(
                enabled: !_isLoggingIn,
                // Already signed in: this is how another account is entered.
                value: () => _handleLogin(replace: !_authRequired),
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.account_circle_outlined),
                  title: Text(_authRequired ? '登录树洞账号' : '切换树洞账号'),
                ),
              ),
            ],
          ),
        ],
        bottom: _showFavoritesOnly
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _buildDivisionFilterBar(),
              ),
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openPublishDialog,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('发帖'),
      ),
    );
  }

  /// Division selector chips bar (全站 + all divisions).
  Widget _buildDivisionFilterBar() {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: colorScheme.outlineVariant.withAlpha(80)),
        ),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // "全站" chip
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: ChoiceChip(
              label: const Text('全站'),
              selected: _selectedDivisionId == null,
              onSelected: (selected) {
                if (selected && _selectedDivisionId != null) {
                  setState(() => _selectedDivisionId = null);
                  _refreshHoles(showLoading: true);
                }
              },
            ),
          ),
          // Division chips
          ..._divisions.map((div) {
            final isSelected = _selectedDivisionId == div.divisionId;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: ChoiceChip(
                label: Text(div.name),
                selected: isSelected,
                onSelected: (selected) {
                  if (selected && _selectedDivisionId != div.divisionId) {
                    setState(() => _selectedDivisionId = div.divisionId);
                    _refreshHoles(showLoading: true);
                  }
                },
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading && _holes.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_authRequired) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 48,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 12),
              const Text(
                '需要登录论坛服务',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                _errorMessage ?? '登录后即可浏览树洞、参与讨论与匿名互动。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _isLoggingIn ? null : () => _handleLogin(),
                icon: const Icon(Icons.login_rounded),
                label: Text(_isLoggingIn ? '正在登录…' : '登录论坛'),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null && _holes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadInitialData,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final prefs = ForumPreferences.instance;

    // Favorited posts mode
    if (_showFavoritesOnly) {
      final favHoles = prefs.favoriteHolesList;
      if (favHoles.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.star_outline_rounded,
                  size: 56,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                const Text(
                  '暂无收藏的帖子',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '在任意帖子详情右上角点击五角星即可收藏',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _toggleFavorites,
                  icon: const Icon(Icons.arrow_back_rounded),
                  label: const Text('返回全站帖子'),
                ),
              ],
            ),
          ),
        );
      }

      return ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount: 1 + favHoles.length,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
                  const SizedBox(width: 6),
                  Text(
                    '我的收藏 (${favHoles.length})',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _toggleFavorites,
                    child: const Text('退出收藏'),
                  ),
                ],
              ),
            );
          }
          final h = favHoles[index - 1];
          return TeaHoleCard(
            hole: h,
            divisionName: _getDivisionName(h.divisionId),
            isPinned: false,
            onTap: () => _openHoleDetail(h),
            onTapTag: (tag) => prefs.setTagFilter(tag),
          );
        },
      );
    }

    final pinned = _pinnedHoles.where((h) => !prefs.shouldHideHole(h)).toList();
    final pinnedIds = _pinnedHoles.map((h) => h.holeId).toSet();
    final nonPinnedHoles = _holes
        .where((h) => !pinnedIds.contains(h.holeId) && !prefs.shouldHideHole(h))
        .toList();

    return RefreshIndicator(
      onRefresh: () => _divisions.isEmpty
          ? _loadInitialData()
          : _refreshHoles(showLoading: false),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount:
            1 + pinned.length + nonPinnedHoles.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          // Search field and active tag filter
          if (index == 0) {
            return _buildListHeader(pinned.length + nonPinnedHoles.length);
          }

          var cursor = index - 1;

          // Pinned holes
          if (cursor < pinned.length) {
            final ph = pinned[cursor];
            return TeaHoleCard(
              hole: ph,
              divisionName: _getDivisionName(ph.divisionId),
              isPinned: true,
              onTap: () => _openHoleDetail(ph),
              onTapTag: (tag) => prefs.setTagFilter(tag),
            );
          }

          cursor -= pinned.length;

          // Normal holes
          if (cursor < nonPinnedHoles.length) {
            final h = nonPinnedHoles[cursor];
            return TeaHoleCard(
              hole: h,
              divisionName: _getDivisionName(h.divisionId),
              isPinned: false,
              onTap: () => _openHoleDetail(h),
              onTapTag: (tag) => prefs.setTagFilter(tag),
            );
          }

          // Load more indicator with infinite scroll support
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _isLoadingMore
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : (_hasMore
                        ? TextButton.icon(
                            onPressed: _loadMoreHoles,
                            icon: const Icon(Icons.expand_more_rounded),
                            label: const Text('加载更多'),
                          )
                        : Text(
                            '已加载全部帖子',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          )),
            ),
          );
        },
      ),
    );
  }

  /// List header as in DanXi: a search field, then the active tag filter.
  Widget _buildListHeader(int totalShowing) {
    final colorScheme = Theme.of(context).colorScheme;
    final prefs = ForumPreferences.instance;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Material(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) =>
                      ForumSearchPage(controller: widget.controller),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '搜索树洞',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (prefs.selectedTagFilter != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InputChip(
                avatar: const Icon(Icons.filter_alt_rounded, size: 16),
                label: Text('按标签筛选: #${prefs.selectedTagFilter}'),
                onDeleted: () => prefs.setTagFilter(null),
                deleteIconColor: colorScheme.primary,
              ),
            ),
          if (totalShowing == 0 && !_isLoading)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Center(
                child: Text(
                  '暂无帖子',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openHoleDetail(TeaHole hole) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => HoleDetailPage(
          controller: widget.controller,
          holeId: hole.holeId,
          initialHole: hole,
        ),
      ),
    );
  }
}
