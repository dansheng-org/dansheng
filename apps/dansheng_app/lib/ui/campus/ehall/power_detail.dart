// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../../screens/account_balance_screen.dart';
import '../campus_api.dart';
import 'usage_bar_chart.dart';
import 'power_alert_settings.dart';

/// Represents parsed dorm electricity balance information matching DanXi ElectricityItem.
class ElectricityBalanceInfo {
  final String balance;
  final String? used;
  final String unit;
  final String? updateTime;
  final String? dormName;

  const ElectricityBalanceInfo({
    required this.balance,
    this.used,
    required this.unit,
    this.updateTime,
    this.dormName,
  });
}

/// Represents parsed dorm electricity usage history item matching DanXi ElectricityHistoryItem.
class ElectricityHistoryRecord {
  final String date;
  final String amount;
  final String dormName;

  const ElectricityHistoryRecord({
    required this.date,
    required this.amount,
    required this.dormName,
  });
}

/// Detail page for dorm electricity balance and usage history.
///
/// Matches DanXi `dorm_electricity_feature.dart` and `data_center_repository.dart`.
/// Displays real balance/unit/date on top via `fudan.electricity` (zlapp power service),
/// and electricity usage history via `fudan.electricity.history` with pagination,
/// supporting my.fudan.edu.cn 2FA via `campus.verifyDining`.
class PowerDetailPage extends StatefulWidget {
  const PowerDetailPage({super.key, required this.controller});

  final DanshengController controller;

  @override
  State<PowerDetailPage> createState() => _PowerDetailPageState();
}

class _PowerDetailPageState extends State<PowerDetailPage> {
  late final CampusApi _api;
  static const int _pageSize = 20;

  ElectricityBalanceInfo? _balanceInfo;
  bool _loadingBalance = false;
  String? _balanceError;
  bool _balanceAuthRequired = false;
  bool _loggingInPower = false;
  int _balanceTicket = 0;

  List<ElectricityHistoryRecord> _historyRecords = [];
  bool _loadingHistory = false;
  bool _loadingMoreHistory = false;
  String? _historyError;
  bool _history2FaRequired = false;
  bool _verifying2Fa = false;
  int _historyOffset = 0;
  bool _hasMoreHistory = true;
  int _historyTicket = 0;

  String _usagePeriod = 'day';
  Map? _usageSummary;
  String? _usageError;
  bool _loadingUsage = false;
  int _usageTicket = 0;
  String? _lastAccountId;

  @override
  void initState() {
    super.initState();
    _api = CampusApi(widget.controller.client);
    _lastAccountId = widget.controller.activeAccountId;
    widget.controller.addListener(_onControllerChange);

    if (_hasAccount) {
      _loadAll();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  bool get _hasAccount =>
      widget.controller.activeAccountId != null &&
      widget.controller.activeAccountId!.isNotEmpty;

  void _onControllerChange() {
    final current = widget.controller.activeAccountId;
    if (current != _lastAccountId) {
      _lastAccountId = current;
      _balanceTicket++;
      _historyTicket++;
      _usageTicket++;
      if (mounted) {
        setState(() {
          _balanceInfo = null;
          _loadingBalance = false;
          _loadingHistory = false;
          _loadingMoreHistory = false;
          _loadingUsage = false;
          _usageSummary = null;
          _usageError = null;
          _balanceError = null;
          _balanceAuthRequired = false;
          _historyRecords.clear();
          _historyError = null;
          _history2FaRequired = false;
          _historyOffset = 0;
          _hasMoreHistory = true;
        });
        if (_hasAccount) {
          _loadAll();
        }
      }
    }
  }

  Future<void> _loadAll() async {
    await Future.wait([
      _loadBalance(),
      _loadHistory(refresh: true),
      _loadUsage(),
    ]);
  }

  bool _isAuthError(Object error) {
    final str = error.toString();
    return str.contains('AuthenticationRequired') ||
        str.contains('NotLoginError') ||
        str.contains('InvalidCredentials') ||
        str.contains('InteractiveLoginRequired') ||
        str.contains('401') ||
        str.contains('postgraduates_need_login') ||
        str.contains('2FA') ||
        str.contains('TwoFactor');
  }

  ElectricityBalanceInfo? _parseBalanceInfo(dynamic response) {
    if (response == null) return null;
    Map map;
    if (response is Map) {
      if (response['payload'] is Map) {
        map = response['payload'] as Map;
      } else if (response['d'] is Map) {
        map = response['d'] as Map;
      } else {
        map = response;
      }
    } else {
      return null;
    }

    final rawBalance =
        map['remaining_kwh'] ??
        map['balance'] ??
        map['fj_surplus'] ??
        map['surplus'] ??
        map['remaining'];
    if (rawBalance == null) return null;

    final balance = rawBalance.toString().trim();
    final used = (map['used_kwh'] ?? map['used'] ?? map['fj_used'])
        ?.toString()
        .trim();
    final unit = (map['unit'] ?? 'kWh').toString().trim();
    final updateTime =
        (map['update_time'] ??
                map['updateTime'] ??
                map['fj_update_time'] ??
                map['updated_at'] ??
                map['date'] ??
                map['t_update_time'])
            ?.toString()
            .trim();

    String? dormName;
    if (map['dorm_name'] != null ||
        map['dormName'] != null ||
        map['room_name'] != null) {
      dormName = (map['dorm_name'] ?? map['dormName'] ?? map['room_name'])
          ?.toString()
          .trim();
    } else {
      final parts =
          [
                map['campus'] ?? map['xq'],
                map['building'] ?? map['ssmc'],
                map['room'] ?? map['fjmc'],
              ]
              .whereType<Object>()
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
      if (parts.isNotEmpty) {
        dormName = parts.join(' ');
      }
    }

    return ElectricityBalanceInfo(
      balance: balance,
      used: used,
      unit: unit.isNotEmpty ? unit : 'kWh',
      updateTime: updateTime,
      dormName: dormName,
    );
  }

  List<ElectricityHistoryRecord> _parseHistoryRecords(dynamic response) {
    if (response == null) return [];
    dynamic listData = response;
    if (listData is Map) {
      if (listData['payload'] is List) {
        listData = listData['payload'];
      } else if (listData['payload'] is Map) {
        final p = listData['payload'] as Map;
        listData = p['records'] ?? p['items'] ?? p['data'] ?? p;
      } else {
        listData =
            listData['records'] ??
            listData['items'] ??
            listData['data'] ??
            listData;
      }
    }

    if (listData is! List) return [];

    final List<ElectricityHistoryRecord> records = [];
    for (final item in listData) {
      if (item is Map) {
        final map = item['payload'] is Map ? (item['payload'] as Map) : item;
        final date =
            (map['date'] ??
                    map['time'] ??
                    map['day'] ??
                    map['datetime'] ??
                    map['record_date'] ??
                    '')
                .toString()
                .trim();
        final amount =
            (map['amount'] ??
                    map['kwh'] ??
                    map['used'] ??
                    map['value'] ??
                    map['usage'] ??
                    '')
                .toString()
                .trim();
        final dormName =
            (map['dorm_name'] ??
                    map['dormName'] ??
                    map['dorm'] ??
                    map['room'] ??
                    map['room_name'] ??
                    map['building'] ??
                    '')
                .toString()
                .trim();
        records.add(
          ElectricityHistoryRecord(
            date: date,
            amount: amount,
            dormName: dormName,
          ),
        );
      } else if (item is List) {
        // DanXi DataCenter raw list: [id, campus, bldg, room, date, amount]
        if (item.length >= 6) {
          final dorm =
              '${item[1].toString().trim()}/${item[2].toString().trim()}/${item[3].toString().trim()}';
          final date = item[4].toString().trim();
          final amount = item[5].toString().trim();
          records.add(
            ElectricityHistoryRecord(
              date: date,
              amount: amount,
              dormName: dorm,
            ),
          );
        } else if (item.length >= 3) {
          records.add(
            ElectricityHistoryRecord(
              date: item[1].toString().trim(),
              amount: item[2].toString().trim(),
              dormName: item[0].toString().trim(),
            ),
          );
        }
      }
    }
    return records;
  }

  Future<void> _loadBalance({bool afterSignIn = false}) async {
    if (!_hasAccount) {
      setState(() {
        _balanceInfo = null;
        _balanceError = '未设置账号，请先绑定复旦统一身份认证账号。';
        _balanceAuthRequired = false;
        _loadingBalance = false;
      });
      return;
    }

    final ticket = ++_balanceTicket;
    final currentAccount = widget.controller.activeAccountId;
    setState(() {
      _loadingBalance = true;
      _balanceError = null;
      _balanceAuthRequired = false;
    });

    try {
      final res = afterSignIn
          ? await _api.readAfterSignIn('fudan.electricity')
          : await _api.call('fudan.electricity');
      if (!mounted ||
          ticket != _balanceTicket ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }
      final info = _parseBalanceInfo(res);
      setState(() {
        _balanceInfo = info;
        _loadingBalance = false;
        _balanceError = info == null ? '未能读取到电量信息' : null;
      });
    } catch (e) {
      if (!mounted ||
          ticket != _balanceTicket ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }
      final isAuth = _isAuthError(e);

      // Attempt cached fallback
      ElectricityBalanceInfo? cachedInfo;
      try {
        final cached = await _api.call('campus.cached', {
          'method': 'fudan.electricity',
        });
        cachedInfo = _parseBalanceInfo(cached);
      } catch (_) {}

      setState(() {
        _loadingBalance = false;
        if (cachedInfo != null) {
          _balanceInfo = cachedInfo;
          _balanceError = '上次缓存数据 · ${campusError(e)}';
          _balanceAuthRequired = isAuth;
        } else {
          _balanceInfo = null;
          _balanceError = campusError(e);
          _balanceAuthRequired = isAuth;
        }
      });
    }
  }

  Future<void> _loginPower() async {
    setState(() => _loggingInPower = true);
    try {
      await _api.call('campus.login', {'service': 'power'});
      if (mounted) {
        await _loadBalance(afterSignIn: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('电量登录失败：${campusError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _loggingInPower = false);
    }
  }

  Future<void> _loadHistory({
    bool refresh = false,
    bool afterSignIn = false,
  }) async {
    if (!_hasAccount) {
      setState(() {
        _historyRecords.clear();
        _historyError = '未设置账号，请先绑定复旦统一身份认证账号。';
        _history2FaRequired = false;
        _loadingHistory = false;
        _loadingMoreHistory = false;
      });
      return;
    }

    if (refresh) {
      _historyOffset = 0;
      _hasMoreHistory = true;
    }

    if (!_hasMoreHistory) return;
    if (_loadingHistory || _loadingMoreHistory) return;

    final isFirstPage = _historyOffset == 0;
    final ticket = ++_historyTicket;
    final currentAccount = widget.controller.activeAccountId;

    setState(() {
      if (isFirstPage) {
        _loadingHistory = true;
        _historyError = null;
        _history2FaRequired = false;
      } else {
        _loadingMoreHistory = true;
      }
    });

    try {
      final res = await (afterSignIn ? _api.readAfterSignIn : _api.call)(
        'fudan.electricity.history',
        {'offset': _historyOffset, 'size': _pageSize},
      );

      if (!mounted ||
          ticket != _historyTicket ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }

      final newItems = _parseHistoryRecords(res);
      setState(() {
        if (isFirstPage) {
          _historyRecords = newItems;
          _loadingHistory = false;
        } else {
          _historyRecords.addAll(newItems);
          _loadingMoreHistory = false;
        }
        _historyOffset += newItems.length;
        if (newItems.length < _pageSize || newItems.isEmpty) {
          _hasMoreHistory = false;
        }
      });
    } catch (e) {
      if (!mounted ||
          ticket != _historyTicket ||
          currentAccount != widget.controller.activeAccountId) {
        return;
      }
      final is2FaOrAuth =
          _isAuthError(e) ||
          e.toString().contains('2FA') ||
          e.toString().contains('verifyDining');

      setState(() {
        _loadingHistory = false;
        _loadingMoreHistory = false;
        _historyError = campusError(e);
        _history2FaRequired = is2FaOrAuth;
      });
    }
  }

  Future<void> _verify2Fa() async {
    setState(() => _verifying2Fa = true);
    try {
      await _api.call('campus.verifyDining', {'service': 'power_history'});
      if (mounted) {
        await Future.wait([
          _loadHistory(refresh: true, afterSignIn: true),
          _loadUsage(afterSignIn: true),
        ]);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('2FA 验证失败：${campusError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _verifying2Fa = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('寝室电量'),
        actions: [
          IconButton(
            key: const Key('power_refresh_button'),
            tooltip: '刷新',
            onPressed: (_loadingBalance || _loadingHistory) ? null : _loadAll,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!_hasAccount) ...[
              _buildNoAccountBanner(colors, textTheme),
            ] else ...[
              _buildBalanceSection(colors, textTheme),
              Card(
                child: ListTile(
                  key: const Key('power_alert_entry'),
                  leading: const Icon(Icons.notifications_active_outlined),
                  title: const Text('设置预警提醒'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PowerAlertSettingsPage(controller: widget.controller),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _buildUsageTrendCard(colors, textTheme),
              const SizedBox(height: 16),
              _buildHistorySection(colors, textTheme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNoAccountBanner(ColorScheme colors, TextTheme textTheme) {
    return Container(
      key: const Key('power_no_account_banner'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_circle_outlined, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                '未设置账号',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '查询寝室电量余额与每日用电历史记录需要先配置复旦统一身份认证账号。',
            style: textTheme.bodySmall?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const Key('power_set_account_button'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    AccountBalanceScreen(controller: widget.controller),
              ),
            ),
            child: const Text('设置账号'),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceSection(ColorScheme colors, TextTheme textTheme) {
    return Material(
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt, color: colors.primary, size: 24),
                const SizedBox(width: 8),
                Text(
                  '寝室电量',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_loadingBalance)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_balanceInfo != null) ...[
              // Real balance and unit on top
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    _balanceInfo!.balance,
                    style: textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _balanceInfo!.unit,
                    style: textTheme.titleMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Dorm Name matching DanXi
              if (_balanceInfo!.dormName != null &&
                  _balanceInfo!.dormName!.isNotEmpty) ...[
                Row(
                  children: [
                    Icon(
                      Icons.home_outlined,
                      size: 16,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _balanceInfo!.dormName!,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              // Subtitle with used amount matching DanXi: dorm_electricity_subtitle
              if (_balanceInfo!.used != null &&
                  _balanceInfo!.used!.isNotEmpty) ...[
                Text(
                  '剩余：${_balanceInfo!.balance} ${_balanceInfo!.unit}；已用：${_balanceInfo!.used} ${_balanceInfo!.unit}',
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              // Date matching DanXi: last_updated
              if (_balanceInfo!.updateTime != null &&
                  _balanceInfo!.updateTime!.isNotEmpty) ...[
                Text(
                  '最近更新：${_balanceInfo!.updateTime}',
                  style: textTheme.bodySmall?.copyWith(color: colors.outline),
                ),
              ],
            ] else if (!_loadingBalance) ...[
              if (_balanceAuthRequired) ...[
                Container(
                  key: const Key('power_balance_auth_notice'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.errorContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.errorContainer),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: colors.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '实时电量服务需要登录统一身份认证',
                              style: textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: colors.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        key: const Key('power_login_button'),
                        onPressed: _loggingInPower ? null : _loginPower,
                        child: _loggingInPower
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('登录电量服务并刷新'),
                      ),
                    ],
                  ),
                ),
              ] else if (_balanceError != null) ...[
                Text(
                  _balanceError!,
                  style: textTheme.bodyMedium?.copyWith(color: colors.error),
                ),
                const SizedBox(height: 6),
                OutlinedButton(
                  key: const Key('power_balance_retry_button'),
                  onPressed: _loadBalance,
                  child: const Text('重试'),
                ),
              ],
            ],
            if (_balanceInfo != null && _balanceError != null) ...[
              const SizedBox(height: 8),
              Text(
                _balanceError!,
                style: textTheme.bodySmall?.copyWith(color: colors.error),
              ),
              if (_balanceAuthRequired) ...[
                const SizedBox(height: 6),
                FilledButton.tonal(
                  key: const Key('power_login_button'),
                  onPressed: _loggingInPower ? null : _loginPower,
                  child: const Text('重新登录电量服务'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection(ColorScheme colors, TextTheme textTheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header
        Row(
          children: [
            Icon(Icons.history, color: colors.primary, size: 22),
            const SizedBox(width: 8),
            Text(
              '用电历史',
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('power_verify_2fa_button'),
              icon: const Icon(Icons.verified_user_outlined, size: 16),
              label: const Text('2FA 验证'),
              onPressed: _verifying2Fa ? null : _verify2Fa,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '每日用电量（kWh）',
          style: textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 10),

        if (_loadingHistory)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: CircularProgressIndicator(),
            ),
          )
        else if (_history2FaRequired)
          Container(
            key: const Key('power_2fa_required_banner'),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.tertiaryContainer),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.security,
                      color: colors.onTertiaryContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '用电历史查询需要 2FA 身份验证',
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '请到 id.fudan.edu.cn 完成校园验证。',
                  style: textTheme.bodySmall?.copyWith(height: 1.4),
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  key: const Key('power_verify_2fa_action_button'),
                  onPressed: _verifying2Fa ? null : _verify2Fa,
                  child: _verifying2Fa
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('完成 2FA 验证并刷新'),
                ),
              ],
            ),
          )
        else if (_historyError != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _historyError!,
                  style: textTheme.bodySmall?.copyWith(color: colors.error),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => _loadHistory(refresh: true),
                      child: const Text('重试'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: _verifying2Fa ? null : _verify2Fa,
                      child: const Text('2FA 验证'),
                    ),
                  ],
                ),
              ],
            ),
          )
        else if (_historyRecords.isEmpty)
          Card(
            key: const Key('power_history_empty_card'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  '暂无用电记录',
                  style: textTheme.bodyMedium?.copyWith(color: colors.outline),
                ),
              ),
            ),
          )
        else ...[
          // History records list with date, kWh, dorm_name and pagination
          ..._historyRecords.asMap().entries.map((entry) {
            final index = entry.key;
            final record = entry.value;
            return _buildHistoryItem(record, index, colors, textTheme);
          }),
          // Pagination controls
          _buildPaginationFooter(colors, textTheme),
        ],
      ],
    );
  }

  Future<void> _loadUsage({bool afterSignIn = false}) async {
    final ticket = ++_usageTicket;
    final account = widget.controller.activeAccountId;
    setState(() {
      _usageSummary = null;
      _usageError = null;
      _loadingUsage = account != null;
    });
    if (account == null) return;
    try {
      final response = await (afterSignIn ? _api.readAfterSignIn : _api.call)(
        'fudan.electricity.statistics',
        {'period': _usagePeriod},
      );
      if (!mounted ||
          ticket != _usageTicket ||
          account != widget.controller.activeAccountId) {
        return;
      }
      final payload = response is Map && response['payload'] is Map
          ? response['payload']
          : response;
      if (payload is! Map || payload['buckets'] is! List) {
        throw const FormatException('Invalid usage statistics');
      }
      setState(() => _usageSummary = payload);
    } catch (e) {
      if (mounted &&
          ticket == _usageTicket &&
          account == widget.controller.activeAccountId) {
        setState(() => _usageError = campusError(e));
      }
    } finally {
      if (mounted && ticket == _usageTicket) {
        setState(() => _loadingUsage = false);
      }
    }
  }

  Widget _buildUsageTrendCard(ColorScheme colors, TextTheme textTheme) {
    final buckets = (_usageSummary?['buckets'] as List? ?? [])
        .whereType<Map>()
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('用电走势', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in {
                  'day': '天',
                  'week': '周',
                  'month': '月',
                  'year': '年',
                }.entries)
                  ChoiceChip(
                    key: ValueKey('usage_period_${entry.key}'),
                    label: Text(entry.value),
                    selected: _usagePeriod == entry.key,
                    onSelected: (_) {
                      setState(() => _usagePeriod = entry.key);
                      _loadUsage();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _usagePeriod == 'week' ? '单位 kWh · 每周按周一归集' : '单位 kWh',
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_loadingUsage)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_usageError != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_usageError!),
                trailing: TextButton(
                  onPressed: _loadUsage,
                  child: const Text('重试'),
                ),
              )
            else if (_usageSummary != null) ...[
              UsageBarChart(buckets: buckets, period: _usagePeriod),
              const SizedBox(height: 12),
              Text(
                '共 ${_usageSummary!['record_count']} 条用电记录',
                style: textTheme.bodySmall,
              ),
              if (_usageSummary!['complete'] != true)
                Text('按校方已提供的记录统计，完整性未确认', style: textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryItem(
    ElectricityHistoryRecord record,
    int index,
    ColorScheme colors,
    TextTheme textTheme,
  ) {
    final amountDisplay =
        record.amount.contains('kWh') || record.amount.contains('度')
        ? record.amount
        : '${record.amount} kWh';

    return Card(
      key: Key('power_history_item_$index'),
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.outlineVariant),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          child: Icon(Icons.bolt, color: colors.onPrimaryContainer, size: 20),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                record.date,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              amountDisplay,
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: colors.primary,
              ),
            ),
          ],
        ),
        subtitle: record.dormName.isNotEmpty
            ? Text(
                record.dormName,
                style: textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
      ),
    );
  }

  Widget _buildPaginationFooter(ColorScheme colors, TextTheme textTheme) {
    if (_loadingMoreHistory) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_hasMoreHistory) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: OutlinedButton.icon(
            key: const Key('power_history_load_more'),
            onPressed: () => _loadHistory(refresh: false),
            icon: const Icon(Icons.expand_more, size: 18),
            label: const Text('加载更多历史记录'),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          '已加载全部用电记录',
          style: textTheme.bodySmall?.copyWith(color: colors.outline),
        ),
      ),
    );
  }
}
