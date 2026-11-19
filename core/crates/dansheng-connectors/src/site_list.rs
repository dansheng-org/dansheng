// SPDX-License-Identifier: GPL-3.0-or-later
//! Public article columns of Fudan department sites (科研动态, 学术讲座, …).
//!
//! The department sites run several CMS templates (WebPlus `list.htm`, VSB
//! `info/…` pages, bespoke layouts), so rows are recognised structurally: an
//! article link plus the smallest enclosing block that carries a date and no
//! other article link. Columns often link straight to the department's WeChat
//! article; those links are returned as-is for the app to open.

use std::collections::HashMap;

use chrono::NaiveDate;
use regex::Regex;
use scraper::{ElementRef, Html};
use serde::{Deserialize, Serialize};

use crate::campus::{CampusError, changed, selector};
use crate::transport::ConnectorError;

/// One entry of a department column.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SiteArticle {
    pub title: String,
    pub url: String,
    pub published_on: NaiveDate,
}

const MAX_ARTICLES: usize = 60;
/// Sign-in and gateway hosts are never read as public columns.
const DENIED_HOSTS: [&str; 6] = [
    "uis.fudan.edu.cn",
    "id.fudan.edu.cn",
    "webvpn.fudan.edu.cn",
    "stuvpn.fudan.edu.cn",
    "ehall.fudan.edu.cn",
    "mail.fudan.edu.cn",
];

fn fudan_host(host: &str) -> bool {
    host.ends_with(".fudan.edu.cn") && !DENIED_HOSTS.contains(&host)
}

/// A public column address on a `*.fudan.edu.cn` department site.
pub fn column_url(url: &str) -> Result<url::Url, CampusError> {
    let invalid = || CampusError::InvalidQuery("column url");
    let url = url::Url::parse(url).map_err(|_| invalid())?;
    if url.scheme() != "https"
        || !url.host_str().is_some_and(fudan_host)
        || url.port().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(invalid());
    }
    Ok(url)
}

/// Article pages: WebPlus `…/c<col>a<id>/page.htm`, VSB `info/<col>/<id>.htm`,
/// other `*.fudan.edu.cn` article paths, and WeChat articles.
fn article_link(page: &url::Url, href: &str) -> Option<url::Url> {
    let href = href.trim();
    if href.starts_with("javascript:") || href.starts_with('#') {
        return None;
    }
    let mut url = page.join(href).ok()?;
    url.set_fragment(None);
    if !url.username().is_empty() || url.password().is_some() || url.port().is_some() {
        return None;
    }
    let host = url.host_str()?.to_owned();
    if host == "mp.weixin.qq.com" {
        let ok = url.scheme() == "https" && url.path().starts_with("/s");
        return ok.then_some(url);
    }
    if !fudan_host(&host) || !matches!(url.scheme(), "https" | "http") {
        return None;
    }
    let path = url.path();
    let article =
        path.ends_with("/page.htm") || path.ends_with("/page.psp") || article_path().is_match(path);
    if !article || url.query().is_some() {
        return None;
    }
    // Same-site http links are served over https by every listed site.
    if url.scheme() == "http" {
        url.set_scheme("https").ok()?;
    }
    Some(url)
}

fn article_path() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(/info/\d+/\d+\.htm|/Data/View/\d+)$").expect("constant regex"))
}

fn full_date() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(20\d{2})\s*[-./年]\s*(\d{1,2})\s*[-./月]\s*(\d{1,2})")
            .expect("constant regex")
    })
}

/// WebPlus "calendar" badges split the date: `23` + `2024.05` (either order).
fn split_date() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?:^|\s)(\d{1,2})\s+(20\d{2})[-./](\d{1,2})(?:\s|$)|(?:^|\s)(20\d{2})[-./](\d{1,2})\s+(\d{1,2})(?:\s|$)")
            .expect("constant regex")
    })
}

fn find_date(value: &str) -> Option<NaiveDate> {
    let ymd = |y: &str, m: &str, d: &str| {
        NaiveDate::from_ymd_opt(y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)
    };
    if let Some(c) = full_date().captures(value) {
        return ymd(&c[1], &c[2], &c[3]);
    }
    let c = split_date().captures(value)?;
    match (c.get(1), c.get(4)) {
        (Some(d), _) => ymd(&c[2], &c[3], d.as_str()),
        (None, Some(y)) => ymd(y.as_str(), &c[5], &c[6]),
        _ => None,
    }
}

/// Text with node boundaries kept: `<div>23</div><div>2024.05</div>` is `23 2024.05`.
fn spaced_text(element: ElementRef<'_>) -> String {
    element
        .text()
        .flat_map(str::split_whitespace)
        .collect::<Vec<_>>()
        .join(" ")
}

/// A link's label: its `title`, else its text without any date badge it wraps.
fn title_of(anchor: ElementRef<'_>) -> String {
    let attr = anchor
        .value()
        .attr("title")
        .map(|t| t.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|t| !t.is_empty());
    let title = attr.unwrap_or_else(|| {
        let text = spaced_text(anchor);
        let text = full_date().replace_all(&text, " ");
        let text = split_date().replace_all(&text, " ");
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    });
    title
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect()
}

/// The row date of a link: the link itself or the nearest enclosing block
/// that carries a date and no other article link.
fn row_date(anchor: ElementRef<'_>, url: &url::Url, page: &url::Url) -> Option<NaiveDate> {
    if let Some(found) = find_date(&spaced_text(anchor)) {
        return Some(found);
    }
    let links = selector("a[href]");
    let mut node = anchor;
    for _ in 0..5 {
        node = node.parent().and_then(ElementRef::wrap)?;
        let others = node
            .select(&links)
            .filter_map(|a| article_link(page, a.value().attr("href")?))
            .any(|u| u != *url);
        if others {
            return None;
        }
        if let Some(found) = find_date(&spaced_text(node)) {
            return Some(found);
        }
    }
    None
}

/// The rows of one column page, newest first.
pub fn parse_site_articles(body: &[u8], page: &url::Url) -> Result<Vec<SiteArticle>, CampusError> {
    let raw = std::str::from_utf8(body).map_err(|_| changed("site", "utf8"))?;
    let doc = Html::parse_document(raw);
    // One row often links the same article several times (image, date, title).
    let mut order: Vec<String> = Vec::new();
    let mut rows: HashMap<String, (Option<NaiveDate>, String, bool)> = HashMap::new();
    let mut any_link = false;
    for anchor in doc.select(&selector("a[href]")) {
        let Some(url) = anchor
            .value()
            .attr("href")
            .and_then(|href| article_link(page, href))
        else {
            continue;
        };
        any_link = true;
        let key = url.to_string();
        let title = title_of(anchor);
        let date = row_date(anchor, &url, page);
        let explicit = anchor
            .value()
            .attr("title")
            .is_some_and(|t| !t.trim().is_empty());
        let entry = rows.entry(key.clone()).or_insert_with(|| {
            order.push(key);
            (None, String::new(), false)
        });
        entry.0 = entry.0.or(date);
        // An explicit title attribute wins; otherwise the longest label does.
        let better = match (explicit, entry.2) {
            (true, false) => true,
            (false, true) => false,
            _ => title.chars().count() > entry.1.chars().count(),
        };
        if better {
            entry.1 = title;
            entry.2 = explicit;
        }
    }
    let mut out = Vec::new();
    for key in order {
        let (date, title, _) = rows.remove(&key).expect("recorded row");
        let (Some(published_on), true) = (date, title.chars().count() >= 4) else {
            continue;
        };
        out.push(SiteArticle {
            title,
            url: key,
            published_on,
        });
        if out.len() > MAX_ARTICLES {
            return Err(ConnectorError::LimitExceeded.into());
        }
    }
    if out.is_empty() && (!any_link || raw.contains("找不到对应的栏目")) {
        return Err(changed("site", "column"));
    }
    out.sort_by_key(|a| std::cmp::Reverse(a.published_on));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(u: &str) -> url::Url {
        url::Url::parse(u).unwrap()
    }

    #[test]
    fn webplus_calendar_rows_with_split_dates() {
        let html = r#"<ul class="nav"><li><a href="/75/e1/c50574a685537/page.htm">捐赠支持</a></li></ul>
        <ul><li class="news"><div class="news_date"><div class="news_days">23</div><div class="news_year">2024.05</div></div>
        <div class="news_title"><a href='/55/2d/c24280a677165/page.htm' title='团队成果入选十大科技进展'>团队成果入选…</a></div></li>
        <li class="news"><div class="news_date"><div class="news_days">16</div><div class="news_year">2024.04</div></div>
        <div class="news_title"><a href='https://mp.weixin.qq.com/s/abcDEF' title='学科排名再创新高'>x</a></div></li></ul>"#;
        let rows = parse_site_articles(
            html.as_bytes(),
            &page("https://ai.fudan.edu.cn/24280/list.htm"),
        )
        .unwrap();
        assert_eq!(rows.len(), 2, "the dateless menu link is not a row");
        assert_eq!(rows[0].title, "团队成果入选十大科技进展");
        assert_eq!(
            rows[0].url,
            "https://ai.fudan.edu.cn/55/2d/c24280a677165/page.htm"
        );
        assert_eq!(
            rows[0].published_on,
            NaiveDate::from_ymd_opt(2024, 5, 23).unwrap()
        );
        assert_eq!(rows[1].url, "https://mp.weixin.qq.com/s/abcDEF");
    }

    #[test]
    fn div_rows_vsb_links_and_newest_first() {
        let html = r#"<div class="jzlb"><div class="btt3"><a href="../info/1034/37247.htm">前沿 | 外国技术封锁下的应对之策</a></div><div class="fbsj4">2025-10-30</div></div>
        <div class="jzlb"><div class="btt3"><a href="http://econ.fudan.edu.cn/info/1034/37300.htm">2025年11月学术报告预告</a></div><div class="fbsj4">2025年11月02日</div></div>"#;
        let rows = parse_site_articles(
            html.as_bytes(),
            &page("https://econ.fudan.edu.cn/kxyj1/kydt1.htm"),
        )
        .unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0].url, "https://econ.fudan.edu.cn/info/1034/37300.htm",
            "http links upgrade"
        );
        assert_eq!(rows[1].url, "https://econ.fudan.edu.cn/info/1034/37247.htm");
    }

    #[test]
    fn a_block_with_two_articles_is_not_one_row() {
        let html = r#"<div>2026-01-01<a href="/a/c1a1/page.htm">第一篇文章标题</a><a href="/a/c1a2/page.htm">第二篇文章标题</a></div>"#;
        let rows = parse_site_articles(
            html.as_bytes(),
            &page("https://chemistry.fudan.edu.cn/1/list.htm"),
        )
        .unwrap();
        assert!(rows.is_empty());
    }

    #[test]
    fn foreign_and_sign_in_links_are_ignored() {
        let html = r#"<li><a href="https://evil.example/c1a1/page.htm">外站文章标题</a> 2026-01-01</li>
        <li><a href="https://uis.fudan.edu.cn/c1a1/page.htm">登录页面标题</a> 2026-01-01</li>"#;
        // No article of the column remains, which reads as a changed page.
        assert!(
            parse_site_articles(
                html.as_bytes(),
                &page("https://law.fudan.edu.cn/1/list.htm")
            )
            .is_err()
        );
    }

    #[test]
    fn repeated_links_take_the_title_and_badges_inside_links_date_rows() {
        let html = r#"<div class="row"><a href="https://mp.weixin.qq.com/s/x1"><img src="a.jpg"></a>
        <a href="https://mp.weixin.qq.com/s/x1">2025-11-19</a>
        <a href="https://mp.weixin.qq.com/s/x1" title="会议预告：晚清民初的碑学">会议预告…</a></div>
        <li><a href="/Data/View/7016"><div class="data-date"><span>25</span><p>2026-08</p></div><p> 团队提出光子芯片新型设计方法 </p></a></li>"#;
        let rows = parse_site_articles(
            html.as_bytes(),
            &page("https://fit.fudan.edu.cn/Data/List/kycg"),
        )
        .unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].title, "团队提出光子芯片新型设计方法");
        assert_eq!(
            rows[0].published_on,
            NaiveDate::from_ymd_opt(2026, 8, 25).unwrap()
        );
        assert_eq!(rows[1].title, "会议预告：晚清民初的碑学");
        assert_eq!(
            rows[1].published_on,
            NaiveDate::from_ymd_opt(2025, 11, 19).unwrap()
        );
    }

    #[test]
    fn only_public_department_columns_are_accepted() {
        assert!(column_url("https://math.fudan.edu.cn/xsbg/list.htm").is_ok());
        assert!(column_url("https://fit.fudan.edu.cn/Data/List/kycg").is_ok());
        for bad in [
            "http://math.fudan.edu.cn/xsbg/list.htm",
            "https://uis.fudan.edu.cn/authserver/login",
            "https://webvpn.fudan.edu.cn/x/list.htm",
            "https://fudan.edu.cn.evil.example/list.htm",
            "https://math.fudan.edu.cn/list.htm?x=1",
            "https://u:p@math.fudan.edu.cn/list.htm",
            "https://math.fudan.edu.cn:8443/list.htm",
        ] {
            assert!(column_url(bad).is_err(), "{bad}");
        }
    }
}
