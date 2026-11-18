// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'research_models.dart';
import 'research_service.dart';

/// Modal bottom sheet displaying detailed profile of a research group (课题组).
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
      _group = _group.copyWith(
        isFollowed: _service.isGroupFollowed(_group.id),
      );
    });
    final msg = _group.isFollowed
        ? '已关注「${_group.name}」'
        : '已取消关注「${_group.name}」';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copyContact() async {
    await Clipboard.setData(ClipboardData(text: _group.contactEmail));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已复制联系邮箱：${_group.contactEmail}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            // Header: Title & Follow button
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _group.name,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_group.leader} · ${_group.leaderTitle}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _toggleFollow,
                  icon: Icon(
                    _group.isFollowed ? Icons.check : Icons.add,
                    size: 18,
                  ),
                  label: Text(_group.isFollowed ? '已关注' : '关注'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Badges: Department & Campus & Location
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Chip(
                  avatar: const Icon(Icons.apartment, size: 16),
                  label: Text(_group.department),
                  visualDensity: VisualDensity.compact,
                ),
                Chip(
                  avatar: const Icon(Icons.location_on_outlined, size: 16),
                  label: Text('${_group.campus} · ${_group.labLocation}'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Research Directions
            Text(
              '研究方向',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final d in _group.researchDirections)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer.withAlpha(120),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      d,
                      style: TextStyle(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),

            // Lab Introduction
            Text(
              '课题组简介',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _group.description,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 20),

            // Representative Papers
            Text(
              '代表性成果 / 近期论文',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _group.recentPapers.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}. ',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _group.recentPapers[i],
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),

            // Recruitment / Openings
            if (_group.recruitment != null) ...[
              Card(
                color: colorScheme.secondaryContainer.withAlpha(90),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.school_outlined,
                            size: 20,
                            color: colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '招生与科研招募',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _group.recruitment!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Contact & Action
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.email_outlined),
              title: const Text('联系邮箱'),
              subtitle: Text(_group.contactEmail),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                tooltip: '复制邮箱',
                onPressed: _copyContact,
              ),
            ),
          ],
        );
      },
    );
  }
}
