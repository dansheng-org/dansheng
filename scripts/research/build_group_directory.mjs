// SPDX-License-Identifier: GPL-3.0-or-later
// Regenerates the research-group (课题组) directory bundled with the app from
// the public faculty homepage portal (faculty.fudan.edu.cn), walking every
// unit of its college list. Each entry links to the PI's official homepage;
// only the name, title, unit, group name and listed research directions are
// kept (no contact details).
//
// Usage: node scripts/research/build_group_directory.mjs
// Writes apps/dansheng_app/lib/ui/campus/research/research_group_directory.dart

import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = 'https://faculty.fudan.edu.cn';
const UA = 'Mozilla/5.0 (compatible; dansheng-directory-builder)';
const OUT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../apps/dansheng_app/lib/ui/campus/research/research_group_directory.dart',
);

let active = 0;
const waiting = [];
async function limited(task) {
  if (active >= 4) await new Promise((r) => waiting.push(r));
  active++;
  try {
    return await task();
  } finally {
    active--;
    waiting.shift()?.();
  }
}

async function get(url) {
  return limited(async () => {
    for (let attempt = 0; attempt < 3; attempt++) {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 20000);
      try {
        const res = await fetch(url, { headers: { 'User-Agent': UA }, signal: ctl.signal });
        if (res.ok) return await res.text();
      } catch {
        // retried below
      } finally {
        clearTimeout(timer);
      }
    }
    return '';
  });
}

const decode = (s) =>
  s
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n))
    .replace(/&#34;|&quot;/g, '"');

function lines(html) {
  return decode(
    html
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<[^>]+>/g, '\n'),
  )
    .split('\n')
    .map((l) => l.replace(/[\s​]+/g, ' ').trim())
    .filter(Boolean);
}

const HEADINGS = new Set(['个人简介', '教育经历', '工作经历', '研究方向', '社会兼职', '团队成员', '其他联系方式', '社会职务', '论文成果', '科研项目', '查看更多', '学科专业', '学术成果', '招生信息', '教学研究', '教育教学', '课程信息', '学生信息', '工作经历', '教育经历', '奖项荣誉']);
// Bilingual labels and lead-ins inside the section, skipped rather than kept.
const NOISE =
  /^(Research Focus|Research Direction|Teacher homepage|Social Functions|Research Interests?|研究方向|具体研究方向包括|主要研究方向)[：:]?$/i;

const NOT_A_TOPIC = new RegExp(
  [
    '发表|论文|期刊|主持|负责人|获|入选|编委|出版|课题|专著|申请|余篇',
    '→|博士|硕士|学士|本科|毕业|挂职|书记|曾|至今|访问',
    '电话|邮箱|phone|e-?mail|tel|@|\\d{5}',
    '男，|女，|党员|盟员|教授$|研究员$|大学$|院长|理事|职务|顶刊|子刊|journal|规模生产|学会|会员|专家|顾问|带头人|学校|秘书长|委员',
    'vol\\.|issue|prof\\.|^[,，、]|^[A-Za-z]{1,4}$|^[A-Z][a-z]+( [A-Z][a-z]+)?$',
    '[/|》《&]|^[-年]|^\\d',
  ].join('|'),
  'i',
);

/// One profile: title line `( 教授 | 博士生导师 | )`, `所在单位：…`, and
/// the 研究方向 section when it has content.
function parseProfile(html, fallbackName) {
  const ls = lines(html);
  const pageTitle = decode((html.match(/<title>([^<]*)<\/title>/i) || [])[1] || '')
    .replace(/--?首页.*$/, '')
    .trim();
  // The title block reads `( 教授 | 博士生导师 | )` across several lines.
  // Or on one line: `( 教授 )`.
  const open = ls.findIndex((l) => l.startsWith('('));
  const titles = [];
  if (open >= 0) {
    for (let i = open; i < Math.min(ls.length, open + 6); i++) {
      const closed = ls[i].includes(')');
      const part = ls[i].replace(/^\(/, '').replace(/\).*$/, '').trim();
      if (part && part !== '|') titles.push(part);
      if (closed) break;
    }
  }
  const field = (key) => {
    const line = ls.find((l) => l.startsWith(`${key}：`));
    return line ? line.slice(key.length + 1).trim() : '';
  };
  // The newer template states `职称：青年副研究员` instead.
  if (!titles.length && field('职称')) {
    titles.push(field('职称'));
    const supervisor = ls.slice(0, 40).find((l) => /^(博士生导师|硕士生导师)$/.test(l));
    if (supervisor) titles.push(supervisor);
  }
  let directions = [];
  const at = ls.lastIndexOf('研究方向');
  if (at >= 0) {
    const body = [];
    // Some templates put adjacent headings first (`研究方向 | Research Focus |
    // 社会职务 | Social Functions | …content`), so skip that run before reading.
    let start = at + 1;
    while (start < ls.length && (HEADINGS.has(ls[start]) || NOISE.test(ls[start]))) start++;
    for (let i = start; i < ls.length && !HEADINGS.has(ls[i]) && body.length < 8; i++) {
      if (ls[i] === '暂无内容') break;
      if (/Copyright|访问量|最后更新/.test(ls[i])) break;
      if (!NOISE.test(ls[i])) body.push(ls[i]);
    }
    directions = body
      .join('；')
      .split(/[；;。\n]|(?:^|\s)\d+[.、．]\s*/)
      .map((d) =>
        d
          .replace(/^[\d.、．()（）·•\s]+/, '')
          .replace(/^(主要)?研究(方向|领域)(为|是|包括)?[：:]?/, '')
          .trim(),
      )
      .filter((d) => d.length >= 2 && d.length <= 40 && !NOISE.test(d) && !d.endsWith('：'))
      // Topic phrases only: no career notes, publications, bios or contact details.
      .filter((d) => !NOT_A_TOPIC.test(d))
      .slice(0, 6);
  }
  // A page titled e.g. "安正华 An Group" names the group; otherwise the PI does.
  const head = pageTitle.split(/--/)[0].replace(/\s+/g, ' ').trim();
  const named =
    /group|lab|课题组|实验室|团队|研究组/i.test(head) && !/简介|研究院|学院|首页/.test(head) && head.length <= 40
      ? head
      : '';
  return {
    name: named || `${fallbackName}课题组`,
    titles: titles.filter((t) => t.length <= 12).slice(0, 3),
    unit: field('所在单位'),
    directions,
  };
}

async function main() {
  const units = await get(`${ROOT}/units.jsp?urltype=tree.TreeTempUrl&wbtreeid=1002`);
  const unitRe = /href="units_teacher\.jsp[^"]*?&id=(\d+)[^"]*">\s*<h3>([^<（]*)（(\d+)）<\/h3>/g;
  const unitList = [...units.matchAll(unitRe)]
    .filter((m) => +m[3] > 0)
    // Teaching and research units only, not offices or hospitals.
    .filter((m) => !/(处|办公室|图书馆|档案馆|医院|文献信息中心)$/.test(m[2].trim()))
    .map((m) => ({ id: m[1], name: m[2].trim() }));
  if (unitList.length < 20) throw new Error(`unit list looks wrong (${unitList.length})`);

  const people = new Map();
  await Promise.all(
    unitList.map(async (unit) => {
      const query = `urltype=tsites.CollegeTeacherList&wbtreeid=1002&st=0&id=${unit.id}&lang=zh_CN`;
      const first = await get(`${ROOT}/units_teacher.jsp?${query}`);
      // Ten teachers per page: `?totalpage=11&PAGENUM=2&…`.
      const total = Math.min(+(first.match(/totalpage=(\d+)/) || [0, 1])[1], 60);
      const pages = [first];
      for (let n = 2; n <= total; n++) {
        pages.push(await get(`${ROOT}/units_teacher.jsp?totalpage=${total}&PAGENUM=${n}&${query}`));
      }
      for (const html of pages) {
        for (const m of html.matchAll(/addimg\("[^"]*","(\/[^"]+\/zh_CN\/index\.htm)","([^"]+)"/g)) {
          const url = ROOT + m[1];
          if (!people.has(url)) people.set(url, { url, person: decode(m[2]).trim(), unit: unit.name });
        }
      }
    }),
  );
  console.error(`units=${unitList.length} people=${people.size}`);

  const entries = [];
  let done = 0;
  await Promise.all(
    [...people.values()].map(async (p) => {
      const html = await get(p.url);
      if (++done % 100 === 0) console.error(`profiles ${done}/${people.size}`);
      if (!html) return;
      const info = parseProfile(html, p.person);
      entries.push({
        name: info.name,
        leader: p.person,
        title: info.titles.join(' / '),
        department: info.unit || p.unit,
        directions: info.directions,
        url: p.url,
      });
    }),
  );
  entries.sort(
    (a, b) => a.department.localeCompare(b.department, 'zh') || a.leader.localeCompare(b.leader, 'zh'),
  );
  const q = (s) => `'${s.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\$/g, '\\$')}'`;
  const body = entries
    .map(
      (e) =>
        `  ResearchGroupItem.directory(name: ${q(e.name)}, leader: ${q(e.leader)}, ` +
        `leaderTitle: ${q(e.title)}, department: ${q(e.department)}, ` +
        `researchDirections: [${e.directions.map(q).join(', ')}], websiteUrl: ${q(e.url)}),`,
    )
    .join('\n');
  const today = new Date().toISOString().slice(0, 10);
  fs.writeFileSync(
    OUT,
    `// SPDX-License-Identifier: GPL-3.0-or-later\n` +
      `// GENERATED by scripts/research/build_group_directory.mjs on ${today}; do not edit.\n` +
      `// Source: ${ROOT} (复旦大学教师个人主页, every unit of its college list).\n\n` +
      `import 'research_models.dart';\n\n` +
      `/// Fudan PIs with an official homepage, as research-group entries.\n` +
      `const String researchGroupDirectoryDate = '${today}';\n\n` +
      `const List<ResearchGroupItem> researchGroupDirectory = [\n${body}\n];\n`,
  );
  // Keep the generated file in the repository's `dart format` style.
  execSync(`dart format "${OUT}"`, { stdio: 'ignore' });
  console.error(`wrote ${entries.length} entries to ${OUT}`);
}

await main();
