pub mod attr {
    use hickory_resolver::lookup::Lookup;
    use hickory_resolver::net::{DnsError, NetError};
    use hickory_resolver::proto::op::ResponseCode;
    use hickory_resolver::proto::rr::RecordType;
    use opentelemetry::KeyValue;

    /// Builds the metric attributes for a completed DNS lookup.
    ///
    /// On success (or a DNS-level error code such as `NXDOMAIN`), the response code is
    /// recorded. Transport/protocol failures (e.g. timeouts) carry no response code, so the
    /// error layers are recorded instead.
    pub fn dns_lookup(record_type: RecordType, result: &Result<Lookup, NetError>) -> Vec<KeyValue> {
        let mut attributes = vec![dns_question_type(record_type)];

        match result {
            Ok(_) => attributes.push(dns_response_code(ResponseCode::NoError)),
            Err(e) => match response_code(e) {
                Some(code) => attributes.push(dns_response_code(code)),
                None => attributes.extend(telemetry::otel::error_layers(&anyhow::Error::new(
                    e.clone(),
                ))),
            },
        }

        attributes
    }

    /// The DNS query type (e.g. `A`, `AAAA`).
    ///
    /// The Gateway only ever resolves `A` and `AAAA`; anything else collapses to `other`.
    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "The Gateway only ever resolves `A` and `AAAA`."
    )]
    pub fn dns_question_type(record_type: RecordType) -> KeyValue {
        const KEY: &str = "dns.question.type";

        let value = match record_type {
            RecordType::A => "A",
            RecordType::AAAA => "AAAA",
            _ => "other",
        };

        KeyValue::new(KEY, value)
    }

    /// The response code of a completed DNS lookup (e.g. `NOERROR`, `NXDOMAIN`).
    ///
    /// The mnemonics match those emitted by the Client (uppercase, per the IANA registry) so
    /// that both report to the same metric. Unassigned codes collapse to `other` to bound the
    /// metric's cardinality.
    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "Unassigned response codes collapse to `other`."
    )]
    pub fn dns_response_code(code: ResponseCode) -> KeyValue {
        const KEY: &str = "dns.response.code";

        let mnemonic = match code {
            ResponseCode::NoError => "NOERROR",
            ResponseCode::FormErr => "FORMERR",
            ResponseCode::ServFail => "SERVFAIL",
            ResponseCode::NXDomain => "NXDOMAIN",
            ResponseCode::NotImp => "NOTIMP",
            ResponseCode::Refused => "REFUSED",
            ResponseCode::YXDomain => "YXDOMAIN",
            ResponseCode::YXRRSet => "YXRRSET",
            ResponseCode::NXRRSet => "NXRRSET",
            ResponseCode::NotAuth => "NOTAUTH",
            ResponseCode::NotZone => "NOTZONE",
            _ => "other",
        };

        KeyValue::new(KEY, mnemonic)
    }

    /// Extracts the DNS response code from a hickory lookup error, if it carries one.
    ///
    /// Transport/protocol errors (timeouts, IO, ...) don't carry a response code.
    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "Only DNS-level errors carry a response code."
    )]
    fn response_code(error: &NetError) -> Option<ResponseCode> {
        match error {
            NetError::Dns(DnsError::ResponseCode(code)) => Some(*code),
            NetError::Dns(DnsError::NoRecordsFound(no_records)) => Some(no_records.response_code),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::attr::{dns_question_type, dns_response_code};
    use hickory_resolver::proto::op::ResponseCode;
    use hickory_resolver::proto::rr::RecordType;
    use opentelemetry::KeyValue;

    #[test]
    fn question_type_maps_a_and_aaaa() {
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
    fn response_code_mnemonics_match_the_client() {
        assert_eq!(
            dns_response_code(ResponseCode::NoError),
            KeyValue::new("dns.response.code", "NOERROR")
        );
        assert_eq!(
            dns_response_code(ResponseCode::NXDomain),
            KeyValue::new("dns.response.code", "NXDOMAIN")
        );
        assert_eq!(
            dns_response_code(ResponseCode::ServFail),
            KeyValue::new("dns.response.code", "SERVFAIL")
        );
    }

    #[test]
    fn unassigned_response_codes_collapse_to_other() {
        assert_eq!(
            dns_response_code(ResponseCode::BADVERS),
            KeyValue::new("dns.response.code", "other")
        );
    }
}
