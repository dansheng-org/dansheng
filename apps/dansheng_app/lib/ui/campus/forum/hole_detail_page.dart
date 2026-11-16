// SPDX-License-Identifier: GPL-3.0-or-later
// Floor layout adapted from DanXi lib/page/forum/hole_detail.dart.
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'dart:async';

import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_chips.dart';
import 'forum_editor_dialog.dart';
import 'forum_filter_settings.dart';
import 'forum_floor_tile.dart';
import 'forum_mention_support.dart';
import 'forum_models.dart';
import 'forum_pagination.dart';
import 'forum_service.dart';

/// Post detail page showing the full hole, its floors, pagination, and reply capabilities.
class HoleDetailPage extends StatefulWidget {
  final DanshengController controller;
  final int holeId;
  final TeaHole? initialHole;

  /// Locate an already-loaded floor by its global ID after the initial fetch.
  /// An unloaded target produces a notice without changing pagination.
  final int? initialFloorId;

  const HoleDetailPage({
    super.key,
    required this.controller,
    required this.holeId,
    this.initialHole,
    this.initialFloorId,
  });

  @override
  State<HoleDetailPage> createState() => _HoleDetailPageState();
}

class _HoleDetailPageState extends State<HoleDetailPage> {
  late final ForumService _service;
  TeaHole? _hole;
  List<TeaFloor> _floors = [];
  final _scrollController = ScrollController();
  final _floorKeys = <int, GlobalKey>{};
  bool _locatingFloor = false;
  bool _didLocateInitialFloor = false;

  int? _highlightFloorId;
  Timer? _highlightTimer;

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _errorMessage;

  static const int _pageSize = forumPageSize;

  @override
  void initState() {
    super.initState();
    _service = ForumService(CampusApi(widget.controller.client));
    _hole = widget.initialHole;
    if (_hole != null) {
      ForumFloorCache.instance.putHole(_hole!);
    }
    _loadInitialData();
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _triggerHighlight(int floorId) {
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightFloorId = floorId);
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightFloorId = null);
    });
  }

  void _openHole(int holeId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            HoleDetailPage(controller: widget.controller, holeId: holeId),
      ),
    );
  }

  Future<void> _locateFloor(int floorId) async {
    var targetIndex = _floors.indexWhere((floor) => floor.floorId == floorId);

    // If not loaded and there are more floors, try loading next page(s)
    if (targetIndex < 0 && _hasMore && !_isLoadingMore) {
      for (var page = 0; page < 3 && targetIndex < 0 && _hasMore; page++) {
        await _loadMoreFloors();
        targetIndex = _floors.indexWhere((floor) => floor.floorId == floorId);
      }
    }

    if (targetIndex < 0) {
      final cachedFloor = ForumFloorCache.instance.getFloor(floorId);
      if (cachedFloor != null && cachedFloor.holeId != widget.holeId) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('楼层属于其他帖子'),
            content: Text('楼层 ##$floorId 属于帖子 #${cachedFloor.holeId}。是否前往该帖子查看？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  _openHole(cachedFloor.holeId);
                },
                child: const Text('前往'),
              ),
            ],
          ),
        );
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('引用楼层 ##$floorId 尚未加载，请先加载更多楼层；它也可能属于其他帖子。')),
        );
      }
      return;
    }

    if (_locatingFloor || !_scrollController.hasClients) return;
    _locatingFloor = true;
    final key = _floorKeys.putIfAbsent(floorId, () => GlobalKey());
    try {
      // ListView is lazy: traverse viewports until the loaded target is built.
      while (mounted && _scrollController.hasClients) {
        final targetContext = key.currentContext;
        if (targetContext != null && targetContext.mounted) {
          await Scrollable.ensureVisible(
            targetContext,
            alignment: .1,
            duration: const Duration(milliseconds: 250),
          );
          _triggerHighlight(floorId);
          return;
        }
        final builtIndices = <int>[
          for (var index = 0; index < _floors.length; index++)
            if (_floorKeys[_floors[index].floorId]?.currentContext != null)
              index,
        ];
        final position = _scrollController.position;
        final backwards =
            builtIndices.isNotEmpty && targetIndex < builtIndices.first;
        final nextOffset =
            (position.pixels +
                    (backwards ? -1 : 1) * position.viewportDimension * .8)
                .clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble();
        if ((nextOffset - position.pixels).abs() < 1) break;
        await _scrollController.animateTo(
          nextOffset,
          duration: const Duration(milliseconds: 100),
          curve: Curves.linear,
        );
        await WidgetsBinding.instance.endOfFrame;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('暂时无法定位楼层 ##$floorId，请刷新后重试。')));
      }
    } finally {
      _locatingFloor = false;
    }
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final holeFuture = _service.fetchHole(widget.holeId);
      final floorsFuture = _service.fetchFloors(
        holeId: widget.holeId,
        offset: 0,
        size: _pageSize,
      );

      final fetchedHole = await holeFuture;
      final fetchedFloors = await floorsFuture;

      if (mounted) {
        setState(() {
          if (fetchedHole != null) {
            _hole = fetchedHole;
            ForumFloorCache.instance.putHole(fetchedHole);
          }
          _floors = fetchedFloors;
          ForumFloorCache.instance.putFloors(fetchedFloors);
          _hasMore = fetchedFloors.length >= _pageSize;
          _isLoading = false;
        });
        if (!_didLocateInitialFloor && widget.initialFloorId != null) {
          _didLocateInitialFloor = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _locateFloor(widget.initialFloorId!);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = campusError(e);
        });
      }
    }
  }

  Future<void> _loadMoreFloors() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final nextFloors = await _service.fetchFloors(
        holeId: widget.holeId,
        offset: _floors.length,
        size: _pageSize,
      );

      if (mounted) {
        setState(() {
          _floors.addAll(nextFloors);
          ForumFloorCache.instance.putFloors(nextFloors);
          _hasMore = nextFloors.length >= _pageSize;
          _isLoadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载更多失败：${campusError(e)}')));
      }
    }
  }

  Future<void> _openReplyDialog({TeaFloor? quoteFloor}) async {
    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ForumReplyDialog(
        holeId: widget.holeId,
        initialContent: quoteFloor != null ? '##${quoteFloor.floorId}\n' : null,
        onReply: _service.reply,
        onReconcile: _service.reconcile,
      ),
    );

    if (result == 'reload_required' || result != null) {
      await _loadInitialData();
      if (result != 'reload_required' && mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('回复已发布')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('#${widget.holeId} 帖子详情'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadInitialData,
          ),
          PopupMenuButton<String>(
            tooltip: '更多选项',
            onSelected: (val) {
              if (val == 'settings') {
                ForumFilterDialog.show(context);
              } else if (val == 'hide') {
                ForumPreferences.instance.hideHole(widget.holeId);
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('已屏蔽帖子 #${widget.holeId}')),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 20),
                    SizedBox(width: 8),
                    Text('过滤偏好设置'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'hide',
                child: Row(
                  children: [
                    Icon(Icons.visibility_off_outlined, size: 20),
                    SizedBox(width: 8),
                    Text('屏蔽此帖'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openReplyDialog(),
        icon: const Icon(Icons.reply_rounded),
        label: const Text('回复'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _floors.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _floors.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.error,
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

    return RefreshIndicator(
      onRefresh: _loadInitialData,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: _floors.length + 1 + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildHoleHeader();
          }

          final floorIndex = index - 1;
          if (floorIndex < _floors.length) {
            return _buildFloorItem(_floors[floorIndex], floorIndex);
          }

          // Load more indicator
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _isLoadingMore
                  ? const CircularProgressIndicator()
                  : TextButton.icon(
                      onPressed: _loadMoreFloors,
                      icon: const Icon(Icons.expand_more_rounded),
                      label: const Text('加载更多楼层'),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHoleHeader() {
    final colorScheme = Theme.of(context).colorScheme;
    final hole = _hole;

    if (hole == null) {
      return const SizedBox(height: 8);
    }

    final visibleTags = hole.tags.where(isVisibleForumTag).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (visibleTags.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: visibleTags.map((t) {
                return RectangularChip(
                  label: t,
                  onTap: () {
                    ForumPreferences.instance.setTagFilter(t);
                    Navigator.of(context).pop();
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
          DefaultTextStyle(
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text('${hole.reply} 回复'),
                if (hole.view > 0) Text('${hole.view} 浏览'),
                if (hole.locked) const Text('已锁定'),
                if (hole.hidden) const Text('已隐藏'),
                if (hole.frozen) const Text('已冻结'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFloorItem(TeaFloor floor, int index) {
    final firstFloor =
        _hole?.floors?.firstFloor ??
        (_floors.isNotEmpty ? _floors.first : null);

    final tile = ForumFloorTile(
      key: _floorKeys.putIfAbsent(floor.floorId, () => GlobalKey()),
      floor: floor,
      firstFloor: firstFloor,
      index: index,
      onTapHole: _openHole,
      onTapFloor: _locateFloor,
      onQuoteReply: (f) => _openReplyDialog(quoteFloor: f),
    );

    if (_highlightFloorId != null && floor.floorId == _highlightFloorId) {
      return _HighlightFadeWrapper(child: tile);
    }
    return tile;
  }
}

/// Fades out a subtle highlight overlay over 1500ms matching DanXi's `_HighlightFadeWrapper`.
class _HighlightFadeWrapper extends StatefulWidget {
  final Widget child;
  const _HighlightFadeWrapper({required this.child});

  @override
  State<_HighlightFadeWrapper> createState() => _HighlightFadeWrapperState();
}

class _HighlightFadeWrapperState extends State<_HighlightFadeWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlightColor =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.35);

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
                CurvedAnimation(parent: _controller, curve: Curves.easeOut),
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: highlightColor,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
