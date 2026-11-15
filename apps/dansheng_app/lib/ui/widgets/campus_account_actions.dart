import 'package:flutter/material.dart';

import '../core/dansheng_state.dart';
import '../screens/account_balance_screen.dart';
import '../screens/settings_screen.dart';

/// Shared account and settings destinations for the campus tabs.
class CampusAccountActions extends StatelessWidget {
  const CampusAccountActions({super.key, required this.controller});
  final DanshengController controller;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: '账号与校园卡',
        icon: const Icon(Icons.account_circle_outlined),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AccountBalanceScreen(controller: controller),
          ),
        ),
      ),
      IconButton(
        tooltip: '设置',
        icon: const Icon(Icons.tune_outlined),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(controller: controller),
          ),
        ),
      ),
    ],
  );
}
