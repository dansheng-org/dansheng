// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../campus_api.dart';
import '../../core/dansheng_state.dart';
import 'forum_format.dart';
import 'forum_models.dart';
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

  static const int _pageSize = 20;

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
      final items = await _service.search(query: query, offset: 0);
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
            .showSnackBar(SnackBar(content: Text('加载更多失败: ${campusError(e)}')));
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
            hintText: '搜索树洞内容...',
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
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colorScheme.outlineVariant.withAlpha(100)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
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
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '#${item.holeId}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                      fontSize: 13,
                    ),
                  ),
                  if (item.floorId != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '(${item.floorId}楼)',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (item.anonyname != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      resolveAnonyname(item.anonyname, item.floorId ?? 1),
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    formatFriendlyTime(item.timeCreated),
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                item.deleted ? '该楼层已被删除' : cleanPreviewText(item.content),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  fontStyle: item.deleted ? FontStyle.italic : FontStyle.normal,
                  color: item.deleted
                      ? colorScheme.outline
                      : colorScheme.onSurface,
                ),
              ),
              if (item.tags.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  children: item.tags.map((t) {
                    return Text(
                      '#$t ',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.primary,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
