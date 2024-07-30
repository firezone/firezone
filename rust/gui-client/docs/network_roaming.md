# Network roaming

Given Ethernet and 2 Wi-Fi networks "A" and "B", this test cycle exercises all interesting combos of:

- Connecting and disconnecting Ethernet and Wi-Fi, while the other is connected and disconnected
- Roaming from one Wi-Fi network to another
- Steady-state network connections

Cycle:

1. Steady on A
2. Change to B
3. Disconnect Wi-Fi
4. Steady offline
5. Connect to A
6. Connect Eth
7. Steady on Eth + A
8. Change to B
9. Disconnect Wi-Fi
10. Steady on Eth
11. Disconnect Eth
12. Connect Eth
13. Connect to Wi-Fi A
14. Disconnect Eth

For each step:

- Make the change. (e.g. click on the Wi-Fi network, or connect / disconnect the Ethernet plug)
- Wait for the OS to reflect the change. (e.g. "Connected to Wi-Fi A" pop-up)
- Run `time curl -4 --silent --max-time 30 https://ifconfig.net/ip`.
- Ensure that you see the Gateway's IP and not your Wi-Fi's external IP.
- Note how long it took `curl` to return success or failure.
