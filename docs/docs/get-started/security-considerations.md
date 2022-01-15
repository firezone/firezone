---
layout: default
title: Security Considerations
nav_order: 4
parent: Get Started
---


# Security Considerations
---

Firezone is still young software. For mission-critical applications, we
recommend **limiting network access to the Web UI** (by default ports tcp/443
and tcp/80) to prevent exposing it to the public Internet at this time.

The WireGuard listen port (by default port udp/51821) can be safely exposed to
allow user devices to connect. Traffic to this port is handled directly by the
WireGuard kernel module.
