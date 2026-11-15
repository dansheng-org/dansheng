// SPDX-License-Identifier: GPL-3.0-or-later
//! Verified Fudan postgraduate teaching-calendar metadata.
//!
//! The anonymous academic catalog supplies the current default semester ID and
//! name, but does not supply teaching dates. Only explicitly verified names below
//! may be joined to calendar dates; neither IDs nor dates are inferred.
//!
//! Verified 2026-11-14: the official 2026-09-08 report, sourced from the university
//! media center, Academic Affairs Office and Graduate School, confirms that both
//! undergraduate and postgraduate teaching began on 2026-09-07:
//! <https://news.fudan.edu.cn/2026/0908/c239a150301/page.htm>.
//! The Graduate School also publishes the 2026-2027 calendar at
//! <https://gs.fudan.edu.cn/_t221/f3/b0/c2892a783280/page.htm>. Its linked calendar
//! image was visually verified on 2026-11-14: the first semester runs from
//! 2026-08-30 through 2027-01-09 inclusive; August 30's row is week 0 and
//! September 7 is week 1's Monday. The second semester runs from 2027-02-14
//! through 2027-06-26 inclusive; February 14's row is week 0 and February 22
//! is week 1's Monday:
//! <https://gs.fudan.edu.cn/_upload/article/images/3d/de/8072247b408eac93214b187badf1/c7f1fe35-8086-4e58-8a3f-2f39f2324b0a.jpg>.
//!
//! The public catalog supplied the names `2026-2027学年1学期` and
//! `2026-2027学年2学期`. The selected default ID is always read dynamically.
//! The stored date is teaching week one's Monday in Shanghai,
//! not registration day or the undergraduate API's Sunday `startDate` convention.
//! A future/unrecognized default must fail closed until its calendar is verified.
//! This resolves the catalog default, not historical PG timetable queries or the
//! remote PG server's active term. No PG authentication or origin fallback occurs.

use crate::ConnectorTransport;
use crate::academic_catalog::FudanAcademicCatalogClient;
use crate::campus::CampusError;
use crate::models::{Semester, SourceContext};
use chrono::{FixedOffset, NaiveDate};

#[derive(Clone, Debug, thiserror::Error, PartialEq, Eq)]
pub enum PostgraduateCalendarError {
    #[error(transparent)]
    Source(#[from] CampusError),
    #[error("SemesterCalendarUnavailable: no verified calendar for the default semester")]
    SemesterCalendarUnavailable,
}

/// Resolve the anonymous catalog default to a standard, verified semester.
///
/// Hosts should expose this read under `fudan.catalog.read`, preserve source
/// failures, and map the unavailable variant to `SemesterCalendarUnavailable`.
/// `source.observed_at` must be the host's current observation time, not a cached
/// record timestamp. The verified semester interval is checked in Asia/Shanghai
/// (UTC+08:00), including its official pre-teaching registration week.
pub async fn current_semester<T: ConnectorTransport>(
    catalog: &FudanAcademicCatalogClient<T>,
    source: &SourceContext,
) -> Result<Semester, PostgraduateCalendarError> {
    let record = catalog.semesters(source).await?;
    let current = record
        .payload
        .semesters
        .iter()
        .find(|semester| semester.id == record.payload.default_semester_id)
        .ok_or(PostgraduateCalendarError::SemesterCalendarUnavailable)?;
    let (starts_on, valid_from, valid_through) = match current.name.as_str() {
        "2026-2027学年1学期" => (
            NaiveDate::from_ymd_opt(2026, 9, 7).expect("verified teaching week one Monday"),
            NaiveDate::from_ymd_opt(2026, 8, 30).expect("verified semester beginning"),
            NaiveDate::from_ymd_opt(2027, 1, 9).expect("verified semester end"),
        ),
        "2026-2027学年2学期" => (
            NaiveDate::from_ymd_opt(2027, 2, 22).expect("verified teaching week one Monday"),
            NaiveDate::from_ymd_opt(2027, 2, 14).expect("verified semester beginning"),
            NaiveDate::from_ymd_opt(2027, 6, 26).expect("verified semester end"),
        ),
        _ => return Err(PostgraduateCalendarError::SemesterCalendarUnavailable),
    };
    let today = source
        .observed_at
        .with_timezone(&FixedOffset::east_opt(8 * 60 * 60).expect("Shanghai UTC offset"))
        .date_naive();
    if !(valid_from..=valid_through).contains(&today) {
        return Err(PostgraduateCalendarError::SemesterCalendarUnavailable);
    }
    Ok(Semester {
        external_id: current.id.clone(),
        name: current.name.clone(),
        starts_on,
    })
}
