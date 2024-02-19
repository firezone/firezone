const fs = require("fs");

function getDiffPercents(main, current) {
  let diff = -1 * (100 - current / (main / 100));

  if (diff > 0) {
    return "+" + diff.toFixed(0) + "%";
  } else if (diff == 0) {
    return "0%";
  } else {
    return diff.toFixed(0) + "%";
  }
}

function humanFileSize(bytes, dp = 1) {
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

exports.script = async function (github, context, test_name) {
  // 1. Read the current results
  const tcp_s2c = JSON.parse(
    fs.readFileSync("iperf3results/tcp_server2client.json")
  ).end;
  const tcp_c2s = JSON.parse(
    fs.readFileSync("iperf3results/tcp_client2server.json")
  ).end;
  const udp_s2c = JSON.parse(
    fs.readFileSync("iperf3results/udp_server2client.json")
  ).end;
  const udp_c2s = JSON.parse(
    fs.readFileSync("iperf3results/udp_client2server.json")
  ).end;

  // 2. Read the main results
  const tcp_s2c_main = JSON.parse(
    fs.readFileSync("iperf3results-main/tcp_server2client.json")
  ).end;
  const tcp_c2s_main = JSON.parse(
    fs.readFileSync("iperf3results-main/tcp_client2server.json")
  ).end;
  const udp_s2c_main = JSON.parse(
    fs.readFileSync("iperf3results-main/udp_server2client.json")
  ).end;
  const udp_c2s_main = JSON.parse(
    fs.readFileSync("iperf3results-main/udp_client2server.json")
  ).end;

  // Retrieve existing bot comments for the PR
  const { data: comments } = await github.rest.issues.listComments({
    owner: context.repo.owner,
    repo: context.repo.repo,
    issue_number: context.issue.number,
  });

  const botComment = comments.find((comment) => {
    return comment.user.type === "Bot" && comment.body.includes(test_name);
  });

  const tcp_server2client_sum_received_bits_per_second =
    humanFileSize(tcp_s2c.sum_received.bits_per_second) +
    " (" +
    getDiffPercents(
      tcp_s2c_main.sum_received.bits_per_second,
      tcp_s2c.sum_received.bits_per_second
    ) +
    ")";
  const tcp_server2client_sum_sent_bits_per_second =
    humanFileSize(tcp_s2c.sum_sent.bits_per_second) +
    " (" +
    getDiffPercents(
      tcp_s2c_main.sum_sent.bits_per_second,
      tcp_s2c.sum_sent.bits_per_second
    ) +
    ")";
  const tcp_server2client_sum_sent_retransmits =
    tcp_s2c.sum_sent.retransmits +
    " (" +
    getDiffPercents(
      tcp_s2c_main.sum_sent.retransmits,
      tcp_s2c.sum_sent.retransmits
    ) +
    ")";

  const tcp_client2server_sum_received_bits_per_second =
    humanFileSize(tcp_c2s.sum_received.bits_per_second) +
    " (" +
    getDiffPercents(
      tcp_c2s_main.sum_received.bits_per_second,
      tcp_c2s.sum_received.bits_per_second
    ) +
    ")";
  const tcp_client2server_sum_sent_bits_per_second =
    humanFileSize(tcp_c2s.sum_sent.bits_per_second) +
    " (" +
    getDiffPercents(
      tcp_c2s_main.sum_sent.bits_per_second,
      tcp_c2s.sum_sent.bits_per_second
    ) +
    ")";
  const tcp_client2server_sum_sent_retransmits =
    tcp_c2s.sum_sent.retransmits +
    " (" +
    getDiffPercents(
      tcp_c2s.sum_sent.retransmits,
      tcp_c2s_main.sum_sent.retransmits
    ) +
    ")";

  const udp_server2client_sum_received_bits_per_second =
    humanFileSize(udp_s2c.sum_received.bits_per_second) +
    " (" +
    getDiffPercents(
      udp_s2c_main.sum_received.bits_per_second,
      udp_s2c.sum_received.bits_per_second
    ) +
    ")";
  const udp_server2client_sum_sent_bits_per_second =
    humanFileSize(udp_s2c.sum_sent.bits_per_second) +
    " (" +
    getDiffPercents(
      udp_s2c_main.sum_sent.bits_per_second,
      udp_s2c.sum_sent.bits_per_second
    ) +
    ")";
  const udp_server2client_sum_sent_retransmits =
    udp_s2c.sum_sent.retransmits +
    " (" +
    getDiffPercents(
      udp_s2c_main.sum_sent.retransmits,
      udp_s2c.sum_sent.retransmits
    ) +
    ")";

  const udp_client2server_sum_received_bits_per_second =
    humanFileSize(udp_c2s.sum_received.bits_per_second) +
    " (" +
    getDiffPercents(
      udp_c2s_main.sum_received.bits_per_second,
      udp_c2s.sum_received.bits_per_second
    ) +
    ")";
  const udp_client2server_sum_sent_bits_per_second =
    humanFileSize(udp_c2s.sum_sent.bits_per_second) +
    " (" +
    getDiffPercents(
      udp_c2s_main.sum_sent.bits_per_second,
      udp_c2s.sum_sent.bits_per_second
    ) +
    ")";
  const udp_client2server_sum_sent_retransmits =
    udp_c2s.sum_sent.retransmits +
    " (" +
    getDiffPercents(
      udp_c2s.sum_sent.retransmits,
      udp_c2s_main.sum_sent.retransmits
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
