// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:dansheng_app/ui/campus/ehall/department_notices/department_directory.dart';
import 'package:dansheng_app/ui/campus/ehall/department_notices/department_notice_model.dart';
import 'package:dansheng_app/ui/campus/ehall/department_notices/department_notice_service.dart';
import 'package:dansheng_app/ui/campus/ehall/department_notices/department_subscription_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DepartmentDirectory', () {
    test('contains comprehensive directory across all categories', () {
      expect(DepartmentDirectory.all.length, greaterThanOrEqualTo(40));
      expect(
        DepartmentDirectory.categories,
        contains(DepartmentDirectory.catHumanities),
      );
      expect(
        DepartmentDirectory.categories,
        contains(DepartmentDirectory.catScienceEngineering),
      );
      expect(
        DepartmentDirectory.categories,
        contains(DepartmentDirectory.catMedicine),
      );
      expect(
        DepartmentDirectory.categories,
        contains(DepartmentDirectory.catGeneral),
      );

      final cs = DepartmentDirectory.byId('cs');
      expect(cs, isNotNull);
      expect(cs!.name, contains('计算与智能创新学院'));
      expect(cs.category, DepartmentDirectory.catScienceEngineering);

      final econ = DepartmentDirectory.byId('econ');
      expect(econ, isNotNull);
      expect(econ!.shortName, '经济学院');

      final basicmed = DepartmentDirectory.byId('basicmed');
      expect(basicmed, isNotNull);
      expect(basicmed!.category, DepartmentDirectory.catMedicine);
      expect(
        basicmed.noticeUrl,
        'https://basicmed.fudan.edu.cn/30927/list.htm',
      );

      final pharm = DepartmentDirectory.byId('pharm');
      expect(pharm, isNotNull);
      expect(pharm!.noticeUrl, 'https://spfdu.fudan.edu.cn/28477/list.htm');
    });

    test('parseSubscribed handles null, empty, and custom selections', () {
      expect(
        DepartmentDirectory.parseSubscribed(null),
        DepartmentDirectory.defaultDepartmentIds,
      );
      expect(
        DepartmentDirectory.parseSubscribed(''),
        DepartmentDirectory.defaultDepartmentIds,
      );
      expect(DepartmentDirectory.parseSubscribed('cs,econ'), ['cs', 'econ']);
      expect(DepartmentDirectory.parseSubscribed('invalid,econ,unknown'), [
        'econ',
      ]);
    });
  });

  group('DepartmentNoticeService & HTML Parsing', () {
    test(
      'parses standard WebPlus table/list rows and resolves relative URLs',
      () {
        const sampleHtml = '''
        <ul class="wp_article_list">
          <li class="list_item">
            <span class="Article_Title"><a href="/2026/1115/c12345a67890/page.htm" title="关于开展2026-2027学年学术研讨会的通知">关于开展2026-2027学年学术研讨会的通知</a></span>
            <span class="Article_PublishDate">2026-11-15</span>
          </li>
          <li class="list_item">
            <span class="Article_Title"><a href="https://other.fudan.edu.cn/info/1.htm">推免生综合素质考核实施办法公示</a></span>
            <span class="Article_PublishDate">2026-11-14</span>
          </li>
          <li class="list_item">
            <a href="http://cs.fudan.edu.cn/list.htm">更多</a>
          </li>
        </ul>
      ''';

        final dept = DepartmentDirectory.byId('cs')!;
        final items = DepartmentNoticeService.parseHtml(sampleHtml, dept);

        expect(items.length, 2);
        expect(items[0].title, '关于开展2026-2027学年学术研讨会的通知');
        expect(items[0].date, '2026-11-15');
        expect(
          items[0].url,
          'https://ai.fudan.edu.cn/2026/1115/c12345a67890/page.htm',
        );
        expect(items[0].departmentId, 'cs');

        expect(items[1].title, '推免生综合素质考核实施办法公示');
        expect(items[1].date, '2026-11-14');
        expect(items[1].url, 'https://other.fudan.edu.cn/info/1.htm');
      },
    );

    test('parses single-quote hrefs and div-based list layouts', () {
      const sampleHtml = '''
        <div class="news_list">
          <div class="news_item">
            <span class="news_title"><a href='/24/dd/c12493a795869/page.htm' title='复旦大学药学院学术讲座通知'>复旦大学药学院学术讲座通知</a></span>
            <span class="news_date">2026-10-22</span>
          </div>
          <div class="news_item">
            <a href='/page/2'>下一页</a>
          </div>
        </div>
      ''';

      final dept = DepartmentDirectory.byId('pharm')!;
      final items = DepartmentNoticeService.parseHtml(sampleHtml, dept);

      expect(items.length, 1);
      expect(items[0].title, '复旦大学药学院学术讲座通知');
      expect(items[0].date, '2026-10-22');
      expect(
        items[0].url,
        'https://spfdu.fudan.edu.cn/24/dd/c12493a795869/page.htm',
      );
      expect(items[0].departmentId, 'pharm');
    });

    test('getTileData formats TileFacts note and rows', () async {
      final service = DepartmentNoticeService.instance;
      service.clear();

      service.injectFixtures('cs', const [
        DepartmentNoticeItem(
          id: '1',
          title: '人工智能前沿报告会',
          url: 'https://ai.fudan.edu.cn/1',
          date: '2026-11-15',
          departmentId: 'cs',
          departmentName: '计算与智能',
        ),
      ]);

      service.injectFixtures('econ', const [
        DepartmentNoticeItem(
          id: '2',
          title: '世界经济论坛论文征集',
          url: 'https://econ.fudan.edu.cn/2',
          date: '2026-11-14',
          departmentId: 'econ',
          departmentName: '经济学院',
        ),
      ]);

      final tileData = await service.getTileData(['cs', 'econ']);
      expect(tileData, isNotNull);
      expect(tileData!.facts.value, '2');
      expect(tileData.facts.unit, '条');
      expect(tileData.facts.note, contains('人工智能前沿报告会'));
      expect(tileData.facts.rows.length, 1);
      expect(tileData.facts.rows.first.label, contains('世界经济论坛'));
    });
  });

  group('DepartmentSubscriptionSheet UI', () {
    testWidgets('allows selecting and deselecting departments', (tester) async {
      List<String>? savedResult;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  savedResult = await showDepartmentSubscriptionSheet(
                    context,
                    currentSelected: ['cs'],
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      // Open sheet
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      // Check header and default state
      expect(find.text('选择接收院系通知'), findsOneWidget);
      expect(find.text('已选 1 个院系'), findsOneWidget);

      // Search for '哲学'
      await tester.enterText(find.byType(TextField), '哲学');
      await tester.pumpAndSettle();

      expect(find.text('哲学学院'), findsOneWidget);

      // Check the checkbox for 哲学学院
      await tester.tap(find.text('哲学学院'));
      await tester.pumpAndSettle();

      expect(find.text('已选 2 个院系'), findsOneWidget);

      // Confirm
      await tester.tap(find.text('确认保存'));
      await tester.pumpAndSettle();

      expect(savedResult, containsAll(['cs', 'philosophy']));
    });
  });
}
