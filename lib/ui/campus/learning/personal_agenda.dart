import 'package:flutter/material.dart';

import '../campus_api.dart';

class PersonalAgenda extends StatefulWidget {
  const PersonalAgenda({
    super.key,
    required this.api,
    required this.day,
    required this.account,
  });
  final CampusApi api;
  final DateTime day;
  final String? account;
  @override
  State<PersonalAgenda> createState() => _AgendaState();
}

class _AgendaState extends State<PersonalAgenda> {
  int seq = 0;
  List<Map> rows = [];
  String? error;
  String get date => widget.day.toIso8601String().split('T').first;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant PersonalAgenda old) {
    super.didUpdateWidget(old);
    if (old.day != widget.day || old.account != widget.account) load();
  }

  Future<void> load() async {
    final n = ++seq;
    rows = [];
    error = null;
    if (widget.account == null) return;
    try {
      final raw = await widget.api.call('agenda.list', {'date': date});
      if (mounted && seq == n) {
        setState(() => rows = (raw as List).whereType<Map>().toList());
      }
    } catch (e) {
      if (mounted && seq == n) setState(() => error = campusError(e));
    }
  }

  Future<void> add() async {
    final stamp = date, account = widget.account;
    final title = await showDialog<String>(
      context: context,
      builder: (d) {
        var description = '';
        return AlertDialog(
          title: const Text('添加个人日程'),
          content: TextField(
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(labelText: '事项'),
            onChanged: (v) => description = v,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, description.trim()),
              child: const Text('选时间'),
            ),
          ],
        );
      },
    );
    if (title == null || title.isEmpty || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    if (time == null || !mounted || account != widget.account) return;
    final start =
        '${stamp}T${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:00+08:00';
    final end = DateTime.parse(start)
        .add(const Duration(hours: 1))
        .toUtc()
        .toIso8601String();
    try {
      await widget.api.call('agenda.add', {
        'title': title,
        'start_at': start,
        'end_at': end,
      });
      if (mounted) await load();
    } catch (e) {
      if (mounted) setState(() => error = campusError(e));
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        ListTile(
          title: const Text('个人日程'),
          subtitle: rows.isEmpty ? Text(error ?? '当天没有个人日程') : null,
          trailing: IconButton(
            tooltip: '添加个人日程',
            onPressed: widget.account == null ? null : add,
            icon: const Icon(Icons.add),
          ),
        ),
        for (final r in rows)
          ListTile(
            leading: const Icon(Icons.event_outlined),
            title: Text(r['title']?.toString() ?? '日程'),
            subtitle: Text(_time(r['start_at'])),
            trailing: IconButton(
              tooltip: '移除个人日程',
              icon: const Icon(Icons.close),
              onPressed: () async {
                try {
                  await widget.api.call('agenda.remove', {'id': r['id']});
                  if (mounted) await load();
                } catch (e) {
                  if (mounted) setState(() => error = campusError(e));
                }
              },
            ),
          ),
      ],
    ),
  );
  String _time(dynamic raw) {
    if (raw == null) return '';
    final parsed = DateTime.tryParse(raw.toString());
    if (parsed == null) return '';
    final local = parsed.toUtc().add(const Duration(hours: 8));
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
