# TURN Relay eBPF Performance Testing Framework

This directory contains bash-based performance testing tools for the eBPF TURN relay router.

## Overview

The test framework allows you to:
- Populate eBPF maps with test channel bindings
- Generate channel data and UDP packets
- Test all 8 relay scenarios (IPv4/IPv6 combinations)
- Measure throughput and packets-per-second (PPS)

## Prerequisites

Required tools:
- `bpftool` - For manipulating eBPF maps
- `nc` (netcat) - For sending/receiving packets
- `tcpdump` - For packet capture and analysis
- `bc` - For calculations
- `dd` - For generating payload data
- `python3` - For IPv6 address conversion (in map_populate.sh)

Optional tools for better monitoring:
- `pv` - For progress visualization
- `bmon`, `iftop`, or `nload` - For real-time monitoring

## Test Scenarios

The framework tests 8 scenarios:

1. **IPv4 → IPv4 Channel → UDP**: Client sends channel data, gateway receives UDP
2. **IPv4 → IPv4 UDP → Channel**: Gateway sends UDP, client receives channel data
3. **IPv6 → IPv6 Channel → UDP**: IPv6 client to IPv6 gateway
4. **IPv6 → IPv6 UDP → Channel**: IPv6 gateway to IPv6 client
5. **IPv4 → IPv6 Channel → UDP**: IPv4 client to IPv6 gateway (cross-stack)
6. **IPv4 → IPv6 UDP → Channel**: IPv6 gateway to IPv4 client (cross-stack)
7. **IPv6 → IPv4 Channel → UDP**: IPv6 client to IPv4 gateway (cross-stack)
8. **IPv6 → IPv4 UDP → Channel**: IPv4 gateway to IPv6 client (cross-stack)

## Usage

### Setup eBPF Relay

The relay must be running with eBPF offloading enabled on the correct interface:

```bash
# For testing on physical interface (e.g., enp1s0) - supports driver mode
EBPF_OFFLOADING=enp1s0 ./relay

# For CI testing with network namespaces (after setting up namespaces) - requires generic mode
EBPF_OFFLOADING=relay-bridge EBPF_ATTACH_MODE=generic ./relay

# For local testing on loopback - requires generic mode
EBPF_OFFLOADING=lo EBPF_ATTACH_MODE=generic ./relay
```

**Important**: Bridge interfaces and loopback only support XDP in generic (SKB) mode, not driver mode. Physical NICs may support driver mode for better performance.

### Quick Test

Run a quick IPv4-to-IPv4 test:
```bash
./run_all_tests.sh quick
```

### Network Namespace Test (CI-friendly)

Run tests using isolated network namespaces:
```bash
# Setup namespaces and run tests
sudo ./run_all_tests.sh netns

# Or manually:
sudo ./setup_netns.sh setup
sudo ./test_netns.sh test
sudo ./setup_netns.sh cleanup
```

### Full Test Suite

Run all scenarios with multiple payload sizes:
```bash
sudo ./run_all_tests.sh full
```

### Individual Tests

Test specific scenarios:
```bash
# IPv4 to IPv4
sudo ./test_ipv4_to_ipv4.sh

# IPv6 to IPv6
sudo ./test_ipv6_to_ipv6.sh

# Cross-stack tests
sudo ./test_ipv4_to_ipv6.sh
sudo ./test_ipv6_to_ipv4.sh
```

### Custom Configuration

Set environment variables to customize tests:
```bash
# Custom payload size and packet count
PAYLOAD_SIZE=1500 PACKET_COUNT=50000 sudo ./test_ipv4_to_ipv4.sh

# Custom payload sizes for full suite
PAYLOAD_SIZES="64 512 1400" sudo ./run_all_tests.sh full
```

### Manual Testing

1. **Start the relay with eBPF** (from the relay directory):
```bash
cd ../server
cargo build --release

# Start relay with eBPF on desired interface
# For physical NICs (driver mode):
EBPF_OFFLOADING=<interface> cargo run --release

# For virtual interfaces, bridges, or loopback (generic mode):
EBPF_OFFLOADING=<interface> EBPF_ATTACH_MODE=generic cargo run --release

# Or for testing:
EBPF_OFFLOADING=lo EBPF_ATTACH_MODE=generic cargo test --test ebpf_ipv4
```

2. **Populate eBPF maps**:
```bash
# Setup IPv4 to IPv4 channel binding
sudo ./map_populate.sh ipv4

# Setup all bindings
sudo ./map_populate.sh all
```

3. **Send packets**:
```bash
# Send channel data (client side)
./packet_gen.sh --mode channel-to-udp --size 1000 --count 10000

# Send UDP packets (gateway side)
./packet_gen.sh --mode udp-to-channel --size 1000 --count 10000
```

4. **Measure performance**:
```bash
# Using tcpdump
sudo ./measure_perf.sh tcpdump 52626

# Real-time monitoring
sudo ./measure_perf.sh realtime 52626
```

## Configuration

Default ports and addresses:
- **Relay IP (IPv4)**: 127.0.0.1
- **Relay IP (IPv6)**: ::1
- **Client Port**: 52625
- **Gateway Port**: 52626
- **TURN Port**: 3478
- **Allocation Port**: 50000
- **Channel Number**: 0x4000 (16384)

## Output

Test results are saved in the `results/` directory with timestamps:
- `perf_test_YYYYMMDD_HHMMSS.txt` - Detailed test output
- `summary_YYYYMMDD_HHMMSS.txt` - Summary of key metrics

## CI/Automated Testing

For CI environments, use network namespaces to create isolated test environments:

```bash
# Complete CI test workflow
sudo ./setup_netns.sh setup                                      # Create namespaces
EBPF_OFFLOADING=relay-bridge EBPF_ATTACH_MODE=generic ./relay &  # Start relay on bridge (generic mode required)
RELAY_PID=$!
sleep 2
sudo ./test_netns.sh test                                        # Run namespace tests
kill $RELAY_PID
sudo ./setup_netns.sh cleanup                                    # Cleanup namespaces
```

**Note**: The `EBPF_ATTACH_MODE=generic` is required for virtual interfaces like bridges and veth pairs. Only physical NICs support driver mode.

## Troubleshooting

1. **"eBPF TURN router program not loaded"**
   - Ensure the relay is running with `EBPF_OFFLOADING` set
   - Check with: `sudo bpftool prog show | grep handle_turn`
   - Verify interface: `ip link show | grep xdp`

2. **"Operation not supported" when loading on bridge/veth**
   - Bridge and virtual interfaces require generic mode
   - Add `EBPF_ATTACH_MODE=generic` to the relay command
   - Example: `EBPF_OFFLOADING=relay-bridge EBPF_ATTACH_MODE=generic ./relay`

2. **"Map not found"**
   - The eBPF program may not be loaded correctly
   - Check maps with: `sudo bpftool map show`
   - Ensure the relay started successfully with eBPF enabled

3. **Permission errors**
   - Most operations require sudo for eBPF map access
   - Run with sudo or configure passwordless sudo

4. **No packets received**
   - Check that the relay is running on the expected interface
   - Verify the `EBPF_OFFLOADING` environment variable matches your test setup
   - For namespace tests, ensure relay is on `relay-bridge` interface
   - Verify map entries with: `sudo bpftool map dump id <map_id>`
   - Check firewall rules aren't blocking UDP traffic

## Performance Tips

1. **Interface Selection**: 
   - Use physical NICs with driver mode for best performance
   - Use generic mode for virtual interfaces (bridges, veth, loopback)
   - Driver mode: `EBPF_OFFLOADING=enp1s0 ./relay`
   - Generic mode: `EBPF_OFFLOADING=lo EBPF_ATTACH_MODE=generic ./relay`
2. **CPU Affinity**: Pin processes to specific CPUs for consistent results
3. **Kernel Tuning**: Adjust UDP buffer sizes for high-throughput tests
4. **Disable Checksums**: For local testing, UDP checksums can be disabled in eBPF config

## Architecture

The testing framework consists of:
- `map_populate.sh` - Populates eBPF maps with channel bindings
- `packet_gen.sh` - Generates and sends test packets
- `test_*.sh` - Individual test scenarios
- `measure_perf.sh` - Performance measurement utilities
- `run_all_tests.sh` - Main test orchestrator

Each test simulates:
- A TURN client on port 52625
- A peer/gateway on port 52626
- The relay listening on port 3478 (TURN)
- Allocations on port 50000

The relay translates between channel data format and regular UDP based on the eBPF map entries.