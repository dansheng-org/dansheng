import 'package:flutter/material.dart';

import '../../core/dansheng_state.dart';
import '../../screens/account_balance_screen.dart';
import '../../screens/settings_screen.dart';
import '../venues/venue_page.dart';
import 'life_page.dart';

/// Service entries only. Network reads belong to the page the user opens.
class EHallPage extends StatelessWidget {
  const EHallPage({super.key, required this.controller});
  final DanshengController controller;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    Widget entry(String title, IconData icon, Widget page) => Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(context, page),
      ),
    );
    Widget service(String title, LifeService service) => entry(
      title,
      service.icon,
      LifePage(service: service, controller: controller),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('eHall'),
        actions: [
          IconButton(
            tooltip: '账号与校园卡',
            onPressed: () =>
                _open(context, AccountBalanceScreen(controller: controller)),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          IconButton(
            tooltip: '设置',
            onPressed: () =>
                _open(context, SettingsScreen(controller: controller)),
            icon: const Icon(Icons.tune_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          service('校园卡', LifeService.transactions),
          service('教室空位', LifeService.rooms),
          service('寝室电量', LifeService.power),
          entry(
            '场馆预约',
            Icons.sports_tennis_outlined,
            VenuePage(controller: controller),
          ),
          service('图书馆客流', LifeService.library),
          service('食堂实时客流', LifeService.dining),
          service('校车班次时刻', LifeService.bus),
          entry('校园邮箱', Icons.mail_outline, const _MailShellPage()),
          service('教务公告', LifeService.notices),
          service('课程成绩', LifeService.grades),
          service('学分与绩点', LifeService.gpa),
          service('考试安排', LifeService.exams),
        ],
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
