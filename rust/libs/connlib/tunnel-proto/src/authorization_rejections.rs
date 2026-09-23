use crate::expiring_map::ExpiringMap;
use crate::p2p_control::no_authorization::{self, NoAuthorization};
use connlib_model::ClientId;
use ip_packet::IpPacket;
use std::net::IpAddr;
use std::time::{Duration, Instant};

/// Limits authorization rejection events per client and destination IP.
#[derive(Default)]
pub(crate) struct AuthorizationRejections {
    recently_notified: ExpiringMap<(ClientId, IpAddr), ()>,
}

impl AuthorizationRejections {
    pub(crate) fn on_rejected(
        &mut self,
        pool: &ip_packet::IpPacketPool,
        client: ClientId,
        rejection: NoAuthorization,
        now: Instant,
    ) -> Option<IpPacket> {
        let key = (client, rejection.dst);
        if self
            .recently_notified
            .get(&key)
            .is_some_and(|entry| now < entry.expires_at)
        {
            return None;
        }

        let event = no_authorization::event(pool, rejection.dst, rejection.protocol)
            .inspect_err(|e| tracing::trace!("Failed to create `NoAuthorization` event: {e:#}"))
            .ok()?;
        self.recently_notified
            .insert(key, (), now, Duration::from_secs(2));

        Some(event)
    }

    pub(crate) fn poll_timeout(&self) -> Option<Instant> {
        self.recently_notified.poll_timeout()
    }

    pub(crate) fn handle_timeout(&mut self, now: Instant) {
        self.recently_notified.handle_timeout(now);
        while self.recently_notified.poll_event().is_some() {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::p2p_control::no_authorization::Protocol;

    #[test_case::test_case(0, false; "same instant")]
    #[test_case::test_case(1999, false; "within two seconds")]
    #[test_case::test_case(2000, true; "after two seconds")]
    fn retries_on_rejected_traffic(milliseconds: u64, expected: bool) {
        let pool = ip_packet::IpPacketPool::new("test");
        let mut rejections = AuthorizationRejections::default();
        let now = Instant::now();
        let client = ClientId::from_u128(1);
        let rejection = rejection("10.0.0.1", 443);

        assert!(
            rejections
                .on_rejected(&pool, client, rejection, now)
                .is_some()
        );
        assert!(
            rejections
                .on_rejected(&pool, client, rejection, now)
                .is_none()
        );
        let retry = rejections.on_rejected(
            &pool,
            client,
            rejection,
            now + Duration::from_millis(milliseconds),
        );

        assert_eq!(retry.is_some(), expected);
    }

    #[test]
    fn limits_each_client_and_ip_independently_of_ports() {
        let pool = ip_packet::IpPacketPool::new("test");
        let mut rejections = AuthorizationRejections::default();
        let now = Instant::now();
        let client = ClientId::from_u128(1);
        let other_client = ClientId::from_u128(2);
        let first = rejection("10.0.0.1", 443);
        let other_port = rejection("10.0.0.1", 80);
        let other_ip = rejection("10.0.0.2", 443);

        assert!(rejections.on_rejected(&pool, client, first, now).is_some());
        assert!(
            rejections
                .on_rejected(&pool, client, other_port, now)
                .is_none()
        );
        assert!(
            rejections
                .on_rejected(&pool, client, other_ip, now)
                .is_some()
        );
        assert!(
            rejections
                .on_rejected(&pool, other_client, first, now)
                .is_some()
        );

        assert!(
            rejections
                .on_rejected(&pool, client, first, now + Duration::from_secs(1))
                .is_none()
        );
        let expires_at = rejections.poll_timeout().unwrap();
        assert_eq!(expires_at, now + Duration::from_secs(2));
        rejections.handle_timeout(expires_at);
        assert_eq!(rejections.poll_timeout(), None);

        let event = rejections
            .on_rejected(&pool, client, other_port, expires_at)
            .unwrap();
        assert_eq!(
            no_authorization::decode(event.as_fz_p2p_control().unwrap()).unwrap(),
            other_port
        );
    }

    fn rejection(dst: &str, dst_port: u16) -> NoAuthorization {
        NoAuthorization {
            dst: dst.parse().unwrap(),
            protocol: Protocol::Tcp { dst_port },
        }
    }
}
