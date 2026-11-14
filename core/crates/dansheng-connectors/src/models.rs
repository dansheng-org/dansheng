// SPDX-License-Identifier: GPL-3.0-or-later
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

/// IDs are opaque host-owned references, not usernames, cookies, or access tokens.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SourceContext {
    pub account_id: String,
    pub source_id: String,
    pub observed_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct SourceRecord<T> {
    pub account_id: String,
    pub source_id: String,
    pub external_id: String,
    pub observed_at: DateTime<Utc>,
    pub updated_at: Option<DateTime<Utc>>,
    pub payload: T,
}

impl SourceContext {
    pub fn record<T>(
        &self,
        external_id: String,
        updated_at: Option<DateTime<Utc>>,
        payload: T,
    ) -> SourceRecord<T> {
        SourceRecord {
            account_id: self.account_id.clone(),
            source_id: self.source_id.clone(),
            external_id,
            observed_at: self.observed_at,
            updated_at,
            payload,
        }
    }

    pub(crate) fn validate(&self) -> Result<(), crate::ConnectorError> {
        if self.account_id.trim().is_empty() || self.source_id.trim().is_empty() {
            return Err(crate::ConnectorError::InvalidConfiguration(
                "source identity",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Semester {
    pub external_id: String,
    pub name: String,
    /// Monday of teaching week 1, in the school's local calendar (Asia/Shanghai).
    pub starts_on: NaiveDate,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SemesterCatalog {
    pub semesters: Vec<Semester>,
    pub default_semester_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct TimetableCourse {
    pub lesson_id: Option<String>,
    pub course_code: Option<String>,
    pub name: String,
    pub teachers: Vec<String>,
    pub room: Option<String>,
    /// ISO weekday: Monday = 1, Sunday = 7.
    pub weekday: u8,
    /// One-based inclusive teaching units; not clock times.
    pub start_unit: u8,
    pub end_unit: u8,
    /// Monday-based teaching weeks. Week zero is retained for UG Sunday spillover.
    pub weeks: Vec<u16>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Timetable {
    pub source: SourceContext,
    pub semester: Semester,
    pub timezone: String,
    /// Each source activity/PG slot is a separate record; never merge different weeks/rooms.
    pub courses: Vec<SourceRecord<TimetableCourse>>,
}
