import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../campus_api.dart';

class PowerAlertSettingsPage extends StatefulWidget {
  const PowerAlertSettingsPage({super.key, required this.controller});
  final DanshengController controller;
  @override
  State<PowerAlertSettingsPage> createState() => _PowerAlertSettingsState();
}

class _PowerAlertSettingsState extends State<PowerAlertSettingsPage>
    with WidgetsBindingObserver {
  late final api = CampusApi(widget.controller.client);
  final threshold = TextEditingController();
  bool enabled = false, busy = false, loaded = false;
  String? account, problem;
  Map? state;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    account = widget.controller.activeAccountId;
    widget.controller.addListener(changed);
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    threshold.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed && !busy) load();
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
      busy = true;
      problem = null;
      state = null;
      loaded = false;
    });
    if (active == null) {
      setState(() => busy = false);
      return;
    }
    try {
      final response = await api.call('powerAlert.get');
      if (!mounted || ticket != generation || active != account) return;
      if (response is! Map || response['threshold_kwh'] is! num) {
        throw const FormatException('Invalid alert state');
      }
      setState(() {
        state = response;
        enabled = response['enabled'] == true;
        threshold.text = response['threshold_kwh'].toString();
        loaded = true;
      });
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => problem = campusError(e));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || !loaded) return;
    final value = enabled
        ? double.tryParse(threshold.text.trim())
        : (state?['threshold_kwh'] as num?)?.toDouble() ?? 5.0;
    if (value == null || !value.isFinite || value <= 0) {
      setState(() => problem = '请输入大于零的剩余电量');
      return;
    }
    final active = account, ticket = ++generation;
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      if (enabled) {
        var permissions = await widget.controller.client.getPermissions();
        if (permissions['notifications_available'] != true) {
          await widget.controller.client.requestNotifications();
          permissions = await widget.controller.client.getPermissions();
        }
        if (permissions['notifications_available'] != true) {
          throw StateError('NotificationPermissionRequired');
        }
      }
      if (!mounted || ticket != generation || active != account) return;
      final response = await api.call('powerAlert.set', {
        'enabled': enabled,
        'threshold_kwh': value,
      });
      if (!mounted || ticket != generation || active != account) return;
      if (response is! Map) throw const FormatException('Invalid alert state');
      setState(() => state = response);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(enabled ? '已开启预警并安排检查' : '已关闭电量预警')),
      );
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(
          () =>
              problem = e.toString().contains('NotificationPermissionRequired')
              ? '请先允许应用通知'
              : campusError(e),
        );
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  Future<void> check() async {
    final active = account, ticket = ++generation;
    setState(() {
      busy = true;
      problem = null;
    });
    try {
      final response = await api.call('powerAlert.check');
      if (mounted &&
          ticket == generation &&
          active == account &&
          response is Map) {
        setState(() => state = response);
      }
    } catch (e) {
      if (mounted && ticket == generation) {
        setState(() => problem = campusError(e));
      }
    } finally {
      if (mounted && ticket == generation) setState(() => busy = false);
    }
  }

  String time(dynamic stamp) => stamp is num
      ? DateTime.fromMillisecondsSinceEpoch(stamp.toInt())
            .toLocal()
            .toString()
            .split('.')
            .first
      : '尚无';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('电量预警提醒'),
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
        if (account == null) const ListTile(title: Text('未设置账号')),
        if (busy) const LinearProgressIndicator(),
        SwitchListTile(
          key: const Key('power_alert_enabled'),
          title: const Text('开启剩余电量预警'),
          value: enabled,
          onChanged: busy || !loaded
              ? null
              : (value) => setState(() => enabled = value),
        ),
        TextField(
          key: const Key('power_alert_threshold'),
          controller: threshold,
          enabled: !busy && loaded,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: '剩余电量阈值',
            suffixText: 'kWh',
            helperText: '剩余电量不高于此值时提醒',
          ),
        ),
        const SizedBox(height: 16),
        const Text('约每小时联网检查一次。系统节电可能延后；同一次低电量只提醒一次，补电超过阈值后会重新启用提醒。'),
        const SizedBox(height: 16),
        FilledButton(
          key: const Key('power_alert_save'),
          onPressed: busy || !loaded ? null : save,
          child: const Text('保存设置'),
        ),
        if (problem != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(problem!),
          ),
        TextButton(
          onPressed: () => api.call('powerAlert.notificationSettings'),
          child: const Text('打开系统通知设置'),
        ),
        if (state != null) ...[
          if (state!['enabled'] == true &&
              state!['notifications_available'] != true)
            const ListTile(title: Text('系统通知未允许，预警无法送达')),
          ListTile(
            title: Text(state!['enabled'] == true ? '预警已开启' : '预警未开启'),
            subtitle: Text(
              state!['background_scheduled'] == true ? '后台检查已安排' : '后台检查未安排',
            ),
          ),
          ListTile(
            title: const Text('最近检查'),
            subtitle: Text(time(state!['last_checked_ms'])),
          ),
          if (state!['remaining_kwh'] is num)
            ListTile(
              title: const Text('上次成功读取的剩余电量'),
              subtitle: Text('${state!['remaining_kwh']} kWh'),
            ),
          if (state!['last_error'] != null)
            ListTile(
              title: const Text('检查未成功'),
              subtitle: Text(
                state!['last_error'] == 'AuthenticationRequired'
                    ? '请返回电量页面登录校园服务后重试'
                    : '网络或校园服务暂不可用，后续将继续检查',
              ),
            ),
          ListTile(
            title: const Text('最近提醒'),
            subtitle: Text(time(state!['last_notified_ms'])),
          ),
          OutlinedButton(
            onPressed: busy || state!['enabled'] != true ? null : check,
            child: const Text('立即检查'),
          ),
        ],
      ],
    ),
  );
}
