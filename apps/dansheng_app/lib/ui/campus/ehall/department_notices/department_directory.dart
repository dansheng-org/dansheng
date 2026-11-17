// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

/// One department / school / college of Fudan University.
@immutable
class DepartmentInfo {
  const DepartmentInfo({
    required this.id,
    required this.name,
    required this.shortName,
    required this.category,
    required this.websiteUrl,
    required this.noticeUrl,
    this.noticeTitle = '通知公告',
  });

  /// Unique identifier code, e.g. 'cs', 'econ', 'chinese'.
  final String id;

  /// Full official Chinese name.
  final String name;

  /// Compact name for badges / chips.
  final String shortName;

  /// Discipline category, e.g. '人文社科', '理工与新工科', '医学部', '公共与继续教育'.
  final String category;

  /// Department official website home URL.
  final String websiteUrl;

  /// Official announcement / notice list URL.
  final String noticeUrl;

  /// Notice section title.
  final String noticeTitle;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DepartmentInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Comprehensive directory of all Fudan University schools and departments.
class DepartmentDirectory {
  const DepartmentDirectory._();

  static const String catHumanities = '人文社科';
  static const String catScienceEngineering = '理工与新工科';
  static const String catMedicine = '医学部';
  static const String catGeneral = '公共与继续教育';

  static const List<String> categories = [
    catHumanities,
    catScienceEngineering,
    catMedicine,
    catGeneral,
  ];

  static const List<DepartmentInfo> all = [
    // --- 人文社科类 ---
    DepartmentInfo(
      id: 'chinese',
      name: '中国语言文学系',
      shortName: '中文系',
      category: catHumanities,
      websiteUrl: 'https://chinese.fudan.edu.cn/',
      noticeUrl: 'https://chinese.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'dfll',
      name: '外国语言文学学院',
      shortName: '外文学院',
      category: catHumanities,
      websiteUrl: 'https://dfll.fudan.edu.cn/',
      noticeUrl: 'https://dfll.fudan.edu.cn/27751/list.htm',
    ),
    DepartmentInfo(
      id: 'history',
      name: '历史学系',
      shortName: '历史系',
      category: catHumanities,
      websiteUrl: 'https://history.fudan.edu.cn/',
      noticeUrl: 'https://history.fudan.edu.cn/xwzx/tzgg.htm',
    ),
    DepartmentInfo(
      id: 'tourism',
      name: '旅游学系',
      shortName: '旅游系',
      category: catHumanities,
      websiteUrl: 'https://tourism.fudan.edu.cn/',
      noticeUrl: 'https://tourism.fudan.edu.cn/xwzx/tzgg.htm',
    ),
    DepartmentInfo(
      id: 'chm',
      name: '文物与博物馆学系',
      shortName: '文博系',
      category: catHumanities,
      websiteUrl: 'https://www.chm.fudan.edu.cn/',
      noticeUrl: 'https://www.chm.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'philosophy',
      name: '哲学学院',
      shortName: '哲学学院',
      category: catHumanities,
      websiteUrl: 'https://philosophy.fudan.edu.cn/',
      noticeUrl: 'https://philosophy.fudan.edu.cn/tzgg_20877/list.htm',
    ),
    DepartmentInfo(
      id: 'law',
      name: '法学院',
      shortName: '法学院',
      category: catHumanities,
      websiteUrl: 'https://law.fudan.edu.cn/',
      noticeUrl: 'https://law.fudan.edu.cn/28093/list.htm',
    ),
    DepartmentInfo(
      id: 'sirpa',
      name: '国际关系与公共事务学院',
      shortName: '国务学院',
      category: catHumanities,
      websiteUrl: 'https://sirpa.fudan.edu.cn/',
      noticeUrl: 'https://sirpa.fudan.edu.cn/35036/list.htm',
    ),
    DepartmentInfo(
      id: 'ssdpp',
      name: '社会发展与公共政策学院',
      shortName: '社政学院',
      category: catHumanities,
      websiteUrl: 'https://ssdpp.fudan.edu.cn/',
      noticeUrl: 'https://ssdpp.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'xwxy',
      name: '新闻学院',
      shortName: '新闻学院',
      category: catHumanities,
      websiteUrl: 'https://xwxy.fudan.edu.cn/',
      noticeUrl: 'https://xwxy.fudan.edu.cn/ggl/list.htm',
      noticeTitle: '公告栏',
    ),
    DepartmentInfo(
      id: 'econ',
      name: '经济学院',
      shortName: '经济学院',
      category: catHumanities,
      websiteUrl: 'https://econ.fudan.edu.cn/',
      noticeUrl: 'https://econ.fudan.edu.cn/xwzx/tzgg.htm',
    ),
    DepartmentInfo(
      id: 'fdsm',
      name: '管理学院',
      shortName: '管院',
      category: catHumanities,
      websiteUrl: 'https://www.fdsm.fudan.edu.cn/',
      noticeUrl: 'https://www.fdsm.fudan.edu.cn/upec/download_ugedu/list.htm',
      noticeTitle: '通知与下载',
    ),
    DepartmentInfo(
      id: 'fisf',
      name: '泛海国际金融学院',
      shortName: '泛海国金',
      category: catHumanities,
      websiteUrl: 'https://fisf.fudan.edu.cn/',
      noticeUrl: 'https://fisf.fudan.edu.cn/lists-notice.html',
    ),
    DepartmentInfo(
      id: 'som',
      name: '马克思主义学院',
      shortName: '马院',
      category: catHumanities,
      websiteUrl: 'https://som.fudan.edu.cn/',
      noticeUrl: 'https://som.fudan.edu.cn/15048/list.htm',
    ),
    DepartmentInfo(
      id: 'ices',
      name: '国际文化交流学院',
      shortName: '国交学院',
      category: catHumanities,
      websiteUrl: 'https://ices.fudan.edu.cn/',
      noticeUrl: 'https://ices.fudan.edu.cn/40353/list.htm',
    ),

    // --- 理工与新工科创新类 ---
    DepartmentInfo(
      id: 'math',
      name: '数学科学学院',
      shortName: '数院',
      category: catScienceEngineering,
      websiteUrl: 'https://math.fudan.edu.cn/',
      noticeUrl: 'https://math.fudan.edu.cn/30286/list.htm',
    ),
    DepartmentInfo(
      id: 'phys',
      name: '物理学系',
      shortName: '物理系',
      category: catScienceEngineering,
      websiteUrl: 'https://phys.fudan.edu.cn/',
      noticeUrl: 'https://phys.fudan.edu.cn/7453/list.htm',
    ),
    DepartmentInfo(
      id: 'imp',
      name: '现代物理研究所/核科学与技术系',
      shortName: '现物所',
      category: catScienceEngineering,
      websiteUrl: 'https://imp.fudan.edu.cn/',
      noticeUrl: 'https://imp.fudan.edu.cn/48897/list.htm',
    ),
    DepartmentInfo(
      id: 'chem',
      name: '化学系',
      shortName: '化学系',
      category: catScienceEngineering,
      websiteUrl: 'https://chemistry.fudan.edu.cn/',
      noticeUrl: 'https://chemistry.fudan.edu.cn/45208/list.htm',
    ),
    DepartmentInfo(
      id: 'polymer',
      name: '高分子科学系',
      shortName: '高分子系',
      category: catScienceEngineering,
      websiteUrl: 'http://polymer.fudan.edu.cn/',
      noticeUrl: 'http://polymer.fudan.edu.cn/31394/list.htm',
    ),
    DepartmentInfo(
      id: 'env',
      name: '环境科学与工程系',
      shortName: '环境系',
      category: catScienceEngineering,
      websiteUrl: 'https://environment.fudan.edu.cn/',
      noticeUrl: 'https://environment.fudan.edu.cn/26493/list.htm',
    ),
    DepartmentInfo(
      id: 'aos',
      name: '大气与海洋科学系',
      shortName: '大气海洋系',
      category: catScienceEngineering,
      websiteUrl: 'https://aos.fudan.edu.cn/',
      noticeUrl: 'https://aos.fudan.edu.cn/annoucement/list.htm',
    ),
    DepartmentInfo(
      id: 'mse',
      name: '材料科学系',
      shortName: '材料系',
      category: catScienceEngineering,
      websiteUrl: 'https://mse.fudan.edu.cn/',
      noticeUrl: 'https://mse.fudan.edu.cn/22912/list.htm',
    ),
    DepartmentInfo(
      id: 'life',
      name: '生命科学学院',
      shortName: '生科院',
      category: catScienceEngineering,
      websiteUrl: 'https://life.fudan.edu.cn/',
      noticeUrl: 'https://life.fudan.edu.cn/28139/list.htm',
    ),
    DepartmentInfo(
      id: 'sds',
      name: '大数据学院',
      shortName: '大数据学院',
      category: catScienceEngineering,
      websiteUrl: 'https://sds.fudan.edu.cn/',
      noticeUrl: 'https://sds.fudan.edu.cn/zytz/list.htm',
      noticeTitle: '重要通知',
    ),
    DepartmentInfo(
      id: 'aero',
      name: '航空航天系',
      shortName: '航空航天系',
      category: catScienceEngineering,
      websiteUrl: 'https://aero-mech.fudan.edu.cn/',
      noticeUrl: 'https://aero-mech.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'sme',
      name: '微电子学院',
      shortName: '微电子学院',
      category: catScienceEngineering,
      websiteUrl: 'https://sme.fudan.edu.cn/',
      noticeUrl: 'https://sme.fudan.edu.cn/29363/list.htm',
      noticeTitle: '学院公告',
    ),
    DepartmentInfo(
      id: 'icmne',
      name: '集成电路与微纳电子创新学院',
      shortName: '微纳电子创新学院',
      category: catScienceEngineering,
      websiteUrl: 'https://icmne.fudan.edu.cn/',
      noticeUrl: 'https://icmne.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'cs',
      name: '计算与智能创新学院 (计算机/软件)',
      shortName: '计算机/计算与智能',
      category: catScienceEngineering,
      websiteUrl: 'https://ai.fudan.edu.cn/',
      noticeUrl: 'https://ai.fudan.edu.cn/24284/list.htm',
    ),
    DepartmentInfo(
      id: 'ciram',
      name: '智能机器人与先进制造创新学院',
      shortName: '先进制造创新学院',
      category: catScienceEngineering,
      websiteUrl: 'https://ciram.fudan.edu.cn/',
      noticeUrl: 'https://ciram.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'icome',
      name: '智能材料与未来能源创新学院',
      shortName: '未来能源创新学院',
      category: catScienceEngineering,
      websiteUrl: 'https://icome.fudan.edu.cn/',
      noticeUrl: 'http://icome.fudan.edu.cn/49262/list.htm',
    ),
    DepartmentInfo(
      id: 'fit',
      name: '未来信息创新学院 (原信院)',
      shortName: '未来信息学院',
      category: catScienceEngineering,
      websiteUrl: 'https://fit.fudan.edu.cn/',
      noticeUrl: 'https://fit.fudan.edu.cn/Data/List/event',
    ),
    DepartmentInfo(
      id: 'bme',
      name: '生物医学工程与技术创新学院',
      shortName: '生医工创新学院',
      category: catScienceEngineering,
      websiteUrl: 'https://bme-college.fudan.edu.cn/',
      noticeUrl: 'https://bme-college.fudan.edu.cn/tzgg_55734/list.htm',
    ),

    // --- 医学部 ---
    DepartmentInfo(
      id: 'basicmed',
      name: '基础医学院',
      shortName: '基础医学院',
      category: catMedicine,
      websiteUrl: 'https://basicmed.fudan.edu.cn/',
      noticeUrl: 'https://basicmed.fudan.edu.cn/30927/list.htm',
    ),
    DepartmentInfo(
      id: 'sph',
      name: '公共卫生学院',
      shortName: '公卫学院',
      category: catMedicine,
      websiteUrl: 'https://sph.fudan.edu.cn/',
      noticeUrl: 'https://sph.fudan.edu.cn/ac/7',
      noticeTitle: '信息公开和告示',
    ),
    DepartmentInfo(
      id: 'pharm',
      name: '药学院',
      shortName: '药学院',
      category: catMedicine,
      websiteUrl: 'https://spfdu.fudan.edu.cn/',
      noticeUrl: 'https://spfdu.fudan.edu.cn/28477/list.htm',
    ),
    DepartmentInfo(
      id: 'nursing',
      name: '护理学院',
      shortName: '护理学院',
      category: catMedicine,
      websiteUrl: 'https://nursing.fudan.edu.cn/',
      noticeUrl: 'https://nursing.fudan.edu.cn/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'zsyy',
      name: '中山临床医学院',
      shortName: '中山医院',
      category: catMedicine,
      websiteUrl: 'https://www.zs-hospital.sh.cn/',
      noticeUrl: 'https://shmc.fudan.edu.cn/news/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'huashan',
      name: '华山临床医学院',
      shortName: '华山医院',
      category: catMedicine,
      websiteUrl: 'https://www.huashan.org.cn/',
      noticeUrl: 'https://www.huashan.org.cn/xwdt/hsgg.htm',
    ),
    DepartmentInfo(
      id: 'kqyy',
      name: '口腔医学院',
      shortName: '口腔医院',
      category: catMedicine,
      websiteUrl: 'https://www.ssdc-fudan.com/',
      noticeUrl: 'https://shmc.fudan.edu.cn/news/tzgg/list.htm',
    ),
    DepartmentInfo(
      id: 'sfms',
      name: '法医学与法庭科学学院',
      shortName: '法医学学院',
      category: catMedicine,
      websiteUrl: 'https://sfms.fudan.edu.cn/',
      noticeUrl: 'https://sfms.fudan.edu.cn/51779/list.htm',
    ),

    // --- 公共与继续教育 ---
    DepartmentInfo(
      id: 'fdty',
      name: '体育教学部',
      shortName: '体教部',
      category: catGeneral,
      websiteUrl: 'https://fdty.fudan.edu.cn/',
      noticeUrl: 'https://fdty.fudan.edu.cn/29222/list.htm',
    ),
    DepartmentInfo(
      id: 'cce',
      name: '终身教育学院',
      shortName: '终身教育学院',
      category: catGeneral,
      websiteUrl: 'https://cce.fudan.edu.cn/',
      noticeUrl: 'https://cce.fudan.edu.cn/14131/list.htm',
    ),
  ];

  static final Map<String, DepartmentInfo> _byId = {
    for (final dept in all) dept.id: dept,
  };

  /// Looks up a department by its identifier.
  static DepartmentInfo? byId(String? id) => id == null ? null : _byId[id];

  /// Lists all departments in [category].
  static List<DepartmentInfo> byCategory(String category) =>
      all.where((d) => d.category == category).toList();

  /// Default subscribed departments when first configured.
  static const List<String> defaultDepartmentIds = [
    'cs',
    'econ',
    'basicmed',
    'math',
  ];

  /// Parses a comma-separated options string into a validated list of department IDs.
  static List<String> parseSubscribed(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return defaultDepartmentIds;
    }
    final ids = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => _byId.containsKey(s))
        .toList();
    return ids.isEmpty ? defaultDepartmentIds : ids;
  }
}
