use base64::{engine::general_purpose::STANDARD, Engine};
use secrecy::{CloneableSecret, ExposeSecret as _, SecretString, Zeroize};
use sha2::Digest as _;
use std::net::{Ipv4Addr, Ipv6Addr};
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

#[derive(Clone)]
pub struct LoginUrl {
    url: Url,

    // Invariant: Must stay the same as the host in `url`.
    // This is duplicated here because `Url::host` is fallible.
    // If we don't duplicate it, we'd have to do extra error handling in several places instead of just one place.
    host: String,
}

impl Zeroize for LoginUrl {
    fn zeroize(&mut self) {
        let placeholder = Url::parse("http://a.com")
            .expect("placeholder URL should always be valid, it's hard-coded");
        let _ = std::mem::replace(&mut self.url, placeholder);
    }
}

impl CloneableSecret for LoginUrl {}

impl LoginUrl {
    pub fn client<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: &SecretString,
        device_id: String,
        device_name: Option<String>,
        public_key: [u8; 32],
    ) -> std::result::Result<Self, LoginUrlError<E>> {
        let external_id = hex::encode(sha2::Sha256::digest(device_id));
        let device_name = device_name
            .or(get_host_name())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            firezone_token,
            "client",
            Some(public_key),
            Some(external_id),
            Some(device_name),
            None,
            None,
        )?;

        Ok(LoginUrl {
            host: parse_host(&url)?,
            url,
        })
    }

    pub fn gateway<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: &SecretString,
        device_id: String,
        device_name: Option<String>,
        public_key: [u8; 32],
    ) -> std::result::Result<Self, LoginUrlError<E>> {
        let external_id = hex::encode(sha2::Sha256::digest(device_id));
        let device_name = device_name
            .or(get_host_name())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            firezone_token,
            "gateway",
            Some(public_key),
            Some(external_id),
            Some(device_name),
            None,
            None,
        )?;

        Ok(LoginUrl {
            host: parse_host(&url)?,
            url,
        })
    }

    pub fn relay<E>(
        url: impl TryInto<Url, Error = E>,
        firezone_token: &SecretString,
        device_name: Option<String>,
        ipv4_address: Option<Ipv4Addr>,
        ipv6_address: Option<Ipv6Addr>,
    ) -> std::result::Result<Self, LoginUrlError<E>> {
        let url = get_websocket_path(
            url.try_into().map_err(LoginUrlError::InvalidUrl)?,
            firezone_token,
            "relay",
            None,
            None,
            device_name,
            ipv4_address,
            ipv6_address,
        )?;

        Ok(LoginUrl {
            host: parse_host(&url)?,
            url,
        })
    }

    // TODO: Only temporarily public until we delete other phoenix-channel impl.
    pub fn inner(&self) -> &Url {
        &self.url
    }

    // TODO: Only temporarily public until we delete other phoenix-channel impl.
    pub fn host(&self) -> &str {
        &self.host
    }
}

/// Parse the host from a URL, including port if present. e.g. `example.com:8080`.
fn parse_host<E>(url: &Url) -> Result<String, LoginUrlError<E>> {
    let host = url.host_str().ok_or(LoginUrlError::MissingHost)?;

    Ok(match url.port() {
        Some(p) => format!("{host}:{p}"),
        None => host.to_owned(),
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

#[allow(clippy::too_many_arguments)]
fn get_websocket_path<E>(
    mut api_url: Url,
    token: &SecretString,
    mode: &str,
    public_key: Option<[u8; 32]>,
    external_id: Option<String>,
    name: Option<String>,
    ipv4_address: Option<Ipv4Addr>,
    ipv6_address: Option<Ipv6Addr>,
) -> std::result::Result<Url, LoginUrlError<E>> {
    set_ws_scheme(&mut api_url)?;

    {
        let mut paths = api_url
            .path_segments_mut()
            .expect("scheme guarantees valid URL");

        paths.pop_if_empty();
        paths.push(mode);
        paths.push("websocket");
    }

    {
        let mut query_pairs = api_url.query_pairs_mut();
        query_pairs.clear();
        query_pairs.append_pair("token", token.expose_secret());

        if let Some(public_key) = public_key {
            query_pairs.append_pair("public_key", &STANDARD.encode(public_key));
        }
        if let Some(external_id) = external_id {
            query_pairs.append_pair("external_id", &external_id);
        }
        if let Some(name) = name {
            query_pairs.append_pair("name", &name);
        }
        if let Some(ipv4_address) = ipv4_address {
            query_pairs.append_pair("ipv4", &ipv4_address.to_string());
        }
        if let Some(ipv4_address) = ipv6_address {
            query_pairs.append_pair("ipv6", &ipv4_address.to_string());
        }
    }

    Ok(api_url)
}

fn set_ws_scheme<E>(url: &mut Url) -> std::result::Result<(), LoginUrlError<E>> {
    let scheme = match url.scheme() {
        "http" | "ws" => "ws",
        "https" | "wss" => "wss",
        other => return Err(LoginUrlError::InvalidUrlScheme(other.to_owned())),
    };

    url.set_scheme(scheme)
        .expect("Developer error: the match before this should make sure we can set this");

    Ok(())
}
