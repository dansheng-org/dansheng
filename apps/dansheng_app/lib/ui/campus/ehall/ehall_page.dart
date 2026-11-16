import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../core/dansheng_state.dart';
import '../../screens/account_balance_screen.dart';
import '../../widgets/campus_account_actions.dart';
import '../campus_api.dart';
import '../venues/venue_page.dart';
import 'board/board_layout.dart';
import 'board/board_store.dart';
import 'board/tile_data.dart';
import 'board/tile_sheet.dart';
import 'board/tile_view.dart';
import 'campus_building.dart';
import 'department_notices/department_directory.dart';
import 'department_notices/department_notices_page.dart';
import 'life_page.dart';

/// The eHall home: a board of service tiles the person arranges like home
/// screen widgets. Each tile can be shown or hidden, sized from an icon to a
/// half screen, and moved by long-pressing it.
///
/// Opening the board never reaches a campus service: tiles show what earlier
/// reads stored on this device. Only pulling to refresh, or a tile's own
/// refresh, asks the services; opening a tile goes to its page as before.
class EHallPage extends StatefulWidget {
  const EHallPage({super.key, required this.controller});
  final DanshengController controller;

  @override
  State<EHallPage> createState() => _EHallPageState();
}

/// What a tile last learned about its service.
class _Reading {
  const _Reading({this.data, this.problem, this.alert = false});
  final TileData? data;

  /// Why the last refresh failed; cleared by the next success.
  final String? problem;
  final bool alert;
}

class _Drag {
  _Drag(this.tile, this.grab, this.topLeft, this.target, this.pointer);
  final EHallTile tile;

  /// Where the finger holds the tile, from its top left corner.
  final Offset grab;
  Offset topLeft;
  int target;
  Offset pointer;
  bool dropping = false;
}

class _EHallPageState extends State<EHallPage> {
  DanshengController get controller => widget.controller;
  late final store = BoardStore(controller.client);
  late final api = CampusApi(controller.client);
  late final layout = ValueNotifier<BoardLayout>(
    store.remembered ?? BoardLayout.standard(),
  );

  final readings = <EHallTile, _Reading>{};
  final busy = <EHallTile>{};
  bool editing = false;

  /// Whether the saved arrangement is known; until then nothing is drawn,
  /// so the default one never flashes up first.
  late bool ready = store.remembered != null;
  int generation = 0;
  String? account;
  String? day;

  final scroll = ScrollController();
  final boardKey = GlobalKey();
  final viewKey = GlobalKey();
  BoardMetrics? metrics;
  _Drag? drag;
  Timer? autoScroll, clock;
  late final AppLifecycleListener lifecycle;

  bool get signedIn => account != null && account!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    account = controller.activeAccountId;
    controller.addListener(_accountCheck);
    lifecycle = AppLifecycleListener(onResume: () => _readCached());
    // Clock-bound tiles (next bus, current period, exam countdown) move on
    // with time; re-reading the local cache is cheap and never goes online.
    clock = Timer.periodic(const Duration(minutes: 1), (_) {
      final today = campusDay(DateTime.now());
      _readCached(
        only: today == day
            ? const {EHallTile.bus, EHallTile.rooms, EHallTile.exams}
            : null,
      );
    });
    store.load().then((saved) {
      if (!mounted) return;
      layout.value = saved;
      setState(() => ready = true);
      _readCached();
    });
  }

  @override
  void dispose() {
    controller.removeListener(_accountCheck);
    lifecycle.dispose();
    clock?.cancel();
    autoScroll?.cancel();
    scroll.dispose();
    layout.dispose();
    super.dispose();
  }

  void _accountCheck() {
    if (controller.activeAccountId == account) return;
    setState(() {
      account = controller.activeAccountId;
      generation++;
      readings.clear();
      busy.clear();
    });
    _readCached();
  }

  // -------------------------------------------------------------------------
  // Reading.

  Iterable<TileSlot> _reading(Set<EHallTile>? only) => layout.value.shown.where(
    (s) => tileReads(s.tile, s.size) && (only == null || only.contains(s.tile)),
  );

  /// Reads the tiles' services from the local cache only.
  Future<void> _readCached({Set<EHallTile>? only}) async {
    final now = DateTime.now();
    day = campusDay(now);
    if (!signedIn) {
      if (mounted) setState(() {});
      return;
    }
    final ticket = generation;
    final source = TileSource.cached(api.call);
    await Future.wait([
      for (final slot in _reading(only))
        readTile(slot, source, now: now, account: account).then((data) {
          if (!mounted || ticket != generation) return;
          final before = readings[slot.tile];
          setState(
            () => readings[slot.tile] = _Reading(
              data: data,
              problem: before?.problem,
              alert: before?.alert ?? false,
            ),
          );
        }),
    ]);
  }

  /// Asks the services for the shown tiles, a few at a time. The host
  /// serialises sign-ins, and tiles that share a prerequisite share its read.
  Future<void> _refresh({Set<EHallTile>? only}) async {
    if (!signedIn) {
      _say('请先在“账号与校园卡”中设置账号');
      return;
    }
    final ticket = generation;
    final now = DateTime.now();
    final live = TileSource.live(api.call);
    final queue = _reading(only).where((s) => !busy.contains(s.tile)).toList();
    setState(() => busy.addAll(queue.map((s) => s.tile)));
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final slot = queue.removeAt(0);
        _Reading next;
        try {
          final fresh = await readTile(slot, live, now: now, account: account);
          // The host stored the result; reading it back keeps whatever the
          // detail pages stored alongside (a usage trend, say).
          final stored = await readTile(
            slot,
            TileSource.cached(api.call),
            now: now,
            account: account,
          );
          next = _Reading(data: stored ?? fresh);
        } catch (e) {
          final (problem, alert) = tileProblem(e);
          next = _Reading(
            data: readings[slot.tile]?.data,
            problem: problem,
            alert: alert,
          );
        }
        if (!mounted || ticket != generation) return;
        setState(() {
          readings[slot.tile] = next;
          busy.remove(slot.tile);
        });
      }
    }

    await Future.wait([for (var i = 0; i < 3; i++) worker()]);
  }

  // -------------------------------------------------------------------------
  // Layout changes.

  void _change(BoardLayout next) {
    final before = layout.value;
    if (next == before) return;
    layout.value = next;
    setState(() {});
    final reread = <EHallTile>{
      for (final slot in next.slots)
        if (slot.shown &&
            tileReads(slot.tile, slot.size) &&
            before.slot(slot.tile) != slot)
          slot.tile,
    };
    for (final tile in reread) {
      // Content options change what is read; drop the old facts at once.
      if (before.slot(tile).options != next.slot(tile).options) {
        readings.remove(tile);
      }
    }
    if (reread.isNotEmpty) _readCached(only: reread);
    store.save(next).catchError((_) {
      if (mounted) _say('布局未能保存，重启后可能恢复原样');
    });
  }

  void _say(String text, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  void _reset() {
    final before = layout.value;
    _change(BoardLayout.standard());
    _say(
      '已恢复默认布局',
      action: SnackBarAction(label: '撤销', onPressed: () => _change(before)),
    );
  }

  Future<void> _settings(EHallTile tile) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => TileSheet(
        tile: tile,
        layout: layout,
        onChanged: _change,
        onRefresh: () => _refresh(only: {tile}),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Navigation.

  Future<void> _push(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Widget _page(TileSlot slot) {
    final options = slot.options;
    LifePage life(LifeService service) =>
        LifePage(service: service, controller: controller);
    return switch (slot.tile) {
      EHallTile.ecard => life(LifeService.transactions),
      EHallTile.rooms => LifePage(
        service: LifeService.rooms,
        controller: controller,
        initialBuilding: CampusBuildings.toCode(options['building'] as String?),
      ),
      EHallTile.power => life(LifeService.power),
      EHallTile.venues => VenuePage(controller: controller),
      EHallTile.library => life(LifeService.library),
      EHallTile.dining => LifePage(
        service: LifeService.dining,
        controller: controller,
        initialDiningArea: diningArea(options),
      ),
      EHallTile.bus => () {
        final (from, to) = busRoute(options);
        return LifePage(
          service: LifeService.bus,
          controller: controller,
          initialFrom: from,
          initialTo: to,
        );
      }(),
      EHallTile.mail => const _MailShellPage(),
      EHallTile.notices => LifePage(
        service: LifeService.notices,
        controller: controller,
        initialGraduate: options['graduate'] == true,
      ),
      EHallTile.grades => life(LifeService.grades),
      EHallTile.gpa => life(LifeService.gpa),
      EHallTile.exams => life(LifeService.exams),
      EHallTile.departmentNotices => DepartmentNoticesPage(
        controller: controller,
        initialDepartments: DepartmentDirectory.parseSubscribed(
          options['departments'] as String?,
        ),
        onUpdateDepartments: (departments) {
          _change(
            layout.value.withOption(
              EHallTile.departmentNotices,
              'departments',
              departments.join(','),
            ),
          );
        },
      ),
    };
  }

  Future<void> _open(TileSlot slot) async {
    if (editing) {
      await _settings(slot.tile);
      return;
    }
    await _push(_page(slot));
    // The page may have refreshed what this tile shows.
    if (mounted && tileReads(slot.tile, slot.size)) {
      _readCached(only: {slot.tile});
    }
  }

  // -------------------------------------------------------------------------
  // Dragging.

  RenderBox? get _boardBox =>
      boardKey.currentContext?.findRenderObject() as RenderBox?;

  void _dragStart(TileSlot slot, Rect rect, Offset pointer) {
    final box = _boardBox;
    if (box == null) return;
    HapticFeedback.mediumImpact();
    final index = layout.value.shown.indexWhere((s) => s.tile == slot.tile);
    setState(() {
      editing = true;
      drag = _Drag(
        slot.tile,
        box.globalToLocal(pointer) - rect.topLeft,
        rect.topLeft,
        index,
        pointer,
      );
    });
  }

  void _dragMove(Offset pointer) {
    final current = drag;
    if (current == null || current.dropping) return;
    current.pointer = pointer;
    _follow();
    _scrollNearEdges();
  }

  /// Places the lifted tile under the finger and finds where it would land.
  void _follow() {
    final current = drag, box = _boardBox, m = metrics;
    if (current == null || box == null || m == null) return;
    final shown = layout.value.shown;
    final slot = shown.firstWhere((s) => s.tile == current.tile);
    final others = [
      for (final s in shown)
        if (s.tile != current.tile) s.size,
    ];
    final size = m
        .rect(TileCell(0, 0, tileColumns(slot.size, m.columns), slot.size.rows))
        .size;
    final local = box.globalToLocal(current.pointer) - current.grab;
    final width = m.rect(TileCell(0, 0, m.columns, 1)).width;
    final topLeft = Offset(
      local.dx.clamp(0.0, math.max(0.0, width - size.width)),
      local.dy,
    );
    final target = nearestInsertion(
      others: others,
      dragged: slot.size,
      metrics: m,
      center: topLeft + size.center(Offset.zero),
      current: current.target,
    );
    setState(() {
      current.topLeft = topLeft;
      current.target = target;
    });
  }

  void _scrollNearEdges() {
    final current = drag;
    final view = viewKey.currentContext?.findRenderObject() as RenderBox?;
    if (current == null || view == null || !scroll.hasClients) return;
    final top = view.localToGlobal(Offset.zero).dy;
    final bottom = top + view.size.height;
    const edge = 64.0;
    final y = current.pointer.dy;
    final speed = y < top + edge
        ? -(top + edge - y) / edge
        : y > bottom - edge
        ? (y - bottom + edge) / edge
        : 0.0;
    if (speed == 0) {
      autoScroll?.cancel();
      autoScroll = null;
      return;
    }
    autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final active = drag;
      if (active == null || !scroll.hasClients) return;
      final position = scroll.position;
      final y = active.pointer.dy;
      final step = y < top + edge
          ? -(top + edge - y) / edge
          : y > bottom - edge
          ? (y - bottom + edge) / edge
          : 0.0;
      final to = (position.pixels + step.clamp(-1.0, 1.0) * 14).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (to != position.pixels) {
        scroll.jumpTo(to);
        _follow();
      }
    });
  }

  void _dragEnd() {
    autoScroll?.cancel();
    autoScroll = null;
    final current = drag;
    if (current == null) return;
    final shown = layout.value.shown;
    final from = shown.indexWhere((s) => s.tile == current.tile);
    // Let the tile settle into its place before it becomes ordinary again.
    setState(() => current.dropping = true);
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (mounted && identical(drag, current)) setState(() => drag = null);
    });
    if (current.target != from) {
      _change(layout.value.moveShown(current.tile, current.target));
    }
  }

  // -------------------------------------------------------------------------
  // Building.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !editing,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && editing) setState(() => editing = false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(editing ? '编辑小组件' : 'eHall'),
          actions: editing
              ? [
                  TextButton(
                    onPressed: () => setState(() => editing = false),
                    child: const Text('完成'),
                  ),
                  const SizedBox(width: 8),
                ]
              : [
                  IconButton(
                    tooltip: '编辑小组件',
                    onPressed: () => setState(() => editing = true),
                    icon: const Icon(Icons.dashboard_customize_outlined),
                  ),
                  CampusAccountActions(controller: controller),
                ],
        ),
        body: RefreshIndicator(
          key: viewKey,
          notificationPredicate: (n) => !editing && n.depth == 0,
          onRefresh: _refresh,
          child: ListView(
            controller: scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              if (editing) _editHint(theme),
              if (!signedIn && !editing) _signedOut(theme),
              if (ready) LayoutBuilder(builder: _board),
              if (editing)
                _hiddenTray(theme)
              else if (layout.value.shown.isEmpty)
                _emptyBoard(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editHint(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: [
        Icon(
          Icons.touch_app_outlined,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '长按拖动调整顺序，轻点设置大小与内容',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _signedOut(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: ListTile(
        leading: Icon(
          Icons.account_circle_outlined,
          color: theme.colorScheme.primary,
        ),
        title: const Text('未设置账号'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _push(AccountBalanceScreen(controller: controller)),
      ),
    ),
  );

  Widget _emptyBoard(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(
      children: [
        Text(
          '首页没有显示的小组件',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: () => setState(() => editing = true),
          child: const Text('添加小组件'),
        ),
      ],
    ),
  );

  Widget _hiddenTray(ThemeData theme) {
    final hidden = layout.value.hidden;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('已隐藏', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (hidden.isEmpty)
            Text(
              '所有小组件都已显示',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final slot in hidden)
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: Text(slot.tile.title),
                    tooltip: '显示${slot.tile.title}',
                    onPressed: () =>
                        _change(layout.value.show(slot.tile, true)),
                  ),
              ],
            ),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _reset,
              icon: const Icon(Icons.restart_alt),
              label: const Text('恢复默认布局'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _board(BuildContext context, BoxConstraints box) {
    final m = BoardMetrics.fit(
      box.maxWidth,
      textScale: MediaQuery.textScalerOf(context).scale(10) / 10,
    );
    metrics = m;
    final shown = layout.value.shown;
    final current = drag;
    var order = shown;
    if (current != null) {
      final lifted = shown.where((s) => s.tile == current.tile);
      if (lifted.isEmpty) {
        drag = null;
      } else {
        order = [
          for (final s in shown)
            if (s.tile != current.tile) s,
        ]..insert(current.target, lifted.first);
      }
    }
    final packing = packBoard([for (final s in order) s.size], m.columns);
    final now = DateTime.now();
    final children = <Widget>[];
    Widget? lifted;
    for (var i = 0; i < order.length; i++) {
      final slot = order[i];
      final rect = m.rect(packing.cells[i]);
      final moving = drag?.tile == slot.tile;
      if (moving && !drag!.dropping) {
        children.add(
          Positioned.fromRect(
            key: const ValueKey('drop-place'),
            rect: rect,
            child: _DropPlace(),
          ),
        );
      }
      final at = moving && !drag!.dropping ? drag!.topLeft & rect.size : rect;
      final tile = AnimatedPositioned(
        key: ValueKey(slot.tile),
        duration: moving && !drag!.dropping
            ? Duration.zero
            : const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        left: at.left,
        top: at.top,
        width: at.width,
        height: at.height,
        // The frame animates; the content is laid out at its final size
        // at once, so a tile changing size never squeezes its face. A lifted
        // tile keeps its size and needs its shadow, so it is not clipped; the
        // structure stays the same so the drag gesture survives the lift.
        child: ClipRect(
          clipBehavior: moving ? Clip.none : Clip.hardEdge,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: rect.width,
            maxWidth: rect.width,
            minHeight: rect.height,
            maxHeight: rect.height,
            child: _tile(slot, rect, now, lifted: moving),
          ),
        ),
      );
      if (moving) {
        lifted = tile;
      } else {
        children.add(tile);
      }
    }
    if (lifted != null) children.add(lifted);
    return SizedBox(
      key: boardKey,
      height: m.height(packing.rows),
      child: Stack(clipBehavior: Clip.none, children: children),
    );
  }

  Widget _tile(TileSlot slot, Rect rect, DateTime now, {bool lifted = false}) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tile = slot.tile;
    final reads = tileReads(tile, slot.size);
    final reading = readings[tile];
    final data = reading?.data;
    String? status;
    var alert = false;
    if (reads) {
      if (!signedIn) {
        status = '未设置账号';
      } else if (reading?.problem != null) {
        status = reading!.problem;
        alert = reading.alert;
      } else if (reading != null && data == null) {
        status = '暂无数据，下拉刷新';
      }
    } else if (tile == EHallTile.venues) {
      status = '查场地 · 我的预约';
    } else if (tile == EHallTile.mail) {
      status = '暂未接入';
    }
    final observed = data?.observedAt;
    final stale =
        observed != null && now.toUtc().difference(observed) > staleAfter(tile);
    final facts = reads && signedIn ? data?.facts : null;
    final face = TileFace(
      tile: tile,
      size: slot.size,
      facts: facts,
      status: status,
      alert: alert,
      stale: stale,
      age: observed == null ? null : readAge(observed, now),
    );
    final spoken = [
      tile.title,
      if (facts != null && facts.spoken.isNotEmpty) facts.spoken,
      ?status,
      if (observed != null) '更新于${readAge(observed, now)}',
    ].join('，');
    final shown = layout.value.shown;
    final index = shown.indexWhere((s) => s.tile == tile);
    return Semantics(
      container: true,
      button: true,
      label: spoken,
      hint: editing ? '轻点设置，长按拖动' : null,
      onTap: () => _open(slot),
      customSemanticsActions: editing
          ? {
              if (index > 0)
                const CustomSemanticsAction(label: '前移'): () =>
                    _change(layout.value.moveShown(tile, index - 1)),
              if (index < shown.length - 1)
                const CustomSemanticsAction(label: '后移'): () =>
                    _change(layout.value.moveShown(tile, index + 1)),
              const CustomSemanticsAction(label: '隐藏'): () =>
                  _change(layout.value.show(tile, false)),
            }
          : const {},
      excludeSemantics: true,
      child: GestureDetector(
        onLongPressStart: (d) => _dragStart(slot, rect, d.globalPosition),
        onLongPressMoveUpdate: (d) => _dragMove(d.globalPosition),
        onLongPressEnd: (_) => _dragEnd(),
        onLongPressCancel: _dragEnd,
        child: AnimatedScale(
          scale: lifted && !(drag?.dropping ?? true) ? 1.04 : 1,
          duration: const Duration(milliseconds: 150),
          child: Material(
            color: colors.surfaceContainerLowest,
            elevation: lifted ? 3 : 0,
            shadowColor: colors.shadow.withValues(alpha: 0.18),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(
                color: editing
                    ? colors.primary.withValues(alpha: 0.45)
                    : colors.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _open(slot),
              child: Stack(
                children: [
                  Positioned.fill(child: face),
                  if (busy.contains(tile))
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (editing && !lifted)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _HideBadge(
                        onPressed: () =>
                            _change(layout.value.show(tile, false)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HideBadge extends StatelessWidget {
  const _HideBadge({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 30,
      height: 30,
      child: InkResponse(
        onTap: onPressed,
        radius: 20,
        child: Center(
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: colors.surfaceContainerHigh,
              shape: BoxShape.circle,
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Icon(Icons.remove, size: 14, color: colors.onSurface),
          ),
        ),
      ),
    );
  }
}

class _DropPlace extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: colors.primary.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
    );
  }
}

class _MailShellPage extends StatelessWidget {
  const _MailShellPage();
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('校园邮箱')),
    body: const ListTile(
      leading: Icon(Icons.mail_outline),
      title: Text('邮箱暂未接入'),
    ),
  );
}
