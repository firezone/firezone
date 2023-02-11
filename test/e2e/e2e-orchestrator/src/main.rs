use std::{
    marker::PhantomData,
    net::{Ipv4Addr, Ipv6Addr},
};

use anyhow::Result;
use async_trait::async_trait;
use config::{Address, ExternalNetworkDescriptor, ExternalNodeDescriptor, NetworkCidr};
use test_setup::{try_send_message, TcpTest, TestProtocol, TestSetup, UdpTest};

mod client;
mod config;
mod node;
mod test_setup;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    TestRunner
        .run_test::<BasicTest<TcpTest, Ipv4Addr>>()
        .await?
        .run_test::<SingleClientAllowed<TcpTest, Ipv4Addr>>()
        .await?
        .run_test::<RangeTests<TcpTest, Ipv4Addr>>()
        .await?
        .run_test::<BasicTest<UdpTest, Ipv4Addr>>()
        .await?
        .run_test::<SingleClientAllowed<UdpTest, Ipv4Addr>>()
        .await?
        .run_test::<RangeTests<UdpTest, Ipv4Addr>>()
        .await?
        .run_test::<BasicTest<TcpTest, Ipv6Addr>>()
        .await?
        .run_test::<SingleClientAllowed<TcpTest, Ipv6Addr>>()
        .await?
        .run_test::<RangeTests<TcpTest, Ipv6Addr>>()
        .await?
        .run_test::<BasicTest<UdpTest, Ipv6Addr>>()
        .await?
        .run_test::<SingleClientAllowed<UdpTest, Ipv6Addr>>()
        .await?
        .run_test::<RangeTests<UdpTest, Ipv6Addr>>()
        .await?;

    Ok(())
}

struct TestRunner;

impl TestRunner {
    async fn run_test<T: Test>(self) -> Result<Self> {
        println!("Running test: {}\n\t{}", T::name(), T::description());
        match T::execute().await {
            Ok(_) => {
                println!("Test {} finished successfully", T::name());
                Ok(self)
            }
            Err(err) => {
                eprintln!("Test {} failed because: {}", T::name(), err);
                Err(err)
            }
        }
    }
}

#[async_trait]
trait Test {
    fn name() -> String;
    fn description() -> String;
    async fn execute() -> Result<()>;
}

struct BasicTest<T, U> {
    _phantom: PhantomData<(T, U)>,
}

#[async_trait]
impl<T: TestProtocol, U> Test for BasicTest<T, U>
where
    ExternalNodeDescriptor: Address<U>,
    ExternalNetworkDescriptor: NetworkCidr<U>,
    U: std::marker::Send + std::marker::Sync,
{
    fn name() -> String {
        format!("Basic {} test", T::protocol())
    }
    fn description() -> String {
        "Allow all clients through".to_string()
    }

    async fn execute() -> Result<()> {
        let mut setup = TestSetup::setup().await?;
        let protocol = T::protocol();
        let listener = setup.get_external_listener(protocol).await?;
        let sender_a = setup.get_sender_node().await?;
        let sender_b = setup.get_sender_node().await?;

        try_send_message(&sender_a, &listener, protocol)
            .await?
            .expect_fail()
            .await?;
        try_send_message(&sender_b, &listener, protocol)
            .await?
            .expect_fail()
            .await?;
        setup.allow_listener(&listener, protocol).await?;
        try_send_message(&sender_b, &listener, protocol)
            .await?
            .expect_success()
            .await?;
        try_send_message(&sender_a, &listener, protocol)
            .await?
            .expect_success()
            .await?;
        setup.cleanup().await?;
        Ok(())
    }
}

struct RangeTests<T, U> {
    _phantom: PhantomData<(T, U)>,
}

#[async_trait]
impl<T: TestProtocol, U> Test for RangeTests<T, U>
where
    ExternalNodeDescriptor: Address<U>,
    ExternalNetworkDescriptor: NetworkCidr<U>,
    U: std::marker::Send + std::marker::Sync,
{
    fn name() -> String {
        format!("{} Range Tests", T::protocol())
    }

    fn description() -> String {
        "Test allowing port-ranges and CIDRs through".to_string()
    }

    async fn execute() -> Result<()> {
        let mut setup = TestSetup::setup().await?;
        let protocol = T::protocol();
        let listener_a = setup.get_external_listener(protocol).await?;
        let listener_b = setup.get_external_listener(protocol).await?;
        let sender_a = setup.get_sender_node().await?;
        let sender_b = setup.get_sender_node().await?;

        try_send_message(&sender_a, &listener_a, protocol)
            .await?
            .expect_fail()
            .await?;
        try_send_message(&sender_a, &listener_b, protocol)
            .await?
            .expect_fail()
            .await?;
        try_send_message(&sender_b, &listener_a, protocol)
            .await?
            .expect_fail()
            .await?;
        try_send_message(&sender_b, &listener_b, protocol)
            .await?
            .expect_fail()
            .await?;
        setup.allow_network_listeners(protocol).await?;
        try_send_message(&sender_a, &listener_a, protocol)
            .await?
            .expect_success()
            .await?;
        try_send_message(&sender_a, &listener_b, protocol)
            .await?
            .expect_success()
            .await?;
        try_send_message(&sender_b, &listener_a, protocol)
            .await?
            .expect_success()
            .await?;
        try_send_message(&sender_b, &listener_b, protocol)
            .await?
            .expect_success()
            .await?;
        setup.cleanup().await?;
        Ok(())
    }
}

struct SingleClientAllowed<T, U> {
    _phantom_data: PhantomData<(T, U)>,
}

#[async_trait]
impl<T: TestProtocol, U> Test for SingleClientAllowed<T, U>
where
    ExternalNodeDescriptor: Address<U>,
    ExternalNetworkDescriptor: NetworkCidr<U>,
    U: std::marker::Send + std::marker::Sync,
{
    fn name() -> String {
        format!("Basic {} test", T::protocol())
    }

    fn description() -> String {
        "Allow only single client through".to_string()
    }

    async fn execute() -> Result<()> {
        let mut setup = TestSetup::setup().await?;
        let protocol = T::protocol();
        let listener = setup.get_external_listener(protocol).await?;
        let sender_a = setup.get_sender_node().await?;
        let sender_b = setup.get_sender_node().await?;

        try_send_message(&sender_a, &listener, protocol)
            .await?
            .expect_fail()
            .await?;
        try_send_message(&sender_b, &listener, protocol)
            .await?
            .expect_fail()
            .await?;
        setup
            .allow_sender_through_to_listener(&sender_a, &listener, protocol)
            .await?;
        try_send_message(&sender_b, &listener, protocol)
            .await?
            .expect_fail()
            .await?;
        try_send_message(&sender_a, &listener, protocol)
            .await?
            .expect_success()
            .await?;
        setup.cleanup().await?;
        Ok(())
    }
}
