// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_floor_tile.dart';
import 'forum_models.dart';
import 'forum_pagination.dart';
import 'forum_service.dart';
import 'hole_detail_page.dart';

/// Search page for finding forum holes and floors.
class ForumSearchPage extends StatefulWidget {
  final DanshengController controller;

  const ForumSearchPage({super.key, required this.controller});

  @override
  State<ForumSearchPage> createState() => _ForumSearchPageState();
}

class _ForumSearchPageState extends State<ForumSearchPage> {
  late final ForumService _service;
  final _searchController = TextEditingController();

  List<ForumSearchResult> _results = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasSearched = false;
  bool _hasMore = false;
  String? _errorMessage;

  static const int _pageSize = forumPageSize;

  @override
  void initState() {
    super.initState();
    _service = ForumService(CampusApi(widget.controller.client));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _hasSearched = true;
      _errorMessage = null;
      _results = [];
    });

    try {
      final items = await _service.search(
        query: query,
        offset: 0,
        size: _pageSize,
      );
      if (mounted) {
        setState(() {
          _results = items;
          _hasMore = items.length >= _pageSize;
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

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final query = _searchController.text.trim();
      final items = await _service.search(
        query: query,
        offset: _results.length,
        size: _pageSize,
      );
      if (mounted) {
        setState(() {
          _results.addAll(items);
          _hasMore = items.length >= _pageSize;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _performSearch(),
          decoration: InputDecoration(
            hintText: '搜索树洞内容…',
            border: InputBorder.none,
            hintStyle: TextStyle(color: colorScheme.onSurfaceVariant),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _results = [];
                        _hasSearched = false;
                      });
                    },
                  )
                : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: _performSearch,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _performSearch,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_hasSearched) {
      return Center(
        child: Text(
          '搜索帖子或楼层',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Text(
          '未找到相关结果',
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _results.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _results.length) {
          final item = _results[index];
          return _buildResultCard(item);
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: _isLoadingMore
                ? const CircularProgressIndicator()
                : TextButton.icon(
                    onPressed: _loadMore,
                    icon: const Icon(Icons.expand_more_rounded),
                    label: const Text('加载更多'),
                  ),
          ),
        );
      },
    );
  }

  Widget _buildResultCard(ForumSearchResult item) {
    return ForumFloorTile(
      key: ValueKey((item.holeId, item.floorId)),
      floor: TeaFloor(
        floorId: item.floorId ?? 0,
        holeId: item.holeId,
        content: item.content,
        anonyname: item.anonyname,
        timeCreated: item.timeCreated,
        deleted: item.deleted,
        fold: item.fold,
        ranking: item.ranking,
        replyTo: item.replyTo,
        specialTag: item.specialTag,
      ),
      showHoleId: true,
      tags: item.tags,
      onTapHole: (holeId) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                HoleDetailPage(controller: widget.controller, holeId: holeId),
          ),
        );
      },
      onTapFloor: (floorId) {
        // A search result is not a complete thread and supplies no floor map.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('引用楼层 ##$floorId 尚未加载，请打开帖子详情后定位。'),
            action: SnackBarAction(
              label: '打开帖子',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => HoleDetailPage(
                      controller: widget.controller,
                      holeId: item.holeId,
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (ctx) => HoleDetailPage(
              controller: widget.controller,
              holeId: item.holeId,
            ),
          ),
        );
      },
    );
  }
}
