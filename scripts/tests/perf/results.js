exports.script = async function (
  github,
  context,
  test_name,
  results,
  main_results
) {
  // Retrieve existing bot comments for the PR
  const { data: comments } = await github.rest.issues.listComments({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: context.issue.number,
  });

  const botComment = comments.find((comment) => {
    return comment.user.type === "Bot" && comment.body.includes(test_name);
  });

  function humanFileSize(bytesStr, dp = 1) {
    let bytes = parseFloat(bytesStr);
    const thresh = 1000;

    if (Math.abs(bytes) < thresh) {
      return bytes + " B";
    }

    const units = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB"];
    let u = -1;
    const r = 10 ** dp;

    do {
      bytes /= thresh;
      ++u;
    } while (
      Math.round(Math.abs(bytes) * r) / r >= thresh &&
      u < units.length - 1
    );

    return bytes.toFixed(dp) + " " + units[u];
  }

  function getDiffPercents(mainStr, currentStr) {
    const main = parseFloat(mainStr);
    const current = parseFloat(currentStr);

    let diff = -1 * (100 - current / (main / 100));

    if (diff > 0) {
      return "+" + diff.toFixed(0) + "%";
    } else if (diff == 0) {
      return "0%";
    } else {
      return diff.toFixed(0) + "%";
    }
  }

  let tcp_server2client_sum_received_bits_per_second =
    humanFileSize(results.tcp_server2client_sum_received_bits_per_second) +
    " (" +
    getDiffPercents(
      main_results.tcp_server2client_sum_received_bits_per_second,
      results.tcp_server2client_sum_received_bits_per_second
    ) +
    ")";
  let tcp_server2client_sum_sent_bits_per_second =
    humanFileSize(results.tcp_server2client_sum_sent_bits_per_second) +
    " (" +
    getDiffPercents(
      main_results.tcp_server2client_sum_sent_bits_per_second,
      results.tcp_server2client_sum_sent_bits_per_second
    ) +
    ")";
  let tcp_server2client_sum_sent_retransmits =
    results.tcp_server2client_sum_sent_retransmits +
    " (" +
    getDiffPercents(
      main_results.tcp_server2client_sum_sent_retransmits,
      results.tcp_server2client_sum_sent_retransmits
    ) +
    ")";

  let tcp_client2server_sum_received_bits_per_second =
    humanFileSize(results.tcp_client2server_sum_received_bits_per_second) +
    " (" +
    getDiffPercents(
      main_results.tcp_client2server_sum_received_bits_per_second,
      results.tcp_client2server_sum_received_bits_per_second
    ) +
    ")";
  let tcp_client2server_sum_sent_bits_per_second =
    humanFileSize(results.tcp_client2server_sum_sent_bits_per_second) +
    " (" +
    getDiffPercents(
      main_results.tcp_client2server_sum_sent_bits_per_second,
      results.tcp_client2server_sum_sent_bits_per_second
    ) +
    ")";
  let tcp_client2server_sum_sent_retransmits =
    results.tcp_client2server_sum_sent_retransmits +
    " (" +
    getDiffPercents(
      main_results.tcp_client2server_sum_sent_retransmits,
      results.tcp_client2server_sum_sent_retransmits
    ) +
    ")";

  let udp_server2client_sum_bits_per_second =
    humanFileSize(results.udp_server2client_sum_bits_per_second) +
    " (" +
    getDiffPercents(
      main_results.udp_server2client_sum_bits_per_second,
      results.udp_server2client_sum_bits_per_second
    ) +
    ")";
  let udp_server2client_sum_jitter_ms =
    parseFloat(results.udp_server2client_sum_jitter_ms).toFixed(2) +
    "ms (" +
    getDiffPercents(
      main_results.udp_server2client_sum_jitter_ms,
      results.udp_server2client_sum_jitter_ms
    ) +
    ")";
  let udp_server2client_sum_lost_percent =
    parseFloat(results.udp_server2client_sum_lost_percent).toFixed(2) +
    "% (" +
    getDiffPercents(
      main_results.udp_server2client_sum_lost_percent,
      results.udp_server2client_sum_lost_percent
    ) +
    ")";

  let udp_client2server_sum_bits_per_second =
    humanFileSize(results.udp_client2server_sum_bits_per_second) +
    " (" +
    getDiffPercents(
      main_results.udp_client2server_sum_bits_per_second,
      results.udp_client2server_sum_bits_per_second
    ) +
    ")";
  let udp_client2server_sum_jitter_ms =
    parseFloat(results.udp_client2server_sum_jitter_ms).toFixed(2) +
    "ms (" +
    getDiffPercents(
      main_results.udp_client2server_sum_jitter_ms,
      results.udp_client2server_sum_jitter_ms
    ) +
    ")";
  let udp_client2server_sum_lost_percent =
    parseFloat(results.udp_client2server_sum_lost_percent).toFixed(2) +
    "% (" +
    getDiffPercents(
      main_results.udp_client2server_sum_lost_percent,
      results.udp_client2server_sum_lost_percent
    ) +
    ")";

  const output = `## Performance Test Results: ${test_name}

### TCP

| Direction        | Received/s                                             | Sent/s                                             | Retransmits                                    |
|------------------|--------------------------------------------------------|----------------------------------------------------|------------------------------------------------|
| Client to Server | ${tcp_client2server_sum_received_bits_per_second} | ${tcp_client2server_sum_sent_bits_per_second} | ${tcp_client2server_sum_sent_retransmits} |
| Server to Client | ${tcp_server2client_sum_received_bits_per_second} | ${tcp_server2client_sum_sent_bits_per_second} | ${tcp_server2client_sum_sent_retransmits} |

### UDP

| Direction        | Total/s                                       | Jitter                                  | Lost                                       |
|------------------|-----------------------------------------------|-----------------------------------------|--------------------------------------------|
| Client to Server | ${udp_client2server_sum_bits_per_second} | ${udp_client2server_sum_jitter_ms} | ${udp_server2client_sum_lost_percent} |
| Server to Client | ${udp_server2client_sum_bits_per_second} | ${udp_server2client_sum_jitter_ms} | ${udp_client2server_sum_lost_percent} |

`;

  // 3. Update previous comment or create new one
  if (botComment) {
    github.rest.issues.updateComment({
      owner: context.repo.owner,
      repo: context.repo.repo,
      comment_id: botComment.id,
      body: output,
    });
  } else {
    github.rest.issues.createComment({
      issue_number: context.issue.number,
      owner: context.repo.owner,
      repo: context.repo.repo,
      body: output,
    });
  }
};
