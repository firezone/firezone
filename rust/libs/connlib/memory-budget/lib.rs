//! Compile-time memory budgets for connlib's fixed-size buffer channels and queues.
//!
//! connlib pre-allocates several bounded channels and queues whose worst-case size is the product of
//! a per-platform capacity and the maximum packet / batch size. Each owning crate computes its own
//! worst case as a `pub const` - `tun::MAX_CHANNEL_MEMORY`, `tunnel::MAX_UDP_OUTBOUND_QUEUE_MEMORY`
//! and `tunnel::MAX_UDP_INBOUND_QUEUE_MEMORY`. This crate gathers those figures in one place and
//! asserts them against the memory budget the platform allows - most importantly the ~50 MB ceiling
//! an iOS Network Extension must stay under, which is what makes bounding these queues matter at all.
//!
//! The checks are `const` assertions evaluated at compile time. Whichever budget matches the target
//! being compiled is enforced: the desktop budgets on every (desktop) CI run, the mobile budgets when
//! connlib is built for iOS / Android.

#[cfg(test)]
mod tests {
    /// iOS Network Extensions are limited to 50 MB of memory; connlib's channels and queues must only
    /// ever occupy a small fraction of that.
    #[cfg(any(target_os = "ios", target_os = "android"))]
    #[test]
    fn fits_mobile_budget() {
        const { assert!(tun::MAX_CHANNEL_MEMORY <= 4 * 1024 * 1024) }
        const { assert!(tunnel::MAX_UDP_OUTBOUND_QUEUE_MEMORY <= 2 * 1024 * 1024) }
        const { assert!(tunnel::MAX_UDP_INBOUND_QUEUE_MEMORY <= 4 * 1024 * 1024) }
    }

    /// Desktop platforms are less constrained, but must not regress into hundreds of MB - which the
    /// UDP send queue in particular previously allowed (~250 MB before it was bounded).
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    #[test]
    fn fits_desktop_budget() {
        const { assert!(tun::MAX_CHANNEL_MEMORY <= 32 * 1024 * 1024) }
        const { assert!(tunnel::MAX_UDP_OUTBOUND_QUEUE_MEMORY <= 20 * 1024 * 1024) }
        const { assert!(tunnel::MAX_UDP_INBOUND_QUEUE_MEMORY <= 16 * 1024 * 1024) }
    }
}
