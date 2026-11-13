// SPDX-License-Identifier: GPL-3.0-or-later
//! Official campus statement traversal and calendar aggregation, independent of UI.
use crate::campus::{
    CampusError, Coverage, EcardTransaction, FudanCampusClient, PageWindow, SourceBatch,
};
use crate::energy_history::{ElectricityHistoryClient, ElectricityHistoryRecord};
use crate::models::{SourceContext, SourceRecord};
use crate::{ConnectorError, ConnectorTransport};
use chrono::{Datelike, Duration, FixedOffset, NaiveDate};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_ROWS: usize = 10_000;
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Period {
    Day,
    Week,
    Month,
    Year,
}
impl Period {
    pub fn bounds(self, date: NaiveDate) -> Result<(NaiveDate, NaiveDate), CampusError> {
        let start = match self {
            Self::Day => Some(date),
            Self::Week => date
                .checked_sub_signed(Duration::days(date.weekday().num_days_from_monday().into())),
            Self::Month => date.with_day(1),
            Self::Year => date.with_ordinal(1),
        }
        .ok_or(CampusError::InvalidQuery("period start"))?;
        let next = match self {
            Self::Day => start.succ_opt(),
            Self::Week => start.checked_add_signed(Duration::days(7)),
            Self::Month if start.month() == 12 => NaiveDate::from_ymd_opt(start.year() + 1, 1, 1),
            Self::Month => NaiveDate::from_ymd_opt(start.year(), start.month() + 1, 1),
            Self::Year => NaiveDate::from_ymd_opt(start.year() + 1, 1, 1),
        }
        .ok_or(CampusError::InvalidQuery("period end"))?;
        Ok((
            start,
            next.pred_opt()
                .ok_or(CampusError::InvalidQuery("period end"))?,
        ))
    }
}

impl<T: ConnectorTransport> FudanCampusClient<T> {
    /// Retrieve every verified source page. A partial page is never reported as a complete statement.
    pub async fn ecard_statement(
        &self,
        source: &SourceContext,
        from: NaiveDate,
        to: NaiveDate,
    ) -> Result<SourceBatch<EcardTransaction>, CampusError> {
        let mut page = 1;
        let mut first = self.ecard_transactions(source, from, to, page).await?;
        loop {
            let next = match first.coverage {
                Coverage::Page { next, .. } => next,
                Coverage::Complete => None,
                _ => return Err(CampusError::PaginationInconsistent),
            };
            let Some(next) = next else {
                // Minute-precision statements can contain identical legitimate payments.
                // Preserve every occurrence with a distinct stable snapshot identifier.
                let mut seen = BTreeMap::<String, usize>::new();
                for row in &mut first.records {
                    let count = seen.entry(row.external_id.clone()).or_default();
                    *count += 1;
                    row.external_id = format!("{}:{}", row.external_id, count);
                }
                first.coverage = Coverage::Complete;
                return Ok(first);
            };
            if next <= page || first.records.len() >= MAX_ROWS {
                return Err(ConnectorError::LimitExceeded.into());
            }
            page = next;
            let batch = self.ecard_transactions(source, from, to, page).await?;
            if first.records.len() + batch.records.len() > MAX_ROWS {
                return Err(ConnectorError::LimitExceeded.into());
            }
            first.records.extend(batch.records);
            first.coverage = batch.coverage;
        }
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ExpenseGroup {
    pub name: String,
    pub expense_cents: i64,
    pub count: usize,
}
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct CardStatistics {
    pub period: Period,
    pub from: NaiveDate,
    pub to: NaiveDate,
    pub complete: bool,
    pub record_count: usize,
    pub expense_cents: i64,
    pub income_cents: i64,
    pub unclassified_count: usize,
    pub by_type: Vec<ExpenseGroup>,
    pub by_location: Vec<ExpenseGroup>,
}
fn add(total: &mut i64, amount: i64) -> Result<(), CampusError> {
    *total = total
        .checked_add(amount)
        .ok_or(CampusError::InvalidQuery("statistics overflow"))?;
    Ok(())
}
fn groups(values: BTreeMap<String, (i64, usize)>) -> Vec<ExpenseGroup> {
    let mut result: Vec<_> = values
        .into_iter()
        .map(|(name, (expense_cents, count))| ExpenseGroup {
            name,
            expense_cents,
            count,
        })
        .collect();
    result.sort_by(|a, b| {
        b.expense_cents
            .cmp(&a.expense_cents)
            .then_with(|| a.name.cmp(&b.name))
    });
    result
}
pub fn card_statistics(
    rows: &[SourceRecord<EcardTransaction>],
    period: Period,
    anchor: NaiveDate,
) -> Result<CardStatistics, CampusError> {
    let (from, to) = period.bounds(anchor)?;
    let mut result = CardStatistics {
        period,
        from,
        to,
        complete: true,
        record_count: 0,
        expense_cents: 0,
        income_cents: 0,
        unclassified_count: 0,
        by_type: vec![],
        by_location: vec![],
    };
    let mut types = BTreeMap::new();
    let mut locations = BTreeMap::new();
    let zone = FixedOffset::east_opt(8 * 3600).expect("campus offset");
    for row in rows {
        let item = &row.payload;
        let day = item.at.with_timezone(&zone).date_naive();
        if day < from || day > to {
            continue;
        }
        if item.amount.currency != "CNY" {
            return Err(CampusError::InvalidQuery("card currency"));
        }
        result.record_count += 1;
        let cents = item.amount.cents;
        // epay's seven-column table reports unsigned magnitudes for purchases.
        // The transaction name, rather than the amount sign alone, identifies flow.
        let name = &item.transaction_type;
        let income = ["退款", "退费", "充值", "补助", "入账", "收入", "返还"]
            .iter()
            .any(|word| name.contains(word));
        let expense = ["消费", "支付", "支出", "扣款", "缴费", "付款", "购电"]
            .iter()
            .any(|word| name.contains(word));
        let magnitude = cents
            .checked_abs()
            .ok_or(CampusError::InvalidQuery("statistics overflow"))?;
        if income {
            add(&mut result.income_cents, magnitude)?;
            continue;
        }
        if !expense && cents >= 0 {
            if cents != 0 {
                result.unclassified_count += 1;
            }
            continue;
        }
        let expense = magnitude;
        add(&mut result.expense_cents, expense)?;
        for (map, name) in [
            (&mut types, item.transaction_type.trim()),
            (&mut locations, item.location.trim()),
        ] {
            let name = if name.is_empty() { "未标注" } else { name };
            let entry = map.entry(name.to_owned()).or_insert((0, 0));
            add(&mut entry.0, expense)?;
            entry.1 += 1;
        }
    }
    result.by_type = groups(types);
    result.by_location = groups(locations);
    Ok(result)
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UsageBucket {
    pub start: NaiveDate,
    pub end: NaiveDate,
    pub amount_kwh: String,
    pub record_count: usize,
}
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct UsageStatistics {
    pub period: Period,
    pub complete: bool,
    pub record_count: usize,
    pub buckets: Vec<UsageBucket>,
}
fn usage_date(raw: &str) -> Result<NaiveDate, CampusError> {
    let value = raw.trim().split(['T', ' ']).next().unwrap_or("");
    ["%Y-%m-%d", "%Y/%m/%d", "%Y.%m.%d"]
        .iter()
        .find_map(|pattern| NaiveDate::parse_from_str(value, pattern).ok())
        .ok_or(CampusError::SchemaChanged {
            domain: "electricity-statistics",
            field: "date",
        })
}
fn micro_kwh(raw: &str) -> Result<i64, CampusError> {
    let value = raw
        .trim()
        .trim_end_matches("kWh")
        .trim_end_matches("千瓦时")
        .trim_end_matches('度')
        .trim();
    let (whole, fraction) = value.split_once('.').unwrap_or((value, ""));
    let invalid = || CampusError::SchemaChanged {
        domain: "electricity-statistics",
        field: "amount",
    };
    if whole.is_empty()
        || !whole.bytes().all(|c| c.is_ascii_digit())
        || fraction.len() > 6
        || !fraction.bytes().all(|c| c.is_ascii_digit())
    {
        return Err(invalid());
    }
    let whole = whole.parse::<i64>().map_err(|_| invalid())?;
    let fraction = format!("{fraction:0<6}")
        .parse::<i64>()
        .map_err(|_| invalid())?;
    whole
        .checked_mul(1_000_000)
        .and_then(|v| v.checked_add(fraction))
        .ok_or_else(invalid)
}
fn kwh(value: i64) -> String {
    let whole = value / 1_000_000;
    let fraction = value % 1_000_000;
    if fraction == 0 {
        whole.to_string()
    } else {
        format!("{whole}.{fraction:06}")
            .trim_end_matches('0')
            .to_owned()
    }
}
pub fn usage_statistics(
    rows: &[ElectricityHistoryRecord],
    period: Period,
    complete: bool,
) -> Result<UsageStatistics, CampusError> {
    let mut values: BTreeMap<NaiveDate, (NaiveDate, i64, usize)> = BTreeMap::new();
    for item in rows {
        let (start, end) = period.bounds(usage_date(&item.date)?)?;
        let entry = values.entry(start).or_insert((end, 0, 0));
        add(&mut entry.1, micro_kwh(&item.amount)?)?;
        entry.2 += 1;
    }
    let buckets = values
        .into_iter()
        .map(|(start, (end, amount, count))| UsageBucket {
            start,
            end,
            amount_kwh: kwh(amount),
            record_count: count,
        })
        .collect();
    Ok(UsageStatistics {
        period,
        complete,
        record_count: rows.len(),
        buckets,
    })
}
impl<T: ConnectorTransport> ElectricityHistoryClient<T> {
    pub async fn statistics(
        &self,
        source: &SourceContext,
        period: Period,
    ) -> Result<UsageStatistics, CampusError> {
        let mut offset = 0;
        let mut rows = Vec::new();
        loop {
            let batch = self
                .electricity_history(source, PageWindow { offset, size: 100 })
                .await?;
            if rows.len() + batch.records.len() > MAX_ROWS {
                return Err(ConnectorError::LimitExceeded.into());
            }
            rows.extend(batch.records.into_iter().map(|r| r.payload));
            match batch.coverage {
                Coverage::Page {
                    next: Some(next), ..
                } if next > offset => {
                    offset = next;
                }
                Coverage::Page { next: None, .. } | Coverage::Complete => {
                    return usage_statistics(&rows, period, true);
                }
                Coverage::Window { .. } => return usage_statistics(&rows, period, false),
                _ => return Err(CampusError::PaginationInconsistent),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::campus::Money;
    use chrono::{TimeZone, Utc};
    fn day(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }
    #[test]
    fn calendar_periods_cover_monday_leap_month_and_year() {
        assert_eq!(
            Period::Week.bounds(day("2026-01-01")).unwrap(),
            (day("2025-12-29"), day("2026-01-04"))
        );
        assert_eq!(
            Period::Month.bounds(day("2024-02-18")).unwrap(),
            (day("2024-02-01"), day("2024-02-29"))
        );
        assert_eq!(
            Period::Year.bounds(day("2024-12-31")).unwrap(),
            (day("2024-01-01"), day("2024-12-31"))
        );
    }
    #[test]
    fn spending_separates_income_uses_cents_and_campus_dates() {
        let source = SourceContext {
            account_id: "fixture".into(),
            source_id: "fixture".into(),
            observed_at: Utc::now(),
        };
        let rows = [
            (-100, "食堂", 23),
            (-205, "超市", 23),
            (10000, "充值", 23),
            (-999, "上月", 15),
        ]
        .into_iter()
        .enumerate()
        .map(|(i, (cents, location, hour))| {
            source.record(
                i.to_string(),
                None,
                EcardTransaction {
                    at: Utc.with_ymd_and_hms(2026, 10, 31, hour, 0, 0).unwrap(),
                    transaction_type: if cents < 0 { "消费" } else { "充值" }.into(),
                    location: location.into(),
                    amount: Money {
                        cents,
                        currency: "CNY".into(),
                    },
                },
            )
        })
        .collect::<Vec<_>>();
        let result = card_statistics(&rows, Period::Month, day("2026-11-10")).unwrap();
        assert_eq!(result.expense_cents, 305);
        assert_eq!(result.income_cents, 10000);
        assert_eq!(result.record_count, 3);
        assert_eq!(result.by_location[0].name, "超市");
        assert_eq!(result.by_type[0].expense_cents, 305);
    }
    fn item(date: &str, amount: &str) -> ElectricityHistoryRecord {
        ElectricityHistoryRecord {
            date: date.into(),
            amount: amount.into(),
            dorm_name: "合成寝室".into(),
        }
    }
    #[test]
    fn unsigned_school_purchases_are_expenses_and_refunds_are_separate() {
        let source = SourceContext {
            account_id: "fixture".into(),
            source_id: "fixture".into(),
            observed_at: Utc::now(),
        };
        let rows = [
            (1250, "扫码消费"),
            (300, "消费退款"),
            (10000, "充值"),
            (55, "未知项目"),
        ]
        .into_iter()
        .enumerate()
        .map(|(i, (cents, name))| {
            source.record(
                i.to_string(),
                None,
                EcardTransaction {
                    at: Utc.with_ymd_and_hms(2026, 11, 1, 1, 0, 0).unwrap(),
                    transaction_type: name.into(),
                    location: "合成商户".into(),
                    amount: Money {
                        cents,
                        currency: "CNY".into(),
                    },
                },
            )
        })
        .collect::<Vec<_>>();
        let result = card_statistics(&rows, Period::Month, day("2026-11-1")).unwrap();
        assert_eq!(result.expense_cents, 1250);
        assert_eq!(result.income_cents, 10300);
        assert_eq!(result.by_type.len(), 1);
        assert_eq!(result.unclassified_count, 1);
        assert_eq!(result.record_count, 4);
    }
    #[test]
    fn usage_groups_calendar_periods_without_float_or_fake_zero() {
        let rows = [
            item("2026-11-01", "0.1"),
            item("2026/11/01", "0.2 kWh"),
            item("2026-11-02", "0"),
            item("2026-12-01", "2.5度"),
        ];
        let monthly = usage_statistics(&rows, Period::Month, true).unwrap();
        assert_eq!(monthly.buckets[0].amount_kwh, "0.3");
        assert_eq!(monthly.buckets[0].record_count, 3);
        assert_eq!(monthly.buckets[1].amount_kwh, "2.5");
        assert_eq!(
            usage_statistics(&rows, Period::Year, true).unwrap().buckets[0].amount_kwh,
            "2.8"
        );
        let daily = usage_statistics(&rows, Period::Day, false).unwrap();
        assert_eq!(daily.buckets[1].amount_kwh, "0");
        assert!(!daily.complete);
    }
    #[test]
    fn invalid_usage_is_reported_instead_of_counted_as_zero() {
        assert!(usage_statistics(&[item("2026-11-01", "未知")], Period::Day, true).is_err());
        assert!(usage_statistics(&[item("invalid", "1")], Period::Month, true).is_err());
    }
}
