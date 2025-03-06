#![cfg_attr(test, allow(clippy::unwrap_used))]

use domain::{
    base::{
        message_builder::AnswerBuilder, name::FlattenInto, HeaderCounts, Message, MessageBuilder,
        ParsedName, Question, RecordSection,
    },
    dep::octseq::OctetsInto,
    rdata::AllRecordData,
};

pub mod prelude {
    // Re-export trait names so other crates can call the functions on them.
    // We don't export the name though so that it cannot conflict.
    pub use domain::base::name::FlattenInto as _;
    pub use domain::base::RecordData as _;
    pub use domain::base::ToName as _;
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

#[derive(Clone)]
pub struct Query {
    inner: Message<Vec<u8>>,
}

impl std::fmt::Debug for Query {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Query")
            .field("qid", &self.inner.header().id())
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
    pub fn into_bytes(mut self, max_len: usize) -> Vec<u8> {
        let qid = self.inner.header().id();

        let len = self.inner.as_slice().len();
        if len <= max_len {
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
    #[error(transparent)]
    Parse(#[from] domain::base::wire::ParseError),
}

pub mod records {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    use domain::rdata::{rfc1035::TxtError, Aaaa, Ptr, Srv, Txt, A};

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
}

#[cfg(test)]
mod tests {
    use std::net::Ipv4Addr;

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
}
