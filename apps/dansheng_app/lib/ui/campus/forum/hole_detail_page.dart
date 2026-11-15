// SPDX-License-Identifier: GPL-3.0-or-later
// Floor layout adapted from DanXi lib/page/forum/hole_detail.dart.
// Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_editor_dialog.dart';
import 'forum_floor_tile.dart';
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
    _loadInitialData();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    final targetIndex = _floors.indexWhere((floor) => floor.floorId == floorId);
    if (targetIndex < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('引用楼层 ##$floorId 尚未加载，请先加载更多楼层；它也可能属于其他帖子。')),
      );
      return;
    }
    if (_locatingFloor || !_scrollController.hasClients) return;
    _locatingFloor = true;
    final key = _floorKeys.putIfAbsent(floorId, () => GlobalKey());
    try {
      // ListView is lazy: traverse viewports until the loaded target is built.
      // Decide direction using floor IDs mapped to list positions, not ranking.
      while (mounted && _scrollController.hasClients) {
        final targetContext = key.currentContext;
        if (targetContext != null && targetContext.mounted) {
          await Scrollable.ensureVisible(
            targetContext,
            alignment: .1,
            duration: const Duration(milliseconds: 250),
          );
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
          if (fetchedHole != null) _hole = fetchedHole;
          _floors = fetchedFloors;
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
          _hasMore = nextFloors.length >= _pageSize;
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

  Future<void> _openReplyDialog() async {
    final result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ForumReplyDialog(
        holeId: widget.holeId,
        onReply: _service.reply,
        onReconcile: _service.reconcile,
      ),
    );

    if (result == 'reload_required' || result != null) {
      // Reload floors to show latest state
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
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openReplyDialog,
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hole.tags.any(isVisibleForumTag)) ...[
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: hole.tags.where(isVisibleForumTag).map((t) {
                return Text(
                  '#$t',
                  style: TextStyle(color: colorScheme.primary),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 8),
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
    return ForumFloorTile(
      key: _floorKeys.putIfAbsent(floor.floorId, () => GlobalKey()),
      floor: floor,
      firstFloor: firstFloor,
      index: index,
      onTapHole: _openHole,
      onTapFloor: _locateFloor,
    );
  }
}
