// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:dansheng_app/ui/campus/research/research_page.dart';
import 'package:dansheng_app/ui/campus/research/research_service.dart';
import 'package:dansheng_app/ui/core/dansheng_client.dart';
import 'package:dansheng_app/ui/core/dansheng_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../ui/test_helpers.dart';

void main() {
  group('ResearchService Unit Tests', () {
    late ResearchService service;

    setUp(() {
      service = ResearchService.instance;
    });

    test(
      'getNews returns articles and filters by category and search query',
      () async {
        final allNews = await service.getNews();
        expect(allNews.length, greaterThanOrEqualTo(5));

        final breakthroughs = await service.getNews(category: '科研突破');
        expect(breakthroughs.every((n) => n.category == '科研突破'), isTrue);

        final searchBrain = await service.getNews(query: '脑科学');
        expect(searchBrain, isNotEmpty);
        expect(
          searchBrain.any(
            (n) => n.title.contains('脑科学') || n.department.contains('脑科学'),
          ),
          isTrue,
        );
      },
    );

    test('getGroups returns groups, filters by department and handles follow toggle', () async {
      final allGroups = await service.getGroups();
      expect(allGroups.length, greaterThanOrEqualTo(5));

      // Test follow toggle
      const testId = 'rg_chip';
      final initialFollowed = service.isGroupFollowed(testId);
      service.toggleFollowGroup(testId);
      expect(service.isGroupFollowed(testId), !initialFollowed);

      // Toggle back
      service.toggleFollowGroup(testId);
      expect(service.isGroupFollowed(testId), initialFollowed);

      // Filter by department
      final csGroups = await service.getGroups(department: '计算机科学技术学院');
      expect(csGroups.every((g) => g.department == '计算机科学技术学院'), isTrue);
    });

    test(
      'getLectures returns academic lectures and toggles bookmarks',
      () async {
        final lectures = await service.getLectures();
        expect(lectures, isNotEmpty);

        const lecId = 'lec_2';
        final initialBookmarked = service.isLectureBookmarked(lecId);
        service.toggleBookmarkLecture(lecId);
        expect(service.isLectureBookmarked(lecId), !initialBookmarked);

        service.toggleBookmarkLecture(lecId);
        expect(service.isLectureBookmarked(lecId), initialBookmarked);
      },
    );

    test('FDUROP services: getNotices, getProjects, and getDocuments with downloads', () async {
      // FDUROP Notices
      final notices = await service.getFduropNotices();
      expect(notices.length, greaterThanOrEqualTo(4));
      expect(notices.any((n) => n.title.contains('FDUROP')), isTrue);

      // FDUROP Open Projects
      final projects = await service.getFduropProjects();
      expect(projects.length, greaterThanOrEqualTo(5));
      expect(
        projects.any(
          (p) => p.program.contains('曦源') || p.program.contains('望道'),
        ),
        isTrue,
      );

      const projId = 'fdurop_p2';
      final initialBookmarked = service.isFduropProjectBookmarked(projId);
      service.toggleBookmarkFduropProject(projId);
      expect(service.isFduropProjectBookmarked(projId), !initialBookmarked);
      service.toggleBookmarkFduropProject(projId);
      expect(service.isFduropProjectBookmarked(projId), initialBookmarked);

      // FDUROP Documents & Download
      final docs = await service.getFduropDocuments();
      expect(docs, isNotEmpty);
      expect(docs.any((d) => d.title.contains('申请书模板')), isTrue);

      const docId = 'doc_1';
      expect(service.isFduropDocumentDownloaded(docId), isFalse);
      await service.downloadFduropDocument(docId);
      expect(service.isFduropDocumentDownloaded(docId), isTrue);
    });
  });

  group('ResearchPage Widget Tests', () {
    late MockDanshengBridge bridge;
    late DanshengClient client;
    late DanshengController controller;

    setUp(() async {
      bridge = MockDanshengBridge();
      bridge.accountId = '2026_research_tester';
      client = DanshengClient(bridge: bridge);
      controller = DanshengController(client: client);
      await controller.initialize();
    });

    testWidgets('Renders ResearchPage with 4 tabs and displays news items', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          home: ResearchPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Verify app bar title and bottom tabs
      expect(find.text('科研'), findsOneWidget);
      expect(find.text('科研动态'), findsOneWidget);
      expect(find.textContaining('课题组'), findsWidgets);
      expect(find.text('本科生科研 (FDUROP)'), findsOneWidget);
      expect(find.widgetWithText(Tab, '学术讲座'), findsOneWidget);

      // Tab 0: 科研动态 items visible
      expect(find.textContaining('《自然》发表复旦大学脑科学'), findsOneWidget);
      expect(find.textContaining('集成芯片全国重点实验室'), findsOneWidget);

      // Filter category chip tap
      await tester.tap(find.widgetWithText(FilterChip, '项目申报'));
      await tester.pumpAndSettle();

      expect(find.textContaining('国家自然科学基金青年学生基础研究项目'), findsOneWidget);
    });

    testWidgets('Tapping a news card opens news detail bottom sheet', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          home: ResearchPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();

      // Tap first news card
      final firstNewsCard = find.textContaining('《自然》发表复旦大学脑科学').first;
      await tester.tap(firstNewsCard);
      await tester.pumpAndSettle();

      // Verify detail sheet is displayed
      expect(find.text('科学技术研究院'), findsWidgets);
      expect(find.textContaining('摘要：'), findsOneWidget);
      expect(find.text('复制来源链接'), findsOneWidget);

      // Close modal sheet
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pop();
      await tester.pumpAndSettle();
    });

    testWidgets(
      'Switching to 课题组 tab displays groups, allows follow toggle and details sheet',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: ResearchPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Switch to 课题组 tab
        await tester.tap(find.widgetWithText(Tab, '课题组 (2)'));
        await tester.pumpAndSettle();

        // Verify groups visible
        expect(find.text('智能信息处理与大模型认知研究组'), findsOneWidget);
        expect(find.text('类脑智能与脑机接口前沿实验室'), findsOneWidget);

        // Verify direction tags
        expect(find.text('自然语言处理'), findsOneWidget);
        expect(find.text('类脑计算'), findsOneWidget);

        // Tap group card to open detail sheet
        await tester.tap(find.text('智能信息处理与大模型认知研究组'));
        await tester.pumpAndSettle();

        // Verify lab detail sheet content
        expect(find.text('课题组简介'), findsOneWidget);
        expect(find.text('代表性成果 / 近期论文'), findsOneWidget);
        final sheetScrollable = find.byType(Scrollable).last;
        await tester.scrollUntilVisible(
          find.text('招生与科研招募'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('招生与科研招募'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('nlp_fudan@fudan.edu.cn'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('nlp_fudan@fudan.edu.cn'), findsOneWidget);
        expect(find.byTooltip('复制邮箱'), findsOneWidget);

        // Close modal sheet
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        navigator.pop();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Switching to 本科生科研 (FDUROP) tab allows viewing open projects, notices and downloading documents',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: ResearchPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Switch to 本科生科研 (FDUROP) tab
        await tester.tap(find.text('本科生科研 (FDUROP)'));
        await tester.pumpAndSettle();

        // Sub-segment 0: 开放课题 visible
        expect(find.textContaining('复旦大学本科生学术研究资助计划'), findsOneWidget);
        expect(find.text('开放课题 (6)'), findsOneWidget);
        expect(find.textContaining('基于端侧小模型的高校课程智能问答助教系统'), findsOneWidget);

        // Tap project card to open project detail sheet
        await tester.tap(find.textContaining('基于端侧小模型的高校课程智能问答助教系统'));
        await tester.pumpAndSettle();

        expect(find.text('课题内容与研究目标'), findsOneWidget);
        expect(find.text('申请要求与先修知识'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('联系导师申请课题'),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('联系导师申请课题'), findsOneWidget);

        // Close detail sheet
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        navigator.pop();
        await tester.pumpAndSettle();

        // Sub-segment 1: 网站通知
        await tester.tap(find.text('网站通知 (5)'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('关于启动2026-2027学年第一学期本科生学术研究资助计划'),
          findsOneWidget,
        );
        expect(find.textContaining('莙政学者'), findsWidgets);

        // Sub-segment 2: 文件下载
        await tester.tap(find.text('文件下载 (6)'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('复旦大学本科生学术研究资助计划（FDUROP）立项申请书模板'),
          findsOneWidget,
        );
        expect(find.byTooltip('下载文件'), findsWidgets);

        // Tap download on first file
        await tester.tap(find.byTooltip('下载文件').first);
        await tester.pumpAndSettle();

        // Check download notification snackbar
        expect(find.textContaining('已成功下载'), findsOneWidget);
        expect(find.byTooltip('已下载'), findsWidgets);
      },
    );

    testWidgets(
      'Switching to 学术讲座 tab displays lectures and allows bookmarking',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: ResearchPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Switch to 学术讲座 tab
        await tester.tap(find.widgetWithText(Tab, '学术讲座'));
        await tester.pumpAndSettle();

        // Verify lecture items visible
        expect(find.textContaining('量子计算前沿演进与拓扑容错物态实现'), findsOneWidget);
        expect(find.textContaining('彼得·格林教授'), findsOneWidget);
        expect(find.textContaining('邯郸校区 相辉堂北堂'), findsOneWidget);

        // Toggle bookmark icon button
        final bookmarkBtn = find.byIcon(Icons.bookmark).first;
        await tester.tap(bookmarkBtn);
        await tester.pumpAndSettle();
      },
    );
  });
}
