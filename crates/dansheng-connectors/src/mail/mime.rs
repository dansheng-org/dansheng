use super::model::*;
use dansheng_core::{CoreError, CoreResult};
use mail_parser::{AddressList, MessageParser, MessagePart};

fn metadata(part: &MessagePart<'_>, index: usize, complete: bool) -> AttachmentMetadata {
    let complete = complete && !part.has_problems() && part.decoded_checked().1.is_empty();
    AttachmentMetadata {
        part: format!("attachment:{index}"),
        name: part.attachment_name().map(|v| bounded(v, 1024).0),
        content_type: part
            .content_type()
            .map(|v| format!("{}/{}", v.ctype(), v.subtype().unwrap_or("octet-stream")))
            .unwrap_or_else(|| "application/octet-stream".into()),
        decoded_size: part.decoded_len(),
        size_complete: complete,
        content_complete: complete,
        content_id: part.content_id().map(|v| bounded(v, 1024).0),
    }
}

fn addresses(value: Option<AddressList<'_>>) -> Vec<MailAddress> {
    value
        .map(|list| {
            list.mailboxes()
                .take(100)
                .map(|a| MailAddress {
                    name: a.name().map(|v| bounded(v, 1024).0),
                    address: a.address().map(|v| bounded(v, 512).0),
                })
                .collect()
        })
        .unwrap_or_default()
}
pub(super) fn bounded(value: &str, max: usize) -> (String, bool) {
    let mut end = value.len().min(max);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    (value[..end].to_owned(), end < value.len())
}
pub(super) fn parse(
    folder: &str,
    validity: u32,
    uid: u32,
    size: u32,
    flags: Vec<String>,
    raw: &[u8],
) -> CoreResult<MailMessage> {
    if raw.len() > MAX_RAW_BYTES {
        return Err(CoreError::new(
            "MailLimitExceeded",
            "mail response exceeds configured limit",
        ));
    }
    parse_full(folder, validity, uid, size, flags, raw)
}

pub(super) fn parse_full(
    folder: &str,
    validity: u32,
    uid: u32,
    size: u32,
    flags: Vec<String>,
    raw: &[u8],
) -> CoreResult<MailMessage> {
    if raw.len() > MAX_ATTACHMENT_RAW_BYTES {
        return Err(CoreError::new(
            "MailLimitExceeded",
            "mail MIME input exceeds limit",
        ));
    }
    let parsed = MessageParser::new()
        .parse(raw)
        .ok_or_else(|| CoreError::new("InvalidMime", "mail message could not be parsed"))?;
    let text = parsed.body_text(0).map(|v| bounded(&v, MAX_BODY_BYTES));
    let html = parsed.body_html(0).map(|v| bounded(&v, MAX_BODY_BYTES));
    let body_truncated = text.as_ref().is_some_and(|v| v.1) || html.as_ref().is_some_and(|v| v.1);
    let complete = raw.len() == size as usize && parsed.parts().all(|p| !p.has_problems());
    let attachments = parsed
        .attachments()
        .take(128)
        .enumerate()
        .map(|(i, part)| metadata(&part, i, complete))
        .collect();
    Ok(MailMessage {
        folder: folder.into(),
        uid_validity: validity,
        uid,
        size,
        flags,
        message_id: parsed.message_id().map(|v| bounded(v, 1024).0),
        subject: parsed.subject().map(|v| bounded(v, 8192).0),
        from: addresses(parsed.from()),
        to: addresses(parsed.to()),
        cc: addresses(parsed.cc()),
        date: parsed.date().map(|v| v.to_rfc3339()),
        text: text.map(|v| v.0),
        html: html.map(|v| v.0),
        attachments,
        mime_complete: complete,
        body_truncated,
        deleted_remotely: false,
    })
}

/// Decode original octets, without text charset conversion or forgiving fallback.
pub(super) fn attachment(
    raw: &[u8],
    size: u32,
    index: usize,
) -> CoreResult<(AttachmentMetadata, Vec<u8>)> {
    if raw.len() != size as usize {
        return Err(CoreError::new(
            "MailAttachmentIncomplete",
            "IMAP returned an incomplete message",
        ));
    }
    if raw.len() > MAX_ATTACHMENT_RAW_BYTES {
        return Err(CoreError::new(
            "MailLimitExceeded",
            "attachment message exceeds raw MIME limit",
        ));
    }
    let parsed = MessageParser::new()
        .parse(raw)
        .ok_or_else(|| CoreError::new("InvalidMime", "mail message could not be parsed"))?;
    if parsed.parts().any(|p| p.has_problems()) {
        return Err(CoreError::new(
            "MailAttachmentIncomplete",
            "mail MIME structure is incomplete or damaged",
        ));
    }
    let part = parsed
        .attachments()
        .nth(index)
        .ok_or_else(|| CoreError::new("NotFound", "mail attachment is not present"))?;
    if part.decoded_len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::new(
            "MailLimitExceeded",
            "decoded mail attachment exceeds 4 MiB",
        ));
    }
    let (bytes, problems) = part.decoded_checked();
    if !problems.is_empty() {
        return Err(CoreError::new(
            "MailAttachmentIncomplete",
            "mail attachment transfer encoding is damaged or unsupported",
        ));
    }
    if bytes.len() > MAX_ATTACHMENT_BYTES {
        return Err(CoreError::new(
            "MailLimitExceeded",
            "decoded mail attachment exceeds 4 MiB",
        ));
    }
    Ok((metadata(&part, index, true), bytes.into_owned()))
}
