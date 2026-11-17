import 'package:flutter/material.dart';

import '../campus_building.dart';
import '../department_notices/department_directory.dart';
import '../department_notices/department_subscription_sheet.dart';
import '../life_page.dart';
import 'board_layout.dart';
import 'tile_data.dart';

/// Sizes offered for [tile]. Shortcuts without data have no use for room
/// that would stay empty.
List<TileSize> tileSizes(EHallTile tile) =>
    tile == EHallTile.venues || tile == EHallTile.mail
    ? const [TileSize.icon, TileSize.small, TileSize.wide]
    : TileSize.values;

String sizeHint(EHallTile tile, TileSize size) {
  if (tile == EHallTile.venues || tile == EHallTile.mail) {
    return size == TileSize.icon ? '仅图标与名称' : '名称与说明';
  }
  return switch (size) {
    TileSize.icon => '仅图标与名称，不读取数据',
    TileSize.small => '名称与一个关键数字',
    TileSize.wide => '关键数字与一行说明',
    TileSize.medium => '关键数字、说明与要点',
    TileSize.large => '摘要，以及列表或图表',
  };
}

/// Settings for one tile: visibility, size, content and position.
class TileSheet extends StatelessWidget {
  const TileSheet({
    super.key,
    required this.tile,
    required this.layout,
    required this.onChanged,
    this.onRefresh,
  });

  final EHallTile tile;
  final ValueNotifier<BoardLayout> layout;
  final ValueChanged<BoardLayout> onChanged;

  /// Reads this tile's service now; null when it shows no data.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<BoardLayout>(
    valueListenable: layout,
    builder: (context, board, _) {
      final theme = Theme.of(context);
      final slot = board.slot(tile);
      final shown = board.shown;
      final position = shown.indexWhere((s) => s.tile == tile);
      void set(BoardLayout next) => onChanged(next);
      final options = _options(context, board, slot, set);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(tile.icon, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      tile.title,
                      style: theme.textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('在首页显示'),
                value: slot.shown,
                onChanged: (value) => set(board.show(tile, value)),
              ),
              const SizedBox(height: 4),
              Text('大小', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final size in tileSizes(tile))
                    ChoiceChip(
                      label: Text('${size.label} ${size.footprint}'),
                      selected: slot.size == size,
                      onSelected: (_) => set(board.resize(tile, size)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                sizeHint(tile, slot.size),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (options != null) ...[
                const SizedBox(height: 18),
                Text('内容', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                options,
              ],
              if (slot.shown) ...[
                const SizedBox(height: 18),
                Text('位置', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: position > 0
                          ? () => set(board.moveShown(tile, position - 1))
                          : null,
                      icon: const Icon(Icons.arrow_upward_rounded),
                      label: const Text('前移'),
                    ),
                    OutlinedButton.icon(
                      onPressed: position >= 0 && position < shown.length - 1
                          ? () => set(board.moveShown(tile, position + 1))
                          : null,
                      icon: const Icon(Icons.arrow_downward_rounded),
                      label: const Text('后移'),
                    ),
                    if (onRefresh != null && tileReads(tile, slot.size))
                      OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          onRefresh!();
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('立即刷新'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget? _options(
    BuildContext context,
    BoardLayout board,
    TileSlot slot,
    ValueChanged<BoardLayout> set,
  ) {
    final options = slot.options;
    switch (tile) {
      case EHallTile.rooms:
        final current = CampusBuildings.toCode(options['building'] as String?);
        return DropdownButtonFormField<String>(
          initialValue: current,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '教学楼'),
          items: [
            for (final campus in RoomCampuses.all)
              for (final code in campus.buildingCodes)
                DropdownMenuItem(
                  value: code,
                  child: Text(
                    '${campus.campus} · ${CampusBuildings.toDisplayName(code)}',
                  ),
                ),
          ],
          onChanged: (code) => set(
            board.withOption(
              tile,
              'building',
              code == CampusBuildings.defaultBuildingCode ? null : code,
            ),
          ),
        );
      case EHallTile.dining:
        final area = diningArea(options);
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (code, name) in diningAreas.indexed)
              ChoiceChip(
                label: Text(name),
                selected: area == code,
                onSelected: (_) => set(
                  board.withOption(tile, 'area', code == 0 ? null : code),
                ),
              ),
          ],
        );
      case EHallTile.bus:
        final (from, to) = busRoute(options);
        BoardLayout route(Campus a, Campus b) => board
            .withOption(tile, 'from', a == Campus.HANDAN_CAMPUS ? null : a.name)
            .withOption(
              tile,
              'to',
              b == Campus.JIANGWAN_CAMPUS ? null : b.name,
            );
        Widget pick(String label, Campus value, ValueChanged<Campus> chosen) =>
            Expanded(
              child: DropdownButtonFormField<Campus>(
                initialValue: value,
                isExpanded: true,
                decoration: InputDecoration(labelText: label),
                items: [
                  for (final campus in Campus.campusValues)
                    DropdownMenuItem(
                      value: campus,
                      child: Text(campus.displayTitle(context)),
                    ),
                ],
                onChanged: (c) {
                  if (c != null) chosen(c);
                },
              ),
            );
        return Row(
          key: ValueKey('$from-$to'),
          children: [
            pick('出发', from, (c) => set(route(c, c == to ? from : to))),
            IconButton(
              tooltip: '交换方向',
              onPressed: () => set(route(to, from)),
              icon: const Icon(Icons.swap_horiz_rounded),
            ),
            pick('到达', to, (c) => set(route(c == from ? to : from, c))),
          ],
        );
      case EHallTile.notices:
        final graduate = options['graduate'] == true;
        return SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('本科生')),
            ButtonSegment(value: true, label: Text('研究生')),
          ],
          selected: {graduate},
          onSelectionChanged: (set_) =>
              set(board.withOption(tile, 'graduate', set_.first ? true : null)),
        );
      case EHallTile.departmentNotices:
        final depts = DepartmentDirectory.parseSubscribed(
          options['departments'] as String?,
        );
        return Row(
          children: [
            Expanded(
              child: Text(
                '已选择 ${depts.length} 个院系',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('选择院系'),
              onPressed: () async {
                final chosen = await showDepartmentSubscriptionSheet(
                  context,
                  currentSelected: depts,
                );
                if (chosen != null) {
                  set(board.withOption(tile, 'departments', chosen.join(',')));
                }
              },
            ),
          ],
        );
      default:
        return null;
    }
  }
}
