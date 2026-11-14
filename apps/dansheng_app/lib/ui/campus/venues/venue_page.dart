// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dansheng_state.dart';
import '../../schema/schema_models.dart';
import '../campus_api.dart';
import '../../screens/schema_screen.dart';
import '../../screens/tasks_screen.dart';
import 'venue_models.dart';

/// Screen for campus sports venue browsing, availability calendar,
/// prominent confirmed manual booking, and external automation task creation.
class VenuePage extends StatefulWidget {
  final DanshengController controller;
  final int? initialVenueId;
  final DateTime? initialDate;

  const VenuePage({
    super.key,
    required this.controller,
    this.initialVenueId,
    this.initialDate,
  });

  @override
  State<VenuePage> createState() => _VenuePageState();
}

class _VenuePageState extends State<VenuePage>
    with SingleTickerProviderStateMixin {
  late final CampusApi _api;
  late final TabController _tabController;

  List<CampusVenue> _venues = [];
  CampusVenue? _selectedVenue;
  DateTime _selectedDate = DateTime.now().toUtc().add(const Duration(hours: 8));

  List<VenueSlot> _slots = [];
  final Map<int, List<VenueSlot>> _selection = {};
  VenueSlot? get _selectedSlot =>
      _selection.values.expand((v) => v).firstOrNull;
  String _search = '';
  String? _campus;
  int _venueGeneration = 0, _calendarGeneration = 0, _historyGeneration = 0;
  int _accountEpoch = 0;
  bool get _canReserve =>
      !_reserving &&
      !_loadingSlots &&
      _slotsError == null &&
      _uncertain.isEmpty &&
      _selection.values.any((v) => v.isNotEmpty);
  void _clearSelection() => _selection.clear();

  List<VenueAppointment> _appointments = [];

  bool _loadingVenues = false;
  bool _loadingSlots = false;
  bool _loadingAppointments = false;
  bool _reserving = false;
  int? _cancellingId;
  final Set<int> _uncertainCancelIds = {};

  List<Map> _uncertain = [];
  bool _authenticating = false;

  String? _venuesError;
  String? _slotsError;
  String? _appointmentsError;
  String? _lastAccountId;

  @override
  void initState() {
    super.initState();
    if (widget.initialDate != null) {
      _selectedDate = widget.initialDate!;
    }
    _api = CampusApi(widget.controller.client);
    _lastAccountId = widget.controller.activeAccountId;
    widget.controller.addListener(_onControllerChanged);
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
      if (_tabController.index == 1 &&
          _appointments.isEmpty &&
          !_loadingAppointments) {
        _loadAppointments();
      }
    });
    _loadVenues();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _tabController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (widget.controller.activeAccountId != _lastAccountId) {
      _lastAccountId = widget.controller.activeAccountId;
      _accountEpoch++;
      _venueGeneration++;
      _calendarGeneration++;
      _historyGeneration++;
      // Revoke local selection and cached data upon account switch
      if (mounted) {
        setState(() {
          _clearSelection();
          _reserving = false;
          _authenticating = false;
          _loadingAppointments = false;
          _selectedVenue = null;
          _slots = [];
          _appointments = [];
          _uncertain = [];
          _uncertainCancelIds.clear();
          _cancellingId = null;
          _venuesError = null;
          _slotsError = null;
          _appointmentsError = null;
        });
        _loadVenues();
        if (_tabController.index == 1) {
          _loadAppointments();
        }
      }
    }
  }

  String _formatDate(DateTime d) {
    final year = d.year.toString().padLeft(4, '0');
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  Map<String, dynamic>? get _automationPlugin {
    for (final p in widget.controller.plugins) {
      if (p['id'] == 'official.fudan-sports' && p['enabled'] == true) {
        return p;
      }
    }
    return null;
  }

  Future<void> _loadVenues() async {
    final ticket = ++_venueGeneration;
    final epoch = _accountEpoch;
    bool current() =>
        mounted && ticket == _venueGeneration && epoch == _accountEpoch;
    setState(() {
      _loadingVenues = true;
      _venuesError = null;
    });

    try {
      final res = await _api.call('venues.venues');
      final List<CampusVenue> list = [];
      if (res is List) {
        for (final item in res) {
          if (item is Map) {
            list.add(CampusVenue.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      if (!mounted || !current()) return;
      setState(() {
        list.sort(
          (a, b) => a.campus == b.campus
              ? a.name.compareTo(b.name)
              : ['邯郸校区', '江湾校区', '枫林校区', '张江校区', '其他校区']
                    .indexOf(a.campus)
                    .compareTo(
                      [
                        '邯郸校区',
                        '江湾校区',
                        '枫林校区',
                        '张江校区',
                        '其他校区',
                      ].indexOf(b.campus),
                    ),
        );
        _venues = list;
        if (list.isNotEmpty &&
            (_selectedVenue == null ||
                !list.any((v) => v.id == _selectedVenue!.id))) {
          if (widget.initialVenueId != null) {
            _selectedVenue = list.firstWhere(
              (v) => v.id == widget.initialVenueId,
              orElse: () => list.first,
            );
          } else {
            _selectedVenue = list.first;
          }
        }
      });

      if (_selectedVenue != null) {
        await _loadCalendar();
      }
    } catch (e) {
      if (!mounted || !current()) return;
      setState(() {
        _venuesError = campusError(e);
      });
    } finally {
      if (mounted && current()) {
        setState(() {
          _loadingVenues = false;
        });
      }
    }
  }

  Future<void> _loadCalendar() async {
    final ticket = ++_calendarGeneration;
    final epoch = _accountEpoch;
    bool current() =>
        mounted && ticket == _calendarGeneration && epoch == _accountEpoch;
    final venue = _selectedVenue;
    if (venue == null) return;

    setState(() {
      _loadingSlots = true;
      _slots = [];
      _slotsError = null;
    });

    try {
      final dateStr = _formatDate(_selectedDate);
      final res = await _api.call('venues.calendar', {
        'venue_id': venue.id,
        'target_date': dateStr,
      });

      final List<VenueSlot> slots = [];
      if (res is Map && res['slots'] is List) {
        for (final item in res['slots'] as List) {
          if (item is Map) {
            slots.add(VenueSlot.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      }

      if (!mounted || !current()) return;
      setState(() {
        _slots = slots;
        _selection.removeWhere(
          (period, _) => !slots.any((s) => s.periodId == period),
        );
        for (final period in _selection.keys.toList()) {
          final selected = _selection[period]!;
          _selection[period] = [
            for (final old in selected)
              for (final fresh in slots)
                if (fresh.periodId == old.periodId &&
                    fresh.courtId == old.courtId)
                  fresh,
          ];
        }
      });
    } catch (e) {
      if (!mounted || !current()) return;
      setState(() {
        _slotsError = campusError(e);
      });
    } finally {
      if (mounted && current()) {
        setState(() {
          _loadingSlots = false;
        });
      }
    }
  }

  Future<void> _loadAppointments() async {
    final ticket = ++_historyGeneration;
    final epoch = _accountEpoch;
    bool current() =>
        mounted && ticket == _historyGeneration && epoch == _accountEpoch;
    setState(() {
      _loadingAppointments = true;
      _appointmentsError = null;
    });

    try {
      final pending = await _api.call('venues.pending');
      if (!mounted || !current()) return;
      if (pending is List) {
        setState(() => _uncertain = pending.whereType<Map>().toList());
      }
      final res = await _api.call('venues.appointments');
      final List<VenueAppointment> list = [];
      if (res is List) {
        for (final item in res) {
          if (item is Map) {
            list.add(
              VenueAppointment.fromJson(Map<String, dynamic>.from(item)),
            );
          }
        }
      }

      if (!mounted || !current()) return;
      setState(() {
        _appointments = list;
      });
    } catch (e) {
      if (!mounted || !current()) return;
      setState(() {
        _appointmentsError = campusError(e);
      });
    } finally {
      if (mounted && current()) {
        setState(() {
          _loadingAppointments = false;
        });
      }
    }
  }

  Future<void> _handleVisibleLogin() async {
    final epoch = _accountEpoch;
    bool current() => mounted && epoch == _accountEpoch;
    setState(() {
      _authenticating = true;
    });

    try {
      await _api.call('venues.visibleLogin');
      if (!mounted || !current()) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('登录成功')));
      await _loadVenues();
      if (!mounted || !current()) return;
      if (_tabController.index == 1) {
        await _loadAppointments();
      }
    } catch (e) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('登录未完成: ${campusError(e)}')));
      }
    } finally {
      if (mounted && current()) {
        setState(() {
          _authenticating = false;
        });
      }
    }
  }

  Future<void> _handleManualReserve() async {
    final venue = _selectedVenue;
    if (venue == null || !_canReserve) return;
    final epoch = _accountEpoch;
    final plans = _selection.values
        .where((v) => v.isNotEmpty)
        .map(
          (v) => {
            'period_id': v.first.periodId,
            'time': v.first.time,
            'courts': v.map((c) => c.courtId).toList(),
          },
        )
        .toList();
    setState(() => _reserving = true);
    try {
      final result = await _api.call('venues.reservePlan', {
        'venue_id': venue.id,
        'target_date': _formatDate(_selectedDate),
        'slots': plans,
      });
      if (!mounted || epoch != _accountEpoch) return;
      final successes = result is Map
          ? (result['successes'] as List? ?? [])
          : [];
      final message = result is Map ? result['message'] : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            successes.length == plans.length
                ? '预约成功！'
                : '已约 ${successes.length}/${plans.length} 个时段：${message ?? "未全部成功"}',
          ),
        ),
      );
      _clearSelection();
      await _loadCalendar();
      await _loadAppointments();
    } catch (e) {
      if (!mounted || epoch != _accountEpoch) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(campusError(e))));
      // Reload the durable journal even if this write timed out before returning an id.
      await _loadAppointments();
    } finally {
      if (mounted && epoch == _accountEpoch) setState(() => _reserving = false);
    }
  }

  Future<void> _handleReconcile(String? task) async {
    final epoch = _accountEpoch;
    bool current() => mounted && epoch == _accountEpoch;
    if (task == null || task.isEmpty) return;
    try {
      final res = await _api.call('venues.reconcile', {'task_id': task});
      if (mounted && current()) {
        final reconciled = res is Map && res['status'] == 'reconciled_success';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(reconciled ? '已在预约记录中确认。' : '暂未匹配到这次预约，仍需核对。'),
          ),
        );
        _loadAppointments();
      }
    } catch (e) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('核对异常: ${campusError(e)}')));
      }
    }
  }

  Future<void> _handleCancelAppointment(VenueAppointment appt) async {
    final epoch = _accountEpoch;
    bool current() => mounted && epoch == _accountEpoch;
    if (_cancellingId != null) return;
    setState(() {
      _cancellingId = appt.id;
    });

    try {
      // Backend presents ONE native ModernSheet for confirmation.
      // Flutter does NOT display a second confirmation dialog.
      final res = await _api.call('venues.cancel', {'appointment_id': appt.id});

      if (!mounted || !current()) return;

      final isUncertain =
          res is Map &&
          (res['status'] == 'uncertain' ||
              res['status'] == 'needs_reconciliation');

      if (isUncertain) {
        setState(() {
          _uncertainCancelIds.add(appt.id);
        });
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('取消状态未确定，需核对'),
            action: SnackBarAction(
              label: '核对',
              onPressed: () => _handleReconcileCancel(appt.id),
            ),
          ),
        );
      } else {
        // Do not fake success: verify cancellation status
        final status = res is Map ? res['status'] : null;
        final isSuccess =
            status == 'success' ||
            status == 'OK' ||
            status == 'cancelled' ||
            (res is Map && res['cancelled'] == true);

        if (isSuccess) {
          setState(() {
            _uncertainCancelIds.remove(appt.id);
          });
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('预约已取消')));
        } else {
          final msg = res is Map
              ? (res['message'] ?? res['reason'] ?? '取消未成功')
              : '取消未成功';
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('取消失败: $msg')));
        }
      }

      await _loadAppointments();
    } catch (e) {
      if (!mounted || !current()) return;
      final isReconcile =
          e is PlatformException &&
          (e.code == 'NeedsReconciliation' ||
              e.code == 'Uncertain' ||
              e.code == 'WriteTimeout');

      if (isReconcile) {
        setState(() {
          _uncertainCancelIds.add(appt.id);
        });
      }

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isReconcile
                ? '取消状态待核对: ${campusError(e)}'
                : '取消失败: ${campusError(e)}',
          ),
          action: isReconcile
              ? SnackBarAction(
                  label: '核对',
                  onPressed: () => _handleReconcileCancel(appt.id),
                )
              : null,
        ),
      );
    } finally {
      if (mounted && current()) {
        setState(() {
          _cancellingId = null;
        });
      }
    }
  }

  Future<void> _handleReconcileCancel(int appointmentId) async {
    final epoch = _accountEpoch;
    bool current() => mounted && epoch == _accountEpoch;
    try {
      final res = await _api.call('venues.reconcileCancel', {
        'appointment_id': appointmentId,
      });

      if (!mounted || !current()) return;

      final isCancelled =
          res is Map &&
          (res['status'] == 'success' ||
              res['status'] == 'cancelled' ||
              res['status'] == 'reconciled_cancelled' ||
              res['status'] == 'reconciled_cancel' ||
              res['status'] == 'reconciled_success' ||
              res['cancelled'] == true ||
              res['reconciled'] == true);

      final isStillUncertain =
          res is Map &&
          (res['status'] == 'needs_reconciliation' ||
              res['status'] == 'uncertain');

      ScaffoldMessenger.of(context).clearSnackBars();
      if (isCancelled) {
        setState(() {
          _uncertainCancelIds.remove(appointmentId);
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('核对完成: 预约已取消')));
      } else if (isStillUncertain) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('核对状态: 取消结果仍未确认，稍后重试')));
      } else {
        setState(() {
          _uncertainCancelIds.remove(appointmentId);
        });
        final msg = res is Map ? (res['message'] ?? '预约仍有效或未取消') : '未取消';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('核对结果: $msg')));
      }

      await _loadAppointments();
    } catch (e) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('核对异常: ${campusError(e)}')));
      }
    }
  }

  void _navigateToAutomationTask() {
    final plugin = _automationPlugin;
    if (plugin == null) return;

    final manifest = plugin['manifest'] is Map<String, dynamic>
        ? plugin['manifest'] as Map<String, dynamic>
        : plugin;

    final uiList = manifest['ui'] as List<dynamic>? ?? [];
    Map<String, dynamic>? scheduleEntry;
    for (final item in uiList) {
      if (item is Map &&
          (item['id'] == 'sports_schedule' || item['type'] == 'form')) {
        scheduleEntry = Map<String, dynamic>.from(item);
        break;
      }
    }
    scheduleEntry ??= uiList.isNotEmpty && uiList.first is Map
        ? Map<String, dynamic>.from(uiList.first as Map)
        : null;

    if (scheduleEntry == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('定时插件未声明预约配置界面')));
      return;
    }

    final declaration = UiDeclarationModel.fromJson(scheduleEntry);

    final initialValues = <String, dynamic>{
      if (_selectedVenue != null) 'venue_id': _selectedVenue!.id,
      'target_date': _formatDate(_selectedDate),
      'selected_slots': [
        for (final courts in _selection.values.where((v) => v.isNotEmpty))
          jsonEncode({
            'time': courts.first.time,
            'period_id': courts.first.periodId,
            'court_id': courts.first.courtId,
            'courts': courts.map((c) => c.courtId).toList(),
            'court_name': courts.first.courtName,
          }),
      ],
    };

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SchemaScreen(
          pluginId: 'official.fudan-sports',
          declaration: declaration,
          client: widget.controller.client,
          activeAccountId: widget.controller.activeAccountId,
          initialValues: initialValues,
          onRefresh: () => widget.controller.refreshAll(),
          componentChanges: widget.controller.componentChanges,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('体育场馆预约'),
        actions: [
          if (_automationPlugin != null)
            IconButton(
              tooltip: '任务中心',
              icon: const Icon(Icons.task_alt),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TasksScreen(controller: widget.controller),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              if (_tabController.index == 0) {
                _loadCalendar();
              } else {
                _loadAppointments();
              }
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '场地预约', icon: Icon(Icons.sports_tennis_outlined)),
            Tab(text: '我的预约', icon: Icon(Icons.history_outlined)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildBookingTab(), _buildAppointmentsTab()],
      ),
      bottomNavigationBar: _buildBottomActionBar(),
    );
  }

  Widget _buildBookingTab() {
    if (_loadingVenues) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_venuesError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              Text(
                _venuesError!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _authenticating ? null : _handleVisibleLogin,
                icon: const Icon(Icons.login),
                label: Text(_authenticating ? '正在登录...' : '统一身份认证登录'),
              ),
              const SizedBox(height: 8),
              TextButton(onPressed: _loadVenues, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadCalendar,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          TextField(
            decoration: const InputDecoration(
              labelText: '搜索场馆',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _search = value.trim()),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            children: [
              for (final campus in [
                '全部校区',
                '邯郸校区',
                '江湾校区',
                '枫林校区',
                '张江校区',
                '其他校区',
              ])
                ChoiceChip(
                  label: Text(campus),
                  selected: (_campus ?? '全部校区') == campus,
                  onSelected: (_) => setState(
                    () => _campus = campus == '全部校区' ? null : campus,
                  ),
                ),
            ],
          ),
          _buildVenueSelector(),
          const SizedBox(height: 16),
          _buildDateSelector(),
          const SizedBox(height: 20),
          _buildSlotSectionHeader(),
          const SizedBox(height: 12),
          _buildSlotsGrid(),
        ],
      ),
    );
  }

  Widget _buildVenueSelector() {
    final venues = _venues
        .where(
          (v) =>
              (_campus == null || v.campus == _campus) &&
              v.name.toLowerCase().contains(_search.toLowerCase()),
        )
        .toList();
    if (venues.isEmpty) {
      return const Padding(padding: EdgeInsets.all(16), child: Text('没有匹配的场馆'));
    }
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            isExpanded: true,
            hint: const Text('请选择场馆'),
            value: venues.any((v) => v.id == _selectedVenue?.id)
                ? _selectedVenue?.id
                : null,
            items: venues.map((v) {
              return DropdownMenuItem<int>(
                value: v.id,
                child: Text(
                  v.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              );
            }).toList(),
            onChanged: (id) {
              if (id == null) return;
              final found = _venues.firstWhere((v) => v.id == id);
              setState(() {
                _selectedVenue = found;
                _clearSelection();
              });
              _loadCalendar();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDateSelector() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final dates = List.generate(7, (i) => now.add(Duration(days: i)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          key: const Key('venue_date_row'),
          children: [
            Expanded(
              child: Text(
                '预约日期: ${_formatDate(_selectedDate)}',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.calendar_month, size: 20),
              tooltip: '选择更多日期',
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(now.year, now.month, now.day),
                  lastDate: now.add(const Duration(days: 60)),
                );
                if (picked != null) {
                  setState(() {
                    _selectedDate = picked;
                    _clearSelection();
                  });
                  _loadCalendar();
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Wrap(
            children: dates.map((d) {
              final isSelected =
                  d.year == _selectedDate.year &&
                  d.month == _selectedDate.month &&
                  d.day == _selectedDate.day;
              final label = '${d.month}/${d.day}';
              final weekday = switch (d.weekday) {
                1 => '周一',
                2 => '周二',
                3 => '周三',
                4 => '周四',
                5 => '周五',
                6 => '周六',
                7 => '周日',
                _ => '',
              };

              return Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: ChoiceChip(
                  label: Text('$label $weekday'),
                  selected: isSelected,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedDate = d;
                        _clearSelection();
                      });
                      _loadCalendar();
                    }
                  },
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildSlotSectionHeader() {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      children: [
        Text(
          '可用场次与时段',
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (_automationPlugin != null)
          OutlinedButton.icon(
            onPressed: _navigateToAutomationTask,
            icon: const Icon(Icons.alarm_add_outlined, size: 18),
            label: const Text('创建定时任务'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    );
  }

  Widget _buildSlotsGrid() {
    if (_loadingSlots) return const Center(child: CircularProgressIndicator());
    if (_slotsError != null) {
      return Column(
        children: [
          Text(_slotsError!),
          TextButton(onPressed: _loadCalendar, child: const Text('重试')),
        ],
      );
    }
    if (_slots.isEmpty) return const Text('当前日期暂无可预约时段');
    final periods = <int, List<VenueSlot>>{};
    for (final slot in _slots) {
      periods.putIfAbsent(slot.periodId, () => []).add(slot);
    }
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('最多选择 3 个时段；每个时段按点选顺序尝试场地。'),
        for (final period in periods.entries) ...[
          CheckboxListTile(
            key: ValueKey('period-${period.key}'),
            title: Text(period.value.first.time),
            subtitle: Text(
              period.value.first.upcoming(_selectedDate, now)
                  ? '${period.value.where((c) => c.available).length} 个场地可约'
                  : '已开始或已结束',
            ),
            value: _selection.containsKey(period.key),
            onChanged:
                _reserving || !period.value.first.upcoming(_selectedDate, now)
                ? null
                : (value) {
                    if (value == true && _selection.length >= 3) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('最多选择 3 个时段')),
                      );
                      return;
                    }
                    setState(() {
                      if (value == true) {
                        _selection[period.key] = [];
                      } else {
                        _selection.remove(period.key);
                      }
                    });
                  },
          ),
          if (_selection.containsKey(period.key))
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final slot in period.value)
                  Builder(
                    builder: (context) {
                      final courts = _selection[period.key]!;
                      final priority = courts.indexWhere(
                        (c) => c.courtId == slot.courtId,
                      );
                      return FilterChip(
                        key: ValueKey('court-${period.key}-${slot.courtId}'),
                        showCheckmark: false,
                        label: Text(
                          '${slot.courtName} · ${slot.available ? "可约" : "满"}',
                        ),
                        avatar: priority < 0
                            ? null
                            : CircleAvatar(child: Text('${priority + 1}')),
                        selected: priority >= 0,
                        onSelected: _reserving
                            ? null
                            : (_) => setState(() {
                                if (priority >= 0) {
                                  courts.removeAt(priority);
                                } else {
                                  courts.add(slot);
                                }
                              }),
                      );
                    },
                  ),
              ],
            ),
        ],
      ],
    );
  }

  Widget? _buildBottomActionBar() {
    if (_tabController.index != 0) return null;

    final slot = _selectedSlot;
    final venue = _selectedVenue;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16.0),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (slot != null && venue != null) ...[
              Row(
                children: [
                  const Icon(Icons.event_seat_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已选: ${venue.name} · ${_selection.length} 个时段',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: !_canReserve ? null : _handleManualReserve,
                    icon: _reserving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(_reserving ? '正在预约...' : '立即预约'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppointmentsTab() {
    final hasUncertainReservations = _uncertain.isNotEmpty;
    final hasUncertainCancels = _uncertainCancelIds.isNotEmpty;

    if (!hasUncertainReservations && !hasUncertainCancels) {
      return _historyBody();
    }

    return Column(
      children: [
        for (final row in _uncertain.take(3))
          ListTile(
            leading: const Icon(Icons.pending_outlined, color: Colors.orange),
            title: Text('预约待核对 · ${row['target_date']} ${row['time']}'),
            trailing: TextButton(
              onPressed: () => _handleReconcile(row['task_id']?.toString()),
              child: const Text('核对'),
            ),
          ),
        for (final id in _uncertainCancelIds)
          ListTile(
            leading: const Icon(
              Icons.sync_problem_outlined,
              color: Colors.deepOrange,
            ),
            title: Text('取消待核对 · 预约号 #$id'),
            trailing: TextButton(
              onPressed: () => _handleReconcileCancel(id),
              child: const Text('核对'),
            ),
          ),
        Expanded(child: _historyBody()),
      ],
    );
  }

  Widget _historyBody() {
    if (_loadingAppointments) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_appointmentsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_appointmentsError!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _loadAppointments,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (_appointments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text('暂无预约记录', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: _loadAppointments,
              child: const Text('刷新记录'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAppointments,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _appointments.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final item = _appointments[index];
          return _buildAppointmentCard(item);
        },
      ),
    );
  }

  Widget _buildAppointmentCard(VenueAppointment item) {
    final isCancelling = _cancellingId == item.id;
    final isUncertainCancel = _uncertainCancelIds.contains(item.id);

    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest
          .withValues(alpha: 0.5),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          final epoch = _accountEpoch;
          try {
            final detail = await _api.call('venues.detail', {
              'appointment_id': item.id,
            });
            if (!mounted || epoch != _accountEpoch) return;
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(
                  item.resourceName.isNotEmpty ? item.resourceName : '预约详情',
                ),
                content: SingleChildScrollView(
                  child: Text(
                    [
                      '预约号：${item.id}',
                      item.statusName,
                      for (final slot in item.slots)
                        '${slot.date} ${slot.time} ${slot.resourceName}',
                      if (detail is Map && detail['code'] != null)
                        '凭证：${detail['code']}',
                    ].where((line) => line.isNotEmpty).join('\n'),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      try {
                        await _api.call('venues.openVoucher', {
                          'appointment_id': item.id,
                        });
                      } catch (e) {
                        if (mounted && epoch == _accountEpoch) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(campusError(e))),
                          );
                        }
                      }
                    },
                    child: const Text('查看预约凭证'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            );
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('查看详情失败: ${campusError(e)}')),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.resourceName.isNotEmpty
                          ? item.resourceName
                          : '场馆预约 #${item.id}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.statusName.isNotEmpty
                          ? item.statusName
                          : (item.status?.toString() ?? '已预约'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (item.slots.isNotEmpty) ...[
                for (final slot in item.slots)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4.0),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.schedule_outlined,
                          size: 16,
                          color: Colors.grey,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '${slot.date} ${slot.time} ${slot.resourceName}'
                                .trim(),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        if (!slot.active)
                          const Text(
                            '已失效',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          )
                        else if (!slot.canCancel &&
                            slot.cancelMessage.isNotEmpty)
                          Text(
                            slot.cancelMessage,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                      ],
                    ),
                  ),
              ] else ...[
                Row(
                  children: [
                    const Icon(
                      Icons.schedule_outlined,
                      size: 16,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${item.date} ${item.time} ${item.courtName}'.trim(),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ],
              if (item.canCancel || isUncertainCancel) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: isUncertainCancel
                      ? OutlinedButton.icon(
                          onPressed: () => _handleReconcileCancel(item.id),
                          icon: const Icon(
                            Icons.sync_problem_outlined,
                            size: 16,
                          ),
                          label: const Text('核对'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.deepOrange,
                            visualDensity: VisualDensity.compact,
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: isCancelling
                              ? null
                              : () => _handleCancelAppointment(item),
                          icon: isCancelling
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.cancel_outlined, size: 16),
                          label: Text(isCancelling ? '正在取消...' : '取消这条预约'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                ),
              ] else if (item.displayCancelMessage.isNotEmpty) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    item.displayCancelMessage,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
