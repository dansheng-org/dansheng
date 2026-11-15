// SPDX-License-Identifier: GPL-3.0-or-later
//! Official campus connectors and optional native mail services.
//! Campus networking and authentication are supplied by the host transport.

pub mod academic_catalog;
pub mod academic_programs;
pub mod campus;
pub mod campus_statistics;
pub mod canvas;
pub mod community;
#[cfg(feature = "services")]
pub mod core_adapter;
pub mod ehall;
#[cfg(feature = "services")]
pub mod electricity_alert;
pub mod energy_history;
#[cfg(feature = "services")]
mod expanded_services;
#[cfg(feature = "services")]
pub mod forum_actions;
pub mod fudan;
#[cfg(feature = "services")]
pub mod fudan_cloud;
pub mod library;
#[cfg(feature = "login")]
pub mod login;
#[cfg(feature = "services")]
pub mod mail;
pub mod models;
#[cfg(feature = "services")]
mod page_transport;
pub mod postgraduate_calendar;
pub mod transport;
#[cfg(feature = "services")]
pub mod webdav_drive;
#[cfg(feature = "webvpn")]
pub mod webvpn;

pub use transport::{
    AuthChallenge, AuthMode, ConnectorError, ConnectorRequest, ConnectorResponse,
    ConnectorTransport, Headers, HttpMethod, TransportAuth,
};
