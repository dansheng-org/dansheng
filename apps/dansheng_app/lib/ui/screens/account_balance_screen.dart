import 'package:flutter/material.dart';

import '../campus/campus_api.dart';
import '../core/dansheng_state.dart';

/// Screen for active account management and campus card balance query.
class AccountBalanceScreen extends StatefulWidget {
  final DanshengController controller;

  const AccountBalanceScreen({super.key, required this.controller});

  @override
  State<AccountBalanceScreen> createState() => _AccountBalanceScreenState();
}

class _AccountBalanceScreenState extends State<AccountBalanceScreen> {
  Future<void> _showSwitchAccountDialog() async {
    final textController = TextEditingController(
      text: widget.controller.activeAccountId ?? '',
    );

    final newId = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('选择校园账号'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: textController,
                decoration: const InputDecoration(
                  labelText: '学号或工号',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(textController.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );

    if (newId != null && newId.isNotEmpty) {
      try {
        await widget.controller.switchAccount(newId);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已切换到账号：$newId')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('切换账号失败：${campusError(e)}')));
        }
      }
    }
  }

  Future<void> _connectService(String service) async {
    try {
      await CampusApi(widget.controller.client)
          .call('campus.login', {'service': service, 'replace': true});
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已登录')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(campusError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountId = widget.controller.activeAccountId;
    final balanceData = widget.controller.balanceData;
    final isLoading = widget.controller.isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号与卡包'),
        actions: [
          if (accountId != null)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '退出当前账号',
              onPressed: () async {
                final logout = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('退出账号？'),
                    content: const Text('删除本机保存的登录凭据，并停止该账号的定时任务。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('退出'),
                      ),
                    ],
                  ),
                );
                if (logout == true && mounted) {
                  await widget.controller.switchAccount('');
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => widget.controller.refreshAll(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => widget.controller.refreshAll(),
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Account Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Icon(
                            Icons.person,
                            color: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '活动账号',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                              ),
                              Text(
                                accountId != null && accountId.isNotEmpty
                                    ? accountId
                                    : '未设置活动账号',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                        FilledButton.tonal(
                          onPressed: _showSwitchAccountDialog,
                          child: const Text('切换'),
                        ),
                      ],
                    ),
                    if (accountId != null && accountId.isNotEmpty)
                      Wrap(
                        spacing: 4,
                        children: [
                          for (final (service, title) in const [
                            ('ecard', '统一认证'),
                            ('canvas', 'Canvas'),
                          ])
                            TextButton(
                              onPressed: () => _connectService(service),
                              child: Text(title),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Campus Card Balance Section
            Text(
              '校园卡余额',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            if (accountId == null || accountId.isEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 48,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 12),
                        const Text('请先设置或登录活动账号以查询卡片余额'),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _showSwitchAccountDialog,
                          child: const Text('设置账号'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ] else ...[
              _buildBalanceCard(balanceData, isLoading),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBalanceCard(Map<String, dynamic>? balanceData, bool isLoading) {
    if (isLoading && balanceData == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(32.0),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (balanceData == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Expanded(child: Text('暂无余额数据')),
              TextButton(
                onPressed: () => widget.controller.refreshBalance(),
                child: const Text('查询余额'),
              ),
            ],
          ),
        ),
      );
    }

    if (balanceData.containsKey('error')) {
      return Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '查询失败',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${balanceData['error']}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => widget.controller.refreshBalance(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final balanceVal =
        balanceData['balance'] ??
        balanceData['amount'] ??
        balanceData['card_balance'] ??
        '--';
    final currency = balanceData['currency']?.toString() ?? 'CNY';
    final updatedAt =
        balanceData['updated_at'] ?? balanceData['timestamp'] ?? '刚刚';

    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primaryContainer,
              Theme.of(context).colorScheme.surfaceContainerHighest,
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.credit_card,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '一卡通钱包',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 20),
                  tooltip: '刷新余额',
                  onPressed: () => widget.controller.refreshBalance(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '可用余额',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer
                    .withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '¥ ',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$balanceVal',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  currency,
                  style: TextStyle(
                    fontSize: 14,
                    color: Theme.of(context).colorScheme.onPrimaryContainer
                        .withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.access_time,
                  size: 14,
                  color: Theme.of(context).colorScheme.onPrimaryContainer
                      .withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '${balanceData['stale'] == true ? "上次成功读取（离线）" : "更新时间"}: $updatedAt',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onPrimaryContainer
                          .withValues(alpha: 0.7),
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
}
