// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:dansheng_app/ui/campus/campus_api.dart';
import 'package:dansheng_app/ui/campus/research/research_models.dart';
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

    test('getGroups returns groups with official websites, filters by department and handles follow toggle', () async {
      final allGroups = await service.getGroups();
      expect(allGroups.length, greaterThanOrEqualTo(15));
      expect(
        allGroups.any((g) => g.websiteUrl.contains('fudan.edu.cn')),
        isTrue,
      );

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
      expect(csGroups.every((g) => g.department.contains('计算机')), isTrue);
    });

    test('getLectures returns academic lectures, filters by category and toggles bookmarks', () async {
      final lectures = await service.getLectures();
      expect(lectures.length, greaterThanOrEqualTo(10));
      expect(
        lectures.any((l) => l.title.contains('西学') || l.title.contains('量子计算')),
        isTrue,
      );

      final humanities = await service.getLectures(category: '人文社科');
      expect(humanities.every((l) => l.category == '人文社科'), isTrue);

      const lecId = 'lec_cs_1';
      final initialBookmarked = service.isLectureBookmarked(lecId);
      service.toggleBookmarkLecture(lecId);
      expect(service.isLectureBookmarked(lecId), !initialBookmarked);

      service.toggleBookmarkLecture(lecId);
      expect(service.isLectureBookmarked(lecId), initialBookmarked);
    });

    test('FDUROP services: notices and paper.fudan.edu.cn open projects with bookmarks', () async {
      // FDUROP Notices
      final notices = await service.getFduropNotices();
      expect(notices.length, greaterThanOrEqualTo(5));
      expect(notices.any((n) => n.title.contains('FDUROP')), isTrue);
      expect(notices.any((n) => n.title.contains('教师开放课题')), isTrue);

      // FDUROP Open Projects
      final projects = (await service.fetchFduropProjectPage(pageSize: 1000))
          .items;
      expect(projects.length, greaterThanOrEqualTo(50));
      expect(
        projects.every((p) => p.portalUrl.contains('paper.fudan.edu.cn')),
        isTrue,
      );

      const projId = 'fdurop_p2';
      final initialBookmarked = service.isFduropProjectBookmarked(projId);
      service.toggleBookmarkFduropProject(projId);
      expect(service.isFduropProjectBookmarked(projId), !initialBookmarked);
      service.toggleBookmarkFduropProject(projId);
      expect(service.isFduropProjectBookmarked(projId), initialBookmarked);
    });

    test('FduropDocumentItem parses the official jwc attachment names', () {
      final apply = FduropDocumentItem.fromAttachment(
        '1-a.【立项】䇹政项目申请书模板（2025年）.docx',
        'https://jwc.fudan.edu.cn/_upload/article/files/a/b/apply.docx',
      );
      expect(apply.title, '䇹政项目申请书模板（2025年）');
      expect(apply.category, '立项申报');
      expect(apply.fileFormat, 'DOCX');
      expect(apply.fileName, '1-a.【立项】䇹政项目申请书模板（2025年）.docx');
      expect(apply.id, apply.downloadUrl);

      expect(
        FduropDocumentItem.fromAttachment(
          '4-b.【财务】FDUROP项目经费报销流程.pdf',
          'u',
        ).category,
        '经费管理',
      );
      final plain = FduropDocumentItem.fromAttachment(
        '5.FDUROP发表文章与学术会议的致谢格式.docx',
        'u2',
      );
      expect(plain.title, 'FDUROP发表文章与学术会议的致谢格式');
      expect(plain.category, '其他');
    });

    test(
      'FDUROP documents list the jwc pages and open through one cached asset',
      () async {
        final calls = <String>[];
        final bridge = MockDanshengBridge();
        bridge.campusHandler = (method, params) async {
          calls.add(method);
          switch (method) {
            case 'fudan.notice.attachments':
              final url = params['url'] as String;
              expect(ResearchService.fduropDocumentPages, contains(url));
              return url.contains('c27281a724487')
                  ? [
                      {
                        'name': '1-a.【立项】䇹政项目申请书模板（2025年）.docx',
                        'url': 'https://jwc.fudan.edu.cn/_upload/a/apply.docx',
                      },
                      {
                        'name': '2-a.【中期】中期报告须知.pdf',
                        'url': 'https://jwc.fudan.edu.cn/_upload/a/mid.pdf',
                      },
                    ]
                  : [
                      {
                        'name': '6-a.【资源】学术规范与论文写作.pdf',
                        'url': 'https://jwc.fudan.edu.cn/_upload/b/res.pdf',
                      },
                    ];
            case 'fudan.notice.attachment.download':
              expect(params['name'], '1-a.【立项】䇹政项目申请书模板（2025年）.docx');
              return {'asset_id': 'asset-apply', 'mime_type': 'application/x'};
            case 'campus.openFile':
              expect(params['asset_id'], 'asset-apply');
              return {'opened': true};
          }
          return <String, dynamic>{};
        };
        final controller = DanshengController(
          client: DanshengClient(bridge: bridge),
        );
        await controller.initialize();
        service.bindApi(null);
        service.bindApi(CampusApi.forAccount(controller));

        final docs = await service.fetchFduropDocuments(refresh: true);
        expect(docs.map((d) => d.category), ['立项申报', '中期检查', '学术资源']);
        expect(service.cachedFduropDocuments, same(docs));

        final apply = docs.first;
        expect(service.isFduropDocumentDownloaded(apply.id), isFalse);
        await service.openFduropDocument(apply);
        await service.openFduropDocument(apply);
        expect(service.isFduropDocumentDownloaded(apply.id), isTrue);
        expect(
          calls.where((m) => m == 'fudan.notice.attachment.download'),
          hasLength(1),
          reason: 'the second open reuses the managed asset',
        );
        expect(calls.where((m) => m == 'campus.openFile'), hasLength(2));
        service.bindApi(null);
      },
    );

    test('FduropProjectItem.fromLiveJson correctly parses backend payload', () {
      final json = {
        'id': 'urop_123',
        'title': '基于Rust的高性能校园内核开发',
        'teacher_name': '张老师',
        'teacher_code': '009988',
        'department_name': '计算机科学技术学院',
        'brief': '设计微内核与沙箱网络',
        'requirement': '熟练掌握 Rust / C++',
        'tutor_email': 'zhang@fudan.edu.cn',
        'tutor_mobile': '13800000000',
        'tutor_introduce': '系统软件专家',
        'lab_introduce': '系统与安全实验室',
        'subject_kinds': ['计算机科学与技术'],
        'topic_labels': ['望道项目'],
      };
      final item = FduropProjectItem.fromLiveJson(json, isBookmarked: true);
      expect(item.id, 'urop_123');
      expect(item.title, '基于Rust的高性能校园内核开发');
      expect(item.advisor, '张老师');
      expect(item.advisorTitle, '教师编号: 009988');
      expect(item.department, '计算机科学技术学院');
      expect(item.description, '设计微内核与沙箱网络');
      expect(item.requirements, '熟练掌握 Rust / C++');
      expect(item.contactEmail, 'zhang@fudan.edu.cn');
      expect(item.tutorMobile, '13800000000');
      expect(item.tutorIntroduce, '系统软件专家');
      expect(item.labIntroduce, '系统与安全实验室');
      expect(item.program, '望道项目');
      expect(item.isBookmarked, isTrue);
    });

    test('Live FDUROP queries topics and detail via CampusApi', () async {
      final bridge = MockDanshengBridge();
      bridge.campusHandler = (method, params) async {
        if (method == 'fudan.fdurop.topics') {
          return [
            {
              'id': 'live_fdurop_101',
              'title': '基于大语言模型的软件工程自动化测试用例生成',
              'teacher_name': '彭鑫',
              'teacher_code': '001234',
              'department_name': '计算机科学技术学院',
              'brief': '研究利用大模型提高复杂系统自动化测试的覆盖率与缺陷检出率。',
              'requirement': '熟练掌握 Python 或 Java，熟悉软件工程与大语言模型微调。',
              'tutor_email': 'pengxin@fudan.edu.cn',
              'tutor_mobile': '021-31242255',
              'tutor_introduce': '复旦大学计算机科学技术学院教授、博士生导师、副院长。',
              'lab_introduce': '复旦大学软件工程实验室 CodeWisdom 团队。',
              'subject_kinds': ['计算机科学与技术', '软件工程'],
              'topic_labels': ['望道项目', '重点项目'],
            },
          ];
        } else if (method == 'fudan.fdurop.topic.detail') {
          return {
            'id': params['id'] ?? 'live_fdurop_101',
            'title': '基于大语言模型的软件工程自动化测试用例生成',
            'teacher_name': '彭鑫',
            'teacher_code': '001234',
            'department_name': '计算机科学技术学院',
            'brief': '研究利用大模型提高复杂系统自动化测试的覆盖率与缺陷检出率。',
            'requirement': '熟练掌握 Python 或 Java，熟悉软件工程与大语言模型微调。',
            'tutor_email': 'pengxin@fudan.edu.cn',
            'tutor_mobile': '021-31242255',
            'tutor_introduce': '复旦大学计算机科学技术学院教授、博士生导师、副院长。',
            'lab_introduce': '复旦大学软件工程实验室 CodeWisdom 团队。',
            'subject_kinds': ['计算机科学与技术', '软件工程'],
            'topic_labels': ['望道项目', '重点项目'],
          };
        }
        return <String, dynamic>{};
      };

      final client = DanshengClient(bridge: bridge);
      final controller = DanshengController(client: client);
      await controller.initialize();

      service.bindApi(CampusApi.forAccount(controller));

      final livePage = await service.fetchFduropProjectPage();
      expect(livePage.isLive, isTrue);
      final liveProjects = livePage.items;
      expect(liveProjects.length, 1);
      expect(liveProjects.first.title, contains('大语言模型'));

      final detail = await service.getFduropProjectDetail('live_fdurop_101');
      expect(detail, isNotNull);
      expect(detail!.advisor, '彭鑫');
      expect(detail.tutorIntroduce, contains('副院长'));
      expect(detail.tutorMobile, '021-31242255');
      expect(detail.labIntroduce, contains('CodeWisdom'));

      // Reset
      service.bindApi(null);
    });

    test('FDUROP search and multi-dimensional filtering by subjectKind, topicLabel, and keyword', () async {
      Future<List<FduropProjectItem>> all({
        String? query,
        String? subjectKind,
        String? topicLabel,
      }) async => (await service.fetchFduropProjectPage(
        pageSize: 1000,
        query: query,
        subjectKind: subjectKind,
        topicLabel: topicLabel,
      )).items;

      // Query by teacher name
      final zhuProjects = await all(query: '朱同玉');
      expect(zhuProjects, isNotEmpty);
      expect(zhuProjects.any((p) => p.advisor.contains('朱同玉')), isTrue);
      expect(zhuProjects.any((p) => p.title.contains('肾移植后免疫稳态重建')), isTrue);

      // Query by title keyword
      final nanoProjects = await all(query: '纳米多孔');
      expect(nanoProjects, isNotEmpty);
      expect(nanoProjects.first.title, contains('球形纳米多孔氧化物'));

      // Query by subject kind
      final medProjects = await all(subjectKind: '医学');
      expect(medProjects, isNotEmpty);
      expect(
        medProjects.every(
          (p) =>
              p.subjectKinds.contains('医学') ||
              p.program.contains('医学') ||
              p.matchesSubjectKind('医学'),
        ),
        isTrue,
      );

      // Query by topic label
      final fundProjects = await all(topicLabel: '国家自然科学基金项目');
      expect(fundProjects, isNotEmpty);
      expect(
        fundProjects.every(
          (p) =>
              p.topicLabels.contains('国家自然科学基金项目') ||
              p.program.contains('国家自然科学基金项目') ||
              p.matchesTopicLabel('国家自然科学基金项目'),
        ),
        isTrue,
      );
    });

    test('Live FDUROP labels and subjects query via CampusApi', () async {
      final bridge = MockDanshengBridge();
      bridge.campusHandler = (method, params) async {
        if (method == 'fudan.fdurop.labels') {
          return [
            {'id': 'lbl_1', 'name_zh': '国家自然科学基金项目'},
            {'id': 'lbl_2', 'name_zh': '国家科技重大专项'},
          ];
        } else if (method == 'fudan.fdurop.subjects') {
          return [
            {'id': 'sub_1', 'name_zh': '交叉学科'},
            {'id': 'sub_2', 'name_zh': '医学'},
            {'id': 'sub_3', 'name_zh': '工学'},
          ];
        }
        return <String, dynamic>{};
      };

      final client = DanshengClient(bridge: bridge);
      final controller = DanshengController(client: client);
      await controller.initialize();

      service.bindApi(CampusApi.forAccount(controller));

      final labels = await service.fduropTopicLabelOptions();
      expect(labels, ['全部', '国家自然科学基金项目', '国家科技重大专项']);

      final subjects = await service.fduropSubjectKindOptions();
      expect(subjects, ['全部', '交叉学科', '医学', '工学']);

      service.bindApi(null);
    });

    test('Offline FDUROP topics are paged over the filtered seed', () async {
      service.bindApi(null);
      final first = await service.fetchFduropProjectPage(pageSize: 20);
      expect(first.isLive, isFalse);
      expect(first.items.length, 20);
      expect(first.total, greaterThanOrEqualTo(50));
      expect(first.hasMore, isTrue);

      final lastPageNo = (first.total / 20).ceil();
      final last = await service.fetchFduropProjectPage(
        page: lastPageNo,
        pageSize: 20,
      );
      expect(last.hasMore, isFalse);
      expect(last.items.length, first.total - (lastPageNo - 1) * 20);
      expect(
        last.items
            .map((p) => p.id)
            .toSet()
            .intersection(first.items.map((p) => p.id).toSet()),
        isEmpty,
      );
    });

    test(
      'Live FDUROP paging sends one keyword and resolves filter ids',
      () async {
        final calls = <Map<String, dynamic>>[];
        final bridge = MockDanshengBridge();
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.fdurop.subjects') {
            return [
              {'id': 'sub_med', 'name_zh': '医学'},
            ];
          }
          if (method == 'fudan.fdurop.labels') {
            return [
              {'id': 'lbl_nsfc', 'name_zh': '国家自然科学基金项目'},
            ];
          }
          if (method == 'fudan.fdurop.topics') {
            calls.add(Map<String, dynamic>.from(params));
            return {
              'items': [
                {
                  'id': 'live_${params['page']}',
                  'title': '课题 ${params['page']}',
                },
              ],
              'page': params['page'],
              'page_size': params['page_size'],
              'total': 45,
              'has_more': params['page'] != 3,
            };
          }
          return <String, dynamic>{};
        };
        final controller = DanshengController(
          client: DanshengClient(bridge: bridge),
        );
        await controller.initialize();
        service.bindApi(CampusApi.forAccount(controller));

        final page = await service.fetchFduropProjectPage(
          page: 2,
          query: '朱',
          subjectKind: '医学',
          topicLabel: '国家自然科学基金项目',
        );
        expect(page.isLive, isTrue);
        expect(page.total, 45);
        expect(page.hasMore, isTrue);
        expect(page.items.single.id, 'live_2');
        expect(calls.single['page'], 2);
        expect(calls.single['page_size'], ResearchService.fduropPageSize);
        expect(calls.single['keyword'], '朱');
        expect(calls.single.containsKey('title'), isFalse);
        expect(calls.single.containsKey('code_or_name'), isFalse);
        expect(calls.single['subject_kind_id'], 'sub_med');
        expect(calls.single['topic_label_id'], 'lbl_nsfc');

        final last = await service.fetchFduropProjectPage(page: 3);
        expect(last.hasMore, isFalse);

        service.bindApi(null);
      },
    );
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
      'Switching to 课题组 tab displays groups, allows follow toggle and details sheet with website',
      (tester) async {
        await tester.pumpWidget(
          buildTestApp(
            home: ResearchPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Switch to 课题组 tab
        await tester.tap(find.widgetWithText(Tab, '课题组 (3)'));
        await tester.pumpAndSettle();

        // Verify groups visible
        expect(find.textContaining('智能信息处理与大模型认知研究组'), findsOneWidget);
        expect(find.textContaining('软件工程实验室'), findsOneWidget);

        // Verify direction tags
        expect(find.text('自然语言处理'), findsOneWidget);
        expect(find.text('智能软件工程 (AI4SE)'), findsOneWidget);

        // Tap group card to open detail sheet
        await tester.tap(find.textContaining('智能信息处理与大模型认知研究组'));
        await tester.pumpAndSettle();

        // Verify lab detail sheet content
        expect(find.text('课题组简介'), findsOneWidget);
        expect(find.text('代表性成果 / 近期论文'), findsOneWidget);
        final sheetScrollable = find.byType(Scrollable).last;
        await tester.scrollUntilVisible(
          find.text('官方主页 / 学院网站'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('官方主页 / 学院网站'), findsOneWidget);
        expect(find.text('https://nlp.fudan.edu.cn'), findsOneWidget);
        expect(find.byTooltip('复制网址'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('招生与科研招募'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('招生与科研招募'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('xpqiu@fudan.edu.cn'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('xpqiu@fudan.edu.cn'), findsOneWidget);
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
      'Switching to 本科生科研 (FDUROP) tab displays portal banner, allows viewing open projects, notices and downloading documents',
      (tester) async {
        final opened = <String>[];
        ResearchService.instance.bindApi(null);
        bridge.campusHandler = (method, params) async {
          switch (method) {
            case 'fudan.notice.attachments':
              return (params['url'] as String).contains('c27281a724487')
                  ? [
                      {
                        'name': '1-a.【立项】䇹政项目申请书模板（2025年）.docx',
                        'url': 'https://jwc.fudan.edu.cn/_upload/a/apply.docx',
                      },
                      {
                        'name': '3-a.【结题】䇹政项目结题表格.doc',
                        'url': 'https://jwc.fudan.edu.cn/_upload/a/close.doc',
                      },
                    ]
                  : <Object>[];
            case 'fudan.notice.attachment.download':
              return {'asset_id': 'asset-1'};
            case 'campus.openFile':
              opened.add(params['asset_id'] as String);
              return {'opened': true};
          }
          return <String, dynamic>{};
        };
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

        // Verify teacher open topic portal banner is present
        expect(find.text('FDUROP 教师开放课题系统'), findsOneWidget);
        expect(
          find.textContaining('paper.fudan.edu.cn/fdurop-pc'),
          findsOneWidget,
        );
        expect(find.text('复制网址'), findsOneWidget);

        // Sub-segment 0: 开放课题 visible
        expect(find.textContaining('复旦大学本科生学术研究资助计划'), findsOneWidget);
        expect(find.textContaining('开放课题 ('), findsOneWidget);
        expect(find.textContaining('基于端侧小模型的高校课程智能问答助教系统'), findsOneWidget);

        // Tap project card to open project detail sheet
        final projectCard = find.textContaining('基于端侧小模型的高校课程智能问答助教系统');
        await tester.ensureVisible(projectCard);
        await tester.pumpAndSettle();
        await tester.tap(projectCard);
        await tester.pumpAndSettle();

        expect(find.text('课题内容与研究目标'), findsOneWidget);
        // The seed detail keeps its full description (an empty live reply no
        // longer replaces it), so the requirements section sits below the fold.
        expect(find.textContaining('MOSS 团队'), findsWidgets);
        final projSheetScrollable = find.byType(Scrollable).last;
        await tester.scrollUntilVisible(
          find.text('申请要求与先修知识'),
          250,
          scrollable: projSheetScrollable,
        );
        expect(find.text('申请要求与先修知识'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('复制平台网址'),
          250,
          scrollable: projSheetScrollable,
        );
        expect(find.text('FDUROP 教师开放课题系统'), findsWidgets);
        expect(find.text('复制平台网址'), findsOneWidget);
        expect(find.text('联系导师申请'), findsOneWidget);

        // Close detail sheet
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        navigator.pop();
        await tester.pumpAndSettle();

        // Scroll back to top so segmented button is in view
        await tester.fling(
          find.byKey(const Key('fdurop-scroll')),
          const Offset(0, 1000),
          2000,
        );
        await tester.pumpAndSettle();

        // Sub-segment 1: 网站通知
        await tester.tap(find.textContaining('网站通知'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('关于启动2026-2027学年第一学期本科生学术研究资助计划'),
          findsOneWidget,
        );
        expect(
          find.textContaining('关于开通“FDUROP 教师开放课题申报与学生双选系统”'),
          findsOneWidget,
        );
        expect(find.textContaining('莙政学者'), findsWidgets);

        // Sub-segment 2: 文件下载 — the official jwc forms, loaded on demand.
        expect(
          bridge.invocationLog.where(
            (c) => c.toString().contains('fudan.notice.attachments'),
          ),
          isEmpty,
          reason: 'files are not fetched before the segment is opened',
        );
        await tester.tap(find.textContaining('文件下载'));
        await tester.pumpAndSettle();

        expect(find.text('䇹政项目申请书模板（2025年）'), findsOneWidget);
        expect(find.text('文件下载 (2)'), findsOneWidget);
        expect(find.byTooltip('下载并打开'), findsNWidgets(2));

        await tester.tap(find.byTooltip('下载并打开').first);
        await tester.pumpAndSettle();

        expect(opened, ['asset-1']);
        expect(find.byTooltip('打开文件'), findsOneWidget);
        expect(find.textContaining('已下载'), findsOneWidget);
      },
    );

    testWidgets('FDUROP open topics load further pages while scrolling', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestApp(
          home: ResearchPage(controller: controller),
          controller: controller,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('本科生科研 (FDUROP)'));
      await tester.pumpAndSettle();

      final total = (await ResearchService.instance.fetchFduropProjectPage(
        pageSize: 1000,
      )).total;
      expect(total, greaterThan(ResearchService.fduropPageSize));
      expect(find.text('开放课题 ($total)'), findsOneWidget);
      expect(find.textContaining('离线示例数据 · 共 $total 项'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('已显示全部 $total 项'),
        800,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('fdurop-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 400,
      );
      expect(find.text('已显示全部 $total 项'), findsOneWidget);
    });

    testWidgets(
      'Switching to 学术讲座 tab displays lectures with category filter and allows bookmarking',
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
        expect(find.textContaining('作为“国故”的西学'), findsOneWidget);
        expect(find.textContaining('陈拓 青年研究员'), findsOneWidget);
        expect(find.textContaining('光华楼西主楼2001'), findsWidgets);

        // Filter by category
        await tester.tap(find.widgetWithText(FilterChip, '物质前沿'));
        await tester.pumpAndSettle();

        expect(find.textContaining('量子计算前沿演进与拓扑容错物态实现'), findsOneWidget);

        // Toggle bookmark icon button
        final bookmarkBtn = find.byIcon(Icons.bookmark).first;
        await tester.tap(bookmarkBtn);
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Live FDUROP topics and project detail sheet renders tutor biography and lab introduction',
      (tester) async {
        bridge.campusHandler = (method, params) async {
          if (method == 'fudan.fdurop.topics') {
            return [
              {
                'id': 'live_urop_test',
                'title': '分布式智能网联车协同感知与边缘决策',
                'teacher_name': '陈老师',
                'teacher_code': '007788',
                'department_name': '计算机科学技术学院',
                'brief': '边缘协同多传感器多模态融合感知与实时路径决策。',
                'requirement': '熟悉 Linux / ROS、C++ 及计算机视觉基础。',
                'tutor_email': 'chen_lab@fudan.edu.cn',
                'tutor_mobile': '13912345678',
                'tutor_introduce': '教育部青年学者，主要从事车联网与边缘计算研究。',
                'lab_introduce': '智能网联边缘计算联合实验室（iConnect Lab）。',
                'subject_kinds': ['计算机科学与技术'],
                'topic_labels': ['登峰项目', '自动驾驶'],
              },
            ];
          } else if (method == 'fudan.fdurop.topic.detail') {
            return {
              'id': 'live_urop_test',
              'title': '分布式智能网联车协同感知与边缘决策',
              'teacher_name': '陈老师',
              'teacher_code': '007788',
              'department_name': '计算机科学技术学院',
              'brief': '边缘协同多传感器多模态融合感知与实时路径决策。',
              'requirement': '熟悉 Linux / ROS、C++ 及计算机视觉基础。',
              'tutor_email': 'chen_lab@fudan.edu.cn',
              'tutor_mobile': '13912345678',
              'tutor_introduce': '教育部青年学者，主要从事车联网与边缘计算研究。',
              'lab_introduce': '智能网联边缘计算联合实验室（iConnect Lab）。',
              'subject_kinds': ['计算机科学与技术'],
              'topic_labels': ['登峰项目', '自动驾驶'],
            };
          }
          return <String, dynamic>{};
        };

        await tester.pumpWidget(
          buildTestApp(
            home: ResearchPage(controller: controller),
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        // Switch to FDUROP tab
        await tester.tap(find.text('本科生科研 (FDUROP)'));
        await tester.pumpAndSettle();

        // Verify live project appears
        expect(find.text('开放课题 (1)'), findsOneWidget);
        expect(find.textContaining('分布式智能网联车协同感知'), findsOneWidget);

        // Tap live project to open detail sheet
        final liveCard = find.textContaining('分布式智能网联车协同感知');
        await tester.ensureVisible(liveCard);
        await tester.pumpAndSettle();
        await tester.tap(liveCard);
        await tester.pumpAndSettle();

        // Verify detail sheet shows live fields
        final sheetScrollable = find.byType(Scrollable).last;
        await tester.scrollUntilVisible(
          find.textContaining('教育部青年学者'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('指导教师简介'), findsOneWidget);
        expect(find.textContaining('教育部青年学者'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.textContaining('智能网联边缘计算联合实验室'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('课题组与实验室介绍'), findsOneWidget);
        expect(find.textContaining('智能网联边缘计算联合实验室'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('13912345678'),
          200,
          scrollable: sheetScrollable,
        );
        expect(find.text('导师联系电话'), findsOneWidget);
        expect(find.text('13912345678'), findsOneWidget);
        expect(find.text('登峰项目'), findsWidgets);

        // Reset
        ResearchService.instance.bindApi(null);
      },
    );
  });
}
