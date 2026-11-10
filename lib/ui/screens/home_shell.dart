import 'dart:async';

import 'package:flutter/material.dart';

import '../core/dansheng_state.dart';
import '../campus/ehall/ehall_page.dart';
import '../campus/learning/learning_page.dart';
import '../campus/forum/forum_page.dart';
import '../campus/agent/agent_page.dart';
import 'plugins_screen.dart';
import 'tasks_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final DanshengController controller;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  final opened = <int>{0};
  late final StreamSubscription<int> links;
  @override
  void initState() {
    super.initState();
    links = widget.controller.navigation.listen((_) {
      if (!mounted) return;
      setState(() {
        opened.add(4);
        index = 4;
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

  Widget page(int i) => switch (i) {
    0 => EHallPage(controller: widget.controller),
    1 => LearningPage(controller: widget.controller),
    2 => AgentPage(controller: widget.controller),
    3 => ForumPage(controller: widget.controller),
    _ => PluginsScreen(controller: widget.controller),
  };
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (_, _) => Scaffold(
      body: IndexedStack(
        index: index,
        children: List.generate(
          5,
          (i) => opened.contains(i)
              ? TickerMode(enabled:index==i,child:KeyedSubtree(
                  key: ValueKey('${widget.controller.activeAccountId}:$i'),
                  child: page(i),
                ))
              : const SizedBox.shrink(),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() {
          opened.add(i);
          index = i;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'eHall',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: 'eLearning',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'Agent',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: '论坛',
          ),
          NavigationDestination(
            icon: Icon(Icons.extension_outlined),
            selectedIcon: Icon(Icons.extension),
            label: '插件',
          ),
        ],
      ),
    ),
  );
}
