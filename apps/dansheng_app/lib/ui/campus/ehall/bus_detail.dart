// SPDX-License-Identifier: GPL-3.0-or-later
// ignore_for_file: constant_identifier_names
import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../campus_api.dart';

/// Campus enum matching DanXi common/constant.dart.
enum Campus {
  HANDAN_CAMPUS,
  FENGLIN_CAMPUS,
  JIANGWAN_CAMPUS,
  ZHANGJIANG_CAMPUS,
  NONE;

  static const List<Campus> campusValues = [
    Campus.HANDAN_CAMPUS,
    Campus.FENGLIN_CAMPUS,
    Campus.JIANGWAN_CAMPUS,
    Campus.ZHANGJIANG_CAMPUS,
  ];

  static const List<Campus> allCampusesWithNone = [
    Campus.NONE,
    Campus.HANDAN_CAMPUS,
    Campus.FENGLIN_CAMPUS,
    Campus.JIANGWAN_CAMPUS,
    Campus.ZHANGJIANG_CAMPUS,
  ];

  String displayTitle(BuildContext? context) {
    switch (this) {
      case Campus.HANDAN_CAMPUS:
        return '邯郸校区';
      case Campus.FENGLIN_CAMPUS:
        return '枫林校区';
      case Campus.JIANGWAN_CAMPUS:
        return '江湾校区';
      case Campus.ZHANGJIANG_CAMPUS:
        return '张江校区';
      case Campus.NONE:
        return '全部校区';
    }
  }

  String get shortName {
    switch (this) {
      case Campus.HANDAN_CAMPUS:
        return '邯郸';
      case Campus.FENGLIN_CAMPUS:
        return '枫林';
      case Campus.JIANGWAN_CAMPUS:
        return '江湾';
      case Campus.ZHANGJIANG_CAMPUS:
        return '张江';
      case Campus.NONE:
        return '全部';
    }
  }

  static Campus fromChineseName(String? name) {
    if (name != null) {
      if (name.contains('邯郸')) return Campus.HANDAN_CAMPUS;
      if (name.contains('枫林')) return Campus.FENGLIN_CAMPUS;
      if (name.contains('江湾')) return Campus.JIANGWAN_CAMPUS;
      if (name.contains('张江')) return Campus.ZHANGJIANG_CAMPUS;
    }
    return Campus.NONE;
  }
}

/// Direction enum matching DanXi repository/fdu/bus_repository.dart.
enum BusDirection {
  NONE,
  DUAL,

  /// From end to start
  BACKWARD,

  /// From start to end
  FORWARD;

  static BusDirection parse(dynamic val) {
    if (val == null) return BusDirection.NONE;
    if (val is int) {
      if (val >= 0 && val < BusDirection.values.length) {
        return BusDirection.values[val];
      }
      return BusDirection.NONE;
    }
    final s = val.toString().toLowerCase().trim();
    if (s == '1' || s == 'dual' || s == 'both') return BusDirection.DUAL;
    if (s == '2' || s == 'backward' || s == 'back') {
      return BusDirection.BACKWARD;
    }
    if (s == '3' || s == 'forward' || s == 'out') return BusDirection.FORWARD;
    if (s == '0' || s == 'none') return BusDirection.NONE;
    return BusDirection.NONE;
  }

  // Icons rather than arrow characters: Android draws ↔ as a color emoji.
  IconData get icon {
    switch (this) {
      case BusDirection.FORWARD:
      case BusDirection.NONE:
        return Icons.arrow_forward_rounded;
      case BusDirection.BACKWARD:
        return Icons.arrow_back_rounded;
      case BusDirection.DUAL:
        return Icons.swap_horiz_rounded;
    }
  }

  BusDirection reverse() {
    switch (this) {
      case BusDirection.FORWARD:
        return BusDirection.BACKWARD;
      case BusDirection.BACKWARD:
        return BusDirection.FORWARD;
      default:
        return this;
    }
  }
}

/// Time parser and comparator for bus schedules.
class BusTime implements Comparable<BusTime> {
  const BusTime(this.hour, this.minute);

  final int hour;
  final int minute;

  static BusTime? parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final normalized = raw.trim().replaceAll('.', ':');
    final parts = normalized.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h != null && m != null) {
        return BusTime(h, m);
      }
    }
    return null;
  }

  String toDisplayFormat() {
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  bool isAfter(DateTime dt) {
    if (hour > dt.hour) return true;
    if (hour == dt.hour && minute > dt.minute) return true;
    return false;
  }

  @override
  int compareTo(BusTime other) {
    if (hour != other.hour) return hour.compareTo(other.hour);
    return minute.compareTo(other.minute);
  }

  @override
  String toString() => toDisplayFormat();
}

/// A parsed bus schedule item matching DanXi BusScheduleItem.
class BusScheduleItem implements Comparable<BusScheduleItem> {
  BusScheduleItem({
    this.id,
    required this.start,
    required this.end,
    this.startName,
    this.endName,
    this.startTime,
    this.endTime,
    required this.direction,
    required this.holidayRun,
  });

  factory BusScheduleItem.fromRawJson(Map<String, dynamic> json) {
    final fromStr = json['from'] ?? json['start'];
    final toStr = json['to'] ?? json['end'];
    final startCampus = Campus.fromChineseName(fromStr?.toString());
    final endCampus = Campus.fromChineseName(toStr?.toString());

    final startTimeStr = json['starts_at'] ?? json['stime'];
    final endTimeStr = json['ends_at'] ?? json['etime'];

    final dirRaw = json['direction'] ?? json['arrow'];
    final direction = BusDirection.parse(dirRaw);

    final holRaw = json['holiday'];
    final isHoliday =
        holRaw == true || holRaw == 1 || holRaw == '1' || holRaw == 'true';

    return BusScheduleItem(
      id: json['id']?.toString(),
      start: startCampus,
      end: endCampus,
      startName: fromStr?.toString(),
      endName: toStr?.toString(),
      startTime: BusTime.parse(startTimeStr?.toString()),
      endTime: BusTime.parse(endTimeStr?.toString()),
      direction: direction,
      holidayRun: isHoliday,
    );
  }

  BusScheduleItem.reversed(BusScheduleItem original)
    : id = original.id,
      start = original.end,
      end = original.start,
      startName = original.endName,
      endName = original.startName,
      startTime = original.endTime ?? original.startTime,
      endTime = original.startTime ?? original.endTime,
      direction = original.direction.reverse(),
      holidayRun = original.holidayRun;

  final String? id;
  final Campus start;
  final Campus end;
  final String? startName;
  final String? endName;
  final BusTime? startTime;
  final BusTime? endTime;
  final BusDirection direction;
  final bool holidayRun;

  BusTime? get realStartTime => startTime ?? endTime;

  @override
  int compareTo(BusScheduleItem other) {
    if (realStartTime == null && other.realStartTime == null) return 0;
    if (realStartTime == null) return 1;
    if (other.realStartTime == null) return -1;
    return realStartTime!.compareTo(other.realStartTime!);
  }
}

/// Bus rows from a fudan.bus result or its cached copy, whatever envelope
/// the result arrived in.
Iterable<Map<String, dynamic>> busRows(dynamic data) sync* {
  if (data == null) return;
  if (data is List) {
    for (final item in data) {
      yield* busRows(item);
    }
    return;
  }
  if (data is Map<String, dynamic>) {
    if (data['records'] is List) {
      yield* busRows(data['records']);
      return;
    }
    if (data['buses'] is List) {
      yield* busRows(data['buses']);
      return;
    }
    if (data['data'] is List) {
      yield* busRows(data['data']);
      return;
    }
    if (data['lists'] is List) {
      yield* busRows(data['lists']);
      return;
    }
    if (data['list'] is List) {
      yield* busRows(data['list']);
      return;
    }
    if (data['payload'] != null) {
      yield* busRows(data['payload']);
      return;
    }
    if (data.containsKey('from') ||
        data.containsKey('start') ||
        data.containsKey('starts_at') ||
        data.containsKey('stime')) {
      yield data;
    }
  } else if (data is Map) {
    yield* busRows(Map<String, dynamic>.from(data));
  }
}

/// The departures from [from] to [to], earliest first, as the bus page lists
/// them (matching DanXi bus.dart): backward rows run reversed, and a
/// two-way row also serves the reverse trip. [Campus.NONE] matches any campus.
List<BusScheduleItem> directedBuses(
  Iterable<BusScheduleItem> items,
  Campus from,
  Campus to,
) {
  return items
      .map((element) {
        // Backward direction means physical vehicle runs in reverse of raw start->end
        if (element.direction == BusDirection.BACKWARD) {
          return BusScheduleItem.reversed(element);
        }
        // Dual (bidirectional) entries reversed when user requests reverse direction
        if (element.direction == BusDirection.DUAL &&
            from != Campus.NONE &&
            to != Campus.NONE &&
            element.start == to &&
            element.end == from) {
          return BusScheduleItem.reversed(element);
        }
        return element;
      })
      .where((element) {
        final matchesStart = from == Campus.NONE || element.start == from;
        final matchesEnd = to == Campus.NONE || element.end == to;
        return matchesStart && matchesEnd;
      })
      .toList()
    ..sort((a, b) => a.compareTo(b));
}

/// Campus bus inquiry page matching DanXi BusPage and repository.
class BusDetailPage extends StatefulWidget {
  const BusDetailPage({
    super.key,
    required this.controller,
    this.initialDate,
    this.initialFrom,
    this.initialTo,
  });

  final DanshengController controller;
  final DateTime? initialDate;

  /// The route to show first; Handan to Jiangwan when not given.
  final Campus? initialFrom, initialTo;

  @override
  State<BusDetailPage> createState() => BusDetailPageState();
}

class BusDetailPageState extends State<BusDetailPage> {
  late DateTime _referenceDate;

  /// Whether holiday schedule is selected.
  late bool _holiday;

  /// Cached loaded schedules for workday and holiday.
  List<BusScheduleItem>? _weekdayLoaded;
  List<BusScheduleItem>? _holidayLoaded;

  /// Start and Destination campuses.
  /// Default to Handan -> Jiangwan as sensible defaults.
  late Campus _startSelectItem = widget.initialFrom ?? Campus.HANDAN_CAMPUS;
  late Campus _endSelectItem = widget.initialTo ?? Campus.JIANGWAN_CAMPUS;

  /// Whether to display all buses or only upcoming ones.
  bool _showAll = false;

  bool _loading = false;
  String? _errorMessage;
  bool _isAuthError = false;
  int _generation = 0;
  String? _lastAccountId;

  CampusApi get _api => CampusApi(widget.controller.client);

  @override
  void initState() {
    super.initState();
    _referenceDate =
        widget.initialDate ??
        DateTime.now().toUtc().add(const Duration(hours: 8));
    _holiday =
        _referenceDate.weekday == DateTime.saturday ||
        _referenceDate.weekday == DateTime.sunday;

    _lastAccountId = widget.controller.activeAccountId;
    widget.controller.addListener(_onControllerChange);

    _loadData();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    if (widget.controller.activeAccountId != _lastAccountId) {
      _lastAccountId = widget.controller.activeAccountId;
      _weekdayLoaded = null;
      _holidayLoaded = null;
      _loadData(force: true);
    }
  }

  Future<void> _loadData({bool force = false}) async {
    final cached = _holiday ? _holidayLoaded : _weekdayLoaded;
    if (cached != null && !force) {
      if (mounted) setState(() {});
      return;
    }

    final ticket = ++_generation;
    final account = widget.controller.activeAccountId;

    setState(() {
      _loading = true;
      _errorMessage = null;
      _isAuthError = false;
    });

    try {
      final raw = await _api.call('fudan.bus', {'holiday': _holiday});
      if (!mounted ||
          ticket != _generation ||
          account != widget.controller.activeAccountId) {
        return;
      }

      final items = <BusScheduleItem>[];
      for (final row in _extractRows(raw)) {
        try {
          items.add(BusScheduleItem.fromRawJson(row));
        } catch (_) {}
      }

      if (_holiday) {
        _holidayLoaded = items;
      } else {
        _weekdayLoaded = items;
      }
    } catch (e) {
      if (!mounted ||
          ticket != _generation ||
          account != widget.controller.activeAccountId) {
        return;
      }

      final errStr = e.toString();
      _isAuthError =
          errStr.contains('AuthenticationRequired') ||
          errStr.contains('NotLoginError') ||
          errStr.contains('401') ||
          errStr.contains('postgraduates_need_login');

      // Try cached fallback if available
      try {
        final old = await _api.call('campus.cached', {
          'method': 'fudan.bus',
          'holiday': _holiday,
        });
        if (old != null && mounted && ticket == _generation) {
          final items = <BusScheduleItem>[];
          for (final row in _extractRows(old)) {
            try {
              items.add(BusScheduleItem.fromRawJson(row));
            } catch (_) {}
          }
          if (items.isNotEmpty) {
            if (_holiday) {
              _holidayLoaded = items;
            } else {
              _weekdayLoaded = items;
            }
          }
        }
      } catch (_) {}

      _errorMessage = campusError(e);
    } finally {
      if (mounted && ticket == _generation) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Iterable<Map<String, dynamic>> _extractRows(dynamic data) => busRows(data);

  void _onLocationSwapped() {
    setState(() {
      final temp = _startSelectItem;
      _startSelectItem = _endSelectItem;
      _endSelectItem = temp;
    });
  }

  List<BusScheduleItem> _filterBus(List<BusScheduleItem> origList) =>
      directedBuses(origList, _startSelectItem, _endSelectItem);

  List<DropdownMenuItem<Campus>> _getItems() =>
      Campus.allCampusesWithNone.map((c) {
        return DropdownMenuItem<Campus>(
          value: c,
          alignment: Alignment.center,
          child: Text(c.displayTitle(context), textAlign: TextAlign.center),
        );
      }).toList();

  List<Widget> _selectedItems() => Campus.allCampusesWithNone
      .map(
        (campus) => Padding(
          padding: const EdgeInsets.only(left: 24),
          child: Center(
            child: Text(
              campus.displayTitle(context),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    final currentList = _holiday ? _holidayLoaded : _weekdayLoaded;
    final currentTime = _referenceDate;
    final hh = currentTime.hour.toString().padLeft(2, '0');
    final mm = currentTime.minute.toString().padLeft(2, '0');

    return Scaffold(
      appBar: AppBar(
        title: const Text('校车班次'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新校车班次',
            onPressed: () => _loadData(force: true),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),

            // Workday vs Holiday schedule toggle
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment<bool>(
                    value: false,
                    label: Text('工作日'),
                    icon: Icon(Icons.work_outline),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    label: Text('节假日'),
                    icon: Icon(Icons.weekend_outlined),
                  ),
                ],
                selected: {_holiday},
                onSelectionChanged: (val) {
                  if (val.first != _holiday) {
                    setState(() => _holiday = val.first);
                    _loadData();
                  }
                },
              ),
            ),

            const SizedBox(height: 12),

            // Campus Origin, Destination and Swap controls
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Card(
                elevation: 0,
                color: Theme.of(context).colorScheme.surfaceContainerHighest
                    .withAlpha(128),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      // Origin dropdown
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '始发站',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                            ),
                            DropdownButton<Campus>(
                              key: const Key('bus_start_dropdown'),
                              alignment: Alignment.center,
                              isExpanded: true,
                              value: _startSelectItem,
                              items: _getItems(),
                              selectedItemBuilder: (_) => _selectedItems(),
                              underline: const SizedBox.shrink(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _startSelectItem = val);
                                }
                              },
                            ),
                          ],
                        ),
                      ),

                      // Swap button
                      Semantics(
                        label: '互换始发站与终点站',
                        button: true,
                        child: IconButton(
                          icon: const Icon(Icons.swap_horiz_rounded),
                          tooltip: '互换起点和终点',
                          onPressed: _onLocationSwapped,
                        ),
                      ),

                      // Destination dropdown
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '终点站',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outline,
                                  ),
                            ),
                            DropdownButton<Campus>(
                              key: const Key('bus_dest_dropdown'),
                              alignment: Alignment.center,
                              isExpanded: true,
                              value: _endSelectItem,
                              items: _getItems(),
                              selectedItemBuilder: (_) => _selectedItems(),
                              underline: const SizedBox.shrink(),
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() => _endSelectItem = val);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 8),

            // Main schedule view
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _loadData(force: true),
                child: _buildContent(currentList, currentTime, hh, mm),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    List<BusScheduleItem>? currentList,
    DateTime currentTime,
    String hh,
    String mm,
  ) {
    if (_loading && currentList == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && (currentList == null || currentList.isEmpty)) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 40,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _errorMessage!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => _loadData(force: true),
                      child: const Text('重试'),
                    ),
                    if (_isAuthError) ...[
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: () async {
                          try {
                            await _api.call('campus.login', {'service': 'bus'});
                            await _loadData(force: true);
                          } catch (e) {
                            if (mounted) {
                              setState(() => _errorMessage = campusError(e));
                            }
                          }
                        },
                        child: const Text('登录并刷新'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Meaningful empty state: identical origin and destination
    if (_startSelectItem == _endSelectItem && _startSelectItem != Campus.NONE) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.all(24.0),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Center(
                  child: Text(
                    '起点与终点相同，请重新选择校区',
                    style: TextStyle(fontSize: 15),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final rawList = currentList ?? [];
    final filtered = _filterBus(rawList);

    // Meaningful empty state: no matching buses
    if (filtered.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          Padding(
            padding: EdgeInsets.all(24.0),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Center(
                  child: Text('暂无相关校车班次', style: TextStyle(fontSize: 15)),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final visible = filtered.where((item) {
      if (_showAll) return true;
      if (item.realStartTime == null) return true;
      return item.realStartTime!.isAfter(currentTime);
    }).toList();

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: 1 + (visible.isEmpty ? 1 : visible.length),
      itemBuilder: (context, index) {
        if (index == 0) {
          // Info banner matching DanXi _getListWidgets
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 4.0,
            ),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(_showAll ? '已显示全部校车班次' : '仅显示 $hh:$mm 以后的校车班次'),
                subtitle: Text(_showAll ? '点击以筛选 $hh:$mm 以后的校车班次' : '点击以显示全部'),
                onTap: () => setState(() => _showAll = !_showAll),
              ),
            ),
          );
        }

        if (visible.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24.0),
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Center(
                  child: Text(
                    '今日余下时段已无发车班次，点击上方卡片可查看今日全部班次',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          );
        }

        final item = visible[index - 1];
        return _buildBusCard(item);
      },
    );
  }

  Widget _buildBusCard(BusScheduleItem item) {
    final startTitle = item.startName ?? item.start.displayTitle(context);
    final endTitle = item.endName ?? item.end.displayTitle(context);
    final startDisp = item.startTime?.toDisplayFormat() ?? '--:--';
    final endDisp = item.endTime?.toDisplayFormat() ?? '--:--';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12.0, horizontal: 16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      startTitle,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      startDisp,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Column(
                  children: [
                    Icon(
                      item.direction.icon,
                      size: 22,
                      color: Theme.of(context).colorScheme.outline,
                      semanticLabel: item.direction == BusDirection.DUAL
                          ? '双向'
                          : '单向',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      endTitle,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      endDisp,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.secondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
