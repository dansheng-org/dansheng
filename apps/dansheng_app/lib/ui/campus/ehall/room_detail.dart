// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../campus_api.dart';
import 'campus_building.dart';
import 'room_models.dart';

export 'room_models.dart';

/// Empty classroom detail page matching DanXi's empty_classroom_detail.dart.
///
/// Features campus/building selector, date picker with quick day navigation,
/// optional classroom filtering within building, 13 numbered per-period cells
/// (green=free, red=occupied, grey=unknown, with no false green on unknown),
/// accessible labels, visible legend, responsive layout for narrow screens,
/// authentic CampusApi('fudan.rooms') calls, webvpn retry on auth error,
/// offline cache fallback, and stale-result / account-switch protection.
class RoomDetailPage extends StatefulWidget {
  const RoomDetailPage({
    super.key,
    required this.controller,
    this.initialBuilding,
    this.initialDate,
  });

  final DanshengController controller;
  final String? initialBuilding;
  final DateTime? initialDate;

  @override
  State<RoomDetailPage> createState() => _RoomDetailPageState();
}

class _RoomDetailPageState extends State<RoomDetailPage> {
  late final CampusApi _api = CampusApi(widget.controller.client);

  late CampusOption _selectedCampus;
  late String _selectedBuildingCode;
  late DateTime _selectedDate;

  final TextEditingController _filterController = TextEditingController();
  bool _onlyFree = false;

  List<RoomItem> _rooms = [];
  bool _isLoading = false;
  String? _problem;
  bool _isAuthError = false;
  bool _isCached = false;

  int _generation = 0;
  String? _lastAccountId;

  String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _lastAccountId = widget.controller.activeAccountId;
    widget.controller.addListener(_onControllerChanged);

    final initialCode = CampusBuildings.toCode(
      widget.initialBuilding ?? CampusBuildings.defaultBuildingCode,
    );
    _selectedCampus = RoomCampuses.campusForBuilding(initialCode);
    _selectedBuildingCode = initialCode;
    _selectedDate = widget.initialDate ?? campusRoomNow();

    _loadRooms();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _filterController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final current = widget.controller.activeAccountId;
    if (current != _lastAccountId) {
      _lastAccountId = current;
      _generation++; // Invalidate pending loads
      if (mounted) {
        setState(() {
          _rooms = [];
          _problem = null;
          _isAuthError = false;
          _isLoading = false;
          _isCached = false;
        });
      }
      _loadRooms();
    }
  }

  Future<void> _loadRooms() async {
    final currentAccount = widget.controller.activeAccountId;
    if (currentAccount == null) {
      setState(() {
        _problem = '未设置账号，请先绑定复旦统一身份认证账号。';
        _isAuthError = false;
        _isLoading = false;
        _isCached = false;
        _rooms = [];
      });
      return;
    }

    final ticket = ++_generation;
    final bCode = CampusBuildings.toCode(_selectedBuildingCode);
    final dateStr = _formatDate(_selectedDate);

    setState(() {
      _isLoading = true;
      _problem = null;
      _isAuthError = false;
    });

    final input = {'building': bCode, 'date': dateStr};

    try {
      final res = await _api.call('fudan.rooms', input);

      if (!mounted ||
          ticket != _generation ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }

      final parsed = RoomDataParser.parse(res);
      setState(() {
        _rooms = parsed;
        _isCached = false;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted ||
          ticket != _generation ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }

      final errStr = e.toString();
      final authNeeded =
          errStr.contains('AuthenticationRequired') ||
          errStr.contains('NotLoginError') ||
          errStr.contains('InvalidCredentials') ||
          errStr.contains('401') ||
          errStr.contains('postgraduates_need_login') ||
          errStr.contains('InteractiveLoginRequired') ||
          errStr.contains('WebVpnLoginRequired');

      dynamic cachedData;
      try {
        cachedData = await _api.call('campus.cached', {
          'method': 'fudan.rooms',
          ...input,
        });
      } catch (_) {}

      if (!mounted ||
          ticket != _generation ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }

      final parsedCached = cachedData != null
          ? RoomDataParser.parse(cachedData)
          : <RoomItem>[];

      setState(() {
        _rooms = parsedCached;
        _isCached = parsedCached.isNotEmpty;
        _problem = campusError(e);
        _isAuthError = authNeeded;
        _isLoading = false;
      });
    }
  }

  Future<void> _handleAuthRetry() async {
    setState(() {
      _isLoading = true;
      _problem = null;
    });
    try {
      await _api.call('campus.login', {'service': 'webvpn'});
      await _loadRooms();
    } catch (e) {
      if (mounted) {
        setState(() {
          _problem = campusError(e);
          _isLoading = false;
        });
      }
    }
  }

  void _onCampusSelected(CampusOption campus) {
    if (_selectedCampus.campus == campus.campus) return;
    setState(() {
      _selectedCampus = campus;
      _selectedBuildingCode = campus.buildingCodes.first;
    });
    _loadRooms();
  }

  void _onBuildingSelected(String code) {
    if (_selectedBuildingCode == code) return;
    setState(() {
      _selectedBuildingCode = code;
    });
    _loadRooms();
  }

  void _changeDate(DateTime newDate) {
    setState(() {
      _selectedDate = newDate;
    });
    _loadRooms();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      _changeDate(picked);
    }
  }

  List<RoomItem> get _filteredRooms {
    final query = _filterController.text.trim().toLowerCase();
    return _rooms.where((room) {
      if (query.isNotEmpty && !room.roomName.toLowerCase().contains(query)) {
        return false;
      }
      if (_onlyFree && !room.hasFreePeriods) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('教室空位'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadRooms,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildCampusSelector(),
            _buildBuildingSelector(),
            _buildDateSelector(),
            _buildFilterRow(),
            _buildHeaderAndLegend(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildCampusSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: RoomCampuses.all.map((c) {
          final selected = _selectedCampus.campus == c.campus;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              avatar: Icon(
                Icons.location_on_outlined,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.primary,
              ),
              label: Text(c.displayName),
              selected: selected,
              onSelected: (val) {
                if (val) _onCampusSelected(c);
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBuildingSelector() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: _selectedCampus.buildingCodes.map((code) {
          final selected = _selectedBuildingCode == code;
          final name = CampusBuildings.toDisplayName(code);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              avatar: Icon(
                Icons.business_outlined,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.onSecondary
                    : Theme.of(context).colorScheme.secondary,
              ),
              label: Text(name),
              tooltip: '$name ($code)',
              selected: selected,
              onSelected: (val) {
                if (val) _onBuildingSelected(code);
              },
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDateSelector() {
    final dateStr = _formatDate(_selectedDate);
    final weekdayStr =
        '周${['一', '二', '三', '四', '五', '六', '日'][_selectedDate.weekday - 1]}';
    final isToday = dateStr == _formatDate(campusRoomNow());

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: '前一天',
            onPressed: () =>
                _changeDate(_selectedDate.subtract(const Duration(days: 1))),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_month, size: 16),
            label: Text(
              '$dateStr ($weekdayStr)',
              style: const TextStyle(fontSize: 13),
            ),
            onPressed: _pickDate,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: '后一天',
            onPressed: () =>
                _changeDate(_selectedDate.add(const Duration(days: 1))),
          ),
          if (!isToday)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: TextButton(
                onPressed: () => _changeDate(campusRoomNow()),
                child: const Text('今天'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 280;
          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSearchTextField(),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _buildFilterChip(),
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: _buildSearchTextField()),
              const SizedBox(width: 8),
              _buildFilterChip(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchTextField() {
    return TextField(
      controller: _filterController,
      decoration: InputDecoration(
        hintText: '筛选教室编号 (如 101, H3101)',
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: _filterController.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear, size: 16),
                onPressed: () {
                  _filterController.clear();
                  setState(() {});
                },
              )
            : null,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildFilterChip() {
    return FilterChip(
      label: const Text('只看空闲'),
      selected: _onlyFree,
      onSelected: (val) => setState(() => _onlyFree = val),
    );
  }

  Widget _buildHeaderAndLegend() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '教室 (${_filteredRooms.length})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _legendItem(const Color(0xFF2E7D32), '空闲'),
                  _legendItem(const Color(0xFFC62828), '占用'),
                  _legendItem(
                    Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey.shade700
                        : Colors.grey.shade400,
                    '未知',
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading && _rooms.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_problem != null && !_isCached) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _isAuthError ? Icons.lock_outline : Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                _problem!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(height: 16),
              if (_isAuthError)
                FilledButton.tonal(
                  onPressed: _handleAuthRetry,
                  child: const Text('登录并刷新'),
                )
              else if (widget.controller.activeAccountId != null)
                OutlinedButton(onPressed: _loadRooms, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final roomsToDisplay = _filteredRooms;

    if (roomsToDisplay.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.meeting_room_outlined,
                size: 48,
                color: Theme.of(context).hintColor,
              ),
              const SizedBox(height: 12),
              Text(
                _filterController.text.isNotEmpty || _onlyFree
                    ? '未找到符合条件的教室'
                    : '该教学楼暂无教室数据',
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
            ],
          ),
        ),
      );
    }

    final currentPeriod = getCurrentPeriodSlot(_selectedDate);

    return ListView.builder(
      itemCount: roomsToDisplay.length + (_isCached ? 1 : 0),
      itemBuilder: (context, index) {
        if (_isCached && index == 0) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前展示缓存数据 · ${_problem ?? "网络不可用"}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                if (_isAuthError)
                  TextButton(
                    onPressed: _handleAuthRetry,
                    child: const Text('登录'),
                  )
                else
                  TextButton(onPressed: _loadRooms, child: const Text('重试')),
              ],
            ),
          );
        }

        final room = roomsToDisplay[index - (_isCached ? 1 : 0)];
        return _buildRoomCard(room, currentPeriod);
      },
    );
  }

  Widget _buildRoomCard(RoomItem room, int? currentPeriod) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 520;

            final roomInfo = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      room.roomName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (room.seats != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${room.seats} 座',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      Text(
                        '座位数未公布',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  room.summaryText,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            );

            final periodWidget = _buildPeriodWidget(room, currentPeriod);

            if (isWide) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: roomInfo),
                  const SizedBox(width: 16),
                  periodWidget,
                ],
              );
            } else {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [roomInfo, const SizedBox(height: 10), periodWidget],
              );
            }
          },
        ),
      ),
    );
  }

  Widget _buildPeriodWidget(RoomItem room, int? currentPeriod) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 19.0 * 5 + 2.0 * 4,
                child: const Text(
                  '| 上午',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 19.0 * 5 + 2.0 * 4,
                child: const Text(
                  '| 下午',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 19.0 * 3 + 2.0 * 2,
                child: const Text(
                  '| 晚上',
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Morning periods 1..5
              for (int p = 1; p <= 5; p++) ...[
                if (p > 1) const SizedBox(width: 2),
                _buildCell(p, room.periods[p - 1], p == currentPeriod),
              ],
              const SizedBox(width: 8),
              // Afternoon periods 6..10
              for (int p = 6; p <= 10; p++) ...[
                if (p > 6) const SizedBox(width: 2),
                _buildCell(p, room.periods[p - 1], p == currentPeriod),
              ],
              const SizedBox(width: 8),
              // Evening periods 11..13
              for (int p = 11; p <= 13; p++) ...[
                if (p > 11) const SizedBox(width: 2),
                _buildCell(p, room.periods[p - 1], p == currentPeriod),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCell(int period, PeriodStatus status, bool isCurrent) {
    final Color bgColor;
    final Color textColor;
    final String statusText;

    switch (status) {
      case PeriodStatus.free:
        bgColor = const Color(0xFF2E7D32); // Green
        textColor = Colors.white;
        statusText = '空闲';
        break;
      case PeriodStatus.occupied:
        bgColor = const Color(0xFFC62828); // Red
        textColor = Colors.white;
        statusText = '占用';
        break;
      case PeriodStatus.unknown:
        bgColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.grey.shade700
            : Colors.grey.shade400; // Neutral grey - NEVER false green!
        textColor = Theme.of(context).brightness == Brightness.dark
            ? Colors.white70
            : Colors.black87;
        statusText = '未知';
        break;
    }

    return Tooltip(
      message: '第$period节：$statusText',
      child: Semantics(
        label: '第$period节：$statusText',
        container: true,
        child: Container(
          width: 19,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(4),
            border: isCurrent
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2.0,
                  )
                : Border.all(color: Colors.black12, width: 0.5),
          ),
          child: Text(
            '$period',
            style: TextStyle(
              fontSize: period >= 10 ? 9 : 10,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}
