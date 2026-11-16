// SPDX-License-Identifier: GPL-3.0-or-later
// DanXi-style floor mention and quote preview adapted from DanXi
// lib/widget/forum/forum_widgets.dart (OTFloorMentionWidget, showFloorDetail)
// and lib/widget/forum/render/render_impl.dart. Copyright (C) 2021 DanXi-Dev; GPL-3.0-or-later.
import 'package:flutter/material.dart';

import 'forum_chips.dart';
import 'forum_content.dart';
import 'forum_filter_settings.dart';
import 'forum_format.dart';
import 'forum_models.dart';

/// Global cache for loaded floors and holes to enable instant quote previews without refetching.
class ForumFloorCache {
  static final ForumFloorCache instance = ForumFloorCache._internal();
  ForumFloorCache._internal();

  final Map<int, TeaFloor> _floors = {};
  final Map<int, TeaHole> _holes = {};

  void putFloor(TeaFloor floor) {
    if (floor.floorId > 0) {
      _floors[floor.floorId] = floor;
    }
  }

  void putFloors(Iterable<TeaFloor> floors) {
    for (final f in floors) {
      putFloor(f);
    }
  }

  TeaFloor? getFloor(int floorId) => _floors[floorId];

  void putHole(TeaHole hole) {
    if (hole.holeId > 0) {
      _holes[hole.holeId] = hole;
      if (hole.floors?.firstFloor != null) {
        putFloor(hole.floors!.firstFloor!);
      }
      if (hole.floors?.lastFloor != null) {
        putFloor(hole.floors!.lastFloor!);
      }
    }
  }

  void putHoles(Iterable<TeaHole> holes) {
    for (final h in holes) {
      putHole(h);
    }
  }

  TeaHole? getHole(int holeId) => _holes[holeId];
}

/// Shows full details of a quoted floor in a modal bottom sheet matching DanXi's `showFloorDetail`.
Future<void> showFloorDetailModal(
  BuildContext context, {
  required TeaFloor floor,
  VoidCallback? onJumpToFloor,
  VoidCallback? onQuoteReply,
}) async {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final prefs = ForumPreferences.instance;
  final displayContent = prefs.filterContent(floor.content);

  final name = floor.anonyname?.trim();
  final nameColor = getHashColor(name ?? '热心同学', isDark: theme.brightness == Brightness.dark);
  final rankText = floor.ranking != null
      ? (floor.ranking == 0 ? '首楼' : '${floor.ranking! + 1}楼')
      : (floor.floorId > 0 ? '##${floor.floorId}' : '');

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sheet Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      ColoredBox(
                        color: nameColor,
                        child: const SizedBox(width: 3, height: 14),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        name?.isNotEmpty == true ? name! : '热心同学',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: nameColor,
                        ),
                      ),
                      if (rankText.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          rankText,
                          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                        ),
                      ],
                      if (floor.timeCreated?.isNotEmpty == true) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatFriendlyTime(floor.timeCreated),
                          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const Divider(),

              // Floor body
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * 0.45,
                ),
                child: SingleChildScrollView(
                  child: floor.deleted
                      ? Text('该楼层已被删除', style: TextStyle(color: colors.outline))
                      : ForumContent(content: displayContent),
                ),
              ),
              const SizedBox(height: 12),

              // Action buttons matching DanXi
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onQuoteReply != null)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onQuoteReply();
                      },
                      icon: const Icon(Icons.format_quote_rounded, size: 18),
                      label: const Text('引用此楼'),
                    ),
                  if (onJumpToFloor != null)
                    FilledButton.tonalIcon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onJumpToFloor();
                      },
                      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                      label: const Text('跳转至该楼'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Mention quote preview widget rendered inline in forum markdown posts.
class ForumMentionQuoteWidget extends StatelessWidget {
  final int id;
  final bool isFloor;
  final VoidCallback? onTap;

  const ForumMentionQuoteWidget({
    super.key,
    required this.id,
    required this.isFloor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final cachedFloor = isFloor ? ForumFloorCache.instance.getFloor(id) : null;
    final cachedHole = !isFloor ? ForumFloorCache.instance.getHole(id) : null;

    if (cachedFloor != null && !cachedFloor.deleted) {
      final name = cachedFloor.anonyname?.trim();
      final nameColor = getHashColor(name ?? '热心同学', isDark: theme.brightness == Brightness.dark);
      final snippet = cleanPreviewText(cachedFloor.content);

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
              border: Border(
                left: BorderSide(color: nameColor, width: 3),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.format_quote_rounded, size: 14, color: nameColor),
                    const SizedBox(width: 4),
                    Text(
                      name?.isNotEmpty == true ? name! : '热心同学',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: nameColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '##${cachedFloor.floorId}',
                      style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                    ),
                    if (cachedFloor.timeCreated?.isNotEmpty == true) ...[
                      const SizedBox(width: 6),
                      Text(
                        formatFriendlyTime(cachedFloor.timeCreated),
                        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (cachedHole != null) {
      final first = cachedHole.floors?.firstFloor;
      final snippet = cleanPreviewText(first?.content);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
              border: Border(
                left: BorderSide(color: colors.primary, width: 3),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tag_rounded, size: 14, color: colors.primary),
                    const SizedBox(width: 4),
                    Text(
                      '#${cachedHole.holeId}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: colors.primary,
                      ),
                    ),
                    if (cachedHole.reply > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '${cachedHole.reply} 回复',
                        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
                if (snippet.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // Fallback pill chip
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ActionChip(
        avatar: Icon(
          isFloor ? Icons.format_quote_rounded : Icons.tag_rounded,
          size: 14,
          color: colors.primary,
        ),
        label: Text(
          isFloor ? '##$id' : '#$id',
          style: TextStyle(fontSize: 12, color: colors.primary, fontWeight: FontWeight.bold),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
        onPressed: onTap,
      ),
    );
  }
}
