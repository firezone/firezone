use std::{marker::PhantomData, sync::Arc, time::Duration};

use anyhow::{anyhow, Result};

use control_types::Protocol;
use tokio::sync::Mutex;

use crate::{
    client::{self, AllowRuleReq, FirezoneClient, Ip},
    config::{
        get_test_env, Address, ExternalNetworkDescriptor, ExternalNodeDescriptor, NetworkCidr,
    },
    node::{ExternalNodeWithDesc, InternalNodeWithDesc},
};

const API_TOKEN: &str = "API_TOKEN";
const URL: &str = "FZ_URL";
const TEST_ENV_PATH: &str = "TEST_ENV_PATH";
const ADMIN_MAIL: &str = "firezone@localhost";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug)]
pub struct TestSetup<T> {
    firezone_client: FirezoneClient,
    // We need multiple references to the structs here for cleanup
    // the mutex is just for the compiler to believe we don't mutate
    // (not going to use unsafecell or something unsafe here <_<)
    // Note the Mutex is tokio's 'coz it's going to be held across await points
    // but this is actually not necessary since we will use this synchroniously
    internal_nodes: Vec<Arc<Mutex<InternalNodeWithDesc>>>,
    external_nodes: Vec<Arc<Mutex<ExternalNodeWithDesc>>>,
    unused_internal_nodes: Vec<Arc<Mutex<InternalNodeWithDesc>>>,
    unused_external_nodes: Vec<Arc<Mutex<ExternalNodeWithDesc>>>,
    external_network_descriptor: ExternalNetworkDescriptor,
    _phantom_data: PhantomData<T>,
}

impl<T> TestSetup<T>
where
    ExternalNodeDescriptor: Address<T>,
    ExternalNetworkDescriptor: NetworkCidr<T>,
{
    pub async fn cleanup(&mut self) -> Result<()> {
        for internal_node in &self.internal_nodes {
            internal_node.lock().await.node.shutdown().await?;
        }

        for external_node in &self.external_nodes {
            external_node.lock().await.node.shutdown().await?;
        }

        Ok(())
    }

    pub async fn get_sender_node(&mut self) -> Result<Arc<Mutex<InternalNodeWithDesc>>> {
        self.unused_internal_nodes
            .pop()
            .ok_or_else(|| anyhow!("Not enough internal nodes for tests"))
    }

    pub async fn get_external_listener(
        &mut self,
        protocol: control_types::Protocol,
    ) -> Result<Arc<Mutex<ExternalNodeWithDesc>>> {
        let listener = self
            .unused_external_nodes
            .pop()
            .ok_or_else(|| anyhow!("Not enough internal nodes for tests"))?;
        {
            listener.lock().await.set_as_listener(protocol).await?;
        }
        Ok(listener)
    }

    pub async fn setup() -> Result<Self> {
        let test_env_path = std::env::var(TEST_ENV_PATH).unwrap_or_else(|_| {
            panic!("You need to provide a valid path to the environment descriptor")
        });
        let api_token = std::env::var(API_TOKEN).unwrap_or_else(|_| {
            panic!(
                "You need to create an api token to run the e2e tests in the env variable: {API_TOKEN}"
            )
        });
        let url = std::env::var(URL).unwrap_or_else(|_| {
            panic!("You need to provide the url of the portal in the env variable: {URL}")
        });
        let test_env_descriptor = get_test_env(test_env_path)?;
        let firezone_client = FirezoneClient::new(api_token, url)?;
        firezone_client.wipe_rules().await?;
        firezone_client.wipe_devices().await?;
        firezone_client
            .wipe_users(vec![ADMIN_MAIL.to_string()])
            .await?;
        let mut internal_nodes = Vec::new();
        for (i, desc) in test_env_descriptor.internals.into_iter().enumerate() {
            let user = firezone_client
                .create_user(client::UserReq::from_email(format!("user{i}@localhost")))
                .await?
                .data;
            let mut dev_req = desc.device.clone();
            dev_req.user_id = Some(user.id);
            firezone_client.create_device(dev_req).await?;
            let node = Arc::new(Mutex::new(
                InternalNodeWithDesc::from_descriptor(desc).await?,
            ));
            internal_nodes.push(node);
        }

        let mut external_nodes = Vec::new();
        for desc in test_env_descriptor.externals {
            let node = Arc::new(Mutex::new(
                ExternalNodeWithDesc::from_descriptor(desc).await?,
            ));
            external_nodes.push(node);
        }

        let unused_internal_nodes = internal_nodes.iter().cloned().collect();
        let unused_external_nodes = external_nodes.iter().cloned().collect();
        let external_network_descriptor = test_env_descriptor.externals_network;
        let _phantom_data = PhantomData {};

        Ok(TestSetup {
            firezone_client,
            internal_nodes,
            external_nodes,
            unused_internal_nodes,
            unused_external_nodes,
            external_network_descriptor,
            _phantom_data,
        })
    }

    pub async fn allow_listener(
        &self,
        listener: &Arc<Mutex<ExternalNodeWithDesc>>,
        protocol: Protocol,
    ) -> Result<()> {
        let listener = listener.lock().await;
        let listener_address = listener.descriptor.address();
        let listener_rule = AllowRuleReq {
            destination: Ip::IpAddr(listener_address.ip()),
            port_range_start: Some(listener_address.port()),
            port_range_end: Some(listener_address.port()),
            protocol: Some(protocol),
            user_id: None,
        };
        self.firezone_client.add_rule(listener_rule).await?;
        Ok(())
    }

    pub async fn allow_network_listeners(&self, protocol: Protocol) -> Result<()> {
        let destination = Ip::IpNet(self.external_network_descriptor.cidr());
        let port_range_start = Some(self.external_network_descriptor.ports.min);
        let port_range_end = Some(self.external_network_descriptor.ports.max);
        let rule = AllowRuleReq {
            destination,
            port_range_start,
            port_range_end,
            protocol: Some(protocol),
            user_id: None,
        };
        self.firezone_client.add_rule(rule).await?;
        Ok(())
    }

    pub async fn allow_sender_through_to_listener(
        &self,
        sender: &Arc<Mutex<InternalNodeWithDesc>>,
        listener: &Arc<Mutex<ExternalNodeWithDesc>>,
        protocol: Protocol,
    ) -> Result<()> {
        let listener = listener.lock().await;
        let sender = sender.lock().await;
        let user_id = self
            .firezone_client
            .get_devices()
            .await?
            .data
            .iter()
            .find_map(|dev| {
                if dev.public_key == sender.descriptor.device.public_key {
                    Some(dev.user_id)
                } else {
                    None
                }
            })
            .ok_or_else(|| {
                anyhow!("Sender doesn't exists in portal, probably need to create it")
            })?;
        let listener_address = listener.descriptor.address();
        let listener_rule = AllowRuleReq {
            destination: Ip::IpAddr(listener_address.ip()),
            port_range_start: Some(listener_address.port()),
            port_range_end: Some(listener_address.port()),
            protocol: Some(protocol),
            user_id: Some(user_id),
        };
        self.firezone_client.add_rule(listener_rule).await?;
        Ok(())
    }
}

#[derive(Debug)]
#[must_use]
pub enum MessageResult<'a, T> {
    Failure,
    Success(
        (
            &'a Arc<Mutex<ExternalNodeWithDesc>>,
            [u8; 16],
            Protocol,
            PhantomData<T>,
        ),
    ),
}

impl<'a, T> MessageResult<'a, T>
where
    ExternalNodeDescriptor: Address<T>,
{
    pub async fn expect_fail(self) -> Result<()> {
        match self {
            MessageResult::Failure => Ok(()),
            MessageResult::Success((listener, _, protocol, _)) => {
                if protocol == control_types::Protocol::Udp {
                    let mut listener = listener.lock().await;
                    let response =
                        tokio::time::timeout(CONNECT_TIMEOUT, listener.node.recv_response()).await;
                    if let Err(_) = response {
                        return Ok(());
                    }
                }
                Err(anyhow!(
                    "Expected message sent to fail however it succeeded"
                ))
            }
        }
    }

    pub async fn expect_success(self) -> Result<()> {
        match self {
            MessageResult::Success((listener, message, protocol, _)) => {
                let mut listener = listener.lock().await;
                let response = tokio::time::timeout(CONNECT_TIMEOUT, listener.node.recv_response())
                    .await???;
                if response == message {
                    listener.set_as_listener(protocol).await?;
                    Ok(())
                } else {
                    Err(anyhow!("Expected message differs from sent message"))
                }
            }
            MessageResult::Failure => Err(anyhow!(
                "Expected message sent to succeed however it failed"
            )),
        }
    }
}

pub async fn try_send_message<'a, T>(
    sender: &Arc<Mutex<InternalNodeWithDesc>>,
    listener: &'a Arc<Mutex<ExternalNodeWithDesc>>,
    protocol: control_types::Protocol,
) -> Result<MessageResult<'a, T>>
where
    ExternalNodeDescriptor: Address<T>,
{
    let message = rand::random::<[u8; 16]>();
    let result = {
        let mut sender = sender.lock().await;
        let listener = listener.lock().await;
        sender
            .send_msg(message.to_vec(), &listener.descriptor, protocol)
            .await?;
        sender.node.recv_response().await?
    };
    match result {
        Ok(_) => Ok(MessageResult::Success((
            listener,
            message,
            protocol,
            PhantomData {},
        ))),
        Err(_) => Ok(MessageResult::Failure),
    }
}

pub trait TestProtocol {
    fn protocol() -> Protocol;
}

pub struct TcpTest(());
pub struct UdpTest(());

impl TestProtocol for TcpTest {
    fn protocol() -> Protocol {
        Protocol::Tcp
    }
}

impl TestProtocol for UdpTest {
    fn protocol() -> Protocol {
        Protocol::Udp
    }
}
