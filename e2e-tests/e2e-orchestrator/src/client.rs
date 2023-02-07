use anyhow::{anyhow, Result};
use control_types::Protocol;
use ipnet::IpNet;
use reqwest::{
    header::{self, HeaderMap, AUTHORIZATION, CONTENT_TYPE},
    IntoUrl, Url,
};
use serde::{Deserialize, Serialize};
use std::{net::IpAddr, str::FromStr};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct FirezoneClient {
    client: reqwest::Client,
    url: Url,
}

impl FirezoneClient {
    pub fn new(api_token: String, url: impl IntoUrl) -> Result<Self> {
        let mut request_headers = HeaderMap::new();
        // could use bearer_auth
        let mut auth = header::HeaderValue::from_str(&format!("Bearer {api_token}")).unwrap();
        auth.set_sensitive(true);
        request_headers.insert(AUTHORIZATION, auth);

        request_headers.insert(CONTENT_TYPE, "application/json".parse().unwrap());

        let client = reqwest::Client::builder()
            .default_headers(request_headers)
            .build()?;
        Ok(Self {
            client,
            url: url.into_url()?,
        })
    }

    pub async fn get_rules(&self) -> Result<RuleList> {
        let response = self.client.get(self.get_rules_url()?).send().await?;
        Ok(response.json().await?)
    }

    pub async fn get_devices(&self) -> Result<DeviceList> {
        let response = self.client.get(self.get_devices_url()?).send().await?;
        Ok(response.json().await?)
    }

    pub async fn get_users(&self) -> Result<UserList> {
        let response = self.client.get(self.get_users_url()?).send().await?;
        Ok(response.json().await?)
    }

    pub async fn add_rule(&self, allow_rule: AllowRuleReq) -> Result<()> {
        let allow_rule_message = Message::AllowRule(allow_rule.clone());
        let response = self
            .client
            .post(self.get_rules_url()?)
            .json(&allow_rule_message)
            .send()
            .await?;

        response.error_for_status()?;

        if !self
            .get_rules()
            .await?
            .data
            .into_iter()
            .map(AllowRuleReq::from)
            .any(|r| r == allow_rule)
        {
            Err(anyhow!("Failed to add rule"))
        } else {
            Ok(())
        }
    }

    async fn delete_rule(&self, id: Uuid) -> Result<()> {
        let mut url = self.get_rules_url()?;
        add_path(&mut url, id.to_string())?;
        let response = self.client.delete(url).send().await?;
        response.error_for_status()?;
        if !self.get_rules().await?.data.into_iter().any(|r| r.id == id) {
            Ok(())
        } else {
            Err(anyhow!("Failed to delete rule"))
        }
    }

    pub async fn wipe_rules(&self) -> Result<()> {
        for rule in self.get_rules().await?.data {
            self.delete_rule(rule.id).await?;
        }
        if self.get_rules().await?.data.is_empty() {
            Ok(())
        } else {
            Err(anyhow!("Some rules were leftover"))
        }
    }

    pub async fn create_device(&self, device: DeviceReq) -> Result<()> {
        let device_message = Message::Device(device.clone());
        let response = self
            .client
            .post(self.get_devices_url()?)
            .json(&device_message)
            .send()
            .await?;

        response.error_for_status()?;

        if !self
            .get_devices()
            .await?
            .data
            .into_iter()
            .any(|d| d.public_key == device.public_key)
        {
            Err(anyhow!("Failed to add device"))
        } else {
            Ok(())
        }
    }

    pub async fn create_user(&self, user: UserReq) -> Result<UserResult> {
        let user_message = Message::User(user.clone());
        let response = self
            .client
            .post(self.get_users_url()?)
            .json(&user_message)
            .send()
            .await?;

        if !self
            .get_users()
            .await?
            .data
            .into_iter()
            .any(|u| u.email == user.email)
        {
            Err(anyhow!("Failed to add user"))
        } else {
            Ok(response.json().await?)
        }
    }

    pub async fn delete_user(&self, id: Uuid) -> Result<()> {
        let mut url = self.get_users_url()?;
        add_path(&mut url, id.to_string())?;
        let response = self.client.delete(url).send().await?;
        response.error_for_status()?;
        if !self.get_users().await?.data.into_iter().any(|u| u.id == id) {
            Ok(())
        } else {
            Err(anyhow!("Failed to delete user"))
        }
    }

    pub async fn delete_device(&self, id: Uuid) -> Result<()> {
        let mut url = self.get_devices_url()?;
        add_path(&mut url, id.to_string())?;
        let response = self.client.delete(url).send().await?;
        response.error_for_status()?;
        if !self
            .get_devices()
            .await?
            .data
            .into_iter()
            .any(|r| r.id == id)
        {
            Ok(())
        } else {
            Err(anyhow!("Failed to delete device"))
        }
    }

    pub async fn wipe_users(&self, exceptions: Vec<String>) -> Result<()> {
        for user in self
            .get_users()
            .await?
            .data
            .iter()
            .filter(|u| !exceptions.contains(&u.email))
        {
            self.delete_user(user.id).await?;
        }
        Ok(())
    }

    pub async fn wipe_devices(&self) -> Result<()> {
        for device in self.get_devices().await?.data {
            self.delete_device(device.id).await?;
        }
        Ok(())
    }

    fn get_users_url(&self) -> Result<Url> {
        self.get_endpoint("users")
    }

    fn get_devices_url(&self) -> Result<Url> {
        self.get_endpoint("devices")
    }

    fn get_rules_url(&self) -> Result<Url> {
        self.get_endpoint("allow_rules")
    }

    fn get_endpoint(&self, endpoint: &str) -> Result<Url> {
        let mut url = self.url.clone();
        add_path(&mut url, "v0")?;
        add_path(&mut url, endpoint)?;
        Ok(url)
    }
}

fn add_path(url: &mut Url, path: impl AsRef<str>) -> Result<()> {
    {
        let mut paths = url.path_segments_mut().map_err(|_| anyhow!("bad url"))?;
        paths.pop_if_empty();
        paths.push(path.as_ref());
    }
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct DeviceList {
    pub data: Vec<Device>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct UserList {
    pub data: Vec<User>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct UserResult {
    pub data: User,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct User {
    pub disable_at: Option<String>,
    pub email: String,
    pub id: Uuid,
    pub inserted_at: Option<String>,
    pub last_signed_in_at: Option<String>,
    pub last_signed_in_method: Option<String>,
    pub role: Option<String>,
    pub updated_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct UserReq {
    pub role: Option<String>,
    pub email: String,
    pub password: Option<String>,
    pub password_confirmation: Option<String>,
}

impl UserReq {
    pub fn from_email(email: String) -> Self {
        Self {
            email,
            role: None,
            password: None,
            password_confirmation: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub struct DeviceReq {
    // Format for allowed_ips and dns vec is not compliant with
    // JSON. Not worth it writing a custom parser.
    pub allowed_ips: Option<String>,
    pub description: Option<String>,
    pub dns: Option<String>,
    pub endpoint: Option<String>,
    pub ipv4: Option<Ip>,
    pub ipv6: Option<Ip>,
    pub name: Option<String>,
    pub public_key: String,
    pub user_id: Option<Uuid>,
    pub mtu: Option<u16>,
    pub persistent_keepalive: Option<u32>,
    pub preshared_key: Option<String>,
    pub use_default_allowed_ips: bool,
    pub use_default_dns: bool,
    pub use_default_endpoint: bool,
    pub use_default_mtu: bool,
    pub use_default_persistent_keepalive: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub struct Device {
    // Format for allowed_ips and dns vec is not compliant with
    // JSON. Not worth it writing a custom parser.
    pub allowed_ips: Option<String>,
    pub description: Option<String>,
    pub dns: Option<String>,
    pub endpoint: Option<String>,
    pub id: Uuid,
    pub ipv4: Option<Ip>,
    pub ipv6: Option<Ip>,
    pub name: Option<String>,
    pub public_key: String,
    pub user_id: Uuid,
    pub mtu: Option<u16>,
    pub persistent_keepalive: Option<u32>,
    pub preshared_key: Option<String>,
    pub use_default_allowed_ips: Option<bool>,
    pub use_default_dns: Option<bool>,
    pub use_default_endpoint: Option<bool>,
    pub use_default_mtu: Option<bool>,
    pub use_default_persistent_keepalive: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct RuleList {
    data: Vec<AllowRule>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Message {
    AllowRule(AllowRuleReq),
    Device(DeviceReq),
    User(UserReq),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(untagged)]
pub enum Ip {
    IpNet(IpNet),
    IpAddr(IpAddr),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ParseErr;

impl FromStr for Ip {
    type Err = ParseErr;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        if let Ok(ip) = IpAddr::from_str(s) {
            return Ok(Self::IpAddr(ip));
        }

        if let Ok(ip) = IpNet::from_str(s) {
            return Ok(Self::IpNet(ip));
        }

        Err(ParseErr)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AllowRuleReq {
    pub destination: Ip,
    pub port_range_start: Option<u16>,
    pub port_range_end: Option<u16>,
    pub protocol: Option<Protocol>,
    pub user_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct AllowRule {
    id: Uuid,
    destination: Ip,
    port_range_start: Option<u16>,
    port_range_end: Option<u16>,
    protocol: Option<Protocol>,
    user_id: Option<Uuid>,
}

impl From<AllowRule> for AllowRuleReq {
    fn from(value: AllowRule) -> Self {
        AllowRuleReq {
            destination: value.destination,
            port_range_start: value.port_range_start,
            port_range_end: value.port_range_end,
            protocol: value.protocol,
            user_id: value.user_id,
        }
    }
}
