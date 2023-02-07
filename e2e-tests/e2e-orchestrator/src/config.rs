use anyhow::Result;
use ipnet::IpNet;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    net::{Ipv4Addr, Ipv6Addr, SocketAddr},
    path::Path,
};

use crate::client::DeviceReq;

pub fn get_test_env(descriptor_path: impl AsRef<Path>) -> Result<EnvDescriptor> {
    let file_reader = File::open(descriptor_path.as_ref())?;
    Ok(serde_json::from_reader(file_reader)?)
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct EnvDescriptor {
    pub internals: Vec<InternalNodeDescriptor>,
    pub externals: Vec<ExternalNodeDescriptor>,
    pub externals_network: ExternalNetworkDescriptor,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ExternalNetworkDescriptor {
    pub ipv4: IpNet,
    pub ipv6: IpNet,
    pub ports: NetworkPorts,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NetworkPorts {
    pub min: u16,
    pub max: u16,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct InternalNodeDescriptor {
    pub name: String,
    pub control_url: Url,
    pub device: DeviceReq,
}

// TODO: unify descriptors
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct ExternalNodeDescriptor {
    pub name: String,
    pub control_url: Url,
    pub ipv4: SocketAddr,
    pub ipv6: SocketAddr,
}

pub trait Address<T> {
    fn address(&self) -> SocketAddr;
}

pub trait NetworkCidr<T> {
    fn cidr(&self) -> IpNet;
}

impl NetworkCidr<Ipv4Addr> for ExternalNetworkDescriptor {
    fn cidr(&self) -> IpNet {
        self.ipv4
    }
}

impl NetworkCidr<Ipv6Addr> for ExternalNetworkDescriptor {
    fn cidr(&self) -> IpNet {
        self.ipv6
    }
}

impl Address<Ipv4Addr> for ExternalNodeDescriptor {
    fn address(&self) -> SocketAddr {
        self.ipv4
    }
}

impl Address<Ipv6Addr> for ExternalNodeDescriptor {
    fn address(&self) -> SocketAddr {
        self.ipv6
    }
}
