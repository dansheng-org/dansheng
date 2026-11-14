// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_editor_dialog.dart';
import 'forum_models.dart';
import 'forum_search_page.dart';
import 'forum_service.dart';
import 'hole_card.dart';
import 'hole_detail_page.dart';

/// Main Forum tab/page providing DanXi-style OpenTreeHole campus community experience.
class ForumPage extends StatefulWidget {
  final DanshengController controller;

  const ForumPage({super.key, required this.controller});

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
  bool _hasMore = true;
  String? _errorMessage;
  bool _authRequired = false;

  static const int _pageSize = 20;

  @override
  void initState() {
    super.initState();
    _service = ForumService(CampusApi(widget.controller.client));
    _loadInitialData();
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
      List<TeaDivision> divisions = [];
      try {
        divisions = await _service.fetchDivisions();
      } catch (e) {
        // Divisions might fail or require login
        if (e.toString().contains('AuthenticationRequired') ||
            e.toString().contains('AccountRequired')) {
          _authRequired = true;
          rethrow;
        }
      }

      // 2. Load holes
      final holes = await _service.fetchHoles(
        divisionId: _selectedDivisionId,
        before: null,
        pageSize: _pageSize,
        order: _sortOrder,
      );

      if (mounted) {
        setState(() {
          _divisions = divisions;
          _holes = holes;
          _hasMore = holes.length >= _pageSize;
          _isLoading = false;
          _authRequired = false;
        });
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
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载更多失败: ${campusError(e)}')));
      }
    }
  }

  /// Trigger forum login flow via campus.login.
  Future<void> _handleLogin() async {
    try {
      await _service.login();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已连接树洞账号')));
        await _loadInitialData();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('登录失败: ${campusError(e)}')));
      }
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

  /// Get pinned holes for the current division (or all pinned holes in 全站 mode).
  List<TeaHole> get _pinnedHoles {
    if (_selectedDivisionId != null) {
      final div = _divisions.firstWhere(
        (d) => d.divisionId == _selectedDivisionId,
        orElse: () => TeaDivision(divisionId: _selectedDivisionId!, name: ''),
      );
      return div.pinned;
    } else {
      // Gather pinned from all divisions
      final List<TeaHole> allPinned = [];
      final Set<int> seen = {};
      for (final d in _divisions) {
        for (final p in d.pinned) {
          if (seen.add(p.holeId)) {
            allPinned.add(p);
          }
        }
      }
      return allPinned;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('复旦树洞'),
        leading: IconButton(
          tooltip: '登录树洞账号',
          icon: const Icon(Icons.account_circle_outlined),
          onPressed: _handleLogin,
        ),
        actions: [
          // Sort order toggle
          IconButton(
            icon: Icon(
              _sortOrder == ForumSortOrder.lastReplied
                  ? Icons.schedule_rounded
                  : Icons.new_releases_outlined,
            ),
            tooltip: _sortOrder.label,
            onPressed: () {
              setState(() {
                _sortOrder = _sortOrder == ForumSortOrder.lastReplied
                    ? ForumSortOrder.lastCreated
                    : ForumSortOrder.lastReplied;
              });
              _refreshHoles(showLoading: true);
            },
          ),
          // Search button
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: '搜索',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (ctx) =>
                      ForumSearchPage(controller: widget.controller),
                ),
              );
            },
          ),
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _refreshHoles(showLoading: true),
          ),
        ],
        bottom: PreferredSize(
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
                '登录后即可浏览树洞、参与讨论与匿名互动。',
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _handleLogin,
                icon: const Icon(Icons.login_rounded),
                label: const Text('登录论坛'),
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

    final pinned = _pinnedHoles;
    final pinnedIds = pinned.map((h) => h.holeId).toSet();
    final nonPinnedHoles = _holes
        .where((h) => !pinnedIds.contains(h.holeId))
        .toList();

    return RefreshIndicator(
      onRefresh: () => _refreshHoles(showLoading: false),
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 8, bottom: 80),
        itemCount:
            1 + pinned.length + nonPinnedHoles.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          // Status bar row (sort order indicator + total count)
          if (index == 0) {
            return _buildStatusHeader(pinned.length + nonPinnedHoles.length);
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
            );
          }

          // Load more indicator
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _isLoadingMore
                  ? const CircularProgressIndicator()
                  : TextButton.icon(
                      onPressed: _loadMoreHoles,
                      icon: const Icon(Icons.expand_more_rounded),
                      label: const Text('加载更多'),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatusHeader(int totalShowing) {
    final colorScheme = Theme.of(context).colorScheme;
    final divisionTitle = _selectedDivisionId == null
        ? '全站'
        : (_getDivisionName(_selectedDivisionId!) ?? '分区');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Text(
            '$divisionTitle · ${_sortOrder.label}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          if (totalShowing == 0 && !_isLoading)
            Text(
              '暂无帖子',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
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
