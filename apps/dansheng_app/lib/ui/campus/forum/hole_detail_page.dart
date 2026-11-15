// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_editor_dialog.dart';
import 'forum_format.dart';
import 'forum_models.dart';
import 'forum_pagination.dart';
import 'forum_service.dart';

/// Post detail page showing the full hole, its floors, pagination, and reply capabilities.
class HoleDetailPage extends StatefulWidget {
  final DanshengController controller;
  final int holeId;
  final TeaHole? initialHole;

  const HoleDetailPage({
    super.key,
    required this.controller,
    required this.holeId,
    this.initialHole,
  });

  @override
  State<HoleDetailPage> createState() => _HoleDetailPageState();
}

class _HoleDetailPageState extends State<HoleDetailPage> {
  late final ForumService _service;
  TeaHole? _hole;
  List<TeaFloor> _floors = [];

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
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
        itemCount: _floors.length + 1 + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _buildHoleHeader();
          }

          final floorIndex = index - 1;
          if (floorIndex < _floors.length) {
            return _buildFloorItem(_floors[floorIndex], floorIndex + 1);
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hole = _hole;

    if (hole == null) {
      return const SizedBox(height: 8);
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant.withAlpha(120)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '#${hole.holeId}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
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
                    '分区 ${hole.divisionId}',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  formatFriendlyTime(hole.timeCreated),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (hole.tags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: hole.tags.map((t) {
                  return Chip(
                    label: Text('#$t'),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 14,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '${hole.reply} 回复',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (hole.view > 0) ...[
                  const SizedBox(width: 16),
                  Icon(
                    Icons.visibility_outlined,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${hole.view} 浏览',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (hole.locked) ...[
                  const SizedBox(width: 16),
                  Icon(Icons.lock_outline, size: 14, color: colorScheme.error),
                  const SizedBox(width: 4),
                  Text(
                    '已锁定',
                    style: TextStyle(fontSize: 12, color: colorScheme.error),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloorItem(TeaFloor floor, int floorNumber) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isOp = floorNumber == 1;
    final anonyname = resolveAnonyname(floor.anonyname, floorNumber);
    final isDeleted = floor.deleted || floor.content == null;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: isOp
          ? colorScheme.primaryContainer.withAlpha(25)
          : colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isOp
              ? colorScheme.primary.withAlpha(80)
              : colorScheme.outlineVariant.withAlpha(80),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top floor metadata row
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isOp
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isOp ? '洞主' : '$floorNumber楼',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isOp
                          ? colorScheme.onPrimary
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  anonyname,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isOp ? colorScheme.primary : colorScheme.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  formatFriendlyTime(floor.timeCreated),
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Content or deleted placeholder
            if (isDeleted)
              Text(
                '该楼层已被删除',
                style: TextStyle(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: colorScheme.outline,
                ),
              )
            else
              Text(
                cleanPreviewText(floor.content),
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),

            if (floor.like > 0 || floor.dislike > 0) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (floor.like > 0) ...[
                    Icon(
                      Icons.thumb_up_alt_outlined,
                      size: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${floor.like}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (floor.dislike > 0) ...[
                    const SizedBox(width: 10),
                    Icon(
                      Icons.thumb_down_alt_outlined,
                      size: 13,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${floor.dislike}',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
