#![cfg_attr(test, allow(clippy::unwrap_used))]

//! Exports OpenTelemetry metrics over OTLP/HTTP, optionally authenticated with an Azure managed identity.

mod exporter;
mod managed_identity;

pub use exporter::{OtlpAuth, check_endpoint, with_exporter};
pub use managed_identity::ManagedIdentity;
