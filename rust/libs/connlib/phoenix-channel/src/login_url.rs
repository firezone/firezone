use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use sha2::Digest as _;
use std::{
    iter,
    marker::PhantomData,
    net::{Ipv4Addr, Ipv6Addr},
    str::FromStr as _,
    sync::Arc,
};
use url::Url;
use uuid::Uuid;

// From https://man7.org/linux/man-pages/man2/gethostname.2.html
// SUSv2 guarantees that "Host names are limited to 255 bytes".
// POSIX.1 guarantees that "Host names (not including the
// terminating null byte) are limited to HOST_NAME_MAX bytes".  On
// Linux, HOST_NAME_MAX is defined with the value 64, which has been
// the limit since Linux 1.0 (earlier kernels imposed a limit of 8
// bytes)
//
// We are counting the nul-byte
#[cfg(not(target_os = "windows"))]
const HOST_NAME_MAX: usize = 256;

#[derive(Debug, Clone, Deserialize, Default)]
pub struct DeviceInfo {
    pub device_uuid: Option<String>,
    pub device_serial: Option<String>,
    pub identifier_for_vendor: Option<String>,
    pub firebase_installation_id: Option<String>,
}

#[derive(Clone)]
pub struct LoginUrl<TFinish> {
    url: Url,

    // Invariant: Must stay the same as the host in `url`.
    // This is duplicated here because `Url::host` is fallible.
    // If we don't duplicate it, we'd have to do extra error handling in several places instead of just one place.
    host: String,
    port: u16,

    certificate: Option<ClientCertificate>,

    phantom: PhantomData<TFinish>,
}

/// An X.509 client certificate presented to the portal during the TLS handshake.
///
/// Constructing a [`LoginUrl`] with a certificate dials the portal's mTLS endpoint instead of the regular one.
/// Platform code builds the [`rustls::ClientConfig`], typically with a certificate resolver backed by a keystore-managed, non-exportable private key, and hands it in here.
#[derive(Clone)]
pub struct ClientCertificate {
    pub tls_config: Arc<rustls::ClientConfig>,
}

#[derive(Debug, Clone)]
pub struct PublicKeyParam(pub [u8; 32]);

impl IntoIterator for PublicKeyParam {
    type Item = (&'static str, String);
    type IntoIter = std::iter::Once<Self::Item>;

    fn into_iter(self) -> Self::IntoIter {
        iter::once(("public_key", STANDARD.encode(self.0)))
    }
}

#[derive(Debug, Clone)]
pub struct NoParams;

impl IntoIterator for NoParams {
    type Item = (&'static str, String);
    type IntoIter = std::iter::Empty<Self::Item>;

    fn into_iter(self) -> Self::IntoIter {
        std::iter::empty()
    }
}

impl LoginUrl<PublicKeyParam> {
    pub fn client<E>(
        url: impl TryInto<Url, Error = E>,
        device_id: String,
        device_name: Option<String>,
        device_info: DeviceInfo,
        certificate: Option<ClientCertificate>,
    ) -> Result<Self, LoginUrlError<E>> {
        let mut url = url.try_into().map_err(LoginUrlError::InvalidUrl)?;

        if certificate.is_some() {
            set_mtls_host(&mut url);
        }

        let external_id = if uuid::Uuid::from_str(&device_id).is_ok() {
            hex::encode(sha2::Sha256::digest(device_id))
        } else {
            device_id
        };

        let device_name = device_name
            .or(get_host_name())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let url = get_websocket_path(
            url,
            "client",
            Some("v2"),
            Some(external_id),
            Some(device_name),
            None,
            None,
            None,
            device_info,
        )?;

        let (host, port) = parse_host(&url)?;

        Ok(LoginUrl {
            host,
            port,
            url,
            certificate,
            phantom: PhantomData,
        })
    }

    pub fn gateway<E>(
        url: impl TryInto<Url, Error = E>,
        device_id: String,
        device_name: Option<String>,
    ) -> Result<Self, LoginUrlError<E>> {
        let external_id = if uuid::Uuid::from_str(&device_id).is_ok() {
            hex::encode(sha2::Sha256::digest(device_id))
        } else {
            device_id
        };
        let device_name = device_name
            .or(get_host_name())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            "gateway",
            Some("v2"),
            Some(external_id),
            Some(device_name),
            None,
            None,
            None,
            Default::default(),
        )?;

        let (host, port) = parse_host(&url)?;

        Ok(LoginUrl {
            host,
            port,
            url,
            certificate: None,
            phantom: PhantomData,
        })
    }
}

impl LoginUrl<NoParams> {
    pub fn relay<E>(
        url: impl TryInto<Url, Error = E>,
        device_name: Option<String>,
        listen_port: u16,
        ipv4_address: Option<Ipv4Addr>,
        ipv6_address: Option<Ipv6Addr>,
    ) -> Result<Self, LoginUrlError<E>> {
        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            "relay",
            None,
            None,
            device_name,
            Some(listen_port),
            ipv4_address,
            ipv6_address,
            Default::default(),
        )?;

        let (host, port) = parse_host(&url)?;

        Ok(LoginUrl {
            host,
            port,
            url,
            certificate: None,
            phantom: PhantomData,
        })
    }
}

impl<TFinish> LoginUrl<TFinish>
where
    TFinish: IntoIterator<Item = (&'static str, String)>,
{
    pub fn to_url(&self, params: TFinish) -> Url {
        let mut url = self.url.clone();

        url.query_pairs_mut().extend_pairs(params);

        url
    }
}

impl<TFinish> LoginUrl<TFinish> {
    pub fn host_and_port(&self) -> (&str, u16) {
        (&self.host, self.port)
    }

    pub fn base_url(&self) -> String {
        let mut url = self.url.clone();

        url.set_path("");
        url.set_query(None);

        url.to_string()
    }

    pub(crate) fn tls_client_config(&self) -> Option<Arc<rustls::ClientConfig>> {
        let certificate = self.certificate.as_ref()?;

        Some(certificate.tls_config.clone())
    }
}

/// Replaces a SaaS API host with its mTLS counterpart, leaving other hosts untouched.
///
/// The portal requests a client certificate based on the host we dial, so presenting a certificate implies dialing the mTLS host.
fn set_mtls_host(url: &mut Url) {
    let mtls_host = match url.host_str() {
        Some("api.firez.one") => "mtls.firez.one",
        Some("api.firezone.dev") => "mtls.firezone.dev",
        _ => return,
    };

    url.set_host(Some(mtls_host))
        .expect("hard-coded hostname is valid");
}

/// Parse the host from a URL, including port if present. e.g. `example.com:8080`.
fn parse_host<E>(url: &Url) -> Result<(String, u16), LoginUrlError<E>> {
    let host = url.host_str().ok_or(LoginUrlError::MissingHost)?;

    Ok(match url.port() {
        Some(p) => (host.to_owned(), p),
        None => (host.to_owned(), 443),
    })
}

#[derive(Debug, thiserror::Error)]
pub enum LoginUrlError<E> {
    #[error("invalid scheme `{0}`; only http(s) and ws(s) are allowed")]
    InvalidUrlScheme(String),
    #[error("failed to parse URL: {0}")]
    InvalidUrl(E),
    #[error("the url is missing a host")]
    MissingHost,
}

#[cfg(not(target_os = "windows"))]
fn get_host_name() -> Option<String> {
    let mut buf = [0; HOST_NAME_MAX];
    // SAFETY: we just allocated a buffer with that size
    if unsafe { libc::gethostname(buf.as_mut_ptr() as *mut _, HOST_NAME_MAX) } != 0 {
        return None;
    }

    String::from_utf8(buf.split(|c| *c == 0).next()?.to_vec()).ok()
}

/// Returns the hostname, or `None` if it's not valid UTF-8
#[cfg(target_os = "windows")]
fn get_host_name() -> Option<String> {
    hostname::get().ok().and_then(|x| x.into_string().ok())
}

fn get_websocket_path<E>(
    mut api_url: Url,
    mode: &str,
    api_version: Option<&str>,
    external_id: Option<String>,
    name: Option<String>,
    port: Option<u16>,
    ipv4_address: Option<Ipv4Addr>,
    ipv6_address: Option<Ipv6Addr>,
    device_info: DeviceInfo,
) -> Result<Url, LoginUrlError<E>> {
    set_ws_scheme(&mut api_url)?;

    {
        let mut paths = api_url
            .path_segments_mut()
            .map_err(|_| LoginUrlError::MissingHost)?;

        paths.pop_if_empty();
        paths.push(mode);
        if let Some(api_version) = api_version {
            paths.push(api_version);
        }
        paths.push("websocket");
    }

    {
        let mut query_pairs = api_url.query_pairs_mut();
        query_pairs.clear();

        if let Some(external_id) = external_id {
            query_pairs.append_pair("external_id", &external_id);
        }
        if let Some(name) = name {
            query_pairs.append_pair("name", &name);
        }
        if let Some(ipv4_address) = ipv4_address {
            query_pairs.append_pair("ipv4", &ipv4_address.to_string());
        }
        if let Some(ipv6_address) = ipv6_address {
            query_pairs.append_pair("ipv6", &ipv6_address.to_string());
        }
        if let Some(port) = port {
            query_pairs.append_pair("port", &port.to_string());
        }
        if let Some(device_serial) = device_info.device_serial {
            query_pairs.append_pair("device_serial", &device_serial);
        }
        if let Some(device_uuid) = device_info.device_uuid {
            query_pairs.append_pair("device_uuid", &device_uuid);
        }
        if let Some(identifier_for_vendor) = device_info.identifier_for_vendor {
            query_pairs.append_pair("identifier_for_vendor", &identifier_for_vendor);
        }
        if let Some(firebase_installation_id) = device_info.firebase_installation_id {
            query_pairs.append_pair("firebase_installation_id", &firebase_installation_id);
        }
    }

    Ok(api_url)
}

fn set_ws_scheme<E>(url: &mut Url) -> Result<(), LoginUrlError<E>> {
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        other => return Err(LoginUrlError::InvalidUrlScheme(other.to_owned())),
    };

    url.set_scheme(scheme)
        .map_err(|_| LoginUrlError::InvalidUrlScheme(scheme.to_owned()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_url_removes_params_and_path() {
        let login_url = LoginUrl::client(
            "wss://api.firez.one",
            "some-id".to_owned(),
            None,
            DeviceInfo::default(),
            None,
        )
        .unwrap();

        let base_url = login_url.base_url();

        assert_eq!(base_url, "wss://api.firez.one/")
    }

    #[test]
    fn client_uses_v2_endpoint() {
        let login_url = LoginUrl::client(
            "wss://api.firez.one",
            "some-id".to_owned(),
            Some("some-name".to_owned()),
            DeviceInfo::default(),
            None,
        )
        .unwrap();

        assert_eq!(
            login_url.to_url(PublicKeyParam([0; 32])).path(),
            "/client/v2/websocket"
        )
    }

    #[test]
    fn client_with_certificate_uses_mtls_api_host() {
        let login_url = LoginUrl::client(
            "wss://api.firez.one:444",
            "some-id".to_owned(),
            Some("some-name".to_owned()),
            DeviceInfo::default(),
            Some(certificate()),
        )
        .unwrap();

        assert_eq!(login_url.host_and_port(), ("mtls.firez.one", 444));
        assert!(login_url.tls_client_config().is_some());
    }

    #[test]
    fn client_with_certificate_uses_mtls_staging_api_host() {
        let login_url = LoginUrl::client(
            "wss://api.firezone.dev",
            "some-id".to_owned(),
            Some("some-name".to_owned()),
            DeviceInfo::default(),
            Some(certificate()),
        )
        .unwrap();

        assert_eq!(login_url.host_and_port(), ("mtls.firezone.dev", 443));
    }

    #[test]
    fn client_with_certificate_keeps_custom_api_host() {
        let login_url = LoginUrl::client(
            "wss://portal.example.com",
            "some-id".to_owned(),
            Some("some-name".to_owned()),
            DeviceInfo::default(),
            Some(certificate()),
        )
        .unwrap();

        assert_eq!(login_url.host_and_port(), ("portal.example.com", 443));
        assert!(login_url.tls_client_config().is_some());
    }

    #[test]
    fn client_without_certificate_keeps_api_host() {
        let login_url = LoginUrl::client(
            "wss://api.firezone.dev",
            "some-id".to_owned(),
            Some("some-name".to_owned()),
            DeviceInfo::default(),
            None,
        )
        .unwrap();

        assert_eq!(login_url.host_and_port(), ("api.firezone.dev", 443));
        assert!(login_url.tls_client_config().is_none());
    }

    #[test]
    fn gateway_uses_v2_endpoint() {
        let login_url = LoginUrl::gateway(
            "wss://api.firez.one",
            "some-id".to_owned(),
            Some("some-name".to_owned()),
        )
        .unwrap();

        assert_eq!(
            login_url.to_url(PublicKeyParam([0; 32])).path(),
            "/gateway/v2/websocket"
        )
    }

    #[test]
    fn relay_keeps_unversioned_endpoint() {
        let login_url = LoginUrl::relay(
            "wss://api.firez.one",
            Some("some-name".to_owned()),
            3478,
            None,
            None,
        )
        .unwrap();

        assert_eq!(login_url.to_url(NoParams).path(), "/relay/websocket")
    }

    fn certificate() -> ClientCertificate {
        let tls_config = rustls::ClientConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();

        ClientCertificate {
            tls_config: Arc::new(tls_config),
        }
    }
}
