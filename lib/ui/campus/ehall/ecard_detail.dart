import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dansheng_state.dart';
import '../../screens/account_balance_screen.dart';
import '../campus_api.dart';
import 'statistics_period_picker.dart';

DateTime _campusToday() => DateTime.now().toUtc().add(const Duration(hours: 8));
String _day(DateTime d) => d.toIso8601String().substring(0, 10);
String _money(dynamic cents) =>
    cents is num ? (cents / 100).toStringAsFixed(2) : '—';
Map _payload(dynamic value) => value is Map && value['payload'] is Map
    ? value['payload'] as Map
    : value is Map
    ? value
    : const {};

class EcardDetailPage extends StatefulWidget {
  const EcardDetailPage({
    super.key,
    required this.controller,
    this.initialDate,
  });
  final DanshengController controller;
  final DateTime? initialDate;
  @override
  State<EcardDetailPage> createState() => _EcardDetailState();
}

class _EcardDetailState extends State<EcardDetailPage> {
  late final api = CampusApi(widget.controller.client);
  late DateTime day = widget.initialDate ?? _campusToday();
  String? account, problem;
  int generation = 0;
  bool busy = false, cached = false, needsLogin = false;
  List<Map> records = [];
  @override
  void initState() {
    super.initState();
    account = widget.controller.activeAccountId;
    widget.controller.addListener(changed);
    load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (account != widget.controller.activeAccountId) {
      account = widget.controller.activeAccountId;
      load();
    }
  }

  Future<void> load() async {
    final ticket = ++generation, active = account;
    setState(() {
      busy = active != null;
      problem = null;
      records = [];
      cached = false;
      needsLogin = false;
    });
    if (active == null) return;
    final input = {'from': _day(day), 'to': _day(day)};
    try {
      final result = await api.call('fudan.ecard.statement', input);
      if (!mounted || ticket != generation || active != account) return;
      final rows = result is Map ? result['records'] : null;
      final coverage = result is Map ? result['coverage'] : null;
      if (rows is! List ||
          coverage is! Map ||
          coverage['state'] != 'complete') {
        throw const FormatException('Incomplete statement');
      }
      setState(() => records = rows.map(_payload).toList());
    } catch (e) {
      dynamic old;
      try {
        old = await api.call('campus.cached', {
          'method': 'fudan.ecard.statement',
          ...input,
        });
      } catch (_) {}
      if (!mounted || ticket != generation || active != account) return;
      setState(() {
        problem = campusError(e);
        final code = e is PlatformException ? e.code : e.toString();
        needsLogin = [
          'AuthenticationRequired',
          'InvalidCredentials',
          'InteractiveLoginRequired',
        ].any(code.contains);
        if (old is Map &&
            old['records'] is List &&
            old['coverage'] is Map &&
            old['coverage']['state'] == 'complete') {
          records = (old['records'] as List).map(_payload).toList();
          cached = true;
        }
      });
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> chooseDay() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: day,
      firstDate: DateTime(2020),
      lastDate: _campusToday(),
      helpText: '选择明细日期',
    );
    if (selected != null && mounted) {
      setState(() => day = selected);
      await load();
    }
  }

  Future<void> login() async {
    final active = account;
    try {
      await api.call('campus.login', {'service': 'ecard'});
      if (mounted && active == account) await load();
    } catch (e) {
      if (mounted && active == account) {
        setState(() => problem = campusError(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('校园卡明细'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            key: const Key('ecard_date'),
            leading: const Icon(Icons.calendar_today_outlined),
            title: Text(_day(day)),
            trailing: const Icon(Icons.expand_more),
            onTap: chooseDay,
          ),
        ),
        Card(
          child: ListTile(
            key: const Key('ecard_statistics_entry'),
            leading: const Icon(Icons.bar_chart),
            title: const Text('支出统计'),
            subtitle: const Text('按周、月、年查看各项支出'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => EcardStatisticsPage(
                  controller: widget.controller,
                  initialDate: day,
                ),
              ),
            ),
          ),
        ),
        if (account == null)
          ListTile(
            title: const Text('未设置账号'),
            trailing: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AccountBalanceScreen(controller: widget.controller),
                ),
              ),
              child: const Text('设置账号'),
            ),
          ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (problem != null)
          ListTile(
            title: Text(cached ? '显示缓存 · $problem' : problem!),
            trailing: TextButton(onPressed: load, child: const Text('重试')),
          ),
        if (!busy && problem == null && account != null && records.isEmpty)
          const ListTile(title: Text('当日暂无明细')),
        if (needsLogin)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: login,
              icon: const Icon(Icons.login),
              label: const Text('登录校园卡'),
            ),
          ),
        for (final row in records)
          Builder(
            builder: (context) {
              final at = DateTime.tryParse(row['at']?.toString() ?? '')
                  ?.toUtc()
                  .add(const Duration(hours: 8));
              final time = at == null
                  ? ''
                  : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
              final amount = row['amount'];
              return ListTile(
                title: Text(row['location']?.toString() ?? '未标注'),
                subtitle: Text(
                  '${_day(day)} $time · ${row['transaction_type'] ?? ''}',
                ),
                trailing: Text(
                  '¥ ${_money(amount is Map ? amount['cents'] : null)}',
                ),
              );
            },
          ),
      ],
    ),
  );
}

class EcardStatisticsPage extends StatefulWidget {
  const EcardStatisticsPage({
    super.key,
    required this.controller,
    required this.initialDate,
  });
  final DanshengController controller;
  final DateTime initialDate;
  @override
  State<EcardStatisticsPage> createState() => _EcardStatisticsState();
}

class _EcardStatisticsState extends State<EcardStatisticsPage> {
  late final api = CampusApi(widget.controller.client);
  late DateTime anchor = widget.initialDate;
  String period = 'month';
  String? account, problem;
  int generation = 0;
  bool busy = false;
  Map? summary;
  @override
  void initState() {
    super.initState();
    account = widget.controller.activeAccountId;
    widget.controller.addListener(changed);
    load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    super.dispose();
  }

  void changed() {
    if (account != widget.controller.activeAccountId) {
      account = widget.controller.activeAccountId;
      load();
    }
  }

  Future<void> load() async {
    final ticket = ++generation, active = account;
    setState(() {
      summary = null;
      problem = null;
      busy = active != null;
    });
    if (active == null) return;
    try {
      final result = await api.call('fudan.ecard.statistics', {
        'period': period,
        'date': _day(anchor),
      });
      if (!mounted || ticket != generation || active != account) return;
      final data = _payload(result);
      if (data['complete'] != true ||
          data['expense_cents'] is! num ||
          DateTime.tryParse(data['from']?.toString() ?? '') == null ||
          DateTime.tryParse(data['to']?.toString() ?? '') == null) {
        throw const FormatException('Incomplete statistics');
      }
      setState(() => summary = data);
    } catch (e) {
      if (mounted && ticket == generation && active == account) {
        setState(() => problem = campusError(e));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> pickDate() async {
    final value = await showStatisticsPeriodPicker(
      context,
      period: period,
      selected: anchor,
      today: _campusToday(),
    );
    if (value != null && mounted) {
      setState(() => anchor = value);
      await load();
    }
  }

  String periodLabel() {
    if (period == 'year') return '${anchor.year}年';
    if (period == 'month') return '${anchor.year}年 ${anchor.month}月';
    final start = DateTime.tryParse(summary?['from']?.toString() ?? '');
    final end = DateTime.tryParse(summary?['to']?.toString() ?? '');
    return start == null || end == null
        ? '选择整周'
        : '${start.year}年 ${start.month}/${start.day}—${end.month}/${end.day}';
  }

  void step(bool forward) {
    final raw = summary?[forward ? 'to' : 'from']?.toString();
    final date = DateTime.tryParse(raw ?? '');
    if (date == null) return;
    final next = DateTime(date.year, date.month, date.day + (forward ? 1 : -1));
    if (_day(next).compareTo(_day(_campusToday())) > 0) return;
    setState(() => anchor = next);
    load();
  }

  Widget groups(String title, String field) {
    final rows = summary?[field] as List? ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (rows.isEmpty) const ListTile(title: Text('暂无支出')),
        for (final row in rows.whereType<Map>())
          ListTile(
            title: Text(row['name']?.toString() ?? '未标注'),
            subtitle: Text('${row['count']} 笔'),
            trailing: Text('¥ ${_money(row['expense_cents'])}'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('校园卡支出统计'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final entry in {
              'week': '周',
              'month': '月',
              'year': '年',
            }.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: period == entry.key,
                onSelected: (_) {
                  setState(() => period = entry.key);
                  load();
                },
              ),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: '上一周期',
              onPressed: busy || summary == null ? null : () => step(false),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: TextButton.icon(
                key: const Key('ecard_period_picker'),
                onPressed: pickDate,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text(periodLabel()),
              ),
            ),
            IconButton(
              tooltip: '下一周期',
              onPressed:
                  busy ||
                      summary == null ||
                      summary!['to'].toString().compareTo(
                            _day(_campusToday()),
                          ) >=
                          0
                  ? null
                  : () => step(true),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (account == null) const ListTile(title: Text('未设置账号')),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (problem != null)
          ListTile(
            title: Text(problem!),
            trailing: TextButton(onPressed: load, child: const Text('重试')),
          ),
        if (summary != null) ...[
          Text(
            '${summary!['from']} 至 ${summary!['to']}',
            textAlign: TextAlign.center,
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('支出合计'),
                  Text(
                    '¥ ${_money(summary!['expense_cents'])}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text('入账合计 ¥ ${_money(summary!['income_cents'])}（含充值、退款等）'),
                  Text('共 ${summary!['record_count']} 笔记录；支出不抵扣入账'),
                  if ((summary!['unclassified_count'] as num? ?? 0) > 0)
                    Text(
                      '${summary!['unclassified_count']} 笔待分类记录未计入支出或入账，请对照明细查看',
                    ),
                ],
              ),
            ),
          ),
          groups('按交易类型', 'by_type'),
          groups('按商户', 'by_location'),
        ],
      ],
    ),
  );
}
