pub mod attr {
    pub use telemetry::otel::attr::*;

    use opentelemetry::KeyValue;

    pub fn network_protocol_name(payload: &[u8]) -> KeyValue {
        const KEY: &str = "network.protocol.name";

        KeyValue::new(KEY, crate::packet_kind::classify(payload))
    }

    /// The transport a DNS query was received / forwarded on.
    pub fn network_transport(transport: crate::dns::Transport) -> KeyValue {
        const KEY: &str = "network.transport";

        match transport {
            crate::dns::Transport::Udp => KeyValue::new(KEY, "udp"),
            crate::dns::Transport::Tcp => KeyValue::new(KEY, "tcp"),
        }
    }

    /// The DNS query type (e.g. `A`, `AAAA`).
    ///
    /// Only IANA-assigned record types (which `domain` renders by their mnemonic) are
    /// emitted as-is. Unrecognised types are rendered by `domain` as `TYPE<n>` and are
    /// collapsed into `other` so that an (untrusted) peer cannot inflate the metric's
    /// cardinality with exotic query types.
    pub fn dns_question_type(qtype: dns_types::RecordType) -> KeyValue {
        const KEY: &str = "dns.question.type";

        let mnemonic = qtype.to_string();

        if mnemonic.starts_with("TYPE") {
            KeyValue::new(KEY, "other")
        } else {
            KeyValue::new(KEY, mnemonic)
        }
    }

    /// A DNS query that was recursed locally, i.e. forwarded directly to an upstream resolver.
    pub fn dns_recursion_local() -> KeyValue {
        KeyValue::new("dns.recursion", "local")
    }

    /// A DNS query that was recursed through the tunnel, i.e. forwarded to a Gateway for resolution.
    pub fn dns_recursion_tunnel() -> KeyValue {
        KeyValue::new("dns.recursion", "tunnel")
    }

    /// The response code of a completed DNS lookup (e.g. `NOERROR`, `NXDOMAIN`).
    ///
    /// `domain` renders unassigned codes as `RCODE<n>`; those are collapsed into
    /// `other` so that an (untrusted) upstream cannot inflate the metric's cardinality.
    pub fn dns_response_code(code: dns_types::ResponseCode) -> KeyValue {
        const KEY: &str = "dns.response.code";

        let mnemonic = code.to_string();

        if mnemonic.starts_with("RCODE") {
            KeyValue::new(KEY, "other")
        } else {
            KeyValue::new(KEY, mnemonic)
        }
    }
}

pub mod metrics {
    pub use telemetry::otel::metrics::*;

    use opentelemetry::metrics::Histogram;

    /// Measures how long connlib takes to recursively resolve a DNS query against
    /// an upstream resolver (locally or through the tunnel).
    pub fn dns_lookup_duration() -> Histogram<f64> {
        opentelemetry::global::meter("connlib")
            .f64_histogram("dns.lookup.duration")
            .with_description("Duration of a recursive DNS lookup against an upstream resolver.")
            .with_unit("s")
            .with_boundaries(vec![
                0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1.0, 2.5, 5.0, 7.5, 10.0,
            ])
            .build()
    }
}

#[cfg(test)]
mod tests {
    use super::attr::dns_question_type;
    use dns_types::RecordType;
    use opentelemetry::KeyValue;

    #[test]
    fn well_known_question_types_are_emitted_verbatim() {
        assert_eq!(
            dns_question_type(RecordType::A),
            KeyValue::new("dns.question.type", "A")
        );
        assert_eq!(
            dns_question_type(RecordType::AAAA),
            KeyValue::new("dns.question.type", "AAAA")
        );
    }

    #[test]
    fn unknown_question_types_collapse_to_other() {
        assert_eq!(
            dns_question_type(RecordType::from_int(60000)),
            KeyValue::new("dns.question.type", "other")
        );
    }
}
