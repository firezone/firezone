#!/bin/bash

function run_test() {
  local i=$1
  local service="client-$i"

  # We'll use a single 'docker compose exec' command for each container.
  # This chains all the commands together for efficiency.
  docker compose exec -T "$service" sh -c "
    set -e

    # Drop traffic to the gateway
    iptables -A OUTPUT -d 172.28.0.7 -j DROP

    # Add a random amount of latency between 1 and 100ms
    latency=\$((RANDOM % 100 + 1))
    tc qdisc add dev eth0 root netem delay \${latency}ms

    # Run curl in the background and capture its PID.
    curl \
      --fail \
      --max-time 13 \
      --keepalive-time 1 \
      --limit-rate 1000000 \
      --output download.file \
      http://download.httpbin/bytes?num=10000000 &

    DOWNLOAD_PID=\$!

    # Wait for the curl process to finish and check its exit code.
    wait \$DOWNLOAD_PID || {
      echo 'Download process failed for service $service'
      exit 1
    }

    # Verify the checksum.
    known_checksum='f5e02aa71e67f41d79023a128ca35bad86cf7b6656967bfe0884b3a3c4325eaf'
    computed_checksum=\$(sha256sum download.file | awk '{ print \$1 }')

    if [[ \"\$computed_checksum\" != \"\$known_checksum\" ]]; then
      echo \"Checksum of downloaded file does not match for service $service\"
      exit 1
    fi

    # Clean up the iptables rule after the test.
    iptables -D OUTPUT -d 172.28.0.7 -j DROP

    echo 'Test for service $service passed successfully.'
  " &
}

# Run the tests in parallel.
for i in {1..200}; do
  run_test "$i" &
done

# This `wait` command will wait for all background jobs (all the `run_test` calls) to complete.
wait

echo "All tests have finished."
