#!/usr/bin/env bash
#MISE description="Stand up the whole work-profile test device: emulator, profile, app, certificate, managed config"
#MISE raw=true
set -euo pipefail

# Each step consumes what the previous one leaves on the device, so they run in sequence rather
# than as `depends`, which mise runs in parallel.
#
# The last two steps need you at the emulator: only a profile owner can put a key into the
# KeyChain or push managed configuration, and the DPC drives both from its own UI. Both tasks
# print numbered instructions when they get there, and the last one waits for you.
for step in build-dpc boot create install-app certificate managed-config; do
    echo
    echo "############ //kotlin/android:work-profile:${step} ############"
    echo
    mise run "//kotlin/android:work-profile:${step}"
done
