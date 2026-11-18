// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';
import 'research_models.dart';

/// Service providing Fudan University research news, research groups (课题组),
/// academic lectures, and FDUROP (本科生科研/望道/莙政/开放课题与文件下载).
class ResearchService extends ChangeNotifier {
  static final ResearchService instance = ResearchService._();
  ResearchService._();

  // In-memory persistent states
  final Set<String> _followedGroupIds = {'rg_nlp', 'rg_brain'};
  final Set<String> _bookmarkedLectureIds = {'lec_1'};
  final Set<String> _bookmarkedFduropProjectIds = {'fdurop_p1'};
  final Set<String> _downloadedFduropDocIds = <String>{};

  Set<String> get followedGroupIds => Set.unmodifiable(_followedGroupIds);
  Set<String> get bookmarkedLectureIds =>
      Set.unmodifiable(_bookmarkedLectureIds);
  Set<String> get bookmarkedFduropProjectIds =>
      Set.unmodifiable(_bookmarkedFduropProjectIds);
  Set<String> get downloadedFduropDocIds =>
      Set.unmodifiable(_downloadedFduropDocIds);

  bool isGroupFollowed(String id) => _followedGroupIds.contains(id);
  bool isLectureBookmarked(String id) => _bookmarkedLectureIds.contains(id);
  bool isFduropProjectBookmarked(String id) =>
      _bookmarkedFduropProjectIds.contains(id);
  bool isFduropDocumentDownloaded(String id) =>
      _downloadedFduropDocIds.contains(id);

  /// Toggle follow state for a research group.
  void toggleFollowGroup(String id) {
    if (_followedGroupIds.contains(id)) {
      _followedGroupIds.remove(id);
    } else {
      _followedGroupIds.add(id);
    }
    notifyListeners();
  }

  /// Toggle bookmark state for an academic lecture.
  void toggleBookmarkLecture(String id) {
    if (_bookmarkedLectureIds.contains(id)) {
      _bookmarkedLectureIds.remove(id);
    } else {
      _bookmarkedLectureIds.add(id);
    }
    notifyListeners();
  }

  /// Toggle bookmark state for an FDUROP project.
  void toggleBookmarkFduropProject(String id) {
    if (_bookmarkedFduropProjectIds.contains(id)) {
      _bookmarkedFduropProjectIds.remove(id);
    } else {
      _bookmarkedFduropProjectIds.add(id);
    }
    notifyListeners();
  }

  /// Mark an FDUROP document as downloaded.
  Future<void> downloadFduropDocument(String id) async {
    // Simulates an async safe document download
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _downloadedFduropDocIds.add(id);
    notifyListeners();
  }

  // =========================================================================
  // 1. 科研动态数据 (Research News)
  // =========================================================================
  static const List<ResearchNewsItem> _initialNews = [
    ResearchNewsItem(
      id: 'news_1',
      title: '《自然》发表复旦大学脑科学前沿科学中心最新神经计算成果',
      summary:
          '科研团队揭示了多尺度神经环路突触可塑性的自适应调控机制，为开发新型低功耗类脑计算算法提供了重要生物学启发。',
      content:
          '复旦大学脑科学前沿科学中心、脑功能与脑疾病全国重点实验室研究团队在《自然》（Nature）发表题为《Adaptive Synaptic Plasticity in Multi-Scale Neural Circuits》的长篇研究论文。该研究结合在体双光子钙成像与全脑投射重构技术，解析了小鼠在复杂联想学习任务中海马与皮层间突触权重的动态演进规律。成果对新一代仿生神经网络与类脑芯片架构设计具有重大指导意义。',
      source: '科学技术研究院',
      department: '脑科学研究院',
      publishDate: '2026-11-16',
      category: '科研突破',
      readCount: 3820,
      isPinned: true,
      url: 'https://news.fudan.edu.cn/research/20261116-brain',
    ),
    ResearchNewsItem(
      id: 'news_2',
      title: '复旦集成芯片全国重点实验室研制出晶圆级二维互补场效应芯片',
      summary:
          '微电子学院芯片团队攻克超薄二维半导体沟道与高介电常数栅介质集成难题，芯片能效比提升超3倍。',
      content:
          '复旦大学微电子学院、集成芯片与系统全国重点实验室团队在后摩尔时代先进逻辑芯片领域取得关键技术突破，研制出基于双层二硫化钼材料的晶圆级二维互补场效应晶体管（CFET）芯片原型。在1nm等效栅长节点下实现了极低的亚阈值摆幅与超低漏电流，为后摩尔时代高性能计算芯片提供了新型技术路径。',
      source: '集成芯片与系统全国重点实验室',
      department: '微电子学院',
      publishDate: '2026-11-14',
      category: '科研突破',
      readCount: 2940,
      isPinned: true,
      url: 'https://microelectronics.fudan.edu.cn/news/20261114',
    ),
    ResearchNewsItem(
      id: 'news_3',
      title: '关于组织申报2027年度国家自然科学基金青年学生基础研究项目（博士研究生）的通知',
      summary:
          '面向在读二年级及以上全日制博士生，支持开展高水平探索性原创研究，请各院系科研科研秘书于12月10日前完成初审。',
      content:
          '为进一步强化青年科技人才队伍建设，国家自然科学基金委2027年度青年学生基础研究项目（博士研究生）申报工作现已启动。资助强度为每项30万元，资助期限2-3年。申请人须具有扎实理论功底和创新学术思想，各院系需严格把握申报质量，做好伦理审查与学术规范把关。',
      source: '科学技术研究院',
      department: '科研院基础研究处',
      publishDate: '2026-11-12',
      category: '项目申报',
      readCount: 5120,
      isPinned: false,
      url: 'https://keyan.fudan.edu.cn/notices/20261112-nsfc',
    ),
    ResearchNewsItem(
      id: 'news_4',
      title: '高分子科学系团队研发出超高透气自愈合生物相容柔性传感电子织物',
      summary:
          '发表于《先进材料》（Advanced Materials），实现了全天候健康体征连续监测与闭环电生理刺激。',
      content:
          '复旦大学高分子科学系、聚合物分子工程国家重点实验室研究团队通过微相分离与动态配位键构筑技术，合成了兼具自愈合、超高透气性与优异拉伸导电率的本征弹性复合材料。该材料在经历10000次弯折后仍能保持99%以上的导电灵敏度，在智能医疗织物和脑机接口体表电极领域展现出广泛应用潜力。',
      source: '高分子科学系',
      department: '高分子科学系',
      publishDate: '2026-11-10',
      category: '科研突破',
      readCount: 1680,
      isPinned: false,
    ),
    ResearchNewsItem(
      id: 'news_5',
      title: '【招生招募】计算机学院智能信息处理重点实验室NLP团队招收2027级推免直博生',
      summary:
          '研究方向涵盖大语言模型推理加速、具身智能知识图谱与多模态对齐，欢迎计算机、数学及相关专业推免生投递简历。',
      content:
          '复旦大学计算机科学技术学院智能信息处理重点实验室NLP与多模态研究组开放2027级推免直博生（2名）与科研助理（2名）申请。实验室拥有充足的高性能算力集群，与国内外一流顶尖实验室保持深度合作，常年支持博士生前往顶级学术会议（ACL、EMNLP、NeurIPS、ICLR）现场作口头报告。',
      source: '计算机科学技术学院',
      department: '计算机科学技术学院',
      publishDate: '2026-11-08',
      category: '招募招生',
      readCount: 4210,
      isPinned: false,
    ),
    ResearchNewsItem(
      id: 'news_6',
      title: '第十五届相辉学术沙龙：从基础物理拓扑物态到量子计算架构',
      summary:
          '特邀中科院与复旦物理系知名学者作专题学术报告，邯郸校区相辉堂北堂同步开放线上直播。',
      content:
          '本期学术沙龙围绕拓扑量子绝缘体、马约拉纳费米子与容错量子计算展开跨学科研讨。报告会设置青年学者研讨环节与墙报交流展区，欢迎全校物理、材料及微电子方向师生参加。',
      source: '物理学系',
      department: '物理学系',
      publishDate: '2026-11-05',
      category: '学术讲座',
      readCount: 1980,
      isPinned: false,
    ),
  ];

  // =========================================================================
  // 2. 课题组数据 (Research Groups)
  // =========================================================================
  static const List<ResearchGroupItem> _initialGroups = [
    ResearchGroupItem(
      id: 'rg_nlp',
      name: '智能信息处理与大模型认知研究组',
      leader: '邱教授',
      leaderTitle: '教授 / 博士生导师 / 国家级高层次人才',
      department: '计算机科学技术学院',
      campus: '江湾校区',
      researchDirections: ['自然语言处理', '大模型推理加速', '多模态对齐', 'AI for Science'],
      description:
          '课题组长期深耕自然语言处理与认知推理前沿，主持国家重点研发计划项目与多项国家自然科学基金重点项目。在国际顶级人工智能与计算语言学会议发表高水平论文百余篇，开源成果获得学术界与产业界广泛关注。',
      recentPapers: [
        'MOSS-2: Efficient Multimodal Alignment via Hierarchical Representation (ICLR 2026)',
        'Reasoning Graph Distillation for Large Language Models (ACL 2026 Oral)',
        'Fast Decoding in Speculative Transformers (NeurIPS 2025)',
      ],
      recruitment: '常年招收推免直博生、博士后研究员及优秀访问学生。推免生需具备扎实的数据结构与数学基础。',
      contactEmail: 'nlp_fudan@fudan.edu.cn',
      labLocation: '江湾校区交叉二号楼B区502室',
    ),
    ResearchGroupItem(
      id: 'rg_brain',
      name: '类脑智能与脑机接口前沿实验室',
      leader: '冯教授团队',
      leaderTitle: '特聘教授 / 国家杰出青年科学基金获得者',
      department: '类脑智能科学与技术研究院 / 脑科学研究院',
      campus: '枫林校区',
      researchDirections: ['类脑计算', '脑机接口', '神经影像大数据', '神经形态芯片'],
      description:
          '实验室依托复旦大学脑科学前沿科学中心和类脑智能科学与技术研究院，面向国家脑科学重大战略，重点攻关高通量侵入/非侵入式脑机接口、全脑神经环路数字化仿真及类脑智能算法。',
      recentPapers: [
        'Adaptive Synaptic Plasticity in Multi-Scale Neural Circuits (Nature 2026)',
        'Wireless High-Density Neural Interface for Motor Decoding (Nature Biomedical Engineering 2025)',
        'Spike-Driven Neuromorphic Architecture for Edge Intelligence (IEEE TPAMI 2025)',
      ],
      recruitment: '招收生物医学工程、自动化、计算机与神经科学背景博士生2名，提供丰厚科研津贴与国际联培机会。',
      contactEmail: 'brain_lab@fudan.edu.cn',
      labLocation: '枫林校区明道楼一楼脑机实验室',
    ),
    ResearchGroupItem(
      id: 'rg_chip',
      name: '集成芯片与超低功耗电路课题组',
      leader: '曾教授',
      leaderTitle: '教授 / 国家集成电路产教融合创新平台首席专家',
      department: '微电子学院',
      campus: '张江校区',
      researchDirections: ['二维材料集成电路', '存算一体芯片', '晶圆级CFET', '射频微波IC'],
      description:
          '课题组拥有完备的微纳加工平台与射频芯片高频测试实验室，承担国家科技重大专项核心课题，致力于攻克新原理器件物理、后摩尔时代三维异质集成与超低功耗智能芯片核心技术。',
      recentPapers: [
        'Wafer-scale 2D Complementary Field-Effect Transistors (Science 2026)',
        'Sub-1nm Equivalent Oxide Thickness High-k Dielectric Integration (Nature Electronics 2025)',
        'Cryogenic SRAM for Quantum Computing Control (ISSCC 2025)',
      ],
      recruitment: '招收微电子学、固体电子学、材料物理方向推免生及博士后。',
      contactEmail: 'chip_fudan@fudan.edu.cn',
      labLocation: '张江校区微电子大楼C栋304室',
    ),
    ResearchGroupItem(
      id: 'rg_polymer',
      name: '智能高分子与柔性电子材料研究室',
      leader: '彭教授团队',
      leaderTitle: '中国科学院院士团队 / 杰青',
      department: '高分子科学系',
      campus: '江湾校区',
      researchDirections: ['柔性光电纤维', '自愈合智能材料', '储能器件', '可穿戴生物传感'],
      description:
          '立足聚合物分子工程国家重点实验室，开创了新型纤维状能源与光电器件新方向，推动功能高分子在智慧医疗、柔性可穿戴传感与航空航天装备中的工程化应用。',
      recentPapers: [
        'Breathable Self-Healing Smart Textiles with Closed-Loop Biofeedback (Advanced Materials 2026)',
        'Photovoltaic Fibers Integrated with Micro-Supercapacitors (Nature Nanotechnology 2025)',
      ],
      recruitment: '招收化学、材料物理与高分子科学方向直博生2名，课题组提供国际一流的仪器表征平台。',
      contactEmail: 'polymer_lab@fudan.edu.cn',
      labLocation: '江湾校区先进材料实验室大楼218室',
    ),
    ResearchGroupItem(
      id: 'rg_virology',
      name: '医学分子病毒学重点实验室病原研究组',
      leader: '袁教授',
      leaderTitle: '讲席教授 / 博士生导师',
      department: '基础医学院',
      campus: '枫林校区',
      researchDirections: ['新发突发传染病', '广谱中和抗体', '抗病毒小分子药物', '宿主天然免疫'],
      description:
          '医学分子病毒学教育部/卫健委重点实验室核心团队，聚焦重大病毒性传染病致病机理、病毒与宿主相互作用网络及新型疫苗与抗病毒药物设计。',
      recentPapers: [
        'Structural Basis of Broad-Spectrum Neutralizing Antibodies Against Emerging Coronaviruses (Cell 2025)',
        'Innate Immune Sensing of Viral RNA Degradation (Nature Microbiology 2025)',
      ],
      recruitment: '招收基础医学、生物化学、生物信息学方向博士生与博士后。',
      contactEmail: 'virology_fudan@fudan.edu.cn',
      labLocation: '枫林校区治道楼五楼重点实验室',
    ),
    ResearchGroupItem(
      id: 'rg_quantum',
      name: '表面物理与低维拓扑量子材料课题组',
      leader: '修教授',
      leaderTitle: '教授 / 国家杰青 / 物理学系副主任',
      department: '物理学系',
      campus: '邯郸校区',
      researchDirections: ['拓扑半金属', '量子反常霍尔效应', '强关联超导', '极低温强磁场输运'],
      description:
          '应用表面物理国家重点实验室重点团队，专注于拓扑狄拉克半金属、外尔半金属以及低维磁性异质结的分子束外延制备与极低温物性测量。',
      recentPapers: [
        'Observation of Higher-Order Topological States in van der Waals Heterostructures (Nature Materials 2025)',
        'Chiral Anomaly in Topological Dirac Semimetals (Physical Review Letters 2025)',
      ],
      recruitment: '招收凝聚态物理、光学及微纳制备方向推免直博生。',
      contactEmail: 'quantum_phys@fudan.edu.cn',
      labLocation: '邯郸校区物理楼108超低温实验室',
    ),
  ];

  // =========================================================================
  // 3. 学术讲座数据 (Academic Lectures)
  // =========================================================================
  static const List<ResearchLectureItem> _initialLectures = [
    ResearchLectureItem(
      id: 'lec_1',
      title: '【浦江科学大师讲坛】量子计算前沿演进与拓扑容错物态实现',
      speaker: '彼得·格林教授 (Prof. Peter Green)',
      speakerTitle: '国际著名拓扑物理学家、外籍院士',
      time: '2026-11-20 (周五) 14:30 - 16:30',
      venue: '邯郸校区 相辉堂北堂 / 线上同步直播',
      organizer: '复旦大学科学技术研究院、物理学系',
      description:
          '讲座将全面回顾非阿贝尔任意子态的实验探测历程，并深入探讨基于拓扑量子纠错码的下一代通用量子计算机系统设计挑战。',
    ),
    ResearchLectureItem(
      id: 'lec_2',
      title: '【江湾交叉前沿论坛】从生物神经元脉冲机制到类脑具身智能机器人',
      speaker: '李博士',
      speakerTitle: '类脑智能前沿研究所首席科学家',
      time: '2026-11-24 (周二) 15:00 - 17:00',
      venue: '江湾校区 交叉二号楼一楼报告厅',
      organizer: '计算机科学技术学院、类脑智能科学与技术研究院',
      description:
          '探讨生物脑突触动力学在仿生四足机器人动态平衡与视觉伺服系统中的移植应用，现场将展示最新类脑控制演示样机。',
    ),
    ResearchLectureItem(
      id: 'lec_3',
      title: '【枫林生物医药讲座】高通量靶向蛋白降解药物（PROTAC/分子胶）设计策略',
      speaker: '陈研究员',
      speakerTitle: '国家重点研发计划首席科学家',
      time: '2026-11-27 (周五) 10:00 - 11:30',
      venue: '枫林校区 复星楼三楼多功能学术厅',
      organizer: '基础医学院、药学院',
      description:
          '系统阐述基于人工智能晶体结构生成与微流控筛选技术的靶向蛋白降解化合物开发新范式。',
    ),
  ];

  // =========================================================================
  // 4. FDUROP 网站通知数据 (FDUROP Notices)
  // =========================================================================
  static const List<FduropNoticeItem> _initialFduropNotices = [
    FduropNoticeItem(
      id: 'fdurop_n1',
      title: '关于启动2026-2027学年第一学期本科生学术研究资助计划（FDUROP）立项申报的通知',
      program: '望道/曦源',
      publishDate: '2026-10-18',
      summary:
          '涵盖“曦源项目”、“望道学者”、“登峰项目”，面向大二、大三全日制本科生开放系统填报，11月25日截止导师线上确认。',
      content:
          '为进一步营造浓郁本科生学术研究氛围，教务处拔尖人才培养办公室即日起启动2026-2027学年秋季学期复旦大学本科生学术研究资助计划（FDUROP）申报工作。曦源项目资助强度为每项1.0万元，望道学者项目资助强度为每项1.5万元，登峰计划每项资助最高2.5万元。申请人需在FDUROP管理系统完成《立项申请书》填报，并联系指导教师完成推荐确认。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261018-declare',
    ),
    FduropNoticeItem(
      id: 'fdurop_n2',
      title: '关于开展2026年度复旦大学“莙政学者”项目结题答辩与优秀成果评选的通知',
      program: '莙政',
      publishDate: '2026-10-25',
      summary:
          '定于11月28日在邯郸校区光华楼举行现场学术汇报会，评选年度“优秀莙政学者”并颁发证书。',
      content:
          '各莙政学者项目组：2026年度李政道先生设立的“莙政学者”科研训练项目已进入收尾结题阶段。请各项目负责人于11月20日前在系统提交结题学术论文（按要求格式排版）、查重报告及财务报销明细表。各学科评审组将安排现场答辩与墙报展示，欢迎全校师生观摩旁听。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261025-junzheng',
    ),
    FduropNoticeItem(
      id: 'fdurop_n3',
      title: '第十四届复旦大学本科生学术研究论坛暨FDUROP年会征文与报告通知',
      program: '全计划',
      publishDate: '2026-11-02',
      summary:
          '大会设自然科学、工程技术、人文社科、医学交叉4个分论坛，优秀论文将汇编成册入选校史文献库。',
      content:
          '复旦大学本科生学术研究论坛每年举办一届，旨在为广大致力于前沿探索的本科生搭建跨校区、跨学科的高水平学术交流舞台。征文范围覆盖所有正在执行或已结题的FDUROP项目研究成果，入选口头报告者将获颁优秀学术演讲证书。',
      url: 'http://www.fdurop.fudan.edu.cn/forum/2026-annual',
    ),
    FduropNoticeItem(
      id: 'fdurop_n4',
      title: '关于组织2026年秋季学期“望道项目”中期进展报告提交与核查的通知',
      program: '望道',
      publishDate: '2026-11-06',
      summary:
          '请各项目负责人登录系统下载并填写《中期进展检查表》，由导师签署进展评估意见后扫描上传。',
      content:
          '望道学者项目执行期过半，中期考核是保证科研质量的关键环节。教务处将对实验进度缓慢、阶段成果不足的项目安排学术督导沟通。请于11月30日前完成系统提交。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261106-midterm',
    ),
    FduropNoticeItem(
      id: 'fdurop_n5',
      title: '2026年度FDUROP交叉学科专项与质研计划立项评审结果公示',
      program: '登峰',
      publishDate: '2026-11-12',
      summary:
          '经专家委员会初审与现场双盲评审，共计42项交叉创新课题获得立项资助，现予以校内公示。',
      content:
          '本次交叉学科专项聚焦“人工智能赋能人文社科”与“医工交叉诊疗技术”两大前沿领域，共有来自18个院系的本科生团队脱颖而出。公示期为5个工作日。',
      url: 'http://www.fdurop.fudan.edu.cn/results/2026-interdisciplinary',
    ),
  ];

  // =========================================================================
  // 5. 开放科研项目数据 (Open Research Projects)
  // =========================================================================
  static const List<FduropProjectItem> _initialFduropProjects = [
    FduropProjectItem(
      id: 'fdurop_p1',
      title: '基于端侧小模型的高校课程智能问答助教系统构建与实证评估',
      program: '曦源项目',
      advisor: '邱教授',
      advisorTitle: '教授 / 博士生导师',
      department: '计算机科学技术学院',
      campus: '江湾校区',
      targetGrade: '大二、大三本科生（计算机、软件工程、大数据专业优先）',
      quota: 2,
      deadline: '2026-11-30',
      status: '招募中',
      description:
          '本项目依托智能信息处理重点实验室，探索将量化小语言模型（SLM）部署于本地移动端或边缘计算设备，结合检索增强生成（RAG）构建专属校园课程知识库，开展端侧推理加速与交互评测。',
      requirements: '掌握Python基础，了解PyTorch基本使用，具备基本自然语言处理或Web全栈开发经验。',
      contactEmail: 'nlp_fudan@fudan.edu.cn',
    ),
    FduropProjectItem(
      id: 'fdurop_p2',
      title: '阿尔茨海默病突触功能障碍小鼠模型的在体双光子钙成像分析',
      program: '望道项目',
      advisor: '冯教授团队',
      advisorTitle: '特聘教授 / 杰青',
      department: '脑科学前沿科学中心 / 基础医学院',
      campus: '枫林校区',
      targetGrade: '大二、大三本科生（基础医学、生命科学、生医工背景）',
      quota: 1,
      deadline: '2026-12-05',
      status: '招募中',
      description:
          '利用双光子激光共聚焦显微镜观察APP/PS1转基因小鼠在早期认知减退阶段皮层锥体神经元树突棘的变化规律，结合荧光分子标记开展长时程活体追踪。',
      requirements: '修读过生物化学或神经生物学，细心耐心，能保证每周至少8小时实验进组时间。',
      contactEmail: 'brain_lab@fudan.edu.cn',
    ),
    FduropProjectItem(
      id: 'fdurop_p3',
      title: '高比能固态锂电池微结构界面电化学演化与原位表征',
      program: '莙政学者',
      advisor: '彭教授团队',
      advisorTitle: '中国科学院院士团队 / 教授',
      department: '先进材料实验室 / 化学系',
      campus: '江湾校区',
      targetGrade: '大二至大四本科生（化学、材料、高分子专业）',
      quota: 2,
      deadline: '2026-11-28',
      status: '招募中',
      description:
          '探究固态电解质与锂金属阳极界面的锂枝晶生长动力学机制，通过分子动力学模拟与原位显微表征辅助设计具有自平滑效应的高性能固态电解质薄膜。',
      requirements: '物理化学与材料学基础扎实，有较强文献阅读能力与实验动手能力。',
      contactEmail: 'polymer_lab@fudan.edu.cn',
    ),
    FduropProjectItem(
      id: 'fdurop_p4',
      title: '新原理二维半导体异质结场效应晶体管器件制备与量子输运测试',
      program: '登峰项目',
      advisor: '曾教授',
      advisorTitle: '教授 / 国家产教融合平台首席专家',
      department: '微电子学院',
      campus: '张江校区',
      targetGrade: '大二、大三本科生（微电子科学、应用物理、电子信息）',
      quota: 2,
      deadline: '2026-12-10',
      status: '招募中',
      description:
          '学习超净间微纳光刻加工、电子束蒸发（EBE）与极低温电学探针台测试技术，参与构建基于原子级二硫化钼/黑磷异质结的新型负电容晶体管原型。',
      requirements: '了解半导体物理或固体电子学基础，有意愿深入微电子器件科研。',
      contactEmail: 'chip_fudan@fudan.edu.cn',
    ),
    FduropProjectItem(
      id: 'fdurop_p5',
      title: '数字经济赋能长三角一体化产业链韧性的实证测度与案例研究',
      program: '开放自选课题',
      advisor: '陆教授',
      advisorTitle: '特聘教授 / 博士生导师',
      department: '经济学院',
      campus: '邯郸校区',
      targetGrade: '大一至大三本科生（经济学、金融学、管理科学专业）',
      quota: 2,
      deadline: '2026-12-15',
      status: '招募中',
      description:
          '基于上市公司供应链网络大数据与长三角微观企业调查问卷，构建产业链韧性量化评估指标体系，结合计量经济学因果推断模型开展经验实证研究。',
      requirements: '熟练掌握Stata或R语言或Python数据清洗，具备较强统计计量基础。',
      contactEmail: 'econ_fudan@fudan.edu.cn',
    ),
    FduropProjectItem(
      id: 'fdurop_p6',
      title: '中国古代文论命题在近现代跨文化语境中的阐释与范式转移',
      program: '望道项目',
      advisor: '查教授',
      advisorTitle: '文科资深教授 / 博士生导师',
      department: '中国语言文学系',
      campus: '邯郸校区',
      targetGrade: '中文系、哲学学院、历史学系本科生',
      quota: 1,
      deadline: '2026-11-26',
      status: '招募中',
      description:
          '考释“意境”、“文气”、“神思”等传统文论范畴在西学东渐时期的翻译与话语重塑，建立多语种对勘文献数据库，撰写高质量学术论文。',
      requirements: '古典文献阅读能力强，英文读写流利，学术志趣坚定。',
      contactEmail: 'chinese_fudan@fudan.edu.cn',
    ),
  ];

  // =========================================================================
  // 6. FDUROP 相关文件下载数据 (FDUROP Document Downloads)
  // =========================================================================
  static const List<FduropDocumentItem> _initialFduropDocuments = [
    FduropDocumentItem(
      id: 'doc_1',
      title: '复旦大学本科生学术研究资助计划（FDUROP）立项申请书模板（2026版）.docx',
      category: '立项申报',
      fileFormat: 'DOCX',
      fileSize: '340 KB',
      updateDate: '2026-10-15',
      downloadUrl: 'http://www.fdurop.fudan.edu.cn/downloads/fdurop_apply_2026.docx',
    ),
    FduropDocumentItem(
      id: 'doc_2',
      title: 'FDUROP中期进展报告表与指导教师审核评语单.docx',
      category: '中期检查',
      fileFormat: 'DOCX',
      fileSize: '185 KB',
      updateDate: '2026-10-18',
      downloadUrl: 'http://www.fdurop.fudan.edu.cn/downloads/fdurop_midterm_form.docx',
    ),
    FduropDocumentItem(
      id: 'doc_3',
      title: '复旦大学FDUROP结题论文写作规范与成果总结报告模板.pdf',
      category: '结题评审',
      fileFormat: 'PDF',
      fileSize: '620 KB',
      updateDate: '2026-10-22',
      downloadUrl: 'http://www.fdurop.fudan.edu.cn/downloads/fdurop_thesis_guide.pdf',
    ),
    FduropDocumentItem(
      id: 'doc_4',
      title: '复旦大学本科生学术研究导师推荐信及团队分工确认书.docx',
      category: '立项申报',
      fileFormat: 'DOCX',
      fileSize: '120 KB',
      updateDate: '2026-10-15',
      downloadUrl: 'http://www.fdurop.fudan.edu.cn/downloads/fdurop_recommendation.docx',
    ),
    FduropDocumentItem(
      id: 'doc_5',
      title: '复旦大学本科生学术研究资助计划经费使用与财务报销指南手册（2026版）.pdf',
      category: '经费管理',
      fileFormat: 'PDF',
      fileSize: '1.1 MB',
      updateDate: '2026-09-28',
      downloadUrl: 'http://www.fdurop.fudan.edu.cn/downloads/fdurop_financial_guide.pdf',
    ),
    FduropDocumentItem(
      id: 'doc_6',
      title: '复旦大学优秀本科生学术研究结题论文精选集（第十三届优秀成果汇编）.pdf',
      category: '结题评审',
      fileFormat: 'PDF',
      fileSize: '4.5 MB',
      updateDate: '2026-09-10',
      downloadUrl: 'http://www.fdurop.fudan.edu.cn/downloads/fdurop_selected_papers_v13.pdf',
    ),
  ];

  // =========================================================================
  // Query APIs
  // =========================================================================

  /// Get research news with optional filtering by category and keyword search.
  Future<List<ResearchNewsItem>> getNews({
    String? category,
    String? query,
  }) async {
    return _initialNews.where((item) {
      if (category != null && category != '全部' && item.category != category) {
        return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = item.title.toLowerCase().contains(q);
        final matchSummary = item.summary.toLowerCase().contains(q);
        final matchDept = item.department.toLowerCase().contains(q);
        final matchSource = item.source.toLowerCase().contains(q);
        if (!matchTitle && !matchSummary && !matchDept && !matchSource) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Get research groups with optional followed-only filter, department filter, and search.
  Future<List<ResearchGroupItem>> getGroups({
    bool? followedOnly,
    String? department,
    String? campus,
    String? query,
  }) async {
    return _initialGroups.map((group) {
      return group.copyWith(
        isFollowed: _followedGroupIds.contains(group.id),
      );
    }).where((item) {
      if (followedOnly == true && !item.isFollowed) {
        return false;
      }
      if (department != null &&
          department != '全部' &&
          item.department != department) {
        return false;
      }
      if (campus != null && campus != '全部' && item.campus != campus) {
        return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchName = item.name.toLowerCase().contains(q);
        final matchLeader = item.leader.toLowerCase().contains(q);
        final matchDept = item.department.toLowerCase().contains(q);
        final matchDirections = item.researchDirections.any(
          (d) => d.toLowerCase().contains(q),
        );
        if (!matchName && !matchLeader && !matchDept && !matchDirections) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Get lectures with bookmark status applied.
  Future<List<ResearchLectureItem>> getLectures({String? query}) async {
    return _initialLectures.map((lec) {
      return lec.copyWith(
        isBookmarked: _bookmarkedLectureIds.contains(lec.id),
      );
    }).where((item) {
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = item.title.toLowerCase().contains(q);
        final matchSpeaker = item.speaker.toLowerCase().contains(q);
        final matchVenue = item.venue.toLowerCase().contains(q);
        if (!matchTitle && !matchSpeaker && !matchVenue) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Get FDUROP website notices.
  Future<List<FduropNoticeItem>> getFduropNotices({
    String? program,
    String? query,
  }) async {
    return _initialFduropNotices.where((notice) {
      if (program != null && program != '全部' && !notice.program.contains(program)) {
        return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = notice.title.toLowerCase().contains(q);
        final matchSummary = notice.summary.toLowerCase().contains(q);
        if (!matchTitle && !matchSummary) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Get FDUROP open research projects for undergraduates.
  Future<List<FduropProjectItem>> getFduropProjects({
    String? program,
    String? department,
    String? query,
    bool? bookmarkedOnly,
  }) async {
    return _initialFduropProjects.map((project) {
      return project.copyWith(
        isBookmarked: _bookmarkedFduropProjectIds.contains(project.id),
      );
    }).where((item) {
      if (bookmarkedOnly == true && !item.isBookmarked) {
        return false;
      }
      if (program != null && program != '全部' && item.program != program) {
        return false;
      }
      if (department != null &&
          department != '全部' &&
          item.department != department) {
        return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = item.title.toLowerCase().contains(q);
        final matchAdvisor = item.advisor.toLowerCase().contains(q);
        final matchDept = item.department.toLowerCase().contains(q);
        final matchDesc = item.description.toLowerCase().contains(q);
        if (!matchTitle && !matchAdvisor && !matchDept && !matchDesc) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Get FDUROP downloadable documents.
  Future<List<FduropDocumentItem>> getFduropDocuments({
    String? category,
    String? query,
  }) async {
    return _initialFduropDocuments.map((doc) {
      return doc.copyWith(
        isDownloaded: _downloadedFduropDocIds.contains(doc.id),
      );
    }).where((item) {
      if (category != null && category != '全部' && item.category != category) {
        return false;
      }
      if (query != null && query.trim().isNotEmpty) {
        final q = query.trim().toLowerCase();
        final matchTitle = item.title.toLowerCase().contains(q);
        final matchCat = item.category.toLowerCase().contains(q);
        if (!matchTitle && !matchCat) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// List of distinct departments for filtering groups.
  List<String> get availableDepartments {
    final depts = _initialGroups.map((g) => g.department).toSet().toList();
    depts.sort();
    return ['全部', ...depts];
  }

  /// List of distinct campuses.
  List<String> get availableCampuses {
    final campuses = _initialGroups.map((g) => g.campus).toSet().toList();
    campuses.sort();
    return ['全部', ...campuses];
  }

  /// List of FDUROP programs for filtering.
  List<String> get availableFduropPrograms =>
      ['全部', '曦源项目', '望道项目', '莙政项目', '登峰项目', '开放自选课题'];

  /// List of FDUROP document categories.
  List<String> get availableFduropDocCategories =>
      ['全部', '立项申报', '中期检查', '结题评审', '经费管理'];
}
