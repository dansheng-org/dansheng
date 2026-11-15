// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic, read-only Android layout preview. Never used by the product entrypoint.
import 'dart:convert';

import 'package:dansheng_app/bridge.g.dart';
import 'package:dansheng_app/ui/campus/forum/forum_page.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:dansheng_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(await forumPreviewApp());
}

Future<Widget> forumPreviewApp({ThemeData? theme}) async {
  final controller = DanshengController(
    client: DanshengClient(bridge: _PreviewBridge()),
  );
  await controller.initialize();
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme ?? AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    home: ForumPage(controller: controller),
  );
}

class _PreviewBridge implements DanshengBridge {
  static const first = r'''最近在整理选课和学习资料，分享几个经验。

**先看培养方案，再看课程安排。**
有问题可以在下面继续讨论。''';

  Map<String, dynamic> floor(
    int id,
    String name,
    String content, {
    int ranking = 0,
    bool deleted = false,
    List<String> fold = const [],
  }) => {
    'floor_id': id,
    'hole_id': 123456,
    'anonyname': name,
    'content': content,
    'time_created': '2026-11-15T10:00:00+08:00',
    'ranking': ranking,
    'deleted': deleted,
    'fold': fold,
    'like': 3,
    'modified': ranking == 2 ? 1 : 0,
  };

  List<Map<String, dynamic>> get floors => [
    floor(9001, '橘猫', r'''# 选课和学习资料

最近在整理选课资料，分享几个经验：

1. **先看培养方案**，确认课程要求。
2. 每周安排复习时间，保留讨论记录。

> 一位同学的建议：不要只看一条评价，要结合自己的目标。

行内公式 $a^2+b^2=c^2$ 也可以正常阅读。

$$\sum_{i=1}^n i = \frac{n(n+1)}{2}$$

```dart
final learning = ['阅读', '讨论', '复习'];
```

| 项目 | 建议 |
| --- | --- |
| 学习 | 每周整理 |
| 资料 | 标记来源 |

继续阅读 #123457，或看楼层 ##9003。'''),
    floor(9002, '小海豹', '同意，尤其是**标记资料来源**这一点。\n换行后的补充也应该保留。', ranking: 1),
    floor(9003, '橘猫', '补充：表格和公式都要留在正文中，不应在详情里变成占位符。', ranking: 2),
    floor(9004, '银杏叶', '这是一段需要用户主动展开的合成内容。', ranking: 3, fold: ['折叠示例']),
    floor(9005, '路过同学', '不应出现在界面的已删除原文', ranking: 4, deleted: true),
  ];

  Map<String, dynamic> hole(
    int id,
    String content,
    List<String> tags, {
    String name = '橘猫',
  }) => {
    'hole_id': id,
    'division_id': 1,
    'reply': 4,
    'view': 120,
    'time_created': '2026-11-15T10:00:00+08:00',
    'time_updated': '2026-11-15T11:10:00+08:00',
    'tags': tags,
    'floors': {
      'first_floor': {...floor(9001, name, content), 'hole_id': id},
      'last_floor': {
        ...floor(9003, '小海豹', '我也在整理，可以交流一下课程安排。', ranking: 2),
        'hole_id': id,
      },
    },
  };

  @override
  Future<String> invoke(HostCommand command, String payload) async {
    if (command == HostCommand.info) return '{}';
    if (command == HostCommand.account) {
      return '{"account_id":"preview-account"}';
    }
    if (command == HostCommand.plugins || command == HostCommand.jobs) {
      return '[]';
    }
    if (command == HostCommand.permissions) return '{}';
    if (command != HostCommand.campus) throw StateError('Read-only preview');
    final request = jsonDecode(payload) as Map<String, dynamic>;
    final params = request['params'] as Map<String, dynamic>;
    final value = switch (request['method']) {
      'community.tea.divisions' => {
        'records': [
          {
            'payload': {'division_id': 1, 'name': '校园生活', 'pinned': []},
          },
        ],
      },
      'community.tea.holes' => {
        'records': [
          for (final row in [
            hole(123456, first, ['学习交流', '校园生活']),
            hole(123457, '今天的天气很好，适合去图书馆坐坐。\n\n大家有什么推荐的阅读清单？', ['日常']),
            hole(123458, '这段内容应先折叠，展开后才显示。', ['*折叠内容']),
          ])
            {'payload': row},
        ],
      },
      'community.tea.hole' => {
        'payload': hole(params['hole_id'] as int, first, ['学习交流', '校园生活']),
      },
      'community.tea.floors' => {
        'records': (params['offset'] ?? 0) == 0
            ? [
                for (final row in floors) {'payload': row},
              ]
            : [],
      },
      'forum.search' => {
        'items': [floors[0], floors[2]],
      },
      _ => throw StateError('Read-only preview'),
    };
    return jsonEncode(value);
  }
}
