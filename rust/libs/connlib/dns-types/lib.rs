#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::{borrow::Cow, fmt, io, str::FromStr, time::Duration};

use base64::{Engine, prelude::BASE64_URL_SAFE_NO_PAD};
use bytes::Bytes;
use domain::{
    base::{
        HeaderCounts, Message, MessageBuilder, ParsedName, Question, RecordSection,
        message_builder::AnswerBuilder, name::FlattenInto,
    },
    dep::octseq::OctetsInto,
    rdata::AllRecordData,
};
use serde::{Deserialize, Serialize};
use url::Url;

pub mod prelude {
    // Re-export trait names so other crates can call the functions on them.
    // We don't export the name though so that it cannot conflict.
    pub use domain::base::RecordData as _;
    pub use domain::base::ToName as _;
    pub use domain::base::name::FlattenInto as _;
}

pub const MAX_NAME_LEN: usize = domain::base::Name::MAX_LEN;

pub type RecordType = domain::base::iana::Rtype;

pub type DomainNameRef<'a> = domain::base::Name<&'a [u8]>;
pub type Record<'a> =
    domain::base::Record<ParsedName<&'a [u8]>, AllRecordData<&'a [u8], ParsedName<&'a [u8]>>>;
pub type RecordData<'a> = AllRecordData<&'a [u8], ParsedName<&'a [u8]>>;

pub type DomainName = domain::base::Name<Vec<u8>>;
pub type OwnedRecord = domain::base::Record<DomainName, AllRecordData<Vec<u8>, DomainName>>;
pub type OwnedRecordData = AllRecordData<Vec<u8>, DomainName>;

pub type ResponseCode = domain::base::iana::Rcode;
pub type Ttl = domain::base::Ttl;

#[derive(Clone)]
pub struct Query {
    inner: Message<Vec<u8>>,
}

impl std::fmt::Debug for Query {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Query")
            .field("qid", &self.inner.header().id())
            .field("flags", &self.inner.header().flags())
            .field("type", &self.qtype())
            .field("domain", &self.domain())
            .finish()
    }
}

impl Query {
    pub fn parse(slice: &[u8]) -> Result<Self, Error> {
        let message = Message::from_octets(slice).map_err(|_| Error::TooShort)?;

        if message.header().qr() {
            return Err(Error::NotAQuery);
        }

        // We don't need to support multiple questions/qname in a single query because
        // nobody does it and since this run with each packet we want to squeeze as much optimization
        // as we can therefore we won't do it.
        //
        // See: https://stackoverflow.com/a/55093896
        let _ = message.sole_question()?; // Verify that there is exactly one question.

        // Verify that we can parse the answers + all records
        for record in message.answer()? {
            record?.into_any_record::<AllRecordData<_, _>>()?;
        }

        Ok(Self {
            inner: message.octets_into(),
        })
    }

    pub fn new(domain: DomainName, rtype: RecordType) -> Self {
        let mut inner = MessageBuilder::new_vec().question();
        inner.header_mut().set_qr(false);
        inner.header_mut().set_rd(true); // Default to recursion desired.
        inner.header_mut().set_random_id(); // Default to a random id.

        inner
            .push((domain, rtype))
            .expect("Vec-backed message builder never fails");

        Self {
            inner: inner.into_message(),
        }
    }

    pub fn with_id(mut self, id: u16) -> Self {
        self.inner.header_mut().set_id(id);

        self
    }

    pub fn id(&self) -> u16 {
        self.inner.header().id()
    }

    pub fn domain(&self) -> DomainName {
        self.question().into_qname().flatten_into()
    }

    pub fn qtype(&self) -> RecordType {
        self.question().qtype()
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.inner.into_octets()
    }

    pub fn as_bytes(&self) -> &[u8] {
        self.inner.as_slice()
    }

    pub fn try_into_http_request(self, url: &DoHUrl) -> Result<http::Request<Bytes>, http::Error> {
        let query = self.with_id(0); // In order to be more HTTP-cache friendly, DoH queries should set their ID to 0.

        let url = format!(
            "{url}?dns={}",
            BASE64_URL_SAFE_NO_PAD.encode(query.as_bytes())
        );

        http::Request::builder()
            .method(http::Method::GET)
            .uri(url)
            .header(http::header::ACCEPT, "application/dns-message")
            .body(Bytes::new())
    }

    fn question(&self) -> Question<ParsedName<&[u8]>> {
        self.inner.sole_question().expect("verified in ctor")
    }
}

impl TryFrom<&[u8]> for Query {
    type Error = Error;

    fn try_from(slice: &[u8]) -> Result<Self, Self::Error> {
        Self::parse(slice)
    }
}

impl TryFrom<&[u8]> for Response {
    type Error = Error;

    fn try_from(slice: &[u8]) -> Result<Self, Self::Error> {
        Self::parse(slice)
    }
}

#[derive(Clone)]
pub struct Response {
    inner: Message<Vec<u8>>,
}

impl std::fmt::Debug for Response {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Response")
            .field("qid", &self.inner.header().id())
            .field("domain", &self.domain())
            .field("type", &self.qtype())
            .field("response_code", &self.response_code())
            .finish_non_exhaustive() // TODO: Add records?
    }
}

impl Response {
    /// Creates an empty, "NOERROR" response for the given query.
    pub fn no_error(query: &Query) -> Self {
        ResponseBuilder::for_query(query, ResponseCode::NOERROR).build()
    }

    pub fn servfail(query: &Query) -> Self {
        ResponseBuilder::for_query(query, ResponseCode::SERVFAIL).build()
    }

    pub fn nxdomain(query: &Query) -> Self {
        ResponseBuilder::for_query(query, ResponseCode::NXDOMAIN).build()
    }

    pub fn parse(slice: &[u8]) -> Result<Self, Error> {
        let message = Message::from_octets(slice).map_err(|_| Error::TooShort)?;

        if !message.header().qr() {
            return Err(Error::NotAResponse);
        }

        let _ = message.sole_question()?; // Verify that there is exactly one question.

        // Verify that we can parse the answers + all records
        for record in message.answer()? {
            record?.into_any_record::<AllRecordData<_, _>>()?;
        }

        Ok(Self {
            inner: message.octets_into(),
        })
    }

    pub fn try_from_http_response(response: http::Response<Bytes>) -> Result<Self, Error> {
        if response.status() != http::StatusCode::OK {
            let status = response.status();
            let body = String::from_utf8(response.into_body().into()).unwrap_or_default();

            return Err(Error::HttpNotSuccess(status, body));
        }

        if response
            .headers()
            .get(http::header::CONTENT_TYPE)
            .is_none_or(|ct| ct != "application/dns-message")
        {
            return Err(Error::NotApplicationDnsMessage);
        }

        Self::parse(response.body())
    }

    pub fn with_id(mut self, id: u16) -> Self {
        self.inner.header_mut().set_id(id);

        self
    }

    pub fn id(&self) -> u16 {
        self.inner.header().id()
    }

    pub fn truncated(&self) -> bool {
        self.inner.header().tc()
    }

    pub fn domain(&self) -> DomainName {
        self.question().into_qname().flatten_into()
    }

    pub fn qtype(&self) -> RecordType {
        self.question().qtype()
    }

    pub fn response_code(&self) -> ResponseCode {
        self.inner.header().rcode()
    }

    pub fn ttl(&self, rtype: RecordType) -> Option<Duration> {
        self.records()
            .filter(|r| r.rtype() == rtype)
            .map(|r| r.ttl().into_duration())
            .min()
    }

    pub fn records(&self) -> impl Iterator<Item = Record<'_>> {
        self.answer().into_iter().map(|r| {
            r.expect("verified in ctor")
                .into_any_record::<AllRecordData<_, _>>()
                .expect("verified in ctor")
        })
    }

    /// Serializes this response into a byte slice.
    ///
    /// The `max_len` parameter specifies the maximum size of the payload.
    /// In case the payload is bigger than `max_len`, it will be truncated and the TC bit in the header will be set.
    pub fn into_bytes(mut self, max_len: u16) -> Vec<u8> {
        let qid = self.inner.header().id();

        let len = self.inner.as_slice().len();
        if len <= max_len as usize {
            return self.inner.into_octets();
        }

        tracing::debug!(%len, %max_len, %qid, domain = %self.domain(), "Truncating DNS response");

        self.inner.header_mut().set_tc(true);

        let start_of_answer = self.answer().pos();

        let mut bytes = self.inner.into_octets();
        bytes.truncate(start_of_answer);

        let headercounts = HeaderCounts::for_message_slice_mut(&mut bytes);

        // We deleted everything after answers, reset all counts to 0.
        headercounts.as_slice_mut().fill(0);

        // Set the question count to 1.
        headercounts.set_qdcount(1);

        bytes
    }

    fn question(&self) -> Question<ParsedName<&[u8]>> {
        self.inner.sole_question().expect("verified in ctor")
    }

    fn answer(&self) -> RecordSection<'_, Vec<u8>> {
        self.inner.answer().expect("verified in ctor")
    }
}

pub struct ResponseBuilder {
    inner: AnswerBuilder<Vec<u8>>,
}

impl ResponseBuilder {
    pub fn for_query(query: &Query, code: ResponseCode) -> Self {
        let inner = MessageBuilder::new_vec()
            .start_answer(&query.inner, code)
            .expect("Vec-backed message builder never fails");

        Self { inner }
    }

    pub fn with_records(mut self, records: impl IntoIterator<Item: Into<OwnedRecord>>) -> Self {
        for record in records {
            self.inner
                .push(record.into())
                .expect("Vec-backed message builder never fails");
        }

        self
    }

    pub fn build(self) -> Response {
        Response {
            inner: self.inner.into_message(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Bytes slice is too short to contain a message")]
    TooShort,
    #[error("DNS message is not a query")]
    NotAQuery,
    #[error("DNS message is not a response")]
    NotAResponse,
    #[error("HTTP response is not 200: {0} {1}")]
    HttpNotSuccess(http::StatusCode, String),
    #[error("HTTP response Content-Type is not application/dns-message")]
    NotApplicationDnsMessage,
    #[error(transparent)]
    Parse(#[from] domain::base::wire::ParseError),
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct DoHUrl(InnerUrl);

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum InnerUrl {
    KnownProvider(Provider),
    Other(Url),
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum Provider {
    Quad9,
    Google,
    Cloudflare,
    OpenDNS,
}

impl DoHUrl {
    const CLOUDFLARE_URL: &str = "https://cloudflare-dns.com/dns-query";
    const OPEN_DNS_URL: &str = "https://doh.opendns.com/dns-query";
    const QUAD9_URL: &str = "https://dns.quad9.net/dns-query";
    const GOOGLE_URL: &str = "https://dns.google/dns-query";

    pub fn quad9() -> Self {
        Self(InnerUrl::KnownProvider(Provider::Quad9))
    }

    pub fn google() -> Self {
        Self(InnerUrl::KnownProvider(Provider::Google))
    }

    pub fn cloudflare() -> Self {
        Self(InnerUrl::KnownProvider(Provider::Cloudflare))
    }

    pub fn opendns() -> Self {
        Self(InnerUrl::KnownProvider(Provider::OpenDNS))
    }

    pub fn host(&self) -> Cow<'static, str> {
        match &self.0 {
            InnerUrl::KnownProvider(Provider::Cloudflare) => Cow::Borrowed("cloudflare-dns.com"),
            InnerUrl::KnownProvider(Provider::OpenDNS) => Cow::Borrowed("doh.opendns.com"),
            InnerUrl::KnownProvider(Provider::Quad9) => Cow::Borrowed("dns.quad9.net"),
            InnerUrl::KnownProvider(Provider::Google) => Cow::Borrowed("dns.google"),
            InnerUrl::Other(url) => {
                Cow::Owned(url.host_str().expect("validated in ctor").to_owned())
            }
        }
    }

    pub fn to_str(&self) -> Cow<'static, str> {
        match &self.0 {
            InnerUrl::KnownProvider(Provider::Cloudflare) => Cow::Borrowed(Self::CLOUDFLARE_URL),
            InnerUrl::KnownProvider(Provider::OpenDNS) => Cow::Borrowed(Self::OPEN_DNS_URL),
            InnerUrl::KnownProvider(Provider::Quad9) => Cow::Borrowed(Self::QUAD9_URL),
            InnerUrl::KnownProvider(Provider::Google) => Cow::Borrowed(Self::GOOGLE_URL),
            InnerUrl::Other(url) => Cow::Owned(url.to_string()),
        }
    }
}

impl fmt::Display for DoHUrl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_str())
    }
}

impl fmt::Debug for DoHUrl {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_str())
    }
}

impl FromStr for DoHUrl {
    type Err = io::Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Efficient fast path for known DoH servers.
        let other = match s {
            Self::QUAD9_URL => return Ok(Self::quad9()),
            Self::CLOUDFLARE_URL => return Ok(Self::cloudflare()),
            Self::OPEN_DNS_URL => return Ok(Self::opendns()),
            Self::GOOGLE_URL => return Ok(Self::google()),
            other => other,
        };

        let url = Url::from_str(other).map_err(io::Error::other)?;

        if url.scheme() != "https" {
            return Err(io::Error::other("Only https scheme is allowed"));
        }

        if url.host().is_none() {
            return Err(io::Error::other("URL without host"));
        }

        if url.query().is_some() {
            return Err(io::Error::other("Query parameters are not allowed"));
        }

        Ok(Self(InnerUrl::Other(url)))
    }
}

impl<'de> Deserialize<'de> for DoHUrl {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de::Error;

        String::deserialize(deserializer)?
            .parse::<Self>()
            .map_err(D::Error::custom)
    }
}

impl Serialize for DoHUrl {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

pub mod records {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    use domain::rdata::{A, Aaaa, Ptr, Srv, Txt, rfc1035::TxtError};

    use super::*;

    pub fn ptr(domain: DomainName) -> OwnedRecordData {
        OwnedRecordData::Ptr(Ptr::new(domain))
    }

    pub fn a(ip: Ipv4Addr) -> OwnedRecordData {
        OwnedRecordData::A(A::new(ip))
    }

    pub fn aaaa(ip: Ipv6Addr) -> OwnedRecordData {
        OwnedRecordData::Aaaa(Aaaa::new(ip))
    }

    pub fn ip(ip: IpAddr) -> OwnedRecordData {
        match ip {
            IpAddr::V4(ip) => a(ip),
            IpAddr::V6(ip) => aaaa(ip),
        }
    }

    pub fn txt(content: Vec<u8>) -> Result<OwnedRecordData, TxtError> {
        Ok(OwnedRecordData::Txt(Txt::from_octets(content)?))
    }

    pub fn srv(priority: u16, weight: u16, port: u16, target: DomainName) -> OwnedRecordData {
        OwnedRecordData::Srv(Srv::new(priority, weight, port, target))
    }

    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "We explicitly only want A and AAAA records."
    )]
    pub fn extract_ip(r: Record<'_>) -> Option<IpAddr> {
        match r.into_data() {
            RecordData::A(a) => Some(a.addr().into()),
            RecordData::Aaaa(aaaa) => Some(aaaa.addr().into()),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    use http::{Method, header};

    use super::*;

    #[test]
    fn can_truncate_response() {
        let domain = DomainName::vec_from_str("example.com").unwrap();

        let query = Query::new(domain.clone(), RecordType::A);
        let response = ResponseBuilder::for_query(&query, ResponseCode::NOERROR)
            .with_records(std::iter::repeat_n(
                (domain.clone(), 1, records::a(Ipv4Addr::LOCALHOST)),
                1000,
            ))
            .build();

        let bytes = response.into_bytes(1000);

        let parsed_response = Response::parse(&bytes).unwrap();

        assert!(parsed_response.truncated());
        assert_eq!(parsed_response.records().count(), 0);
        assert_eq!(parsed_response.domain(), domain);
    }

    #[test]
    fn parse_host_from_known_url() {
        assert_eq!(DoHUrl::google().host(), "dns.google");
        assert_eq!(DoHUrl::cloudflare().host(), "cloudflare-dns.com");
        assert_eq!(DoHUrl::quad9().host(), "dns.quad9.net");
        assert_eq!(DoHUrl::opendns().host(), "doh.opendns.com");
    }

    #[test]
    fn url_and_host_are_consistent() {
        assert!(DoHUrl::CLOUDFLARE_URL.contains(DoHUrl::cloudflare().host().as_ref()));
        assert!(DoHUrl::GOOGLE_URL.contains(DoHUrl::google().host().as_ref()));
        assert!(DoHUrl::QUAD9_URL.contains(DoHUrl::quad9().host().as_ref()));
        assert!(DoHUrl::OPEN_DNS_URL.contains(DoHUrl::opendns().host().as_ref()));
    }

    #[test]
    fn parse_host_from_custom_url() {
        assert_eq!(
            "https://dnsserver.example.net/dns-query"
                .parse::<DoHUrl>()
                .unwrap()
                .host(),
            "dnsserver.example.net"
        );
    }

    // Test-vector from https://datatracker.ietf.org/doc/html/rfc8484#section-4.1.1
    #[test]
    fn can_encode_query_as_http_request() {
        let example_com = DomainName::vec_from_str("www.example.com.").unwrap();

        let query = Query::new(example_com, RecordType::A);

        let request = query
            .try_into_http_request(&"https://dnsserver.example.net/dns-query".parse().unwrap())
            .unwrap();

        assert_eq!(request.method(), Method::GET);
        assert_eq!(
            request.headers().get(header::ACCEPT).unwrap(),
            "application/dns-message"
        );
        assert_eq!(
            request.uri().query().unwrap(),
            "dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB"
        );
        assert_eq!(request.uri().path(), "/dns-query");
    }

    // Test-vector from https://datatracker.ietf.org/doc/html/rfc8484#section-4.2.2
    #[test]
    fn can_decode_http_response_as_response() {
        let response = http::Response::builder().status(200).header(header::CONTENT_TYPE, "application/dns-message")
            .header(header::CONTENT_LENGTH, 61)
            .body(Bytes::from_static(&hex_literal::hex!("00008180000100010000000003777777076578616d706c6503636f6d00001c0001c00c001c000100000e7d001020010db8abcd00120001000200030004")))
            .unwrap();

        let response = Response::try_from_http_response(response).unwrap();

        let ips = response
            .records()
            .filter_map(crate::records::extract_ip)
            .collect::<Vec<_>>();

        assert_eq!(
            ips,
            vec![IpAddr::V6(Ipv6Addr::new(
                0x2001, 0xdb8, 0xabcd, 0x12, 0x1, 0x2, 0x3, 0x4
            ))]
        );
        assert_eq!(
            response.ttl(RecordType::AAAA).unwrap(),
            Duration::from_secs(3709)
        )
    }
}
