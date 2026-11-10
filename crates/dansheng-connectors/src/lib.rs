// SPDX-License-Identifier: GPL-3.0-or-later
//! Official campus connectors and optional native mail services.
//! Campus networking and authentication are supplied by the host transport.

pub mod campus;
pub mod canvas;
pub mod community;
#[cfg(feature = "services")]
pub mod core_adapter;
pub mod energy_history;
#[cfg(feature = "services")]
pub mod forum_actions;
pub mod fudan;
#[cfg(feature = "login")]
pub mod login;
#[cfg(feature = "services")]
pub mod mail;
pub mod models;
pub mod transport;
#[cfg(feature = "webvpn")]
pub mod webvpn;

pub use transport::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse,
    ConnectorTransport, Headers, HttpMethod, TransportAuth,
};
