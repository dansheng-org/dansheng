import 'dart:async';

import 'package:flutter/material.dart';

import '../core/dansheng_state.dart';
import '../campus/ehall/ehall_page.dart';
import '../campus/learning/learning_page.dart';
import '../campus/forum/forum_page.dart';
import '../campus/agent/agent_page.dart';
import 'plugins_screen.dart';
import 'tasks_screen.dart';

enum _Tab {
  ehall('eHall', Icons.dashboard_outlined, Icons.dashboard, reload: true),
  learning(
    'eLearning',
    Icons.calendar_month_outlined,
    Icons.calendar_month,
    reload: true,
  ),
  agent('Agent', Icons.auto_awesome_outlined, Icons.auto_awesome),
  // The forum keeps where you were reading; tapping its tab again refreshes it.
  forum('论坛', Icons.forum_outlined, Icons.forum, refreshOnTap: true),
  plugins('插件', Icons.extension_outlined, Icons.extension);

  const _Tab(
    this.label,
    this.icon,
    this.selectedIcon, {
    this.reload = false,
    this.refreshOnTap = false,
  });
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Campus pages read again whenever they are opened, so they never show
  /// what was there before a sign-in. Agent and plugins keep their state.
  final bool reload;

  /// Tapping the tab while it is open loads it afresh.
  final bool refreshOnTap;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final DanshengController controller;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  _Tab current = _Tab.ehall;
  final opened = <_Tab>{_Tab.ehall};
  final visits = <_Tab, int>{};
  late final StreamSubscription<int> links;

  @override
  void initState() {
    super.initState();
    links = widget.controller.navigation.listen((_) {
      if (!mounted) return;
      setState(() {
        opened.add(_Tab.plugins);
        current = _Tab.plugins;
      });
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TasksScreen(controller: widget.controller),
        ),
      );
    });
  }

  @override
  void dispose() {
    links.cancel();
    super.dispose();
  }

  List<_Tab> get tabs => [
    for (final tab in _Tab.values)
      if (tab != _Tab.forum || widget.controller.forumEnabled) tab,
  ];

  void select(_Tab tab) {
    if (tab == current) {
      if (tab.refreshOnTap) {
        setState(() => visits[tab] = (visits[tab] ?? 0) + 1);
      }
      return;
    }
    setState(() {
      // A page already built is rebuilt from scratch, so it loads afresh.
      if (tab.reload && opened.contains(tab)) {
        visits[tab] = (visits[tab] ?? 0) + 1;
      }
      opened.add(tab);
      current = tab;
    });
  }

  Widget page(_Tab tab) => switch (tab) {
    _Tab.ehall => EHallPage(controller: widget.controller),
    _Tab.learning => LearningPage(controller: widget.controller),
    _Tab.agent => AgentPage(controller: widget.controller),
    _Tab.forum => ForumPage(controller: widget.controller),
    _Tab.plugins => PluginsScreen(controller: widget.controller),
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (_, _) {
      final shown = tabs;
      if (!shown.contains(current)) current = _Tab.ehall;
      final account = widget.controller.activeAccountId;
      return Scaffold(
        body: IndexedStack(
          index: shown.indexOf(current),
          children: [
            for (final tab in shown)
              opened.contains(tab)
                  ? TickerMode(
                      enabled: tab == current,
                      child: KeyedSubtree(
                        key: ValueKey(
                          '$account:${tab.name}:${visits[tab] ?? 0}',
                        ),
                        child: page(tab),
                      ),
                    )
                  : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: shown.indexOf(current),
          onDestinationSelected: (i) => select(shown[i]),
          destinations: [
            for (final tab in shown)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
              ),
          ],
        ),
      );
    },
  );
}
