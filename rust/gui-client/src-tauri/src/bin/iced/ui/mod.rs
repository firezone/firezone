//! Firezone design-system primitives for the iced binary ("fz-ui").
//!
//! Each component is a Rust function that returns an `iced::Element` and
//! pulls its colors / radii / spacing from the design tokens in
//! `super::theme::Tokens`. The function signatures match the patterns
//! used in the Elixir admin portal's Phoenix components so visual parity
//! is mechanical.

pub mod button;
