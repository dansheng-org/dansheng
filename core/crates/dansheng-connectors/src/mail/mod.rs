//! Native, account-scoped mail service. Enabled by the connector `services` feature.
//! No credentials are stored in records or key/value storage; a real vault port is required.
mod mime;
mod model;
mod protocol;
mod service;

pub use model::{
    AttachmentBinding, AttachmentMetadata, Draft, DraftAttachment, DraftInput, MailConfig,
    MailEndpoint, MailMessage, MailboxFolder, TlsMode,
};
pub use service::MailService;

#[cfg(test)]
mod tests;
