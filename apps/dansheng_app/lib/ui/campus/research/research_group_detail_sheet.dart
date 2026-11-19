// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../campus_api.dart';
import 'research_models.dart';
import 'research_service.dart';

/// Bottom sheet for one research group (课题组): the PI, unit, listed research
/// directions, and the official homepage, which holds everything else.
Future<void> showResearchGroupDetailSheet(
  BuildContext context,
  ResearchGroupItem group,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => _ResearchGroupDetailView(initialGroup: group),
  );
}

class _ResearchGroupDetailView extends StatefulWidget {
  final ResearchGroupItem initialGroup;

  const _ResearchGroupDetailView({required this.initialGroup});

  @override
  State<_ResearchGroupDetailView> createState() =>
      _ResearchGroupDetailViewState();
}

class _ResearchGroupDetailViewState extends State<_ResearchGroupDetailView> {
  late ResearchGroupItem _group;
  final ResearchService _service = ResearchService.instance;

  @override
  void initState() {
    super.initState();
    _group = widget.initialGroup.copyWith(
      isFollowed: _service.isGroupFollowed(widget.initialGroup.id),
    );
  }

  void _toggleFollow() {
    _service.toggleFollowGroup(_group.id);
    setState(() {
      _group = _group.copyWith(isFollowed: _service.isGroupFollowed(_group.id));
    });
  }

  Future<void> _openHomepage() async {
    try {
      await _service.openLink(_group.websiteUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(e))));
      }
    }
  }

  Future<void> _copyHomepage() async {
    await Clipboard.setData(ClipboardData(text: _group.websiteUrl));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制主页链接')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _group.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        _group.leader,
                        if (_group.leaderTitle.isNotEmpty) _group.leaderTitle,
                      ].join(' · '),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _toggleFollow,
                icon: Icon(
                  _group.isFollowed ? Icons.star : Icons.star_border,
                  size: 18,
                ),
                label: Text(_group.isFollowed ? '已关注' : '关注'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Chip(
            avatar: const Icon(Icons.account_balance_outlined, size: 16),
            label: Text(_group.department),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(height: 16),
          Text(
            '研究方向',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          if (_group.researchDirections.isEmpty)
            Text(
              '主页未列出研究方向，可打开主页查看简介、论文与招生信息。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final d in _group.researchDirections)
                  Chip(label: Text(d), visualDensity: VisualDensity.compact),
              ],
            ),
          const SizedBox(height: 20),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: colorScheme.surfaceContainerHighest.withAlpha(120),
            child: ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('教师个人主页'),
              subtitle: Text(
                _group.websiteUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: '复制链接',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: _copyHomepage,
              ),
              onTap: _openHomepage,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '论文成果、科研项目与招生信息以主页为准。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
