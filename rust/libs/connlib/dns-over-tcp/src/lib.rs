#![cfg_attr(test, allow(clippy::unwrap_used))]

mod client;
mod codec;
mod server;

pub use client::{Client, QueryResult, QueryToken};
pub use server::{Query, Server};
