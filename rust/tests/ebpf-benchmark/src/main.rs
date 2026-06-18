//! Microbenchmark for the `handle_turn` XDP program.
//!
//! Loads the compiled eBPF object, populates the routing maps for a single IPv4
//! channel binding and measures the in-kernel processing cost of the two IPv4
//! data paths via `bpftool prog run` (`BPF_PROG_TEST_RUN`):
//!
//! - `forward`: IPv4 UDP -> IPv4 ChannelData (the program prepends the 4-byte channel-data header)
//! - `reverse`: IPv4 ChannelData -> IPv4 UDP (the program strips the channel-data header)
//!
//! See `README.md` for prerequisites (root, `bpftool`, the pinned nightly toolchain).

#[cfg(not(target_os = "linux"))]
#[expect(
    clippy::print_stderr,
    reason = "fallback message on unsupported platforms"
)]
fn main() {
    eprintln!("ebpf-benchmark only runs on Linux (needs BPF_PROG_TEST_RUN and bpftool).");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::main()
}

#[cfg(target_os = "linux")]
mod linux {
    use std::{
        net::{Ipv4Addr, Ipv6Addr, SocketAddrV4},
        os::unix::process::CommandExt as _,
        path::{Path, PathBuf},
        process::Command,
    };

    use anyhow::{Context as _, Result, anyhow, bail};
    use aya::{
        Ebpf, Pod,
        maps::{HashMap, PerCpuArray, PerCpuValues},
        programs::Xdp,
    };
    use ebpf_shared::{ClientAndChannelV4, PortAndPeerV4};
    use etherparse::PacketBuilder;

    /// The relay client (data-channel side). Its port is the UDP source on the channel-data leg.
    const CLIENT: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(100, 64, 0, 2), 51820);
    /// The peer (plain-UDP side). Its port is the UDP source on the allocation leg.
    const PEER: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::new(192, 0, 2, 10), 7777);
    /// The allocation port; must be within the TURN range (49152..=65535).
    const ALLOCATION_PORT: u16 = 49152;
    /// The channel number; must be within the ChannelData range (0x4000..=0x7FFF).
    const CHANNEL: u16 = 0x4000;
    /// The relay's own addresses. Both must be set and distinct from `PEER`'s IP so that
    /// `is_own_public_ip` returns `false` and the reverse path takes the plain-UDP branch.
    const PUBLIC_V4: Ipv4Addr = Ipv4Addr::new(198, 51, 100, 1);
    const PUBLIC_V6: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1);

    const MAC_SRC: [u8; 6] = [0x02, 0, 0, 0, 0, 1];
    const MAC_DST: [u8; 6] = [0x02, 0, 0, 0, 0, 2];

    const TURN_PORT: u16 = 3478;
    const XDP_TX: u32 = 3;

    /// The largest payload the relay ever forwards: a full-MTU WireGuard packet.
    const MAX_RELAYED: usize = ip_packet::MAX_IP_SIZE + ip_packet::WG_OVERHEAD;

    #[derive(clap::Parser)]
    #[command(about = "Benchmark the `handle_turn` XDP program via `bpftool prog run`.")]
    struct Args {
        /// Kernel-side repetitions per `bpftool prog run` invocation (averaged in-kernel).
        #[arg(long, default_value_t = 1_000_000)]
        repeat: u32,
        /// Number of `bpftool prog run` invocations per case; the median is reported.
        #[arg(long, default_value_t = 10)]
        invocations: u32,
        /// Relayed-payload sizes (bytes), comma-separated. Defaults to a spread up to the Firezone max.
        #[arg(long, value_delimiter = ',')]
        sizes: Vec<usize>,
        /// Which direction(s) to benchmark.
        #[arg(long, value_enum, default_value_t = Direction::Both)]
        direction: Direction,
        /// Path to the `bpftool` binary.
        #[arg(long, default_value = "bpftool")]
        bpftool: String,
        /// Emit CSV instead of a table.
        #[arg(long)]
        csv: bool,
        /// Skip the discarded warmup invocation before each case.
        #[arg(long)]
        no_warmup: bool,
    }

    #[derive(Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
    enum Direction {
        Forward,
        Reverse,
        Both,
    }

    impl Direction {
        fn cases(self) -> &'static [Case] {
            match self {
                Direction::Forward => &[Case::Forward],
                Direction::Reverse => &[Case::Reverse],
                Direction::Both => &[Case::Forward, Case::Reverse],
            }
        }
    }

    #[derive(Clone, Copy)]
    enum Case {
        Forward,
        Reverse,
    }

    impl Case {
        fn name(self) -> &'static str {
            match self {
                Case::Forward => "fwd (UDP->chan)",
                Case::Reverse => "rev (chan->UDP)",
            }
        }

        /// Builds the input Ethernet frame for a given relayed-payload size.
        fn frame(self, relayed: usize) -> Result<Vec<u8>> {
            match self {
                Case::Forward => forward_frame(relayed),
                Case::Reverse => reverse_frame(relayed),
            }
        }
    }

    pub fn main() -> Result<()> {
        let args = <Args as clap::Parser>::parse();

        reexec_as_root()?;

        let sizes = sizes(&args.sizes)?;

        let mut ebpf = Ebpf::load(aya::include_bytes_aligned!(concat!(
            env!("OUT_DIR"),
            "/ebpf-turn-router-main"
        )))
        .context("failed to load eBPF object")?;

        let program: &mut Xdp = ebpf
            .program_mut("handle_turn")
            .context("program `handle_turn` not found")?
            .try_into()?;
        program.load().context("failed to load `handle_turn`")?;
        let prog_id = program.info().context("failed to read program info")?.id();

        populate_maps(&mut ebpf)?;

        let mut rows = Vec::new();

        for &case in args.direction.cases() {
            verify(&args.bpftool, prog_id, case)?;

            for &relayed in &sizes {
                let frame = case.frame(relayed)?;
                let durations = measure(&args, prog_id, &frame)?;
                rows.push(Row::new(case, relayed, frame.len(), &durations));
            }
        }

        report(&rows, args.csv);

        Ok(())
    }

    /// Re-exec under `sudo` when not already root.
    ///
    /// Loading the program and `BPF_PROG_TEST_RUN` require `CAP_BPF`/`CAP_PERFMON`, so the
    /// benchmark elevates itself — `cargo run -p ebpf-benchmark` works without a manual `sudo`.
    fn reexec_as_root() -> Result<()> {
        // SAFETY: `geteuid` has no preconditions and is always safe to call.
        if unsafe { libc::geteuid() } == 0 {
            return Ok(());
        }

        let exe = std::env::current_exe().context("failed to resolve current executable")?;

        // `exec` replaces the process image and only returns if it fails.
        let error = Command::new("sudo")
            .arg("--preserve-env=PATH")
            .arg(exe)
            .args(std::env::args_os().skip(1))
            .exec();

        bail!("failed to re-exec under sudo: {error}")
    }

    /// Inserts the IPv4 channel binding (populating both lookup directions) and the public addresses.
    fn populate_maps(ebpf: &mut Ebpf) -> Result<()> {
        let cc = ClientAndChannelV4::new(*CLIENT.ip(), CLIENT.port(), CHANNEL);
        let pp = PortAndPeerV4::new(*PEER.ip(), ALLOCATION_PORT, PEER.port());

        HashMap::<_, ClientAndChannelV4, PortAndPeerV4>::try_from(
            ebpf.map_mut("CHAN_TO_UDP_44")
                .context("CHAN_TO_UDP_44 not found")?,
        )?
        .insert(cc, pp, 0)?;
        HashMap::<_, PortAndPeerV4, ClientAndChannelV4>::try_from(
            ebpf.map_mut("UDP_TO_CHAN_44")
                .context("UDP_TO_CHAN_44 not found")?,
        )?
        .insert(pp, cc, 0)?;

        set_per_cpu(ebpf, "PUBLIC_ADDR_V4", PUBLIC_V4.octets())?;
        set_per_cpu(ebpf, "PUBLIC_ADDR_V6", PUBLIC_V6.octets())?;

        Ok(())
    }

    fn set_per_cpu<T: Pod + Clone>(ebpf: &mut Ebpf, name: &str, value: T) -> Result<()> {
        let map = ebpf
            .map_mut(name)
            .with_context(|| format!("`{name}` not found"))?;
        let mut per_cpu: PerCpuArray<_, T> = PerCpuArray::try_from(map)?;
        let num_cpus = aya::util::nr_cpus()
            .map_err(|(_, e)| anyhow!("failed to determine number of CPUs: {e}"))?;
        per_cpu
            .set(0, PerCpuValues::try_from(vec![value; num_cpus])?, 0)
            .with_context(|| format!("failed to set `{name}`"))?;

        Ok(())
    }

    /// Runs the case once, asserts `XDP_TX` and that the output packet was transformed as expected.
    fn verify(bpftool: &str, prog_id: u32, case: Case) -> Result<()> {
        let relayed = 512;
        let frame = case.frame(relayed)?;
        let (data_in, data_out) = temp_paths();
        std::fs::write(&data_in, &frame)?;

        let (retval, _) = run(bpftool, prog_id, &data_in, &data_out, 1)?;
        if retval != XDP_TX {
            bail!(
                "{}: expected XDP_TX ({XDP_TX}) but got {retval} - maps/config not set up correctly",
                case.name()
            );
        }

        let out = std::fs::read(&data_out)?;
        let parsed = etherparse::SlicedPacket::from_ethernet(&out)
            .with_context(|| format!("{}: failed to parse output frame", case.name()))?;
        let Some(etherparse::TransportSlice::Udp(udp)) = parsed.transport else {
            bail!("{}: output is not UDP", case.name());
        };

        let (exp_src, exp_dst, exp_len) = match case {
            Case::Forward => (TURN_PORT, CLIENT.port(), frame.len() + 4),
            Case::Reverse => (ALLOCATION_PORT, PEER.port(), frame.len() - 4),
        };
        if udp.source_port() != exp_src || udp.destination_port() != exp_dst {
            bail!(
                "{}: unexpected output ports {}->{} (want {exp_src}->{exp_dst})",
                case.name(),
                udp.source_port(),
                udp.destination_port()
            );
        }
        if out.len() != exp_len {
            bail!(
                "{}: unexpected output length {} (want {exp_len})",
                case.name(),
                out.len()
            );
        }

        Ok(())
    }

    /// Returns the per-invocation average durations (ns) for `invocations` runs, asserting `XDP_TX` each time.
    fn measure(args: &Args, prog_id: u32, frame: &[u8]) -> Result<Vec<u64>> {
        let (data_in, data_out) = temp_paths();
        std::fs::write(&data_in, frame)?;

        if !args.no_warmup {
            run(&args.bpftool, prog_id, &data_in, &data_out, args.repeat)?;
        }

        let mut durations = Vec::with_capacity(args.invocations as usize);
        for _ in 0..args.invocations {
            let (retval, duration) = run(&args.bpftool, prog_id, &data_in, &data_out, args.repeat)?;
            if retval != XDP_TX {
                bail!("expected XDP_TX ({XDP_TX}) but got {retval}");
            }
            durations.push(duration);
        }

        Ok(durations)
    }

    /// Invokes `bpftool prog run` and returns `(retval, average_duration_ns)`.
    fn run(
        bpftool: &str,
        prog_id: u32,
        data_in: &Path,
        data_out: &Path,
        repeat: u32,
    ) -> Result<(u32, u64)> {
        let output = Command::new(bpftool)
            .args(["--json", "prog", "run", "id"])
            .arg(prog_id.to_string())
            .arg("data_in")
            .arg(data_in)
            .arg("data_out")
            .arg(data_out)
            .arg("repeat")
            .arg(repeat.to_string())
            .output()
            .with_context(|| format!("failed to spawn `{bpftool}`"))?;

        if !output.status.success() {
            bail!(
                "`bpftool prog run` failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }

        parse(&output.stdout, &output.stderr)
    }

    /// Parses `retval` and `duration` (ns) from bpftool's output, preferring its JSON form.
    fn parse(stdout: &[u8], stderr: &[u8]) -> Result<(u32, u64)> {
        if let Ok(value) = serde_json::from_slice::<serde_json::Value>(stdout)
            && let (Some(retval), Some(duration)) = (
                value.get("retval").and_then(serde_json::Value::as_u64),
                value.get("duration").and_then(serde_json::Value::as_u64),
            )
        {
            return Ok((retval as u32, duration));
        }

        // Older bpftool builds print e.g. "Return value: 3, duration (average): 24ns".
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(stdout),
            String::from_utf8_lossy(stderr)
        )
        .to_lowercase();

        let retval = uint_after(&text, "value").context("could not parse bpftool return value")?;
        let duration = uint_after(&text, "duration").context("could not parse bpftool duration")?;

        Ok((retval as u32, duration))
    }

    /// Finds `marker`, then parses the first run of digits that follows it.
    fn uint_after(text: &str, marker: &str) -> Option<u64> {
        let rest = &text[text.find(marker)? + marker.len()..];
        let digits = rest
            .trim_start_matches(|c: char| !c.is_ascii_digit())
            .chars()
            .take_while(char::is_ascii_digit)
            .collect::<String>();

        digits.parse().ok()
    }

    fn forward_frame(relayed: usize) -> Result<Vec<u8>> {
        // Plain UDP from the peer to the allocation port; payload is the relayed WireGuard packet.
        write_frame(*PEER.ip(), PEER.port(), ALLOCATION_PORT, &payload(relayed))
    }

    fn reverse_frame(relayed: usize) -> Result<Vec<u8>> {
        // ChannelData from the client to the TURN port; UDP payload is the channel-data header + relayed packet.
        let mut udp_payload = Vec::with_capacity(4 + relayed);
        udp_payload.extend_from_slice(&CHANNEL.to_be_bytes());
        udp_payload.extend_from_slice(&(relayed as u16).to_be_bytes());
        udp_payload.extend_from_slice(&payload(relayed));

        write_frame(*CLIENT.ip(), CLIENT.port(), TURN_PORT, &udp_payload)
    }

    fn write_frame(
        src: Ipv4Addr,
        src_port: u16,
        dst_port: u16,
        udp_payload: &[u8],
    ) -> Result<Vec<u8>> {
        let builder = PacketBuilder::ethernet2(MAC_SRC, MAC_DST)
            .ipv4(src.octets(), PUBLIC_V4.octets(), 64)
            .udp(src_port, dst_port);

        let mut frame = Vec::with_capacity(builder.size(udp_payload.len()));
        builder
            .write(&mut frame, udp_payload)
            .context("failed to build packet")?;

        Ok(frame)
    }

    fn payload(len: usize) -> Vec<u8> {
        vec![0xAB; len]
    }

    fn temp_paths() -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir();
        let pid = std::process::id();
        (
            dir.join(format!("ebpf-bench-in-{pid}.bin")),
            dir.join(format!("ebpf-bench-out-{pid}.bin")),
        )
    }

    /// The default size sweep, capped at what Firezone actually transmits.
    fn sizes(requested: &[usize]) -> Result<Vec<usize>> {
        let mut sizes = if requested.is_empty() {
            vec![
                32,
                64,
                128,
                256,
                512,
                1024,
                ip_packet::MAX_IP_SIZE,
                MAX_RELAYED,
            ]
        } else {
            requested.to_vec()
        };
        sizes.retain(|&s| s <= MAX_RELAYED);
        sizes.sort_unstable();
        sizes.dedup();

        if sizes.is_empty() {
            bail!("no sizes to benchmark (max relayed payload is {MAX_RELAYED} bytes)");
        }

        Ok(sizes)
    }

    struct Row {
        case: &'static str,
        relayed: usize,
        frame: usize,
        median: u64,
        min: u64,
        max: u64,
    }

    impl Row {
        fn new(case: Case, relayed: usize, frame: usize, durations: &[u64]) -> Self {
            let mut sorted = durations.to_vec();
            sorted.sort_unstable();

            Self {
                case: case.name(),
                relayed,
                frame,
                median: sorted[sorted.len() / 2],
                min: sorted[0],
                max: sorted[sorted.len() - 1],
            }
        }

        fn mpps(&self) -> f64 {
            if self.median == 0 {
                return f64::INFINITY;
            }
            1_000.0 / self.median as f64
        }

        fn gbps(&self) -> f64 {
            if self.median == 0 {
                return f64::INFINITY;
            }
            (self.frame * 8) as f64 / self.median as f64
        }
    }

    #[expect(
        clippy::print_stdout,
        reason = "the benchmark prints its results to stdout"
    )]
    fn report(rows: &[Row], csv: bool) {
        if csv {
            println!("direction,relayed_bytes,frame_bytes,ns_median,ns_min,ns_max,mpps,gbps");
            for r in rows {
                println!(
                    "{},{},{},{},{},{},{:.3},{:.3}",
                    r.case,
                    r.relayed,
                    r.frame,
                    r.median,
                    r.min,
                    r.max,
                    r.mpps(),
                    r.gbps()
                );
            }
            return;
        }

        println!(
            "{:<16} {:>8} {:>7} {:>11} {:>7} {:>7} {:>9} {:>8}",
            "direction", "relayed", "frame", "ns/pkt(med)", "min", "max", "Mpps", "Gbps"
        );
        for r in rows {
            println!(
                "{:<16} {:>8} {:>7} {:>11} {:>7} {:>7} {:>9.2} {:>8.2}",
                r.case,
                r.relayed,
                r.frame,
                r.median,
                r.min,
                r.max,
                r.mpps(),
                r.gbps()
            );
        }
    }
}
