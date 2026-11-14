//! Fixed read-only probes using the real Core transport and official login code.
//! Private response bodies and credentials stay in memory and are never exported.
use chrono::Utc;
use dansheng_connectors::login::{LoginProgress, LoginTarget, login_with_progress};
use dansheng_core::{Engine, Principal, Request, UnavailablePlatform};
use regex::Regex;
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Arc,
    time::Instant,
};
use url::Url;

const ACCOUNT: &str = "research-campus";
const TIMEOUT_MS: u64 = 12_000;
const CAMPUS_CLOUD_ORIGIN: &str = "https://cloud.fudan.edu.cn";

// No Debug/Serialize implementation: these values must not enter diagnostics.
struct Credentials {
    user: String,
    password: String,
    canvas_token: Option<String>,
}

fn parse_credentials(text: &str) -> Result<Credentials, &'static str> {
    let mut fields = BTreeMap::new();
    for line in text.trim_start_matches('\u{feff}').lines() {
        let Some((key, raw)) = line.split_once([':', '：', '=']) else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        if !matches!(key.as_str(), "user" | "password" | "canvastoken") {
            continue;
        }
        let raw = raw.trim().trim_end_matches(',').trim();
        let value = if raw.len() >= 2
            && matches!(raw.as_bytes()[0], b'\'' | b'"')
            && raw.as_bytes().last() == raw.as_bytes().first()
        {
            &raw[1..raw.len() - 1]
        } else {
            raw
        };
        if value.is_empty()
            || value.contains(['\r', '\n', '\0'])
            || fields.insert(key, value.to_owned()).is_some()
        {
            return Err("InvalidCredentialFields");
        }
    }
    let user = fields.remove("user").ok_or("MissingAccount")?;
    let password = fields.remove("password").ok_or("MissingPassword")?;
    if !(4..=64).contains(&user.len())
        || !user
            .bytes()
            .all(|v| v.is_ascii_alphanumeric() || matches!(v, b'_' | b'-'))
        || password.len() > 512
    {
        return Err("InvalidCredentialFields");
    }
    Ok(Credentials {
        user,
        password,
        canvas_token: fields.remove("canvastoken"),
    })
}

#[derive(Clone, Copy)]
struct Probe {
    case: &'static str,
    url: &'static str,
}

const PUBLIC_PROBES: &[Probe] = &[
    Probe {
        case: "ehall_home",
        url: "https://ehall.fudan.edu.cn/",
    },
    Probe {
        case: "ehall_new_home",
        url: "https://ehall.fudan.edu.cn/new/index.html",
    },
    Probe {
        case: "ehall_directory_all",
        url: "https://ehall.fudan.edu.cn/appmarket/frontend/default/getApp?type=all",
    },
    Probe {
        case: "ehall_directory_limit",
        url: "https://ehall.fudan.edu.cn/appmarket/frontend/default/getApp?type=all&limit=1",
    },
    // These are observed GET collection routes, requested without a private session.
    Probe {
        case: "ehall_tasks_without_session",
        url: "https://ehall.fudan.edu.cn/personal/frontend/task?type=todo&page=1&pageSize=1",
    },
    Probe {
        case: "ehall_applications_without_session",
        url: "https://ehall.fudan.edu.cn/personal/frontend/task/apply?type=all&page=1&pageSize=1",
    },
    Probe {
        case: "personal_data_portal",
        url: "https://my.fudan.edu.cn/",
    },
    Probe {
        case: "undergraduate_lesson_search",
        url: "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search",
    },
    // Semester 527 was observed in the public page on 2026-11-09; it is a bounded research sample.
    Probe {
        case: "undergraduate_catalog_first_page",
        url: "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/semester/527/search/527?queryPage__=1,1",
    },
    Probe {
        case: "undergraduate_program_catalog",
        url: "https://fdjwgl.fudan.edu.cn/manager/bizType/2/page-center/major-program-search-view?skipAuth=1",
    },
    Probe {
        case: "graduate_portal",
        url: "https://gsportal.fudan.edu.cn/yjsmhpublicapp/sys/fddxyjsmhxt/index.do",
    },
    Probe {
        case: "course_evaluation",
        url: "https://ce.fudan.edu.cn/",
    },
    Probe {
        case: "lecture_resources",
        url: "https://icourse.fudan.edu.cn/",
    },
    Probe {
        case: "library_home",
        url: "https://library.fudan.edu.cn/",
    },
    Probe {
        case: "library_opac_portal",
        url: "https://opac.fudan.edu.cn/",
    },
    // This exact public instance and view were discovered in the official OPAC script.
    Probe {
        case: "library_primo_configuration",
        url: "https://fudan-primo.hosted.exlibrisgroup.com.cn/primo_library/libweb/webservices/rest/v1/configuration/fdu",
    },
    Probe {
        case: "ecard_home",
        url: "https://ecard.fudan.edu.cn/epay",
    },
    Probe {
        case: "electricity_portal",
        url: "https://elife.fudan.edu.cn/",
    },
    Probe {
        case: "payment_portal",
        url: "https://cwgl.fudan.edu.cn/payment/",
    },
    Probe {
        case: "freshman_portal",
        url: "https://freshman.fudan.edu.cn/",
    },
    Probe {
        case: "career_portal",
        url: "https://career.fudan.edu.cn/",
    },
    Probe {
        case: "campus_map",
        url: "https://map.fudan.edu.cn/",
    },
    Probe {
        case: "campus_cloud",
        url: "https://cloud.fudan.edu.cn/",
    },
    Probe {
        case: "certificate_printing",
        url: "https://output.fudan.edu.cn/",
    },
    Probe {
        case: "thesis_portal",
        url: "https://thesis.fudan.edu.cn/",
    },
    Probe {
        case: "legacy_pe_records",
        url: "https://fdtyjw.fudan.edu.cn/sportScore/stScore.aspx",
    },
    Probe {
        case: "webvpn_login_entry",
        url: "https://webvpn.fudan.edu.cn/login?cas_login=true",
    },
];

#[derive(Serialize)]
struct Check {
    case: String,
    logical_url: String,
    method: &'static str,
    authenticated_session: bool,
    elapsed_ms: u128,
    http_status: Option<u64>,
    error_code: Option<String>,
    mime: Option<String>,
    bytes: usize,
    json_kind: Option<&'static str>,
    json_keys: Vec<String>,
    item_count: Option<usize>,
    reported_total: Option<u64>,
    api_code: Option<i64>,
    password_inputs: usize,
    script_count: usize,
    login_markers: bool,
    redirect_class: Option<&'static str>,
}

fn header<'a>(value: &'a Value, name: &str) -> Option<&'a str> {
    value["headers"]
        .as_object()?
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))?
        .1
        .as_str()
}

fn safe_mime(raw: &str) -> Option<String> {
    let mime = raw.split(';').next()?.trim().to_ascii_lowercase();
    if mime.len() <= 96
        && mime
            .bytes()
            .all(|v| v.is_ascii_alphanumeric() || matches!(v, b'/' | b'-' | b'+' | b'.'))
    {
        Some(mime)
    } else {
        None
    }
}

fn known_schema_keys(value: &Value) -> Vec<String> {
    const KEYS: &[&str] = &[
        "data",
        "rows",
        "items",
        "results",
        "result",
        "total",
        "totalCount",
        "count",
        "page",
        "size",
        "_page_",
        "_sorts_",
        "success",
        "code",
        "error",
        "errors",
        "message",
        "id",
        "login_id",
        "enrollments",
        "pagination",
        "primo-view",
        "e",
        "m",
        "d",
    ];
    value
        .as_object()
        .map(|map| {
            KEYS.iter()
                .filter(|key| map.contains_key(**key))
                .map(|key| (*key).to_owned())
                .collect()
        })
        .unwrap_or_default()
}

fn summarize(
    case: &str,
    logical_url: &str,
    authenticated_session: bool,
    value: &Value,
    elapsed_ms: u128,
) -> Check {
    let body = value["body"].as_str().unwrap_or("");
    let parsed = serde_json::from_str::<Value>(body).ok();
    let json_kind = parsed.as_ref().map(|value| match value {
        Value::Array(_) => "array",
        Value::Object(_) => "object",
        Value::Null => "null",
        _ => "scalar",
    });
    let item_count = parsed.as_ref().and_then(|value| {
        value
            .as_array()
            .map(Vec::len)
            .or_else(|| {
                ["data", "rows", "items", "results"]
                    .iter()
                    .find_map(|key| value[*key].as_array().map(Vec::len))
            })
            .or_else(|| value["d"]["list"].as_array().map(Vec::len))
    });
    let reported_total = parsed.as_ref().and_then(|value| {
        value["d"]["total"]
            .as_u64()
            .or_else(|| value["_page_"]["totalRows"].as_u64())
            .or_else(|| value["total"].as_u64())
    });
    let api_code = parsed
        .as_ref()
        .and_then(|value| value["e"].as_i64().or_else(|| value["code"].as_i64()));
    let lower = body.to_ascii_lowercase();
    let password_inputs = Regex::new(r#"(?i)<input\b[^>]*\btype\s*=\s*["']?password\b"#)
        .unwrap()
        .find_iter(body)
        .count();
    let script_count = Regex::new(r"(?i)<script\b")
        .unwrap()
        .find_iter(body)
        .count();
    let login_markers = password_inputs > 0
        || lower.contains("uis.fudan.edu.cn/authserver/login")
        || lower.contains("id.fudan.edu.cn/ac/");
    let redirect_class = header(value, "location").map(|location| {
        let base = Url::parse(logical_url).ok();
        let target = Url::parse(location)
            .ok()
            .or_else(|| base.as_ref()?.join(location).ok());
        match target.as_ref().and_then(Url::host_str) {
            Some("id.fudan.edu.cn") => "fudan_id",
            Some("uis.fudan.edu.cn") => "fudan_uis",
            Some(host) if base.as_ref().and_then(Url::host_str) == Some(host) => "same_service",
            Some(_) => "other_origin",
            None => "unclassified",
        }
    });
    Check {
        case: case.into(),
        logical_url: logical_url.into(),
        method: "GET",
        authenticated_session,
        elapsed_ms,
        http_status: value["status"].as_u64(),
        error_code: None,
        mime: header(value, "content-type").and_then(safe_mime),
        bytes: body.len(),
        json_kind,
        json_keys: parsed.as_ref().map(known_schema_keys).unwrap_or_default(),
        item_count,
        reported_total,
        api_code,
        password_inputs,
        script_count,
        login_markers,
        redirect_class,
    }
}

async fn core_call(engine: &Arc<Engine>, method: &str, params: Value) -> Result<Value, String> {
    let response = engine
        .handle(
            Principal::owner(),
            Request {
                id: "research".into(),
                method: method.into(),
                params,
            },
        )
        .await;
    if let Some(error) = response.error {
        return Err(error.code);
    }
    response.result.ok_or_else(|| "MissingResult".into())
}

async fn read(
    engine: &Arc<Engine>,
    case: &str,
    url: &str,
    logical_url: &str,
    session: bool,
) -> (Check, Option<Value>) {
    let started = Instant::now();
    let mut params = json!({"url":url,"method":"GET","headers":{"Accept":"application/json, text/html;q=0.9, */*;q=0.5"},"timeout_ms":TIMEOUT_MS,"follow_redirects":false});
    if session {
        params["account_id"] = json!(ACCOUNT)
    }
    match core_call(engine, "http.request", params).await {
        Ok(value) => (
            summarize(
                case,
                logical_url,
                session,
                &value,
                started.elapsed().as_millis(),
            ),
            Some(value),
        ),
        Err(code) => {
            let mut summary = summarize(
                case,
                logical_url,
                session,
                &json!({}),
                started.elapsed().as_millis(),
            );
            summary.error_code = Some(code);
            (summary, None)
        }
    }
}

#[derive(Serialize)]
struct Authentication {
    service: &'static str,
    credential_mode: &'static str,
    state: &'static str,
    error_code: Option<String>,
    progress: Value,
    identity_matches: Option<bool>,
    coverage: &'static str,
    checks: Vec<Check>,
}

fn canvas_profile_matches(profile: Option<&Value>, expected_user: &str) -> Option<bool> {
    let profile = profile?;
    let valid_id = profile["id"].as_u64().is_some_and(|id| id > 0)
        || profile["id"].as_str().is_some_and(|id| {
            !id.is_empty()
                && id.len() <= 32
                && id.bytes().all(|v| v.is_ascii_digit())
                && id.bytes().any(|v| v != b'0')
        });
    if !valid_id {
        return None;
    }
    let login = profile["login_id"].as_str()?;
    Some(
        login.eq_ignore_ascii_case(expected_user)
            || login.eq_ignore_ascii_case(&format!("{expected_user}@fudan.edu.cn"))
            || login.eq_ignore_ascii_case(&format!("{expected_user}@m.fudan.edu.cn")),
    )
}

fn numeric_id(value: &Value) -> Option<String> {
    let id = value
        .as_u64()
        .map(|value| value.to_string())
        .or_else(|| value.as_str().map(str::to_owned))?;
    (!id.is_empty()
        && id.len() <= 32
        && id.bytes().all(|v| v.is_ascii_digit())
        && id.bytes().any(|v| v != b'0'))
    .then_some(id)
}

fn catalog_ids(response: Option<&Value>) -> Option<(String, String)> {
    let response = response.filter(|response| response["status"] == 200)?;
    let body = serde_json::from_str::<Value>(response["body"].as_str()?).ok()?;
    let first = body["data"].as_array()?.first()?;
    Some((
        numeric_id(&first["id"])?,
        numeric_id(&first["course"]["id"])?,
    ))
}

async fn canvas(engine: &Arc<Engine>, credentials: &Credentials) -> Authentication {
    let mut report = Authentication {
        service: "canvas",
        credential_mode: "existing_bearer",
        state: "not_started",
        error_code: None,
        progress: json!({}),
        identity_matches: None,
        coverage: "profile_and_first_visible_course_only",
        checks: vec![],
    };
    let Some(token) = credentials.canvas_token.as_ref() else {
        report.error_code = Some("MissingCanvasToken".into());
        report.state = "unavailable";
        return report;
    };
    if let Err(code) = core_call(engine, "auth.session.set", json!({"account_id":ACCOUNT,"origin":"https://elearning.fudan.edu.cn","bearer":token,"cookies":[],"persist":false})).await { report.error_code = Some(code); report.state = "unavailable"; return report }
    let profile_url = "https://elearning.fudan.edu.cn/api/v1/users/self/profile";
    let (check, value) = read(engine, "canvas_profile", profile_url, profile_url, true).await;
    report.checks.push(check);
    let profile = value
        .as_ref()
        .filter(|value| value["status"] == 200)
        .and_then(|value| serde_json::from_str::<Value>(value["body"].as_str()?).ok());
    let identity_matches = canvas_profile_matches(profile.as_ref(), &credentials.user);
    report.identity_matches = identity_matches;
    if identity_matches != Some(true) {
        report.state = "identity_unverified";
        let _ = core_call(engine, "auth.logout", json!({"account_id":ACCOUNT})).await;
        return report;
    }
    report.state = "profile_verified";
    let courses_url =
        "https://elearning.fudan.edu.cn/api/v1/courses?enrollment_state=active&per_page=1";
    let (check, value) = read(
        engine,
        "canvas_first_visible_course",
        courses_url,
        courses_url,
        true,
    )
    .await;
    report.checks.push(check);
    let rows = value
        .as_ref()
        .filter(|value| value["status"] == 200)
        .and_then(|value| serde_json::from_str::<Value>(value["body"].as_str()?).ok());
    let course_id = rows
        .as_ref()
        .and_then(Value::as_array)
        .and_then(|rows| rows.first())
        .and_then(|row| numeric_id(&row["id"]));
    if let Some(course_id) = course_id {
        for (case, suffix) in [
            ("canvas_classic_quizzes", "quizzes?per_page=1"),
            ("canvas_discussion_topics", "discussion_topics?per_page=1"),
            (
                "canvas_own_enrollments",
                "enrollments?user_id=self&per_page=1",
            ),
            ("canvas_assignment_groups", "assignment_groups?per_page=1"),
        ] {
            let url = format!("https://elearning.fudan.edu.cn/api/v1/courses/{course_id}/{suffix}");
            let logical =
                format!("https://elearning.fudan.edu.cn/api/v1/courses/{{course_id}}/{suffix}");
            report
                .checks
                .push(read(engine, case, &url, &logical, true).await.0);
        }
    }
    let _ = core_call(engine, "auth.logout", json!({"account_id":ACCOUNT})).await;
    report
}

async fn password_probe(
    engine: &Arc<Engine>,
    credentials: &Credentials,
    service: &'static str,
    target: LoginTarget,
    reads: &[Probe],
) -> Authentication {
    let progress = LoginProgress::default();
    let mut report = Authentication {
        service,
        credential_mode: "single_password_attempt",
        state: "not_started",
        error_code: None,
        progress: json!({}),
        identity_matches: None,
        coverage: "fixed_service_read_shapes_only",
        checks: vec![],
    };
    match login_with_progress(
        &credentials.user,
        &credentials.password,
        target,
        progress.clone(),
    )
    .await
    {
        Ok(session) => {
            report.state = "session_candidate";
            match core_call(engine, "auth.session.set", json!({"account_id":ACCOUNT,"origin":session.origin,"cookies":session.cookies,"persist":false})).await {
                Ok(_) => for probe in reads { report.checks.push(read(engine, probe.case, probe.url, probe.url, true).await.0) },
                Err(code) => report.error_code = Some(code),
            }
            let _ = core_call(engine, "auth.logout", json!({"account_id":ACCOUNT})).await;
        }
        Err(error) => {
            report.state = "login_not_completed";
            report.error_code = Some(error.code().into());
        }
    }
    report.progress = progress.snapshot();
    report
}

#[derive(Serialize)]
struct ServiceCheck {
    method: &'static str,
    outcome: &'static str,
    error_code: Option<String>,
    http_status: Option<u16>,
    schema_field: Option<String>,
    elapsed_ms: u128,
    record_count: Option<usize>,
    cached_count: Option<usize>,
    coverage: Option<String>,
    section_count: Option<usize>,
    module_count: Option<usize>,
    section_coverage: Option<String>,
    course_tree_coverage: Option<String>,
    public_only: bool,
}

async fn service_read(
    engine: &Arc<Engine>,
    method: &'static str,
    mut params: Value,
    public_only: bool,
    checks: &mut Vec<ServiceCheck>,
) -> Option<Value> {
    params["account_id"] = json!(ACCOUNT);
    let started = Instant::now();
    let response = engine
        .handle(
            Principal::owner(),
            Request {
                id: "typed-research".into(),
                method: method.into(),
                params,
            },
        )
        .await;
    let result = if let Some(error) = response.error {
        Err(error)
    } else {
        response
            .result
            .ok_or_else(|| dansheng_core::CoreError::new("MissingResult", "missing typed result"))
    };
    match result {
        Ok(value) => {
            let batch = value.get("batch").unwrap_or(&value);
            let rows = batch
                .get("records")
                .and_then(Value::as_array)
                .or_else(|| value.as_array());
            let source = batch
                .pointer("/source/source_id")
                .and_then(Value::as_str)
                .or_else(|| value["source_id"].as_str())
                .or_else(|| {
                    rows.and_then(|v| v.first())
                        .and_then(|v| v["source_id"].as_str())
                });
            let record_count = rows
                .map(Vec::len)
                .or_else(|| value.get("payload").map(|_| 1));
            let cached_count = if let Some(source) = source {
                core_call(
                    engine,
                    "sources.query",
                    json!({
                        "account_id":ACCOUNT,"source_id":source,"limit":500
                    }),
                )
                .await
                .ok()
                .and_then(|v| v.as_array().map(Vec::len))
            } else {
                None
            };
            checks.push(ServiceCheck {
                method,
                outcome: "typed_read_succeeded",
                error_code: None,
                http_status: None,
                schema_field: None,
                elapsed_ms: started.elapsed().as_millis(),
                record_count,
                cached_count,
                coverage: batch
                    .pointer("/coverage/state")
                    .and_then(Value::as_str)
                    .or_else(|| {
                        value
                            .pointer("/payload/text_coverage/state")
                            .and_then(Value::as_str)
                    })
                    .map(str::to_owned),
                section_count: value
                    .pointer("/payload/sections")
                    .and_then(Value::as_array)
                    .map(Vec::len),
                module_count: value
                    .pointer("/payload/course_modules")
                    .and_then(Value::as_array)
                    .map(Vec::len),
                section_coverage: value
                    .pointer("/payload/coverage/sections/state")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                course_tree_coverage: value
                    .pointer("/payload/coverage/course_tree/state")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                public_only,
            });
            Some(value)
        }
        Err(error) => {
            let http_status = (error.code == "SourceHttpError")
                .then(|| error.message.parse::<u16>().ok())
                .flatten()
                .filter(|status| (100..=599).contains(status));
            let schema_field = (error.code == "SourceSchemaChanged"
                && error.message.len() <= 128
                && error
                    .message
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b' ' | b'-')))
            .then_some(error.message);
            checks.push(ServiceCheck {
                method,
                outcome: "read_blocked",
                error_code: Some(error.code),
                http_status,
                schema_field,
                elapsed_ms: started.elapsed().as_millis(),
                record_count: None,
                cached_count: None,
                coverage: None,
                section_count: None,
                module_count: None,
                section_coverage: None,
                course_tree_coverage: None,
                public_only,
            });
            None
        }
    }
}

async fn public_services(engine: &Arc<Engine>, checks: &mut Vec<ServiceCheck>) {
    let semesters = service_read(engine, "fudan.catalog.semesters", json!({}), true, checks).await;
    let default = semesters
        .as_ref()
        .and_then(|v| numeric_id(&v["payload"]["default_semester_id"]));
    if let Some(semester) = default {
        let page = service_read(
            engine,
            "fudan.catalog.lessons",
            json!({
                "semester_id":semester,"page":1,"page_size":1
            }),
            true,
            checks,
        )
        .await;
        let first = page
            .as_ref()
            .and_then(|v| v["records"].as_array())
            .and_then(|v| v.first());
        let ids = first.and_then(|v| {
            Some((
                numeric_id(&v["payload"]["lesson_id"])?,
                numeric_id(&v["payload"]["course"]["course_id"])?,
            ))
        });
        if let Some(next) = page
            .as_ref()
            .and_then(|v| v["coverage"]["next"].as_u64())
            .filter(|v| *v == 2)
        {
            service_read(
                engine,
                "fudan.catalog.lessons",
                json!({
                    "semester_id":semester,"page":next,"page_size":1
                }),
                true,
                checks,
            )
            .await;
        }
        if let Some((lesson, course)) = ids {
            service_read(
                engine,
                "fudan.catalog.course",
                json!({"semester_id":semester,"course_id":course}),
                true,
                checks,
            )
            .await;
            service_read(
                engine,
                "fudan.catalog.syllabus",
                json!({"lesson_id":lesson}),
                true,
                checks,
            )
            .await;
        }
    }
    service_read(
        engine,
        "fudan.ehall.catalog",
        json!({"limit":10}),
        true,
        checks,
    )
    .await;
    // A deliberate nonexistent public lookup verifies a successful, scoped empty
    // result without pretending that singleVolume is a keyword search.
    service_read(
        engine,
        "fudan.library.lookup",
        json!({
            "kind":"call_number","value":"DANSHENG-SYNTHETIC-NONEXISTENT-CALL-NUMBER","limit":1
        }),
        true,
        checks,
    )
    .await;
    // Ordinary public call-number query; derive every subsequent ID from the
    // live typed response, never from a hard-coded catalogue/reader identifier.
    let volumes = service_read(
        engine,
        "fudan.library.lookup",
        json!({
            "kind":"call_number","value":"I247.57","limit":1
        }),
        true,
        checks,
    )
    .await;
    if let Some(id) = volumes
        .as_ref()
        .and_then(|v| v["records"].as_array())
        .and_then(|rows| rows.first())
        .and_then(|row| numeric_id(&row["payload"]["catalogue_id"]))
    {
        service_read(
            engine,
            "fudan.library.bibliography",
            json!({"catalogue_id":id}),
            true,
            checks,
        )
        .await;
        service_read(
            engine,
            "fudan.library.holdings",
            json!({"catalogue_id":id,"page":1,"page_size":1}),
            true,
            checks,
        )
        .await;
    }
    let programs = service_read(
        engine,
        "fudan.programs.list",
        json!({"page":1,"page_size":1}),
        true,
        checks,
    )
    .await;
    if let Some(next) = programs
        .as_ref()
        .and_then(|v| v["coverage"]["next"].as_u64())
        .filter(|v| *v == 2)
    {
        service_read(
            engine,
            "fudan.programs.list",
            json!({"page":next,"page_size":1}),
            true,
            checks,
        )
        .await;
    }
    if let Some(id) = programs
        .as_ref()
        .and_then(|v| v["records"].as_array())
        .and_then(|rows| rows.first())
        .and_then(|row| {
            numeric_id(&row["payload"]["id"]).or_else(|| numeric_id(&row["payload"]["program_id"]))
        })
    {
        service_read(
            engine,
            "fudan.programs.detail",
            json!({"program_id":id}),
            true,
            checks,
        )
        .await;
    }
}

/// Separate, explicitly selected profile/mode. It never falls back from a
/// rejected bearer or changes the App's existing authentication configuration.
async fn canvas_session_services(
    engine: &Arc<Engine>,
    credentials: &Credentials,
    checks: &mut Vec<ServiceCheck>,
) -> Authentication {
    let progress = LoginProgress::default();
    let mut report = Authentication {
        service: "canvas",
        credential_mode: "password_http_session_research",
        state: "not_started",
        error_code: None,
        progress: json!({}),
        identity_matches: None,
        coverage: "profile_identity_then_bounded_learning_reads",
        checks: vec![],
    };
    match login_with_progress(
        &credentials.user,
        &credentials.password,
        LoginTarget::Canvas,
        progress.clone(),
    )
    .await
    {
        Err(error) => {
            report.state = "login_not_completed";
            report.error_code = Some(error.code().into());
        }
        Ok(session) => {
            report.state = "session_candidate";
            if let Err(code) = core_call(engine, "auth.session.set", json!({
                "account_id":ACCOUNT,"origin":session.origin,"cookies":session.cookies,"persist":false
            })).await { report.error_code=Some(code); }
            else {
                let (check, response) = read(engine,"canvas_session_profile",
                    "https://elearning.fudan.edu.cn/api/v1/users/self/profile",
                    "https://elearning.fudan.edu.cn/api/v1/users/self/profile",true).await;
                let profile = response.as_ref().filter(|v| v["status"] == 200)
                    .and_then(|v| serde_json::from_str::<Value>(v["body"].as_str()?).ok());
                report.identity_matches=canvas_profile_matches(profile.as_ref(), &credentials.user);
                report.checks.push(check);
                if report.identity_matches != Some(true) {
                    report.state="identity_unverified";
                    report.error_code=Some("IdentityUnverified".into());
                } else {
                    report.state="profile_identity_verified";
                    let config=core_call(engine,"canvas.configure",json!({
                        "account_id":ACCOUNT,"origin":"https://elearning.fudan.edu.cn","access":"host_session"
                    })).await;
                    if let Err(code)=config { report.error_code=Some(code); }
                    else {
                        let url="https://elearning.fudan.edu.cn/api/v1/courses?per_page=1";
                        let (check, response)=read(engine,"canvas_session_first_course",url,url,true).await;
                        let course=response.as_ref().filter(|v|v["status"]==200)
                            .and_then(|v|serde_json::from_str::<Value>(v["body"].as_str()?).ok())
                            .and_then(|v|v.as_array().and_then(|rows|rows.first()).and_then(|row|numeric_id(&row["id"])));
                        report.checks.push(check);
                        if let Some(course)=course {
                            for method in ["canvas.quizzes.sync","canvas.discussions.sync","canvas.assignment_groups.sync","canvas.enrollments.self","canvas.grades.self"] {
                                service_read(engine,method,json!({"course_id":course}),false,checks).await;
                            }
                        }
                    }
                }
            }
            let _ = core_call(engine, "auth.logout", json!({"account_id":ACCOUNT})).await;
        }
    }
    report.progress = progress.snapshot();
    report
}

#[derive(Serialize)]
struct Report {
    generated_at_utc: String,
    tool: &'static str,
    transport: &'static str,
    credential_file_read: bool,
    raw_data_exported: bool,
    remote_business_writes: u8,
    automatic_password_retries: u8,
    campus_lan_origins: Vec<&'static str>,
    public_checks: Vec<Check>,
    authenticated_checks: Vec<Authentication>,
    service_checks: Vec<ServiceCheck>,
}

fn output_parent(path: &Path) -> Result<PathBuf, &'static str> {
    if !path.is_absolute() || path.exists() {
        return Err("ReportMustBeNewAbsolutePath");
    }
    let parent = path
        .parent()
        .ok_or("InvalidReportPath")?
        .canonicalize()
        .map_err(|_| "ReportParentMissing")?;
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .ok_or("InvalidSourceRoot")?
        .canonicalize()
        .map_err(|_| "InvalidSourceRoot")?;
    if parent.starts_with(root) {
        return Err("ProfileMustBeOutsideRepository");
    }
    Ok(parent)
}

async fn run() -> Result<(), &'static str> {
    let mut args = std::env::args().skip(1);
    let mut mode = "public".to_owned();
    let mut credentials_path = None;
    let mut output = None;
    let mut campus_lan = false;
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--mode" => mode = args.next().ok_or("MissingMode")?,
            "--credentials" => {
                credentials_path = Some(PathBuf::from(args.next().ok_or("MissingCredentialPath")?))
            }
            "--report" => output = Some(PathBuf::from(args.next().ok_or("MissingReportPath")?)),
            "--campus-lan" => campus_lan = true,
            _ => return Err("UnsupportedArguments"),
        }
    }
    if !matches!(
        mode.as_str(),
        "public"
            | "discovery"
            | "services"
            | "canvas"
            | "canvas-session"
            | "academic"
            | "ecard"
            | "life"
            | "webvpn"
            | "all"
    ) {
        return Err("UnsupportedMode");
    }
    let output = output.ok_or("MissingReportPath")?;
    let parent = output_parent(&output)?;
    if campus_lan && !matches!(mode.as_str(), "public" | "discovery") {
        return Err("CampusPolicyIsForAnonymousDiscoveryOnly");
    }
    let credentials = if !matches!(mode.as_str(), "public" | "discovery" | "services") {
        let path = credentials_path.ok_or("MissingCredentialPath")?;
        if !path.is_absolute()
            || fs::metadata(&path)
                .map_err(|_| "CredentialFileUnavailable")?
                .len()
                > 8192
        {
            return Err("CredentialFileUnavailable");
        }
        let credential_parent = path
            .parent()
            .ok_or("CredentialFileUnavailable")?
            .canonicalize()
            .map_err(|_| "CredentialFileUnavailable")?;
        if parent.starts_with(credential_parent) {
            return Err("ProfileMustBeOutsideCredentialRepository");
        }
        let text = fs::read_to_string(path).map_err(|_| "CredentialFileUnavailable")?;
        Some(parse_credentials(&text)?)
    } else {
        None
    };
    let runtime = parent.join(format!("native-probe-{}", uuid::Uuid::new_v4()));
    let engine =
        Engine::open(runtime, Arc::new(UnavailablePlatform)).map_err(|_| "CoreUnavailable")?;
    engine
        .register_service(Arc::new(dansheng_connectors::core_adapter::CampusService))
        .map_err(|_| "ServiceRegistryUnavailable")?;
    core_call(
        &engine,
        "accounts.upsert",
        json!({"account_id":ACCOUNT,"label":"Research account","provider":"research"}),
    )
    .await
    .map_err(|_| "CoreUnavailable")?;
    if campus_lan {
        // The requested policy is local to this disposable profile and to one exact origin.
        core_call(
            &engine,
            "http.policy.set",
            json!({
                "allow_private_network":false,
                "private_network_origins":[CAMPUS_CLOUD_ORIGIN]
            }),
        )
        .await
        .map_err(|_| "CampusPolicyUnavailable")?;
    }
    let mut report = Report {
        generated_at_utc: Utc::now().to_rfc3339(),
        tool: "fudan-service-research/0.1.0",
        transport: "current_workspace_native_core",
        credential_file_read: credentials.is_some(),
        raw_data_exported: false,
        remote_business_writes: 0,
        automatic_password_retries: 0,
        campus_lan_origins: if campus_lan {
            vec![CAMPUS_CLOUD_ORIGIN]
        } else {
            vec![]
        },
        public_checks: vec![],
        authenticated_checks: vec![],
        service_checks: vec![],
    };
    if mode == "services" {
        public_services(&engine, &mut report.service_checks).await;
    }
    if matches!(mode.as_str(), "public" | "discovery" | "all") {
        let mut tasks = tokio::task::JoinSet::new();
        let mut academic_ids = None;
        let probes: Vec<Probe> = PUBLIC_PROBES
            .iter()
            .filter(|probe| {
                mode != "discovery"
                    || matches!(
                        probe.case,
                        "ehall_directory_all"
                            | "ehall_directory_limit"
                            | "ehall_tasks_without_session"
                            | "ehall_applications_without_session"
                            | "campus_cloud"
                            | "undergraduate_catalog_first_page"
                    )
            })
            .copied()
            .collect();
        for chunk in probes.chunks(4) {
            for probe in chunk {
                let engine = engine.clone();
                let probe = *probe;
                tasks.spawn(
                    async move { read(&engine, probe.case, probe.url, probe.url, false).await },
                );
            }
            while let Some(result) = tasks.join_next().await {
                let (check, response) = result.map_err(|_| "ProbeTaskFailed")?;
                if check.case == "undergraduate_catalog_first_page" {
                    academic_ids = catalog_ids(response.as_ref());
                }
                report.public_checks.push(check);
            }
        }
        if let Some((lesson_id, course_id)) = academic_ids {
            for (case, url, logical) in [
                (
                    "undergraduate_syllabus_available",
                    format!(
                        "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/check-can-info?id={lesson_id}"
                    ),
                    "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/check-can-info?id={lesson_id}",
                ),
                (
                    "undergraduate_syllabus_detail",
                    format!(
                        "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/teachingSyllabusInfo/{lesson_id}"
                    ),
                    "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/teachingSyllabusInfo/{lesson_id}",
                ),
                (
                    "undergraduate_course_detail",
                    format!(
                        "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/info/{course_id}"
                    ),
                    "https://fdjwgl.fudan.edu.cn/student/for-all/lesson-search/info/{course_id}",
                ),
            ] {
                report
                    .public_checks
                    .push(read(&engine, case, &url, logical, false).await.0);
            }
        }
        report.public_checks.sort_by(|a, b| a.case.cmp(&b.case));
    }
    if let Some(credentials) = credentials.as_ref() {
        if mode == "canvas-session" {
            let check =
                canvas_session_services(&engine, credentials, &mut report.service_checks).await;
            report.authenticated_checks.push(check);
        }
        if matches!(mode.as_str(), "canvas" | "all") {
            report
                .authenticated_checks
                .push(canvas(&engine, credentials).await);
        }
        let mut targets = vec![];
        if matches!(mode.as_str(), "academic" | "all") {
            targets.push((
                "academic",
                LoginTarget::Academic,
                vec![Probe {
                    case: "academic_private_course_table",
                    url: "https://fdjwgl.fudan.edu.cn/student/for-std/course-table",
                }],
            ));
        }
        if matches!(mode.as_str(), "ecard" | "all") {
            targets.push((
                "ecard",
                LoginTarget::Ecard,
                vec![Probe {
                    case: "ecard_authenticated_page",
                    url: "https://ecard.fudan.edu.cn/epay",
                }],
            ));
        }
        if matches!(mode.as_str(), "life" | "all") {
            targets.push((
                "dorm",
                LoginTarget::Dorm,
                vec![Probe {
                    case: "dorm_authenticated_page",
                    url: "https://zlapp.fudan.edu.cn/fudanelec/wap/default/info",
                }],
            ));
            targets.push((
                "personal_data",
                LoginTarget::Dining,
                vec![Probe {
                    case: "personal_data_authenticated_page",
                    url: "https://my.fudan.edu.cn/simple_list/stqk",
                }],
            ));
        }
        if matches!(mode.as_str(), "webvpn" | "all") {
            targets.push((
                "webvpn",
                LoginTarget::WebVpn,
                vec![Probe {
                    case: "webvpn_authenticated_home",
                    url: "https://webvpn.fudan.edu.cn/",
                }],
            ));
        }
        for (service, target, reads) in targets {
            let authentication =
                password_probe(&engine, credentials, service, target, &reads).await;
            let stop = matches!(
                authentication.error_code.as_deref(),
                Some("InvalidCredentials" | "InteractiveLoginRequired")
            );
            report.authenticated_checks.push(authentication);
            if stop {
                break;
            }
        }
    }
    drop(engine);
    let bytes = serde_json::to_vec_pretty(&report).map_err(|_| "ReportSerializationFailed")?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(output)
        .map_err(|_| "ReportWriteFailed")?;
    file.write_all(&bytes).map_err(|_| "ReportWriteFailed")?;
    println!(
        "{}",
        serde_json::to_string(&report).map_err(|_| "ReportSerializationFailed")?
    );
    Ok(())
}

#[tokio::main]
async fn main() {
    if let Err(code) = run().await {
        eprintln!("{code}");
        std::process::exit(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_parser_accepts_the_existing_app_format_without_forum_use() {
        let parsed = parse_credentials("\u{feff}user: 'synthetic123',\npassword: \"synthetic:secret\",\ndanxiuser: ignored@example.invalid\ndanxipassword: ignored\ncanvasToken: 'synthetic-token'\n").unwrap();
        assert_eq!(parsed.user, "synthetic123");
        assert_eq!(parsed.password, "synthetic:secret");
        assert_eq!(parsed.canvas_token.as_deref(), Some("synthetic-token"));
    }

    #[test]
    fn duplicate_and_empty_credentials_fail_without_echoing_values() {
        assert_eq!(
            parse_credentials("user: synthetic123\npassword: SECRET\npassword: OTHER").err(),
            Some("InvalidCredentialFields")
        );
        assert_eq!(
            parse_credentials("user: synthetic123\npassword: ''").err(),
            Some("InvalidCredentialFields")
        );
    }

    #[test]
    fn private_json_values_and_personal_keys_never_enter_the_summary() {
        let value = json!({"status":200,"headers":{"Content-Type":"application/json; charset=utf-8"},"body":json!({"data":[{"name":"PERSONAL_SECRET","token":"TOKEN_SECRET","id":"ACCOUNT_SECRET"}],"PERSONAL_KEY_SECRET":"hidden","total":1}).to_string()});
        let summary = summarize(
            "fixture",
            "https://elearning.fudan.edu.cn/api/v1/courses/{course_id}/quizzes",
            true,
            &value,
            1,
        );
        let rendered = serde_json::to_string(&summary).unwrap();
        for secret in [
            "PERSONAL_SECRET",
            "TOKEN_SECRET",
            "ACCOUNT_SECRET",
            "PERSONAL_KEY_SECRET",
        ] {
            assert!(!rendered.contains(secret));
        }
        assert_eq!(summary.item_count, Some(1));
        assert_eq!(summary.mime.as_deref(), Some("application/json"));
    }

    #[test]
    fn redirect_tickets_and_html_values_are_not_exported() {
        let value = json!({"status":302,"headers":{"location":"https://id.fudan.edu.cn/ac/?ticket=SECRET_TICKET","content-type":"text/html"},"body":"<input type='password' value='SECRET_PASSWORD'><script>var ticket='SECRET_BODY';</script>"});
        let summary = summarize("fixture", "https://ehall.fudan.edu.cn/", false, &value, 1);
        assert_eq!(summary.redirect_class, Some("fudan_id"));
        assert_eq!(summary.password_inputs, 1);
        assert!(summary.login_markers);
        assert!(!serde_json::to_string(&summary).unwrap().contains("SECRET"));
    }

    #[test]
    fn public_targets_are_fixed_https_school_origins_with_no_credentials() {
        for probe in PUBLIC_PROBES {
            let url = Url::parse(probe.url).unwrap();
            assert_eq!(url.scheme(), "https");
            assert!(
                url.host_str().unwrap().ends_with(".fudan.edu.cn")
                    || url.host_str() == Some("fudan-primo.hosted.exlibrisgroup.com.cn")
            );
            assert!(url.username().is_empty() && url.password().is_none());
            assert!(!probe.case.contains("submit") && !probe.case.contains("reserve"));
        }
    }

    #[test]
    fn mime_header_cannot_smuggle_arbitrary_response_text() {
        assert!(safe_mime("SECRET TOKEN").is_none());
        assert_eq!(
            safe_mime("text/html; private=SECRET").as_deref(),
            Some("text/html")
        );
    }

    #[test]
    fn ehall_nonempty_list_and_zero_total_remain_distinct() {
        let value = json!({"status":200,"body":json!({"e":0,"m":"","d":{"list":[{"name":"PRIVATE_CONTACT"}],"total":0}}).to_string()});
        let summary = summarize("fixture", "https://ehall.fudan.edu.cn/", false, &value, 0);
        assert_eq!(summary.item_count, Some(1));
        assert_eq!(summary.reported_total, Some(0));
        assert_eq!(summary.api_code, Some(0));
        assert!(
            !serde_json::to_string(&summary)
                .unwrap()
                .contains("PRIVATE_CONTACT")
        );
    }

    #[test]
    fn unverifiable_canvas_identity_is_not_reported_as_a_different_account() {
        assert_eq!(canvas_profile_matches(None, "synthetic123"), None);
        assert_eq!(
            canvas_profile_matches(Some(&json!({"login_id":"synthetic123"})), "synthetic123"),
            None
        );
        assert_eq!(
            canvas_profile_matches(Some(&json!({"id":1,"login_id":"other"})), "synthetic123"),
            Some(false)
        );
        assert_eq!(
            canvas_profile_matches(
                Some(&json!({"id":"9007199254740993","login_id":"synthetic123@m.fudan.edu.cn"})),
                "synthetic123"
            ),
            Some(true)
        );
    }

    #[test]
    fn repository_and_existing_files_cannot_receive_probe_reports() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        assert_eq!(
            output_parent(&root.join("never-created-probe-report.json")).err(),
            Some("ProfileMustBeOutsideRepository")
        );
        assert_eq!(
            output_parent(&root.join("Cargo.toml")).err(),
            Some("ReportMustBeNewAbsolutePath")
        );
    }

    #[test]
    fn source_ids_cannot_inject_request_paths_or_confuse_lesson_and_course() {
        assert!(numeric_id(&json!("../submit?token=SECRET")).is_none());
        assert!(numeric_id(&json!(0)).is_none());
        let response = json!({"status":200,"body":json!({"data":[{"id":"9007199254740993","course":{"id":123}}]}).to_string()});
        assert_eq!(
            catalog_ids(Some(&response)),
            Some(("9007199254740993".into(), "123".into()))
        );
        assert!(catalog_ids(Some(&json!({"status":401,"body":response["body"]}))).is_none());
    }
}
