use base64::{Engine, engine::general_purpose::STANDARD};
use secrecy::SecretString;
use serde::Deserialize;
use sha2::Digest as _;
use std::{
    iter,
    marker::PhantomData,
    net::{Ipv4Addr, Ipv6Addr},
    str::FromStr as _,
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

    /// The authentication token, sent via X-Authorization header.
    token: SecretString,

    phantom: PhantomData<TFinish>,
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
        firezone_token: &SecretString,
        device_id: String,
        device_name: Option<String>,
        device_info: DeviceInfo,
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
            "client",
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
            token: firezone_token.clone(),
            phantom: PhantomData,
        })
    }

    pub fn gateway<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: &SecretString,
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
            token: firezone_token.clone(),
            phantom: PhantomData,
        })
    }
}

impl LoginUrl<NoParams> {
    pub fn relay<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: &SecretString,
        device_name: Option<String>,
        listen_port: u16,
        ipv4_address: Option<Ipv4Addr>,
        ipv6_address: Option<Ipv6Addr>,
    ) -> Result<Self, LoginUrlError<E>> {
        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            "relay",
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
            token: firezone_token.clone(),
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

    pub fn token(&self) -> &SecretString {
        &self.token
    }
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
            &SecretString::from("foobar"),
            "some-id".to_owned(),
            None,
            DeviceInfo::default(),
        )
        .unwrap();

        let base_url = login_url.base_url();

        assert_eq!(base_url, "wss://api.firez.one/")
    }
}
