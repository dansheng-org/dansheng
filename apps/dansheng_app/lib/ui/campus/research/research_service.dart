// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/foundation.dart';

import '../campus_api.dart';
import 'fdurop_seed_data.dart';
import 'research_models.dart';

/// Service providing Fudan University research news, research groups (课题组),
/// academic lectures, and FDUROP (本科生科研/望道/莙政/开放课题与文件下载).
class ResearchService extends ChangeNotifier {
  static final ResearchService instance = ResearchService._();
  ResearchService._();

  CampusApi? _api;

  /// Bind or unbind the authenticated campus API port from the host session.
  void bindApi(CampusApi? api) {
    _api = api;
  }

  // In-memory persistent states
  final Set<String> _followedGroupIds = {'rg_nlp', 'rg_brain', 'rg_chip'};
  final Set<String> _bookmarkedLectureIds = {'lec_1', 'lec_hist_1'};
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
      summary: '科研团队揭示了多尺度神经环路突触可塑性的自适应调控机制，为开发新型低功耗类脑计算算法提供了重要生物学启发。',
      content: '复旦大学脑科学前沿科学中心、脑功能与脑疾病全国重点实验室研究团队在《自然》（Nature）发表题为《Adaptive Synaptic Plasticity in Multi-Scale Neural Circuits》的长篇研究论文。该研究结合在体双光子钙成像与全脑投射重构技术，解析了小鼠在复杂联想学习任务中海马与皮层间突触权重的动态演进规律。成果对新一代仿生神经网络与类脑芯片架构设计具有重大指导意义。',
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
      summary: '微电子学院芯片团队攻克超薄二维半导体沟道与高介电常数栅介质集成难题，芯片能效比提升超3倍。',
      content: '复旦大学微电子学院、集成芯片与系统全国重点实验室团队在后摩尔时代先进逻辑芯片领域取得关键技术突破，研制出基于双层二硫化钼材料的晶圆级二维互补场效应晶体管（CFET）芯片原型。在1nm等效栅长节点下实现了极低的亚阈值摆幅与超低漏电流，为后摩尔时代高性能计算芯片提供了新型技术路径。',
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
      summary: '面向在读二年级及以上全日制博士生，支持开展高水平探索性原创研究，请各院系科研秘书于12月10日前完成初审。',
      content: '为进一步强化青年科技人才队伍建设，国家自然科学基金委2027年度青年学生基础研究项目（博士研究生）申报工作现已启动。资助强度为每项30万元，资助期限2-3年。申请人须具有扎实理论功底和创新学术思想，各院系需严格把握申报质量，做好伦理审查与学术规范把关。',
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
      summary: '发表于《先进材料》（Advanced Materials），实现了全天候健康体征连续监测与闭环电生理刺激。',
      content: '复旦大学高分子科学系、聚合物分子工程国家重点实验室研究团队通过微相分离与动态配位键构筑技术，合成了兼具自愈合、超高透气性与优异拉伸导电率的本征弹性复合材料。该材料在经历10000次弯折后仍能保持99%以上的导电灵敏度，在智能医疗织物和脑机接口体表电极领域展现出广泛应用潜力。',
      source: '高分子科学系',
      department: '高分子科学系',
      publishDate: '2026-11-10',
      category: '科研突破',
      readCount: 1680,
      isPinned: false,
      url: 'https://polymer.fudan.edu.cn/news/20261110',
    ),
    ResearchNewsItem(
      id: 'news_5',
      title: '【招生招募】计算机学院智能信息处理重点实验室NLP团队招收2027级推免直博生',
      summary: '研究方向涵盖大语言模型推理加速、具身智能知识图谱与多模态对齐，欢迎计算机、数学及相关专业推免生投递简历。',
      content: '复旦大学计算机科学技术学院智能信息处理重点实验室NLP与多模态研究组开放2027级推免直博生（2名）与科研助理（2名）申请。实验室拥有充足的高性能算力集群，与国内外一流顶尖实验室保持深度合作，常年支持博士生前往顶级学术会议（ACL、EMNLP、NeurIPS、ICLR）现场作口头报告。',
      source: '计算机科学技术学院',
      department: '计算机科学技术学院',
      publishDate: '2026-11-08',
      category: '招募招生',
      readCount: 4210,
      isPinned: false,
      url: 'https://cs.fudan.edu.cn/recruit/20261108',
    ),
    ResearchNewsItem(
      id: 'news_6',
      title: '第十五届相辉学术沙龙：从基础物理拓扑物态到量子计算架构',
      summary: '特邀中科院与复旦物理系知名学者作专题学术报告，邯郸校区相辉堂北堂同步开放线上直播。',
      content: '本期学术沙龙围绕拓扑量子绝缘体、马约拉纳费米子与容错量子计算展开跨学科研讨。报告会设置青年学者研讨环节与墙报交流展区，欢迎全校物理、材料及微电子方向师生参加。',
      source: '物理学系',
      department: '物理学系',
      publishDate: '2026-11-05',
      category: '学术讲座',
      readCount: 1980,
      isPinned: false,
      url: 'https://phys.fudan.edu.cn/events/20261105',
    ),
  ];

  // =========================================================================
  // 2. 课题组数据 (Research Groups - 覆盖复旦域名 *.fudan.edu.cn 丰富课题组)
  // =========================================================================
  static const List<ResearchGroupItem> _initialGroups = [
    // 计算机 / 软件 / 人工智能
    ResearchGroupItem(
      id: 'rg_nlp',
      name: '智能信息处理与大模型认知研究组 (Fudan NLP)',
      leader: '邱锡鹏教授',
      leaderTitle: '教授 / 博士生导师 / 国家级高层次人才',
      department: '计算机科学技术学院',
      campus: '江湾校区',
      researchDirections: ['自然语言处理', '大模型推理加速', '多模态对齐', 'AI for Science'],
      description: '课题组长期深耕自然语言处理与认知推理前沿，主持国家重点研发计划项目与多项国家自然科学基金重点项目。自主研发并开源了 MOSS 系列大语言模型，在国际顶级人工智能与计算语言学会议发表高水平论文百余篇。',
      recentPapers: [
        'MOSS-2: Efficient Multimodal Alignment via Hierarchical Representation (ICLR 2026)',
        'Reasoning Graph Distillation for Large Language Models (ACL 2026 Oral)',
        'Fast Decoding in Speculative Transformers (NeurIPS 2025)',
      ],
      recruitment: '常年招收推免直博生、博士后研究员及优秀访问学生。推免生需具备扎实的数据结构与数学基础。',
      contactEmail: 'xpqiu@fudan.edu.cn',
      labLocation: '江湾校区交叉二号楼B区502室',
      websiteUrl: 'https://nlp.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_codewisdom',
      name: '软件工程实验室 (CodeWisdom 团队)',
      leader: '彭鑫教授 / 赵文耘教授',
      leaderTitle: '教授 / 软件学院副院长 / CCF杰出会员',
      department: '计算机科学技术学院 / 软件学院',
      campus: '江湾校区',
      researchDirections: ['智能软件工程 (AI4SE)', '大模型代码生成', '软件智能化运维', '系统重构'],
      description: 'CodeWisdom 团队致力于软件智能化开发与运维技术攻关，在大模型辅助编程、软件架构重构与微服务故障诊断等方向拥有深厚产学研积累，多次荣获 ACM SIGSOFT 杰出论文奖。',
      recentPapers: [
        'Agentic Program Synthesis with Interactive Semantic Feedback (ICSE 2026)',
        'Automated Root Cause Localization for Cloud Microservices (FSE 2025)',
        'Repository-Level Code Refactoring with LLM Agents (ASE 2025)',
      ],
      recruitment: '招收软件工程、计算机系统方向直博生与硕士生，提供头部大厂实战联合研发机会。',
      contactEmail: 'xinpeng@fudan.edu.cn',
      labLocation: '江湾校区交叉二号楼A区301室',
      websiteUrl: 'https://cs.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_fvl',
      name: '复旦视觉与学习实验室 (Fudan Vision & Learning Lab, FVL)',
      leader: '姜育刚教授',
      leaderTitle: '复旦大学副校长 / IEEE Fellow / 国家杰青',
      department: '计算机科学技术学院',
      campus: '江湾校区',
      researchDirections: ['计算机视觉', '多模态视频理解', '具身智能感知', '大模型安全与评测'],
      description: 'FVL 实验室致力于通过海量图像、视频和多模态数据赋予机器感知与理解现实世界的能力，在长视频理解、多模态预训练模型与具身智能决策等方向取得多项国际顶会冠亚军成果。',
      recentPapers: [
        'OmniVideo: Long-form Video Understanding with Spatiotemporal Reasoning (CVPR 2026)',
        'Embodied Visual Navigation with World Models (ECCV 2025)',
        'Unified Multimodal Alignment under Noisy Supervision (NeurIPS 2025)',
      ],
      recruitment: '欢迎数学、编程能力拔尖的本科生进组见习，长期招收博士后与博士研究生。',
      contactEmail: 'ygj@fudan.edu.cn',
      labLocation: '江湾校区交叉二号楼4楼FVL中心',
      websiteUrl: 'https://cs.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_disc',
      name: '数据智能与社会计算实验室 (Fudan DISC Lab)',
      leader: '黄萱菁教授团队',
      leaderTitle: '讲席教授 / ACL Fellow / 中国中文信息学会常务理事',
      department: '计算机科学技术学院',
      campus: '江湾校区',
      researchDirections: ['社会计算', '跨模态语义分析', '情感与认知计算', '金融/法律垂直领域大模型'],
      description:
          'DISC 实验室专注于自然语言处理、社会计算与人工智能跨学科应用，研发了面向金融风控、司法推理与智慧医疗的多项行业前沿大模型系统。',
      recentPapers: [
        'Multi-Agent Collaborative Reasoning for Complex Social Dilemmas (AAAI 2026)',
        'Cross-Lingual Cultural Value Alignment in Generative AI (EMNLP 2025)',
      ],
      recruitment: '招收对 AI 与社科/金融交叉研究有浓厚兴趣的学生，每年招收直博生2名。',
      contactEmail: 'xjhuang@fudan.edu.cn',
      labLocation: '江湾校区交叉二号楼516室',
      websiteUrl: 'https://fudan-disc.com',
    ),
    ResearchGroupItem(
      id: 'rg_ipads',
      name: '系统软件与并行计算实验室 (IPADS)',
      leader: '陈海波教授 / 夏虞斌教授',
      leaderTitle: '特聘教授 / IEEE Fellow / ACM Fellow',
      department: '软件学院 / 计算机科学技术学院',
      campus: '张江校区',
      researchDirections: ['操作系统', '系统安全与隔离', '分布式并行系统', '异构智能计算芯片支撑'],
      description: 'IPADS 实验室专注于高安全、高可靠与高性能系统软件基石研究，成果广泛应用于国产移动操作系统与大规模分布式云计算平台，多次获得 SOSP / OSDI 最佳论文奖。',
      recentPapers: [
        'Microkernel OS Architecture for Heterogeneous AI Accelerators (OSDI 2026)',
        'Formally Verified Memory Protection in Virtualization Hypervisors (SOSP 2025)',
      ],
      recruitment: '招收系统编程、C/Rust 功底扎实，对底层操作系统原理充满激情的学生。',
      contactEmail: 'haibochen@fudan.edu.cn',
      labLocation: '张江校区微电子软件大楼412室',
      websiteUrl: 'https://ipads.se.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_cis',
      name: '协同信息与系统实验室 (Fudan CIS Lab / CSCW)',
      leader: '顾宁教授',
      leaderTitle: '教授 / 中国计算机学会CSCW专委会前主任',
      department: '计算机科学技术学院',
      campus: '邯郸校区',
      researchDirections: ['人机协同计算 (CSCW)', '人机交互 (HCI)', '社会计算', '智能协同工作环境'],
      description: '实验室以人为中心开展协同计算与普适智能系统研究，探索大模型驱动下新型智能人机交互界面与可穿戴增强系统。',
      recentPapers: [
        'Human-AI Collaborative Ideation in Creative Workflows (CHI 2026)',
        'Wearable Context-Aware Assistant for Industrial Assembly (CSCW 2025)',
      ],
      recruitment: '招收人机交互、前端全栈、社会计算背景学生。',
      contactEmail: 'ning.gu@fudan.edu.cn',
      labLocation: '邯郸校区逸夫楼408室',
      websiteUrl: 'https://cs.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_sec',
      name: '网络空间安全与系统防护实验室',
      leader: '杨珉教授 / 张源教授',
      leaderTitle: '国家杰青 / 计算机学院党委副书记',
      department: '计算机科学技术学院',
      campus: '江湾校区',
      researchDirections: ['移动安全', '软件漏洞挖掘', '二进制逆向分析', '大模型内生安全与攻防'],
      description: '实验室在移动终端安全、系统软件脆弱性分析与智能大模型越狱攻防方面居国内顶尖水平，连续多年在 IEEE S&P、USENIX Security 等安全四大顶会发表成果。',
      recentPapers: [
        'Automated Jailbreak Vulnerability Detection in Commercial LLMs (USENIX Security 2026)',
        'Precise Taint Tracking in Complex Android Frameworks (IEEE S&P 2025)',
      ],
      recruitment: '欢迎对安全攻防、CTF竞赛与漏洞挖掘有热情的同学加入。',
      contactEmail: 'm_yang@fudan.edu.cn',
      labLocation: '江湾校区交叉二号楼318室',
      websiteUrl: 'https://cs.fudan.edu.cn',
    ),

    // 微电子与集成电路
    ResearchGroupItem(
      id: 'rg_chip',
      name: '集成芯片与极限微缩电路团队',
      leader: '周鹏教授 / 刘春森研究员',
      leaderTitle: '国家杰青 / 微电子学院副院长',
      department: '微电子学院 / 集成芯片与系统全国重点实验室',
      campus: '张江校区',
      researchDirections: ['二维半导体晶体管', '超快闪存集成', '互补场效应晶体管 (CFET)', '三维异质集成'],
      description:
          '面向后摩尔时代集成电路瓶颈，重点攻坚二维过渡金属硫属化合物（TMDs）器件集成、晶圆级高介电常数界面优化与超高速非易失性芯片物理。',
      recentPapers: [
        'Wafer-scale 2D Complementary Field-Effect Transistors (Science 2026)',
        'Sub-1nm Equivalent Oxide Thickness High-k Dielectric Integration (Nature Electronics 2025)',
      ],
      recruitment: '招收微电子学、固体电子学、材料物理方向推免生及博士后。',
      contactEmail: 'pengzhou@fudan.edu.cn',
      labLocation: '张江校区微电子大楼C栋304室',
      websiteUrl: 'https://sme.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_litho',
      name: '先进光刻与半导体计算仿真实验室',
      leader: '熊诗圣教授',
      leaderTitle: '特聘教授 / 国家海外高层次人才 / 芯片创新学院',
      department: '未来信息创新学院 / 微电子学院',
      campus: '张江校区',
      researchDirections: [
        '先进制程光刻',
        '定向自组装 (DSA)',
        'AI for Science 计算光刻',
        '新型存储介质',
      ],
      description:
          '实验室聚焦先进制程纳米制造与图形化技术，运用嵌段共聚物定向自组装结合人工智能反演算法，实现亚10纳米超高分辨率图样加工。',
      recentPapers: [
        'Deep Learning Guided Directed Self-Assembly for Sub-7nm Lithography (Nature Nanotechnology 2026)',
        'Computational Lithography Optimization via Physics-Informed Neural Networks (SPIE 2025)',
      ],
      recruitment: '招收微纳加工、化学物理、高分子与计算机交叉背景研究生。',
      contactEmail: 'sxiong@fudan.edu.cn',
      labLocation: '张江校区微纳芯片实验楼202室',
      websiteUrl: 'https://sme.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_neuromorphic',
      name: '类脑芯片与神经形态存储器件团队',
      leader: '陈琳教授 / 孙清清教授',
      leaderTitle: '国家杰青 / 青年拔尖人才',
      department: '微电子学院',
      campus: '张江校区',
      researchDirections: [
        '忆阻器 (Memristor)',
        '神经形态计算芯片',
        '存内计算 (PIM)',
        '柔性生物电子感知',
      ],
      description:
          '致力于研发低功耗高并行度类脑认知芯片，设计制造多态氧化物/硫化物忆阻器阵列，突破传统冯·诺依曼架构下的算力与功耗墙限制。',
      recentPapers: [
        'Multi-Terminal Memristive Synapses for Sensory-Motor Closed-Loop Systems (Nature Communications 2026)',
        'Low-Voltage In-Memory Computing for Spiking Neural Networks (IEDM 2025)',
      ],
      recruitment: '招收对类脑感知硬件、微电子材料与电路设计感兴趣的推免生。',
      contactEmail: 'linchen@fudan.edu.cn',
      labLocation: '张江校区微电子大楼A栋208室',
      websiteUrl: 'https://sme.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_eda',
      name: '集成电路 EDA 与模拟电路优化课题组',
      leader: '曾璇教授',
      leaderTitle: '讲席教授 / IEEE Fellow / 国家杰出青年科学基金获得者',
      department: '微电子学院',
      campus: '张江校区',
      researchDirections: [
        '集成电路电子设计自动化 (EDA)',
        '模拟/射频电路建模',
        '良率与可靠性优化',
        '机器学习EDA',
      ],
      description:
          '国内 EDA 领域领军团队，长期承担国家集成电路重大科研攻关，针对纳米尺度复杂模拟集成电路模型求解难题提出一系列创新统计分析算法。',
      recentPapers: [
        'Graph Neural Networks for Fast Analog Circuit Sizing and Yield Optimization (DAC 2026)',
        'Non-Monte Carlo Statistical Static Timing Analysis for Advanced Nodes (IEEE TCAD 2025)',
      ],
      recruitment: '招收数学好、算法功底扎实，立志攻关国产 EDA 核心工业软件的学生。',
      contactEmail: 'xzeng@fudan.edu.cn',
      labLocation: '张江校区微电子大楼B栋410室',
      websiteUrl: 'https://sme.fudan.edu.cn',
    ),

    // 脑科学 / 神经生物学 / ISTBI
    ResearchGroupItem(
      id: 'rg_brain',
      name: '全脑计算模型与类脑智能实验室',
      leader: '冯建峰教授团队',
      leaderTitle: '欧洲科学院院士 / 英国皇家学会皇家客席教授 / ISTBI院长',
      department: '类脑智能科学与技术研究院 (ISTBI)',
      campus: '枫林校区 / 张江校区',
      researchDirections: [
        '计算神经科学',
        '数字孪生脑 (Digital Twin Brain)',
        '全脑神经元仿真',
        '脑疾病靶点预测',
      ],
      description: '实验室依托复旦大学脑科学前沿科学中心和类脑研究院，搭建了世界领先的超大规模全脑计算平台，致力于解析人类认知神经环路并在超算上实现亿级神经元动力学模拟。',
      recentPapers: [
        'Whole-Brain Digital Twin of the Primate Cerebral Cortex (Nature Computational Science 2026)',
        'Spike-Driven Neuromorphic Architecture for Edge Intelligence (IEEE TPAMI 2025)',
      ],
      recruitment: '招收生物医学工程、自动化、应用数学、计算机与神经科学背景博士生与博士后。',
      contactEmail: 'jianfeng64@fudan.edu.cn',
      labLocation: '枫林校区明道楼一楼脑机实验室',
      websiteUrl: 'https://istbi.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_cortical',
      name: '大脑皮层微环路与神经突触生理实验室',
      leader: '舒友生教授',
      leaderTitle: '国家杰青 / 脑科学转化研究院常务副院长',
      department: '脑科学转化研究院',
      campus: '枫林校区',
      researchDirections: ['神经微环路电生理', '轴突兴奋性机制', '自突触动力学', '癫痫发病机制与干预'],
      description: '课题组专注皮层锥体神经元与中间神经元的突触连接与放电规律，通过脑片膜片钳记录与高分辨双光子成像，系统探究中枢神经系统信息传递与病理机制。',
      recentPapers: [
        'Axonal Kv1 Channel Modulation of Action Potential Dynamics (Neuron 2026)',
        'Autaptic Self-Inhibition Fine-Tunes Cortical Synchrony (Cell Reports 2025)',
      ],
      recruitment: '招收基础医学、生理学、神经生物学方向硕士与博士生。',
      contactEmail: 'yousheng@fudan.edu.cn',
      labLocation: '枫林校区明道楼3楼电生理实验室',
      websiteUrl: 'https://itbr.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_sleep',
      name: '睡眠机制与脑神经精神药理学课题组',
      leader: '黄志力教授',
      leaderTitle: '特聘教授 / 中国睡眠研究会前理事长 / 国家杰青',
      department: '基础医学院药理学系',
      campus: '枫林校区',
      researchDirections: ['睡眠觉醒神经环路', '伏隔核与多巴胺机制', '失眠障碍靶点', '催眠镇静新药筛选'],
      description:
          '系统阐明了基底神经节特别是伏隔核腺苷与多巴胺受体调控觉醒的分子神经机制，发现了一批具有自主知识产权的促觉醒与助眠候选药物分子。',
      recentPapers: [
        'Nucleus Accumbens D2 Receptor Neurons Control Behavioral Arousal (Nature Communications 2026)',
        'GABAergic Striatal Pathways Modulate Slow-Wave Sleep (Current Biology 2025)',
      ],
      recruitment: '常年招收药理学、基础医学、神经生物学直博生。',
      contactEmail: 'huangzl@fudan.edu.cn',
      labLocation: '枫林校区科研2号楼508室',
      websiteUrl: 'https://shmc.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_somatosensory',
      name: '躯体感觉与情绪编码机制实验室',
      leader: '刘本龙青年研究员',
      leaderTitle: '脑科学前沿科学中心独立 PI / 博士生导师',
      department: '脑科学研究院 / 医学神经生物学国家重点实验室',
      campus: '枫林校区',
      researchDirections: ['痛觉与触觉环路', '情绪感知神经机制', '神经环路示踪技术', '慢性痛中枢可塑性'],
      description: '综合运用狂犬病毒示踪、光遗传学及活体钙信号光纤记录技术，解析感觉信号如何被大脑边缘系统解码并赋予情绪色彩。',
      recentPapers: [
        'Paraventricular Thalamic Projections Drive Aversive Pain Memory (Nature Neuroscience 2025)',
      ],
      recruitment: '欢迎生物科学、临床医学专业本科生进组参与本科生科研计划。',
      contactEmail: 'benlong_liu@fudan.edu.cn',
      labLocation: '枫林校区治道楼6楼神经生物学实验室',
      websiteUrl: 'https://iobs.fudan.edu.cn',
    ),

    // 化学 / 材料 / 高分子科学
    ResearchGroupItem(
      id: 'rg_mesoporous',
      name: '功能介孔材料与能源催化实验室',
      leader: '赵东元院士团队',
      leaderTitle: '中国科学院院士 / 发展中国家科学院院士 / 化学系教授',
      department: '化学系 / 先进材料实验室',
      campus: '江湾校区',
      researchDirections: ['功能介孔无机材料', '介孔碳与聚合物合成', '电催化水裂解', '二次电池储能'],
      description: '国际介孔材料领域引领团队，首创了有机-有机自组装介孔分子合成新路径，研发出一系列高比表面积多级孔结构吸附与能源催化材料，荣获国家自然科学一等奖。',
      recentPapers: [
        'Confined Synthesis of Single-Atom Catalysts in Mesoporous Carbon Frameworks (JACS 2026)',
        'Ordered Mesoporous Polymers for Ultrafast Lithium-Sulfur Batteries (Angewandte Chemie 2025)',
      ],
      recruitment: '招收无机化学、材料化学、催化方向推免生与博士后。',
      contactEmail: 'dyzhao@fudan.edu.cn',
      labLocation: '江湾校区先进材料大楼110室',
      websiteUrl: 'https://chemistry.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_polymer',
      name: '智能高分子与纤维柔性电子实验室',
      leader: '彭慧胜院士团队',
      leaderTitle: '中国科学院院士 / 聚合物分子工程国家重点实验室主任',
      department: '高分子科学系',
      campus: '江湾校区',
      researchDirections: ['纤维聚合物电池', '智能发光织物', '可穿戴电生理传感', '柔性储能集成'],
      description:
          '在国际上开创了纤维状能源生成与储存器件全新研究方向，成功制备出全柔性大面积显示发光织物，推动了可穿戴电子和智能服装的跨越式发展。',
      recentPapers: [
        'Breathable Self-Healing Smart Textiles with Closed-Loop Biofeedback (Advanced Materials 2026)',
        'Scalable Production of High-Energy-Density Polymer Fiber Batteries (Nature 2025)',
      ],
      recruitment: '招收高分子物理、化学工程、凝聚态物理方向优秀青年学者与博士生。',
      contactEmail: 'penghs@fudan.edu.cn',
      labLocation: '江湾校区高分子科学楼312室',
      websiteUrl: 'https://polymer.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_nir',
      name: '近红外生物荧光分子探针实验室',
      leader: '张凡教授',
      leaderTitle: '特聘教授 / 发展中国家科学院院士 / 国家杰青',
      department: '化学系 / 聚合物分子工程国家重点实验室',
      campus: '江湾校区',
      researchDirections: ['近红外二区荧光探针', '上转换发光材料', '活体荧光寿命成像', '肿瘤微环境手术导航'],
      description: '专注于近红外二区（1000-1700 nm）新型稀土纳米发光材料与有机探针设计合成，实现了高信噪比、毫米级深穿透度的体内动态微血管与肿瘤活体精准成像。',
      recentPapers: [
        'Multiplexed Near-Infrared-II Lifetime Imaging for Guided Tumor Resection (Nature Photonics 2026)',
        'Renal-Clearable Rare-Earth Nanoprobes for Real-Time Vasculature Monitoring (Chemical Reviews 2025)',
      ],
      recruitment: '招收无机发光、化学生物学、分子影像学交叉方向研究生。',
      contactEmail: 'zhangfan@fudan.edu.cn',
      labLocation: '江湾校区化学楼A区405室',
      websiteUrl: 'https://chemistry.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_lasp',
      name: '计算化学与多相催化势能面实验室',
      leader: '刘智攀教授',
      leaderTitle: '讲席教授 / 英国皇家化学会会士 / 国家杰青',
      department: '化学系 / 计算物质科学教育部重点实验室',
      campus: '江湾校区',
      researchDirections: ['理论计算化学', 'LASP 神经网络势函数', '全局反应路径搜索', '工业异相催化机理'],
      description: '自主研发了大规模原子模拟程序 LASP（Large-scale Atomic Simulation Program），开创了基于神经网络全局优化复杂化学反应表面势能面的理论新方法。',
      recentPapers: [
        'Neural Network Potential Guided Reaction Discovery on Complex Alloy Catalysts (Nature Catalysis 2026)',
        'Dynamic Restructuring of Copper Interfaces in CO2 Electroreduction (JACS 2025)',
      ],
      recruitment: '招收物理化学、计算数学、AI for Science 背景推免生。',
      contactEmail: 'zpliu@fudan.edu.cn',
      labLocation: '江湾校区化学楼B区318室',
      websiteUrl: 'https://chemistry.fudan.edu.cn',
    ),

    // 物理学 / 低维量子态 / 超导
    ResearchGroupItem(
      id: 'rg_2dphys',
      name: '低维量子凝聚态物理实验室',
      leader: '张远波教授',
      leaderTitle: '特聘教授 / 物理学系主任 / 国家杰青',
      department: '物理学系 / 应用表面物理国家重点实验室',
      campus: '邯郸校区',
      researchDirections: [
        '二维材料量子霍尔效应',
        '拓扑绝缘体与范德华异质结',
        '极低温强磁场电输运',
        '扫描隧道显微学',
      ],
      description: '在石墨烯和二维黑磷新相态的发现与量子输运探测上作出里程碑式贡献，系统揭示了二维体系中分数电荷与狄拉克费米子物理规律。',
      recentPapers: [
        'Fractional Quantum Anomalous Hall Effect in Twisted Bilayer TMDs (Nature 2026)',
        'Tunable Excitonic Insulator States in Van der Waals Bilayers (Science 2025)',
      ],
      recruitment: '招收对凝聚态实验、洁净室微纳器件加工有志向的推免生。',
      contactEmail: 'zhyb@fudan.edu.cn',
      labLocation: '邯郸校区恒隆物理楼105低维物理中心',
      websiteUrl: 'https://phys.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_supercond',
      name: '高温超导与非弹性中子散射实验室',
      leader: '赵俊教授',
      leaderTitle: '教授 / 国家杰青 / 物理学系特聘研究员',
      department: '物理学系',
      campus: '邯郸校区 / 江湾校区',
      researchDirections: ['镍基/铜基高温超导机理', '中子散射测量', '高质量单晶生长', '量子磁性与自旋涨落'],
      description: '利用国际大型中子散射大科学装置，深入解析非常规超导体的自旋激发谱与晶体对称性破缺，在国际顶尖学术刊物发表多篇关于非常规超导母相磁性图景的重要成果。',
      recentPapers: [
        'Spin Excitations in Single-Crystal Nickelate Superconductors (Nature Materials 2026)',
        'Magnetic Resonance in Iron-Based Superconducting Phases (Physical Review Letters 2025)',
      ],
      recruitment: '招收凝聚态物理学、中子衍射、极端低温物性测量方向研究生。',
      contactEmail: 'zhaojun@fudan.edu.cn',
      labLocation: '江湾校区物理科学科研楼108室',
      websiteUrl: 'https://phys.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_ultrafast',
      name: '超快非线性激光显微光谱实验室',
      leader: '吴施伟教授',
      leaderTitle: '教授 / 国家海外高层次人才 / 物理学系副主任',
      department: '物理学系',
      campus: '邯郸校区',
      researchDirections: ['超快光学与显微光谱', '二维磁体光生磁学', '太赫兹时域光谱', '纳米近场光学'],
      description: '结合飞秒激光光谱技术与超高真空显微术，探索二维层状磁性材料中的光致自旋超快翻转与激子-极化子相干相互作用。',
      recentPapers: [
        'Ultrafast Spin Reorientation in Two-Dimensional Van der Waals Magnets (Nature Physics 2025)',
      ],
      recruitment: '招收光学、激光技术、凝聚态实验方向推免生。',
      contactEmail: 'swwu@fudan.edu.cn',
      labLocation: '邯郸校区物理楼激光超快光谱实验室',
      websiteUrl: 'https://phys.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_quantum_info',
      name: '量子测量与量子信息理论课题组',
      leader: '朱黄俊教授',
      leaderTitle: '教授 / 博士生导师 / 理论物理所',
      department: '物理学系 / 理论物理研究所',
      campus: '邯郸校区',
      researchDirections: ['量子精密测量', '量子纠缠理论', '对称性信息重构', '量子计算纠错编码'],
      description: '聚焦量子力学基本问题、量子态层析与量子信道估计，发展了高效对称广义量子测量的几何分类理论。',
      recentPapers: [
        'Optimal Quantum Metrology under Correlated Noise Environments (Physical Review Letters 2026)',
      ],
      recruitment: '招收数学、理论物理、量子科学方向学术型研究生。',
      contactEmail: 'zhuhuangjun@fudan.edu.cn',
      labLocation: '邯郸校区恒隆物理楼522理论物理室',
      websiteUrl: 'https://phys.fudan.edu.cn',
    ),

    // 生命科学 / 现代人类学 / 生物医学
    ResearchGroupItem(
      id: 'rg_genomics',
      name: '现代人类学与群体基因组学重点实验室',
      leader: '金力院士团队',
      leaderTitle: '中国科学院院士 / 复旦大学校长 / 遗传工程国家重点实验室',
      department: '生命科学学院 / 人类表型组研究院',
      campus: '江湾校区',
      researchDirections: ['东亚人群演化史', '人类表型组学大数据', '复杂疾病易感基因', '分子人类学与古DNA'],
      description:
          '开创了多维度人类表型组测量与分析国际大科学计划，在东亚人群起源迁徙、环境适应性基因筛选及复杂多表型跨尺度关联机制方面处于国际引领地位。',
      recentPapers: [
        'Phenome-Wide Association Map of 1,000 Human Health Traits (Cell 2026)',
        'Ancient Genomes Reveal Prehistoric Dispersals in East Asia (Science 2025)',
      ],
      recruitment: '招收生物信息学、统计遗传学、分子生物学背景优秀学生。',
      contactEmail: 'ljin@fudan.edu.cn',
      labLocation: '江湾校区生科院立人生物楼402室',
      websiteUrl: 'https://life.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_proteomics',
      name: '功能蛋白质组学与转录调控实验室',
      leader: '丁琛教授',
      leaderTitle: '教授 / 国家杰青 / 遗传工程国家重点实验室固定PI',
      department: '生命科学学院',
      campus: '江湾校区',
      researchDirections: ['高通量蛋白质组学', '转录因子复合体动态追踪', '临床肿瘤分子分型', '化学蛋白质组学'],
      description: '自主研发转录因子活化谱测定（CAT-Prot）新方法，建立了多种恶性实体肿瘤的全蛋白质组深度图谱，为靶向药物耐药机制解析提供高精度分子证据。',
      recentPapers: [
        'Comprehensive Proteogenomic Characterization of Early-Stage Lung Cancers (Cell 2025)',
      ],
      recruitment: '招收质谱分析、分子生物学、生信分析方向直博生。',
      contactEmail: 'chend@fudan.edu.cn',
      labLocation: '江湾校区立人生物楼215室',
      websiteUrl: 'https://life.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_nanomedicine',
      name: '纳米药物与智能靶向递送课题组',
      leader: '占昌友教授',
      leaderTitle: '教授 / 国家杰青 / 基础医学院副院长',
      department: '基础医学院 / 药学院',
      campus: '枫林校区',
      researchDirections: [
        '脂质纳米粒 (LNP) 体内命运',
        '血脑屏障靶向跨越',
        '核酸药物纳米递送',
        '临床精准制剂转化',
      ],
      description:
          '系统阐明了天然抗体对纳米颗粒血液循环与器官靶向性的微观调控机制，开发出可高效穿透血脑屏障的新型非侵入式中枢神经递药载体。',
      recentPapers: [
        'Pre-Existing Natural IgM Regulates Pharmacokinetics of Lipid Nanoparticles (Nature Communications 2026)',
        'Brain-Targeted Polymeric Micelles Overcoming Blood-Brain Barrier (Nano Letters 2025)',
      ],
      recruitment: '招收药剂学、生物医学工程、高分子化学方向推免生。',
      contactEmail: 'cyzhan@fudan.edu.cn',
      labLocation: '枫林校区科研1号楼401药剂实验室',
      websiteUrl: 'https://shmc.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_virology',
      name: '医学分子病毒学重点实验室病原研究组',
      leader: '袁正宏教授 / 蔡启良研究员',
      leaderTitle: '讲席教授 / 重点实验室主任',
      department: '基础医学院 / 医学分子病毒学重点实验室',
      campus: '枫林校区',
      researchDirections: [
        '乙肝病毒慢性感染机制',
        '广谱中和抗体筛选',
        '新发传染病宿主天然免疫',
        '抗病毒小分子候选药',
      ],
      description:
          '医学分子病毒学教育部/卫健委重点实验室核心团队，聚焦重大慢性与新发病毒性传染病致病机理、病毒复制调控网络及临床疫苗创新。',
      recentPapers: [
        'Structural Basis of Broad-Spectrum Neutralizing Antibodies Against Emerging Coronaviruses (Cell 2025)',
      ],
      recruitment: '招收基础医学、病原微生物学、分子免疫学方向研究生。',
      contactEmail: 'zhyuan@fudan.edu.cn',
      labLocation: '枫林校区治道楼五楼重点实验室',
      websiteUrl: 'https://shmc.fudan.edu.cn',
    ),

    // 环境 / 地球科学
    ResearchGroupItem(
      id: 'rg_atmospheric',
      name: '大气多相化学与环境健康实验室',
      leader: '陈建民院士团队',
      leaderTitle: '中国科学院院士 / 法国国家科学研究中心外籍客座教授',
      department: '环境科学与工程系',
      campus: '江湾校区',
      researchDirections: ['大气多相反应化学', '二次有机气溶胶成核', '细颗粒物暴露毒理', '车载在线质谱技术'],
      description:
          '面向国家空气质量持续改善与碳中和战略，研发了自主知识产权的大气二次气溶胶在线源解析与烟雾箱模拟技术，深入揭示多污染物协同减排机制。',
      recentPapers: [
        'Atmospheric Multiphase Oxidation Driving Secondary Organic Aerosol Growth (Nature Geoscience 2026)',
      ],
      recruitment: '招收环境科学、大气化学、分析化学仪器研制方向研究生。',
      contactEmail: 'jmchen@fudan.edu.cn',
      labLocation: '江湾校区环境科学楼306室',
      websiteUrl: 'https://environment.fudan.edu.cn',
    ),

    // 数学科学学院
    ResearchGroupItem(
      id: 'rg_math_dyn',
      name: '动力系统与复分析前沿研究中心',
      leader: '沈维孝院士 / 傅吉祥教授',
      leaderTitle: '中国科学院院士 / 复旦大学数学科学学院教授',
      department: '数学科学学院 / 上海数学中心',
      campus: '邯郸校区 / 江湾校区',
      researchDirections: ['实一维动力系统', '拟共形几何', '超复流形几何', '非线性偏微分方程'],
      description:
          '在实分析与动力系统领域取得突破性国际公认成就，完全证明了实一维单峰映射庞加莱猜测与拟周期薛定谔算子绝对连续谱存在的长期公开数学难题。',
      recentPapers: [
        'Harmonic Measures and Quasiconformal Rigidity in Polynomial Dynamics (Annals of Mathematics 2026)',
      ],
      recruitment: '招收基础数学、动力系统、几何分析方向优秀推免直博生。',
      contactEmail: 'weixiao@fudan.edu.cn',
      labLocation: '江湾校区上海数学中心大楼205室',
      websiteUrl: 'https://math.fudan.edu.cn',
    ),

    // 经济与人文历史社科
    ResearchGroupItem(
      id: 'rg_econ',
      name: '中国现代经济发展与空间经济学研究中心',
      leader: '陆铭特聘教授',
      leaderTitle: '文科资深教授 / 教育部长江学者特聘教授',
      department: '经济学院',
      campus: '邯郸校区',
      researchDirections: ['空间经济学', '中国城市化与区域协调', '数字经济与就业结构', '户籍制度改革评估'],
      description: '依托复旦大学当代中国经济研究中心，长期以严谨微观实证数据深入剖析中国统一大市场、生产要素流动与区域高质量发展。',
      recentPapers: [
        'Agglomeration and Spatial Equilibrium in Digital China (Journal of Development Economics 2025)',
      ],
      recruitment: '招收应用经济学、实证微观计量方向博士生。',
      contactEmail: 'minglu@fudan.edu.cn',
      labLocation: '邯郸校区经济学院大楼612室',
      websiteUrl: 'https://econ.fudan.edu.cn',
    ),
    ResearchGroupItem(
      id: 'rg_history',
      name: '中古历史与敦煌吐鲁番文书研究组',
      leader: '冯培红教授 / 余欣教授',
      leaderTitle: '教育部国家级高层次人才 / 历史学系博士生导师',
      department: '历史学系',
      campus: '邯郸校区',
      researchDirections: ['中古丝绸之路赋役制度', '敦煌吐鲁番汉文文书', '中外物质文化交流', '唐代政治与社会'],
      description:
          '汇聚国内外最新出土丝路文书文献，深入考释中古政治、经济制度与基层社会治理，多部专著荣获教育部高等学校人文社会科学研究优秀成果奖。',
      recentPapers: [
        'Dunhuang Manuscripts and the Evolution of Medieval Fiscal System (Historical Research 2025)',
      ],
      recruitment: '招收历史文献学、中国古代史方向硕士与博士生。',
      contactEmail: 'history_lab@fudan.edu.cn',
      labLocation: '邯郸校区光华楼西主楼2208室',
      websiteUrl: 'https://history.fudan.edu.cn',
    ),
  ];

  // =========================================================================
  // 3. 学术讲座数据 (Academic Lectures - 丰富各学院报告、名家讲座与人文讲堂)
  // =========================================================================
  static const List<ResearchLectureItem> _initialLectures = [
    ResearchLectureItem(
      id: 'lec_hist_1',
      title: '作为“国故”的西学——明末清初西学在二十世纪上半叶的书写与记忆',
      speaker: '陈拓 青年研究员',
      speakerTitle: '历史学系优秀青年学者',
      time: '2026-11-19 (周四) 09:30 - 11:30',
      venue: '邯郸校区 光华楼西主楼2001会议室',
      organizer: '复旦大学历史学系',
      description: '深入考析明末清初入华耶稣会士传入之天文学、数学、地理学等西方学识，在二十世纪上半叶如何被传统文人学者重新诠释为“国学”或“国故”的历史进程与文化记忆构建。',
      campus: '邯郸校区',
      category: '人文社科',
      isBookmarked: true,
    ),
    ResearchLectureItem(
      id: 'lec_hist_2',
      title: '关于近代庙产兴学运动的几个关键问题与社会结构变迁',
      speaker: '许效正 教授',
      speakerTitle: '著名近代史学者 / 博士生导师',
      time: '2026-11-19 (周四) 14:30 - 16:30',
      venue: '邯郸校区 光华楼西主楼2001会议室',
      organizer: '复旦大学历史学系',
      description:
          '讲座从清末民初庙产与现代学堂经费筹集冲突切入，剖析地方士绅、宗族庙宇与国家政权在基层教育现代化推行过程中的权变与博弈。',
      campus: '邯郸校区',
      category: '人文社科',
    ),
    ResearchLectureItem(
      id: 'lec_hist_3',
      title: '【中古中国前沿讲座】略谈敦煌学的材料、学术范式与前沿议题',
      speaker: '冯培红 教授',
      speakerTitle: '国家级高层次人才 / 历史学系教授',
      time: '2026-11-20 (周五) 15:00 - 17:00',
      venue: '邯郸校区 光华楼西主楼2201学术厅',
      organizer: '复旦大学历史学系、中古中国研究中心',
      description: '梳理近百年敦煌汉文与多语种文献发掘历程，结合出土归义军文书与丝路考古新进展，展望数字人文与跨语际中古史研究前景。',
      campus: '邯郸校区',
      category: '人文社科',
    ),
    ResearchLectureItem(
      id: 'lec_hist_4',
      title: '【学术年会】中西交流与知识生产：制度、文本与物质媒介（第一场）',
      speaker: '多位海内外特邀史学家',
      speakerTitle: '跨学科国际研讨会',
      time: '2026-11-21 至 11-22 (全天)',
      venue: '邯郸校区 光华楼西主楼2001会议大厅',
      organizer: '复旦大学中外现代化进程研究中心、历史学系',
      description:
          '大会设置四个分会场：1. 译介文本的跨文化旅行；2. 物质文明与科技器具流动；3. 知识制度与学堂转型；4. 地图学与全球视野塑形。',
      campus: '邯郸校区',
      category: '人文社科',
    ),
    ResearchLectureItem(
      id: 'lec_1',
      title: '【浦江科学大师讲坛】量子计算前沿演进与拓扑容错物态实现',
      speaker: '彼得·格林教授 (Prof. Peter Green)',
      speakerTitle: '国际著名拓扑物理学家、外籍院士',
      time: '2026-11-20 (周五) 14:30 - 16:30',
      venue: '邯郸校区 相辉堂北堂 / 线上同步直播',
      organizer: '复旦大学科学技术研究院、物理学系',
      description: '讲座将全面回顾非阿贝尔任意子态的实验探测历程，并深入探讨基于拓扑量子纠错码的下一代通用量子计算机系统设计挑战。',
      campus: '邯郸校区',
      category: '物质前沿',
      isBookmarked: true,
    ),
    ResearchLectureItem(
      id: 'lec_cs_1',
      title: '【江湾计算交叉前沿】从神经元脉冲机制到具身智能机器人的物理世界交互',
      speaker: '姜育刚教授 / 邱锡鹏教授',
      speakerTitle: '计算机科学技术学院核心学者团队',
      time: '2026-11-24 (周二) 15:00 - 17:00',
      venue: '江湾校区 交叉二号楼一楼报告厅',
      organizer: '计算机科学技术学院、智能信息处理重点实验室',
      description: '探讨多模态视频大模型与端侧强化学习在足式机器人复杂地形导航中的闭环控制，现场将联合演示软硬件一体化机器人仿真平台。',
      campus: '江湾校区',
      category: '信息技术',
    ),
    ResearchLectureItem(
      id: 'lec_cs_2',
      title: '【CodeWisdom 前沿讲座】软件智能体（Agent）驱动的自主软件演化与质量把关',
      speaker: '彭鑫 教授',
      speakerTitle: '软件工程实验室带头人',
      time: '2026-11-25 (周三) 14:00 - 15:30',
      venue: '江湾校区 交叉二号楼A301学术研讨厅',
      organizer: '软件学院、计算机科学技术学院',
      description:
          '剖析大模型代码生成工具在实际大规模工业生产系统落地中的“幻觉”与脆弱性，提出结合符号执行与动态测试的 Agent 质量防御体系。',
      campus: '江湾校区',
      category: '信息技术',
    ),
    ResearchLectureItem(
      id: 'lec_chip_1',
      title: '【张江集成电路学术沙龙】超薄晶圆级二维半导体晶体管物理极限与工业化路线',
      speaker: '周鹏 教授',
      speakerTitle: '微电子学院副院长 / 国家杰青',
      time: '2026-11-26 (周四) 10:00 - 11:30',
      venue: '张江校区 微电子大楼B楼学术报告厅',
      organizer: '微电子学院、集成芯片与系统全国重点实验室',
      description:
          '详细解读晶圆级双层二硫化钼 CFET 制造工艺难点，对比传统硅基 FinFET 与 GAA 架构在 1nm 节点之后的能效与漏电优势。',
      campus: '张江校区',
      category: '信息技术',
    ),
    ResearchLectureItem(
      id: 'lec_med_1',
      title: '【枫林生物医药讲堂】高通量靶向蛋白降解药物（PROTAC/分子胶）设计新策略',
      speaker: '占昌友 教授',
      speakerTitle: '基础医学院副院长 / 国家杰青',
      time: '2026-11-27 (周五) 10:00 - 11:30',
      venue: '枫林校区 复星楼三楼多功能学术厅',
      organizer: '基础医学院、药学院',
      description:
          '系统阐述利用人工智能晶体结构生成与微流控快速筛选技术加速靶向降解嵌合体候选分子的发现路径，重点讲解克服血脑屏障跨越的纳米递送方案。',
      campus: '枫林校区',
      category: '生命健康',
    ),
    ResearchLectureItem(
      id: 'lec_brain_1',
      title: '【脑科学转化论坛】大脑皮层微环路电生理与单神经元计算机制',
      speaker: '舒友生 教授',
      speakerTitle: '脑科学转化研究院常务副院长',
      time: '2026-11-28 (周六) 14:30 - 16:00',
      venue: '枫林校区 明道楼二楼第一报告厅',
      organizer: '脑科学转化研究院、脑科学前沿科学中心',
      description:
          '结合多通道全细胞膜片钳记录与共聚焦钙成像，展示大脑皮层锥体细胞轴突初段（AIS）在调控动作电位起始和自突触反馈中的最新电生理证据。',
      campus: '枫林校区',
      category: '生命健康',
    ),
    ResearchLectureItem(
      id: 'lec_chem_1',
      title: '【相辉名家讲座】介孔分子合成的奇妙世界：从基础无机化学到产业储能落地',
      speaker: '赵东元 院士',
      speakerTitle: '中国科学院院士 / 国家自然科学一等奖获得者',
      time: '2026-12-01 (周二) 15:30 - 17:30',
      venue: '江湾校区 先进材料实验室一楼学术报告厅',
      organizer: '化学系、先进材料实验室',
      description:
          '生动回顾三十年介孔材料有机合成研究历程，展示多级纳米孔道碳材料在超级电容器、固态锂电池及重金属环境净化中的工程化奇迹。',
      campus: '江湾校区',
      category: '物质前沿',
    ),
    ResearchLectureItem(
      id: 'lec_math_1',
      title: '【复旦数学前沿讨论会】实一维动力系统的调和测度与重整化拟共形分析',
      speaker: '沈维孝 院士',
      speakerTitle: '中国科学院院士 / 发展中国家科学院院士',
      time: '2026-12-03 (周四) 14:00 - 15:30',
      venue: '邯郸校区 光华楼东主楼2201报告厅',
      organizer: '数学科学学院、上海数学中心',
      description:
          '深入探讨实复解析动力系统交叉领域的刚性定理（Rigidity Theorem），讲解一维单峰映射庞加莱测度在拟周期微扰下的稳定态演变。',
      campus: '邯郸校区',
      category: '物质前沿',
    ),
    ResearchLectureItem(
      id: 'lec_econ_1',
      title: '【经院大金论坛】大国治理与空间平衡：统一大市场下的城乡要素流动',
      speaker: '陆铭 特聘教授',
      speakerTitle: '文科资深教授 / 教育部长江学者特聘教授',
      time: '2026-12-04 (周五) 18:30 - 20:30',
      venue: '邯郸校区 经济学院大金报告厅',
      organizer: '经济学院、当代中国经济研究中心',
      description: '从经济地理学空间集聚与平衡视角出发，剖析当前土地财政改革、跨区域人口要素流动与中国未来大都市圈发展的内在逻辑。',
      campus: '邯郸校区',
      category: '人文社科',
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
      summary: '涵盖“曦源项目”、“望道学者”、“登峰项目”，面向大二、大三全日制本科生开放系统填报，11月25日截止导师线上确认。',
      content: '为进一步营造浓郁本科生学术研究氛围，教务处拔尖人才培养办公室即日起启动2026-2027学年秋季学期复旦大学本科生学术研究资助计划（FDUROP）申报工作。曦源项目资助强度为每项1.0万元，望道学者项目资助强度为每项1.5万元，登峰计划每项资助最高2.5万元。申请人需在FDUROP管理系统完成《立项申请书》填报，并联系指导教师完成推荐确认。学生亦可登录 FDUROP 教师开放课题系统 (paper.fudan.edu.cn) 挑选心仪导师与课题。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261018-declare',
    ),
    FduropNoticeItem(
      id: 'fdurop_n_portal',
      title: '关于开通“FDUROP 教师开放课题申报与学生双选系统”的温馨提示',
      program: '全计划',
      publishDate: '2026-10-20',
      summary: '指导教师可随时在线发布开放研究课题，本科生可通过统一身份认证 UIS 登录系统查看并申请课题：paper.fudan.edu.cn/fdurop-pc。',
      content: '为打破院系壁垒，强化师生科研双向互选，复旦大学教务处已全面升级“FDUROP 教师开放课题平台”（访问网址：https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index）。全校各学科教授、研究员均已陆续在平台录入最新前沿课题；有志于申报莙政、望道、曦源、登辉项目的同学请及时登录查阅，并与导师邮件联络确认。',
      url: 'https://paper.fudan.edu.cn/fdurop-pc/#/for-student/teacher-open-topic/index',
    ),
    FduropNoticeItem(
      id: 'fdurop_n2',
      title: '关于开展2026年度复旦大学“莙政学者”项目结题答辩与优秀成果评选的通知',
      program: '莙政',
      publishDate: '2026-10-25',
      summary: '定于11月28日在邯郸校区光华楼举行现场学术汇报会，评选年度“优秀莙政学者”并颁发证书。',
      content: '各莙政学者项目组：2026年度李政道先生设立的“莙政学者”科研训练项目已进入收尾结题阶段。请各项目负责人于11月20日前在系统提交结题学术论文（按要求格式排版）、查重报告及财务报销明细表。各学科评审组将安排现场答辩与墙报展示，欢迎全校师生观摩旁听。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261025-junzheng',
    ),
    FduropNoticeItem(
      id: 'fdurop_n3',
      title: '第十四届复旦大学本科生学术研究论坛暨FDUROP年会征文与报告通知',
      program: '全计划',
      publishDate: '2026-11-02',
      summary: '大会设自然科学、工程技术、人文社科、医学交叉4个分论坛，优秀论文将汇编成册入选校史文献库。',
      content: '复旦大学本科生学术研究论坛每年举办一届，旨在为广大致力于前沿探索的本科生搭建跨校区、跨学科的高水平学术交流舞台。征文范围覆盖所有正在执行或已结题的FDUROP项目研究成果，入选口头报告者将获颁优秀学术演讲证书。',
      url: 'http://www.fdurop.fudan.edu.cn/forum/2026-annual',
    ),
    FduropNoticeItem(
      id: 'fdurop_n4',
      title: '关于组织2026年秋季学期“望道项目”中期进展报告提交与核查的通知',
      program: '望道',
      publishDate: '2026-11-06',
      summary: '请各项目负责人登录系统下载并填写《中期进展检查表》，由导师签署进展评估意见后扫描上传。',
      content: '望道学者项目执行期过半，中期考核是保证科研质量的关键环节。教务处将对实验进度缓慢、阶段成果不足的项目安排学术督导沟通。请于11月30日前完成系统提交。',
      url: 'http://www.fdurop.fudan.edu.cn/notices/20261106-midterm',
    ),
    FduropNoticeItem(
      id: 'fdurop_n5',
      title: '2026年度FDUROP交叉学科专项与登峰新工科计划立项评审结果公示',
      program: '登峰',
      publishDate: '2026-11-12',
      summary: '经专家委员会初审与现场双盲评审，共计42项交叉创新课题获得立项资助，现予以校内公示。',
      content: '本次交叉学科专项聚焦“人工智能赋能人文社科”与“医工交叉诊疗技术”两大前沿领域，共有来自18个院系的本科生团队脱颖而出。公示期为5个工作日。',
      url: 'http://www.fdurop.fudan.edu.cn/results/2026-interdisciplinary',
    ),
  ];

  // =========================================================================
  // 5. 开放科研项目数据 (Open Research Projects - 来源于 paper.fudan.edu.cn 教师开放课题系统与院系招募)
  // =========================================================================
  static const List<FduropProjectItem> _initialFduropProjects =
      initialFduropProjects;

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
      downloadUrl:
          'http://www.fdurop.fudan.edu.cn/downloads/fdurop_apply_2026.docx',
    ),
    FduropDocumentItem(
      id: 'doc_2',
      title: 'FDUROP中期进展报告表与指导教师审核评语单.docx',
      category: '中期检查',
      fileFormat: 'DOCX',
      fileSize: '185 KB',
      updateDate: '2026-10-18',
      downloadUrl:
          'http://www.fdurop.fudan.edu.cn/downloads/fdurop_midterm_form.docx',
    ),
    FduropDocumentItem(
      id: 'doc_3',
      title: '复旦大学FDUROP结题论文写作规范与成果总结报告模板.pdf',
      category: '结题评审',
      fileFormat: 'PDF',
      fileSize: '620 KB',
      updateDate: '2026-10-22',
      downloadUrl:
          'http://www.fdurop.fudan.edu.cn/downloads/fdurop_thesis_guide.pdf',
    ),
    FduropDocumentItem(
      id: 'doc_4',
      title: '复旦大学本科生学术研究导师推荐信及团队分工确认书.docx',
      category: '立项申报',
      fileFormat: 'DOCX',
      fileSize: '120 KB',
      updateDate: '2026-10-15',
      downloadUrl:
          'http://www.fdurop.fudan.edu.cn/downloads/fdurop_recommendation.docx',
    ),
    FduropDocumentItem(
      id: 'doc_5',
      title: '复旦大学本科生学术研究资助计划经费使用与财务报销指南手册（2026版）.pdf',
      category: '经费管理',
      fileFormat: 'PDF',
      fileSize: '1.1 MB',
      updateDate: '2026-09-28',
      downloadUrl:
          'http://www.fdurop.fudan.edu.cn/downloads/fdurop_financial_guide.pdf',
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
    return _initialGroups
        .map((group) {
          return group.copyWith(
            isFollowed: _followedGroupIds.contains(group.id),
          );
        })
        .where((item) {
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
        })
        .toList();
  }

  /// Get lectures with bookmark status applied and optional search/category filter.
  Future<List<ResearchLectureItem>> getLectures({
    String? query,
    String? category,
    bool? bookmarkedOnly,
  }) async {
    return _initialLectures
        .map((lec) {
          return lec.copyWith(
            isBookmarked: _bookmarkedLectureIds.contains(lec.id),
          );
        })
        .where((item) {
          if (bookmarkedOnly == true && !item.isBookmarked) {
            return false;
          }
          if (category != null &&
              category != '全部' &&
              item.category != category) {
            return false;
          }
          if (query != null && query.trim().isNotEmpty) {
            final q = query.trim().toLowerCase();
            final matchTitle = item.title.toLowerCase().contains(q);
            final matchSpeaker = item.speaker.toLowerCase().contains(q);
            final matchVenue = item.venue.toLowerCase().contains(q);
            final matchOrganizer = item.organizer.toLowerCase().contains(q);
            if (!matchTitle &&
                !matchSpeaker &&
                !matchVenue &&
                !matchOrganizer) {
              return false;
            }
          }
          return true;
        })
        .toList();
  }

  /// Get FDUROP website notices.
  Future<List<FduropNoticeItem>> getFduropNotices({
    String? program,
    String? query,
  }) async {
    return _initialFduropNotices.where((notice) {
      if (program != null &&
          program != '全部' &&
          !notice.program.contains(program)) {
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
    String? subjectKind,
    String? topicLabel,
    String? department,
    String? query,
    bool? bookmarkedOnly,
    int pageSize = 100,
  }) async {
    if (_api != null) {
      try {
        final params = <String, dynamic>{
          'page': 1,
          'page_size': pageSize,
          if (query != null && query.trim().isNotEmpty) ...{
            'keyword': query.trim(),
            'code_or_name': query.trim(),
            'title': query.trim(),
          },
        };
        final res = await _api!.call('fudan.fdurop.topics', params);
        if (res is List && res.isNotEmpty) {
          final liveList = res
              .map(
                (e) => FduropProjectItem.fromLiveJson(
                  Map<String, dynamic>.from(e as Map),
                  isBookmarked: _bookmarkedFduropProjectIds.contains(
                    e['id']?.toString(),
                  ),
                ),
              )
              .toList();

          return liveList.where((item) {
            if (bookmarkedOnly == true && !item.isBookmarked) return false;
            if (subjectKind != null && subjectKind != '全部') {
              if (!item.matchesSubjectKind(subjectKind)) return false;
            }
            if (topicLabel != null && topicLabel != '全部') {
              if (!item.matchesTopicLabel(topicLabel)) return false;
            }
            if (program != null && program != '全部') {
              final matchProgram =
                  item.program.contains(program) ||
                  item.topicLabels.any((l) => l.contains(program)) ||
                  item.subjectKinds.any((s) => s.contains(program));
              if (!matchProgram) return false;
            }
            if (department != null &&
                department != '全部' &&
                !item.department.contains(department)) {
              return false;
            }
            if (query != null && query.trim().isNotEmpty) {
              if (!item.matchesQuery(query)) return false;
            }
            return true;
          }).toList();
        }
      } catch (_) {
        // Fallback to static mock on error / unauthenticated
      }
    }

    return _initialFduropProjects
        .map((project) {
          return project.copyWith(
            isBookmarked: _bookmarkedFduropProjectIds.contains(project.id),
          );
        })
        .where((item) {
          if (bookmarkedOnly == true && !item.isBookmarked) {
            return false;
          }
          if (subjectKind != null && subjectKind != '全部') {
            if (!item.matchesSubjectKind(subjectKind)) return false;
          }
          if (topicLabel != null && topicLabel != '全部') {
            if (!item.matchesTopicLabel(topicLabel)) return false;
          }
          if (program != null && program != '全部') {
            final matchProgram =
                item.program.contains(program) ||
                item.topicLabels.any((l) => l.contains(program)) ||
                item.subjectKinds.any((s) => s.contains(program));
            if (!matchProgram) return false;
          }
          if (department != null &&
              department != '全部' &&
              !item.department.contains(department)) {
            return false;
          }
          if (query != null && query.trim().isNotEmpty) {
            if (!item.matchesQuery(query)) {
              return false;
            }
          }
          return true;
        })
        .toList();
  }

  /// Get detailed profile of an FDUROP topic including tutor and lab details.
  Future<FduropProjectItem?> getFduropProjectDetail(String id) async {
    if (_api != null) {
      try {
        final res = await _api!.call('fudan.fdurop.topic.detail', {'id': id});
        if (res is Map) {
          return FduropProjectItem.fromLiveJson(
            Map<String, dynamic>.from(res),
            isBookmarked: _bookmarkedFduropProjectIds.contains(id),
          );
        }
      } catch (_) {
        // Fallback
      }
    }
    final list = await getFduropProjects();
    final matches = list.where((p) => p.id == id);
    return matches.isNotEmpty ? matches.first : null;
  }

  /// Get FDUROP downloadable documents.
  Future<List<FduropDocumentItem>> getFduropDocuments({
    String? category,
    String? query,
  }) async {
    return _initialFduropDocuments
        .map((doc) {
          return doc.copyWith(
            isDownloaded: _downloadedFduropDocIds.contains(doc.id),
          );
        })
        .where((item) {
          if (category != null &&
              category != '全部' &&
              item.category != category) {
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
        })
        .toList();
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

  /// List of lecture categories for filtering.
  List<String> get availableLectureCategories => [
    '全部',
    '人文社科',
    '信息技术',
    '物质前沿',
    '生命健康',
  ];

  /// List of FDUROP programs for filtering.
  List<String> get availableFduropPrograms => [
    '全部',
    '曦源项目',
    '望道项目',
    '莙政项目',
    '登峰项目',
    '开放自选课题',
  ];

  /// List of FDUROP academic subject discipline kinds (学科门类) from paper.fudan.edu.cn.
  List<String> get availableFduropSubjectKinds => [
    '全部',
    '交叉学科',
    '医学',
    '工学',
    '理学',
    '文学',
    '法学',
    '经济学',
    '管理学',
    '历史学',
    '哲学',
    '教育学',
    '艺术学',
  ];

  /// List of FDUROP topic labels / funding sources (课题标签/资助来源) from paper.fudan.edu.cn.
  List<String> get availableFduropTopicLabels => [
    '全部',
    '国家自然科学基金项目',
    '国家科技重大专项',
    '国家社科基金项目',
    '省（市）级基金项目',
    '企事业单位委托项目',
    '国际合作项目',
    '其它项目',
  ];

  /// Query live topic labels from paper.fudan.edu.cn via CampusApi.
  Future<List<Map<String, dynamic>>> queryLiveTopicLabels() async {
    if (_api != null) {
      try {
        final res = await _api!.call('fudan.fdurop.labels', {});
        if (res is List) {
          return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {
        // Fallback
      }
    }
    return availableFduropTopicLabels
        .where((l) => l != '全部')
        .map((l) => {'name_zh': l})
        .toList();
  }

  /// Query live subject kinds from paper.fudan.edu.cn via CampusApi.
  Future<List<Map<String, dynamic>>> queryLiveSubjectKinds() async {
    if (_api != null) {
      try {
        final res = await _api!.call('fudan.fdurop.subjects', {});
        if (res is List) {
          return res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        }
      } catch (_) {
        // Fallback
      }
    }
    return availableFduropSubjectKinds
        .where((s) => s != '全部')
        .map((s) => {'name_zh': s})
        .toList();
  }

  /// List of FDUROP document categories.
  List<String> get availableFduropDocCategories => [
    '全部',
    '立项申报',
    '中期检查',
    '结题评审',
    '经费管理',
  ];
}
