// SPDX-License-Identifier: GPL-3.0-or-later
//! Official, bounded academic catalog and eHall service adapters.
//! School protocols stay outside the shared core. Every call uses the same
//! account grants, credential transport and source ACLs as the existing services.
use crate::{
    academic_catalog::{CatalogFilters, CatalogPage, FudanAcademicCatalogClient},
    academic_programs::{FudanProgramClient, ProgramPage},
    core_adapter::{BoundTransport, publish_value},
    ehall::{EhallClient, EhallPage, EhallReadBudget, EhallTaskKind},
    library::{LibraryClient, LibraryError, LibraryLoanKind, LibraryLookupKind, LibraryPage},
    models::SourceContext,
};
use chrono::Utc;
use dansheng_core::{
    api::{CoreError, CoreResult, Principal, required_string},
    policy::Grant,
    services::ServiceContext,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

pub(crate) const METHODS: &[(&str, &str)] = &[
    ("fudan.catalog.semesters", "fudan.catalog.read"),
    ("fudan.catalog.lessons", "fudan.catalog.read"),
    ("fudan.catalog.course", "fudan.catalog.read"),
    ("fudan.catalog.syllabus", "fudan.catalog.read"),
    ("fudan.programs.list", "fudan.programs.read"),
    ("fudan.programs.detail", "fudan.programs.read"),
    ("fudan.ehall.catalog", "fudan.ehall.catalog.read"),
    ("fudan.ehall.tasks", "fudan.ehall.tasks.read"),
    ("fudan.ehall.tasks.sync", "fudan.ehall.tasks.read"),
    ("fudan.library.lookup", "fudan.library.catalog.read"),
    ("fudan.library.bibliography", "fudan.library.catalog.read"),
    ("fudan.library.holdings", "fudan.library.catalog.read"),
    ("fudan.library.reader.observe", "fudan.library.configure"),
    ("fudan.library.reader.bind", "fudan.library.configure"),
    ("fudan.library.reader.clear", "fudan.library.configure"),
    ("fudan.library.loans.current", "fudan.library.loans.read"),
    ("fudan.library.loans.history", "fudan.library.history.read"),
];
const READER_BINDINGS: &str = "service:fudan-library:reader-binding";

fn library_error(error: LibraryError) -> CoreError {
    match error {
        LibraryError::Campus(error) => crate::core_adapter::campus_error(error),
        LibraryError::Transport(error) => crate::core_adapter::source_error(error),
        LibraryError::IdentityUnverified => CoreError::new(
            "LibraryIdentityUnverified",
            "verify the intended reader through the trusted host first",
        ),
        LibraryError::IdentityMismatch => CoreError::new(
            "LibraryIdentityMismatch",
            "the library credential subject differs from the trusted binding",
        ),
        LibraryError::NotFound => {
            CoreError::new("SourceRecordNotFound", "library record not found")
        }
        LibraryError::ProtocolUnverified { field } => {
            CoreError::new("SourceProtocolUnverified", field)
        }
    }
}

fn reader_ref(params: &Value) -> CoreResult<&str> {
    let value = required_string(params, "reader_ref")?;
    let digest = value
        .strip_prefix("library-reader:")
        .filter(|s| {
            s.len() == 64
                && s.bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        })
        .ok_or_else(|| CoreError::invalid("invalid reader fingerprint"))?;
    let _ = digest;
    Ok(value)
}

fn library_page(params: &Value) -> CoreResult<LibraryPage> {
    Ok(LibraryPage {
        page_no: positive_number(params, "page", 1, 10_000)? as u32,
        page_size: positive_number(
            params,
            "page_size",
            20,
            u64::from(crate::library::MAX_LIBRARY_PAGE_SIZE),
        )? as u16,
    })
}

pub(crate) fn handles(method: &str) -> bool {
    METHODS.iter().any(|(name, _)| *name == method)
}

fn positive_number(params: &Value, key: &str, default: u64, max: u64) -> CoreResult<u64> {
    let value = params.get(key).map_or(Some(default), Value::as_u64);
    value
        .filter(|v| (1..=max).contains(v))
        .ok_or_else(|| CoreError::invalid(format!("invalid {key}")))
}

fn decimal_id<'a>(params: &'a Value, key: &str) -> CoreResult<&'a str> {
    let value = required_string(params, key)?;
    if value.len() > 32
        || !value.bytes().all(|c| c.is_ascii_digit())
        || value.bytes().all(|c| c == b'0')
    {
        return Err(CoreError::invalid(format!("invalid {key}")));
    }
    Ok(value)
}

fn filters(params: &Value) -> CoreResult<CatalogFilters> {
    let fields = params
        .get("filters")
        .map(|v| serde_json::from_value(v.clone()))
        .transpose()?;
    let filters = CatalogFilters {
        fields: fields.unwrap_or_default(),
    };
    filters
        .validate()
        .map_err(crate::core_adapter::campus_error)?;
    Ok(filters)
}

fn task_kind(params: &Value) -> CoreResult<EhallTaskKind> {
    serde_json::from_value(params.get("kind").cloned().unwrap_or_else(|| json!("todo")))
        .map_err(|_| CoreError::invalid("kind must be todo, done or application"))
}

fn task_label(kind: EhallTaskKind) -> &'static str {
    match kind {
        EhallTaskKind::Todo => "todo",
        EhallTaskKind::Done => "done",
        EhallTaskKind::Application => "application",
    }
}

/// A query owns a source across pages. A new page never replaces other pages;
/// semester and canonical filters prevent distinct searches sharing checkpoints.
fn source_id(method: &str, params: &Value) -> CoreResult<String> {
    Ok(match method {
        "fudan.catalog.lessons" => {
            let semester = decimal_id(params, "semester_id")?;
            let digest = Sha256::digest(serde_json::to_vec(&filters(params)?.fields)?);
            format!("official.fudan.catalog.lessons:{semester}:{digest:x}")
        }
        "fudan.catalog.course" => format!(
            "official.fudan.catalog.course:{}",
            decimal_id(params, "semester_id")?
        ),
        "fudan.catalog.syllabus" => format!(
            "official.fudan.catalog.syllabus:{}",
            decimal_id(params, "lesson_id")?
        ),
        "fudan.programs.detail" => format!(
            "official.fudan.programs.detail:{}",
            decimal_id(params, "program_id")?
        ),
        "fudan.ehall.tasks" | "fudan.ehall.tasks.sync" => {
            format!(
                "official.fudan.ehall.tasks:{}",
                task_label(task_kind(params)?)
            )
        }
        "fudan.library.lookup" => {
            let kind: LibraryLookupKind = serde_json::from_value(params["kind"].clone())
                .map_err(|_| CoreError::invalid("kind must be barcode or call_number"))?;
            let value = required_string(params, "value")?;
            if value.len() > 256 || value.chars().any(char::is_control) {
                return Err(CoreError::invalid("invalid library lookup"));
            }
            let digest = Sha256::digest(serde_json::to_vec(&(kind, value))?);
            format!("official.fudan.library.lookup:{digest:x}")
        }
        "fudan.library.bibliography" | "fudan.library.holdings" => {
            format!("official.{method}:{}", decimal_id(params, "catalogue_id")?)
        }
        _ => format!("official.{method}"),
    })
}

pub(crate) async fn call(
    context: ServiceContext<'_>,
    principal: &Principal,
    grant: &Grant,
    method: &str,
    params: &Value,
) -> CoreResult<Value> {
    let capability = METHODS
        .iter()
        .find(|(name, _)| *name == method)
        .ok_or_else(|| CoreError::new("MethodNotFound", "unknown expanded campus method"))?
        .1;
    grant.check(principal, capability)?;
    let account = required_string(params, "account_id")?;
    grant.check_account(principal, Some(account))?;
    // A trusted owner explicitly supplies a separately verified fingerprint.
    // Observing getReaderInfo never auto-binds it, and MCP cannot configure it.
    if matches!(
        method,
        "fudan.library.reader.bind" | "fudan.library.reader.clear"
    ) {
        if !principal.is_owner() {
            return Err(CoreError::new(
                "PermissionDenied",
                "only the owner may configure a reader binding",
            ));
        }
        if method.ends_with(".clear") {
            context.store.kv_delete(READER_BINDINGS, account)?;
            return Ok(json!({"account_id":account,"bound":false}));
        }
        let expected = reader_ref(params)?;
        let previous = context.store.kv_get(READER_BINDINGS, account)?;
        if previous["reader_ref"]
            .as_str()
            .is_some_and(|old| old != expected)
        {
            return Err(CoreError::new(
                "AccountBindingMismatch",
                "clear the previous reader binding before changing its subject",
            ));
        }
        context.store.kv_set(READER_BINDINGS, account, &json!({
            "origin":crate::library::LIBRARY_ORIGIN,"reader_ref":expected,"binding_kind":"owner_verified"
        }))?;
        return Ok(
            json!({"account_id":account,"bound":true,"verification":"owner_provided_fingerprint"}),
        );
    }
    if method == "fudan.library.reader.observe" && !principal.is_owner() {
        return Err(CoreError::new(
            "PermissionDenied",
            "reader identity observation is a trusted host operation",
        ));
    }
    let mut source = SourceContext {
        account_id: account.to_owned(),
        source_id: source_id(method, params)?,
        observed_at: Utc::now(),
    };
    let reader_binding = if method.starts_with("fudan.library.loans.") {
        let binding = context.store.kv_get(READER_BINDINGS, account)?;
        if binding["origin"] != crate::library::LIBRARY_ORIGIN
            || binding["binding_kind"] != "owner_verified"
        {
            return Err(library_error(LibraryError::IdentityUnverified));
        }
        let reference = reader_ref(&binding)?;
        source.source_id.push(':');
        source.source_id.push_str(reference);
        Some(binding)
    } else {
        None
    };
    const OWNER: &str = "service:fudan";
    if method.starts_with("fudan.programs.") {
        let allowed = if method.ends_with(".list") {
            &["account_id", "page", "page_size"][..]
        } else {
            &["account_id", "program_id"][..]
        };
        if params
            .as_object()
            .is_none_or(|object| object.keys().any(|key| !allowed.contains(&key.as_str())))
        {
            return Err(CoreError::invalid(
                "only verified public program parameters are supported",
            ));
        }
        if method.ends_with(".detail") {
            let program = decimal_id(params, "program_id")?;
            let known = context.store.records(principal, grant, &json!({
                "record_owner":OWNER,"account_id":account,"source_id":"official.fudan.programs.list",
                "external_id":format!("program:2:{program}"),"limit":1
            }), None)?;
            if known.is_empty() {
                return Err(CoreError::new(
                    "ProgramNotInCachedCatalog",
                    "read a public catalog page containing this program first",
                ));
            }
        }
    }
    context.store.require_source_capabilities(
        OWNER,
        &source.source_id,
        &[capability.to_owned()].into_iter().collect(),
    )?;

    if method == "fudan.catalog.course" {
        let semester = decimal_id(params, "semester_id")?;
        let course = decimal_id(params, "course_id")?;
        let external = format!("catalog_course:{semester}:{course}");
        let rows = context.store.records(
            principal,
            grant,
            &json!({"record_owner":OWNER,"account_id":account,"source_id":source.source_id,"external_id":external,"limit":1}),
            None,
        )?;
        let row = rows.first().ok_or_else(|| {
            CoreError::new(
                "CatalogCourseNotCached",
                "read a matching semester catalog page first",
            )
        })?;
        // The independent detail endpoint returned 404. This result makes its
        // catalog provenance explicit and does not claim a detail-page read.
        return Ok(json!({
            "account_id":account,"source_id":source.source_id,"external_id":external,
            "payload":row["data"],"cached_at":row["updated_at"],
            "cache_state":"cached_catalog_projection"
        }));
    }

    let mut io_grant = grant.clone();
    io_grant.capabilities.insert("http.request".into());
    io_grant.origins.insert(
        if method.starts_with("fudan.catalog.") {
            crate::academic_catalog::CATALOG_ORIGIN
        } else if method.starts_with("fudan.programs.") {
            crate::academic_programs::PROGRAM_ORIGIN
        } else if method.starts_with("fudan.library.") {
            crate::library::LIBRARY_ORIGIN
        } else {
            crate::ehall::EHALL_ORIGIN
        }
        .into(),
    );
    let transport = BoundTransport {
        account,
        store: context.store,
        source_capability: capability,
        credential_lease: Default::default(),
        network: context.network,
        platform: context.platform,
        principal,
        grant: &io_grant,
    };
    if method.starts_with("fudan.programs.") {
        let client = FudanProgramClient::new(transport);
        let value = if method.ends_with(".list") {
            serde_json::to_value(
                client
                    .list(
                        &source,
                        ProgramPage {
                            number: positive_number(params, "page", 1, 10_000)? as u32,
                            size: positive_number(params, "page_size", 20, 100)? as u16,
                        },
                    )
                    .await
                    .map_err(crate::core_adapter::campus_error)?,
            )?
        } else {
            serde_json::to_value(
                client
                    .detail(&source, decimal_id(params, "program_id")?)
                    .await
                    .map_err(crate::core_adapter::campus_error)?,
            )?
        };
        publish_value(context.store, OWNER, &source, method, &value)?;
        return Ok(value);
    }
    if method.starts_with("fudan.library.") {
        let client = LibraryClient::new(transport);
        if method == "fudan.library.reader.observe" {
            // This hash is not persisted and is not proof of the intended reader.
            return serde_json::to_value(
                client
                    .reader_identity(&source)
                    .await
                    .map_err(library_error)?,
            )
            .map_err(Into::into);
        }
        if method.starts_with("fudan.library.loans.") {
            let binding = reader_binding
                .as_ref()
                .ok_or_else(|| library_error(LibraryError::IdentityUnverified))?;
            let page = client
                .loans(
                    &source,
                    if method.ends_with(".history") {
                        LibraryLoanKind::History
                    } else {
                        LibraryLoanKind::Current
                    },
                    library_page(params)?,
                    binding["reader_ref"].as_str(),
                )
                .await
                .map_err(library_error)?;
            let value = serde_json::to_value(page)?;
            publish_value(context.store, OWNER, &source, method, &value)?;
            return Ok(value);
        }
        let value = match method {
            "fudan.library.lookup" => serde_json::to_value(
                client
                    .single_volume(
                        &source,
                        serde_json::from_value(params["kind"].clone())?,
                        required_string(params, "value")?,
                        positive_number(params, "limit", 20, 100)? as u16,
                    )
                    .await
                    .map_err(library_error)?,
            )?,
            "fudan.library.bibliography" => serde_json::to_value(
                client
                    .bibliography(&source, decimal_id(params, "catalogue_id")?)
                    .await
                    .map_err(library_error)?,
            )?,
            "fudan.library.holdings" => serde_json::to_value(
                client
                    .holdings(
                        &source,
                        decimal_id(params, "catalogue_id")?,
                        library_page(params)?,
                    )
                    .await
                    .map_err(library_error)?,
            )?,
            _ => return Err(CoreError::new("MethodNotFound", "unknown library method")),
        };
        publish_value(context.store, OWNER, &source, method, &value)?;
        return Ok(value);
    }
    if method.starts_with("fudan.catalog.") {
        let client = FudanAcademicCatalogClient::new(transport);
        let value = match method {
            "fudan.catalog.semesters" => serde_json::to_value(
                client
                    .semesters(&source)
                    .await
                    .map_err(crate::core_adapter::campus_error)?,
            )?,
            "fudan.catalog.lessons" => {
                let semester = decimal_id(params, "semester_id")?;
                let page = CatalogPage {
                    number: positive_number(params, "page", 1, 10_000)? as u32,
                    size: positive_number(params, "page_size", 20, 100)? as u16,
                };
                let batch = client
                    .lessons(&source, semester, page, &filters(params)?)
                    .await
                    .map_err(crate::core_adapter::campus_error)?;
                let courses_source = SourceContext {
                    source_id: format!("official.fudan.catalog.course:{semester}"),
                    ..source.clone()
                };
                let mut rows = std::collections::BTreeMap::new();
                for record in &batch.records {
                    let course = record
                        .payload
                        .course_record(&courses_source)
                        .map_err(crate::core_adapter::campus_error)?;
                    let data = serde_json::to_value(course.payload)?;
                    if let Some(previous) = rows.insert(course.external_id, data.clone())
                        && previous != data
                    {
                        return Err(CoreError::new(
                            "SourceSchemaChanged",
                            "conflicting course projections",
                        ));
                    }
                }
                context.store.require_source_capabilities(
                    OWNER,
                    &courses_source.source_id,
                    &[capability.to_owned()].into_iter().collect(),
                )?;
                context.store.commit_source(
                    OWNER, account, &courses_source.source_id, "catalog_course",
                    &rows.into_iter().collect::<Vec<_>>(),
                    &json!({"observed_at":source.observed_at,"coverage":batch.coverage,"provenance":"catalog_projection"}),
                )?;
                serde_json::to_value(batch)?
            }
            "fudan.catalog.syllabus" => serde_json::to_value(
                client
                    .syllabus(&source, decimal_id(params, "lesson_id")?)
                    .await
                    .map_err(crate::core_adapter::campus_error)?,
            )?,
            _ => return Err(CoreError::new("MethodNotFound", "unknown catalog method")),
        };
        publish_value(context.store, OWNER, &source, method, &value)?;
        return Ok(value);
    }

    let client = EhallClient::new(transport);
    if method == "fudan.ehall.tasks.sync" {
        let collection = client
            .collect_tasks(
                &source,
                task_kind(params)?,
                positive_number(
                    params,
                    "page_size",
                    20,
                    u64::from(crate::ehall::MAX_PAGE_SIZE),
                )? as u16,
                EhallReadBudget {
                    max_pages: positive_number(params, "max_pages", 10, 100)? as u16,
                    max_items: positive_number(params, "max_items", 500, 5_000)? as usize,
                    max_bytes: positive_number(
                        params,
                        "max_bytes",
                        4 * 1024 * 1024,
                        32 * 1024 * 1024,
                    )? as usize,
                },
            )
            .await
            .map_err(crate::core_adapter::campus_error)?;
        let value = serde_json::to_value(collection)?;
        publish_value(context.store, OWNER, &source, method, &value)?;
        return Ok(value);
    }
    let value = match method {
        "fudan.ehall.catalog" => serde_json::to_value(
            client
                .catalog(&source, positive_number(params, "limit", 20, 100)? as u16)
                .await
                .map_err(crate::core_adapter::campus_error)?,
        )?,
        "fudan.ehall.tasks" => serde_json::to_value(
            client
                .tasks(
                    &source,
                    task_kind(params)?,
                    EhallPage {
                        page: positive_number(params, "page", 1, 10_000)? as u32,
                        page_size: positive_number(
                            params,
                            "page_size",
                            20,
                            u64::from(crate::ehall::MAX_PAGE_SIZE),
                        )? as u16,
                    },
                )
                .await
                .map_err(crate::core_adapter::campus_error)?,
        )?,
        _ => return Err(CoreError::new("MethodNotFound", "unknown eHall method")),
    };
    publish_value(context.store, OWNER, &source, method, &value)?;
    Ok(value)
}
