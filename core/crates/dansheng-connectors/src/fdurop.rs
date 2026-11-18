// SPDX-License-Identifier: GPL-3.0-or-later
//! Fudan University Undergraduate Research Opportunities Program (FDUROP / 望道 / 莙政) connector.

use crate::transport::{
    ConnectorError, ConnectorRequest, ConnectorTransport, HttpMethod, TransportAuth,
};
use serde::{Deserialize, Serialize};
use url::Url;

const FDUROP_BASE: &str = "https://paper.fudan.edu.cn/fdurop-service";

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct FduropOpenTopicItem {
    pub id: String,
    pub title: String,
    pub brief: String,
    pub requirement: String,
    pub teacher_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub teacher_code: Option<String>,
    pub department_name: String,
    pub subject_kinds: Vec<String>,
    pub topic_labels: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct FduropTopicDetail {
    #[serde(flatten)]
    pub topic: FduropOpenTopicItem,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tutor_email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tutor_mobile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tutor_office_phone: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tutor_introduce: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lab_introduce: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct FduropTopicLabel {
    pub id: String,
    pub name_zh: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_en: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct FduropSubjectKind {
    pub id: String,
    pub name_zh: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_en: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct FduropSearchQuery {
    pub page: u32,
    pub page_size: u32,
    pub title: Option<String>,
    pub code_or_name: Option<String>,
    pub keyword: Option<String>,
    pub subject_kind_id: Option<String>,
    pub topic_label_id: Option<String>,
    pub department_id: Option<String>,
}

pub struct FduropClient<'a> {
    transport: &'a dyn ConnectorTransport,
    account: &'a str,
}

impl<'a> FduropClient<'a> {
    pub fn new(transport: &'a dyn ConnectorTransport, account: &'a str) -> Self {
        Self { transport, account }
    }

    pub async fn search_open_topics(
        &self,
        query: &FduropSearchQuery,
    ) -> Result<Vec<FduropOpenTopicItem>, ConnectorError> {
        let kw = query
            .keyword
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let has_title = query
            .title
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .is_some();
        let has_code = query
            .code_or_name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .is_some();

        if let Some(keyword) = kw.filter(|_| !has_title && !has_code) {
            let mut title_q = query.clone();
                title_q.keyword = None;
                title_q.title = Some(keyword.to_string());
                title_q.code_or_name = None;

                let mut name_q = query.clone();
                name_q.keyword = None;
                name_q.title = None;
                name_q.code_or_name = Some(keyword.to_string());

                let mut items = self.search_open_topics_single(&title_q).await?;
                if let Ok(extra) = self.search_open_topics_single(&name_q).await {
                    let mut seen: std::collections::HashSet<String> =
                        items.iter().map(|i| i.id.clone()).collect();
                    for item in extra {
                        if seen.insert(item.id.clone()) {
                            items.push(item);
                        }
                    }
                }
                return Ok(items);
            }

        self.search_open_topics_single(query).await
    }

    async fn search_open_topics_single(
        &self,
        query: &FduropSearchQuery,
    ) -> Result<Vec<FduropOpenTopicItem>, ConnectorError> {
        let page = query.page.max(1);
        let page_size = query.page_size.clamp(1, 1000);
        let mut url = Url::parse(&format!(
            "{FDUROP_BASE}/api/v1/for-std/urop-init-flow/open-topic/search"
        ))
        .map_err(|_| ConnectorError::InvalidConfiguration("fdurop search url"))?;
        {
            let mut pairs = url.query_pairs_mut();
            pairs.append_pair("queryPage__", &format!("{page},{page_size}"));
            if let Some(t) = query
                .title
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                pairs.append_pair("title", t);
            }
            if let Some(c) = query
                .code_or_name
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                pairs.append_pair("codeOrName", c);
            }
            if let Some(s) = query
                .subject_kind_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                pairs.append_pair("subjectKindId", s);
            }
            if let Some(l) = query
                .topic_label_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                pairs.append_pair("topicLabelId", l);
            }
            if let Some(d) = query
                .department_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                pairs.append_pair("departmentId", d);
            }
        }

        let request = ConnectorRequest {
            method: HttpMethod::Get,
            url,
            headers: vec![("Accept".into(), "application/json".into())],
            body: None,
            auth: TransportAuth::HostToken {
                account_id: self.account.into(),
            },
        };

        let response = self.transport.execute(request).await?;
        if response.status == 401 || response.status == 403 {
            return Err(ConnectorError::AuthRequired(
                crate::transport::AuthChallenge {
                    connector: "fdurop".into(),
                    origin: "https://paper.fudan.edu.cn".into(),
                    account_id: self.account.into(),
                    mode: crate::transport::AuthMode::Token,
                },
            ));
        }
        if response.status != 200 {
            return Err(ConnectorError::HttpStatus(response.status));
        }

        let val: serde_json::Value = serde_json::from_slice(&response.body)
            .map_err(|_| ConnectorError::InvalidConfiguration("fdurop search json parse"))?;

        if val["code"].as_i64() != Some(0) {
            let msg = val["msg"].as_str().unwrap_or("error");
            if msg.contains("un login") || msg.contains("login") {
                return Err(ConnectorError::AuthRequired(
                    crate::transport::AuthChallenge {
                        connector: "fdurop".into(),
                        origin: "https://paper.fudan.edu.cn".into(),
                        account_id: self.account.into(),
                        mode: crate::transport::AuthMode::Token,
                    },
                ));
            }
            return Err(ConnectorError::InvalidConfiguration(
                "fdurop api response error",
            ));
        }

        let raw_list = val["data"]
            .as_array()
            .or_else(|| val["data"]["dataList"].as_array())
            .or_else(|| val["data"]["rows"].as_array());

        let mut items = Vec::new();
        if let Some(arr) = raw_list {
            for row in arr {
                let id = row["id"].as_str().unwrap_or_default().to_string();
                let title = row["title"].as_str().unwrap_or_default().to_string();
                let brief = row["brief"].as_str().unwrap_or_default().to_string();
                let requirement = row["requirement"].as_str().unwrap_or_default().to_string();
                let teacher_name = row["teacher"]["person"]["nameZh"]
                    .as_str()
                    .or_else(|| row["teacher"]["person"]["name"].as_str())
                    .unwrap_or_default()
                    .to_string();
                let teacher_code = row["teacher"]["code"].as_str().map(|s| s.to_string());
                let department_name = row["teacher"]["department"]["nameZh"]
                    .as_str()
                    .or_else(|| row["teacher"]["department"]["name"].as_str())
                    .unwrap_or_default()
                    .to_string();
                let subject_kinds = row["subjectKindList"]
                    .as_array()
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|s| {
                                s["nameZh"]
                                    .as_str()
                                    .or_else(|| s["name"].as_str())
                                    .map(|n| n.to_string())
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let topic_labels = row["topicLabelList"]
                    .as_array()
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|l| {
                                l["nameZh"]
                                    .as_str()
                                    .or_else(|| l["name"].as_str())
                                    .map(|n| n.to_string())
                            })
                            .collect()
                    })
                    .unwrap_or_default();

                items.push(FduropOpenTopicItem {
                    id,
                    title,
                    brief,
                    requirement,
                    teacher_name,
                    teacher_code,
                    department_name,
                    subject_kinds,
                    topic_labels,
                });
            }
        }

        Ok(items)
    }

    pub async fn query_topic_labels(&self) -> Result<Vec<FduropTopicLabel>, ConnectorError> {
        let url = Url::parse(&format!(
            "{FDUROP_BASE}/api/v1/bizType/2/urop-topic-label/queryAll"
        ))
        .map_err(|_| ConnectorError::InvalidConfiguration("fdurop labels url"))?;
        let request = ConnectorRequest {
            method: HttpMethod::Get,
            url,
            headers: vec![("Accept".into(), "application/json".into())],
            body: None,
            auth: TransportAuth::HostToken {
                account_id: self.account.into(),
            },
        };
        let response = self.transport.execute(request).await?;
        if response.status == 401 || response.status == 403 {
            return Err(ConnectorError::AuthRequired(
                crate::transport::AuthChallenge {
                    connector: "fdurop".into(),
                    origin: "https://paper.fudan.edu.cn".into(),
                    account_id: self.account.into(),
                    mode: crate::transport::AuthMode::Token,
                },
            ));
        }
        if response.status != 200 {
            return Err(ConnectorError::HttpStatus(response.status));
        }
        let val: serde_json::Value = serde_json::from_slice(&response.body)
            .map_err(|_| ConnectorError::InvalidConfiguration("fdurop labels json parse"))?;
        let mut labels = Vec::new();
        if let Some(arr) = val["data"].as_array() {
            for row in arr {
                let id = row["id"].as_str().unwrap_or_default().to_string();
                let name_zh = row["nameZh"]
                    .as_str()
                    .or_else(|| row["name"].as_str())
                    .unwrap_or_default()
                    .to_string();
                let name_en = row["nameEn"].as_str().map(|s| s.to_string());
                if !id.is_empty() && !name_zh.is_empty() {
                    labels.push(FduropTopicLabel {
                        id,
                        name_zh,
                        name_en,
                    });
                }
            }
        }
        Ok(labels)
    }

    pub async fn query_subject_kinds(&self) -> Result<Vec<FduropSubjectKind>, ConnectorError> {
        let url = Url::parse(&format!(
            "{FDUROP_BASE}/api/v1/bizType/2/urop-subject-kind/queryAll"
        ))
        .map_err(|_| ConnectorError::InvalidConfiguration("fdurop subjects url"))?;
        let request = ConnectorRequest {
            method: HttpMethod::Get,
            url,
            headers: vec![("Accept".into(), "application/json".into())],
            body: None,
            auth: TransportAuth::HostToken {
                account_id: self.account.into(),
            },
        };
        let response = self.transport.execute(request).await?;
        if response.status == 401 || response.status == 403 {
            return Err(ConnectorError::AuthRequired(
                crate::transport::AuthChallenge {
                    connector: "fdurop".into(),
                    origin: "https://paper.fudan.edu.cn".into(),
                    account_id: self.account.into(),
                    mode: crate::transport::AuthMode::Token,
                },
            ));
        }
        if response.status != 200 {
            return Err(ConnectorError::HttpStatus(response.status));
        }
        let val: serde_json::Value = serde_json::from_slice(&response.body)
            .map_err(|_| ConnectorError::InvalidConfiguration("fdurop subjects json parse"))?;
        let mut subjects = Vec::new();
        if let Some(arr) = val["data"].as_array() {
            for row in arr {
                let id = row["id"].as_str().unwrap_or_default().to_string();
                let name_zh = row["nameZh"]
                    .as_str()
                    .or_else(|| row["name"].as_str())
                    .unwrap_or_default()
                    .to_string();
                let name_en = row["nameEn"].as_str().map(|s| s.to_string());
                if !id.is_empty() && !name_zh.is_empty() {
                    subjects.push(FduropSubjectKind {
                        id,
                        name_zh,
                        name_en,
                    });
                }
            }
        }
        Ok(subjects)
    }

    pub async fn topic_detail(&self, topic_id: &str) -> Result<FduropTopicDetail, ConnectorError> {
        if topic_id.is_empty() || topic_id.len() > 64 || topic_id.chars().any(char::is_control) {
            return Err(ConnectorError::InvalidConfiguration("invalid topic id"));
        }

        let url = Url::parse(&format!(
            "{FDUROP_BASE}/api/v1/for-std/urop-init-flow/topic-view/{topic_id}"
        ))
        .map_err(|_| ConnectorError::InvalidConfiguration("fdurop detail url"))?;

        let request = ConnectorRequest {
            method: HttpMethod::Get,
            url,
            headers: vec![("Accept".into(), "application/json".into())],
            body: None,
            auth: TransportAuth::HostToken {
                account_id: self.account.into(),
            },
        };

        let response = self.transport.execute(request).await?;
        if response.status == 401 || response.status == 403 {
            return Err(ConnectorError::AuthRequired(
                crate::transport::AuthChallenge {
                    connector: "fdurop".into(),
                    origin: "https://paper.fudan.edu.cn".into(),
                    account_id: self.account.into(),
                    mode: crate::transport::AuthMode::Token,
                },
            ));
        }
        if response.status != 200 {
            return Err(ConnectorError::HttpStatus(response.status));
        }

        let val: serde_json::Value = serde_json::from_slice(&response.body)
            .map_err(|_| ConnectorError::InvalidConfiguration("fdurop detail json parse"))?;

        if val["code"].as_i64() != Some(0) {
            let msg = val["msg"].as_str().unwrap_or("error");
            if msg.contains("un login") || msg.contains("login") {
                return Err(ConnectorError::AuthRequired(
                    crate::transport::AuthChallenge {
                        connector: "fdurop".into(),
                        origin: "https://paper.fudan.edu.cn".into(),
                        account_id: self.account.into(),
                        mode: crate::transport::AuthMode::Token,
                    },
                ));
            }
            return Err(ConnectorError::InvalidConfiguration(
                "fdurop api response error",
            ));
        }

        let data = &val["data"];
        let topic_json = &data["uropTopic"];
        let teacher_json = &data["teacher"];
        let tutor_json = &data["uropTutor"];

        let title = topic_json["title"].as_str().unwrap_or_default().to_string();
        let brief = topic_json["brief"].as_str().unwrap_or_default().to_string();
        let requirement = topic_json["requirement"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        let teacher_name = teacher_json["person"]["nameZh"]
            .as_str()
            .or_else(|| teacher_json["person"]["name"].as_str())
            .unwrap_or_default()
            .to_string();
        let teacher_code = teacher_json["code"].as_str().map(|s| s.to_string());
        let department_name = teacher_json["department"]["nameZh"]
            .as_str()
            .or_else(|| teacher_json["department"]["name"].as_str())
            .unwrap_or_default()
            .to_string();

        let subject_kinds = topic_json["subjectKindList"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|s| {
                        s["nameZh"]
                            .as_str()
                            .or_else(|| s["name"].as_str())
                            .map(|n| n.to_string())
                    })
                    .collect()
            })
            .unwrap_or_default();

        let topic_labels = topic_json["topicLabelList"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|l| {
                        l["nameZh"]
                            .as_str()
                            .or_else(|| l["name"].as_str())
                            .map(|n| n.to_string())
                    })
                    .collect()
            })
            .unwrap_or_default();

        let tutor_email = tutor_json["email"].as_str().map(|s| s.to_string());
        let tutor_mobile = tutor_json["mobile"].as_str().map(|s| s.to_string());
        let tutor_office_phone = tutor_json["officePhone"].as_str().map(|s| s.to_string());
        let tutor_introduce = tutor_json["tutorIntroduce"].as_str().map(|s| s.to_string());
        let lab_introduce = tutor_json["introduce"].as_str().map(|s| s.to_string());

        Ok(FduropTopicDetail {
            topic: FduropOpenTopicItem {
                id: topic_id.to_string(),
                title,
                brief,
                requirement,
                teacher_name,
                teacher_code,
                department_name,
                subject_kinds,
                topic_labels,
            },
            tutor_email,
            tutor_mobile,
            tutor_office_phone,
            tutor_introduce,
            lab_introduce,
        })
    }
}
