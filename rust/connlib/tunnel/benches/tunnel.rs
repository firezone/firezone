use anyhow::Result;
use tracing_subscriber::EnvFilter;

fn main() -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_test_writer()
        .try_init();
    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(platform::perf())?;
    Ok(())
}

#[cfg(not(target_os = "windows"))]
mod platform {
    #[allow(clippy::unnecessary_wraps)]
    #[allow(clippy::unused_async)]
    pub(crate) async fn perf() -> anyhow::Result<()> {
        Ok(())
    }
}

/// Synthetic performance test
///
/// Echoes UDP packets between a local socket and the Wintun interface
#[cfg(target_os = "windows")]
mod platform {
    use anyhow::Result;
    use firezone_tunnel::Tun;
    use ip_packet::{IpPacket, Packet as _};
    use std::{
        future::poll_fn,
        net::{Ipv4Addr, Ipv6Addr},
        time::Duration,
    };
    use tokio::{
        net::UdpSocket,
        time::{timeout, Instant},
    };

    pub(crate) async fn perf() -> Result<()> {
        // Install wintun so the test can run
        let wintun_path = connlib_shared::windows::wintun_dll_path().unwrap();
        tokio::fs::create_dir_all(wintun_path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&wintun_path, connlib_shared::windows::wintun_bytes())
            .await
            .unwrap();

        let mut tun = Tun::new()?;

        const MTU: usize = 1_280;
        const NUM_REQUESTS: u64 = 1_000;
        const REQ_CODE: u8 = 42;
        const REQ_LEN: usize = 1_000;
        const RESP_CODE: u8 = 43;
        const SERVER_PORT: u16 = 3000;

        let ipv4 = Ipv4Addr::from([100, 90, 215, 97]);
        let ipv6 = Ipv6Addr::from([0xfd00, 0x2021, 0x1111, 0x0, 0x0, 0x0, 0x0016, 0x588f]);
        let mut device_manager =
            connlib_shared::tun_device_manager::platform::TunDeviceManager::new()?;
        device_manager.set_ips(ipv4, ipv6).await?;
        tun.add_route(ipv4.into())?;

        let server_addr = (ipv4, SERVER_PORT).into();

        // Listen for incoming packets on Wintun, and echo them.
        let server_task = tokio::spawn(async move {
            tracing::debug!("Server task entered");
            let mut requests_served = 0;
            // We aren't interested in allocator speed or doing any processing,
            // so just cache the response packet
            let mut response_pkt = None;
            let mut time_spent = Duration::from_millis(0);
            loop {
                let mut req_buf = [0u8; MTU];
                poll_fn(|cx| tun.poll_read(&mut req_buf, cx)).await?;
                let start = Instant::now();
                let original_pkt = IpPacket::new(&req_buf).unwrap();
                let Some(original_udp) = original_pkt.as_udp() else {
                    continue;
                };
                if original_udp.get_destination() != SERVER_PORT {
                    continue;
                }
                if original_udp.payload()[0] != REQ_CODE {
                    panic!("Wrong request code");
                }

                // Only generate the response packet on the first loop,
                // then just reuse it.
                let res_buf = response_pkt
                    .get_or_insert_with(|| {
                        ip_packet::make::udp_packet(
                            original_pkt.destination(),
                            original_pkt.source(),
                            original_udp.get_destination(),
                            original_udp.get_source(),
                            vec![RESP_CODE],
                        )
                    })
                    .packet();
                tun.write4(res_buf)?;
                requests_served += 1;
                time_spent += start.elapsed();
                if requests_served >= NUM_REQUESTS {
                    break;
                }
            }

            tracing::info!(?time_spent, "Server all good");
            Ok::<_, anyhow::Error>(())
        });

        // Wait for Wintun to be ready, then send it UDP packets and listen for
        // the echo.
        let client_task = tokio::spawn(async move {
            // We'd like to hit 100 Mbps up which is nothing special but it's a good
            // start.
            const EXPECTED_BITS_PER_SECOND: u64 = 100_000_000;
            // This has to be an `Option` because Windows takes about 4 seconds
            // to get the interface ready.
            let mut start_instant = None;

            tracing::debug!("Client task entered");
            let sock = UdpSocket::bind("0.0.0.0:0").await?;
            let mut responses_received = 0;
            let mut req_buf = vec![0u8; REQ_LEN];
            req_buf[0] = REQ_CODE;
            loop {
                let Ok(_) = sock.send_to(&req_buf, server_addr).await else {
                    // It seems to take a few seconds for Windows to set everything up.
                    tracing::warn!("Failed to send");
                    tokio::time::sleep(Duration::from_secs(1)).await;
                    continue;
                };
                start_instant.get_or_insert_with(Instant::now);
                let mut recv_buf = [0u8; MTU];
                let Ok((bytes_received, packet_src)) = sock.recv_from(&mut recv_buf).await else {
                    tracing::warn!("Timeout or couldn't recv packet");
                    continue;
                };
                if packet_src != server_addr {
                    tracing::warn!("Packet not from server");
                    continue;
                }
                assert_eq!(bytes_received, 1);
                assert_eq!(recv_buf[0], RESP_CODE);
                responses_received += 1;
                if responses_received >= NUM_REQUESTS {
                    break;
                }
            }

            let actual_dur = start_instant.unwrap().elapsed();
            // The 1_000_000 is needed to get decent precision without floats
            let actual_bps =
                NUM_REQUESTS * REQ_LEN as u64 * 8 * 1_000_000 / actual_dur.as_micros() as u64;
            assert!(
                actual_bps >= EXPECTED_BITS_PER_SECOND,
                "{:?} < {:?}",
                actual_bps,
                EXPECTED_BITS_PER_SECOND
            );
            tracing::info!(?actual_bps, "Client all good");
            Ok::<_, anyhow::Error>(())
        });

        timeout(Duration::from_secs(30), async move {
            client_task.await??;
            server_task.await??;
            Ok::<_, anyhow::Error>(())
        })
        .await??;

        Ok(())
    }
}
