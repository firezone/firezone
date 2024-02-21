const fs = require("fs");
const path = require("path");

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

exports.script = async function (github, context, test_names) {
  let output = `### Performance Test Results`;
  let tcp_output = `

| Received/s | Sent/s | Retransmits |
|---|---|---|
`;

  let udp_output = `
| Total/s | Jitter | Lost |
|---|---|---|
`;

  for (const test_name of test_names) {
    // 1. Read the current results
    const results = JSON.parse(fs.readFileSync(test_name + ".json")).end;

    // 2. Read the main results
    const results_main = JSON.parse(
      fs.readFileSync(path.join("main", test_name + ".json"))
    ).end;


    if (test_name.includes("tcp")) {
      const tcp_sum_received_bits_per_second =
        humanFileSize(results.sum_received.bits_per_second) +
        " (" +
        getDiffPercents(
          results_main.sum_received.bits_per_second,
          results.sum_received.bits_per_second
        ) +
        ")";
      const tcp_sum_sent_bits_per_second =
        humanFileSize(results.sum_sent.bits_per_second) +
        " (" +
        getDiffPercents(
          results_main.sum_sent.bits_per_second,
          results.sum_sent.bits_per_second
        ) +
        ")";
      const tcp_sum_sent_retransmits =
        results.sum_sent.retransmits +
        " (" +
        getDiffPercents(
          results_main.sum_sent.retransmits,
          results.sum_sent.retransmits
        ) +
        ")";

      tcp_output += `| ${tcp_sum_received_bits_per_second} | ${tcp_sum_sent_bits_per_second} | ${tcp_sum_sent_retransmits} |`;
    } else if (test_name.includes("udp")) {
      const udp_sum_bits_per_second =
        humanFileSize(results.sum.bits_per_second) +
        " (" +
        getDiffPercents(
          results_main.sum.bits_per_second,
          results.sum.bits_per_second
        ) +
        ")";
      const udp_sum_jitter_ms =
        results.sum.jitter_ms.toFixed(2) +
        "ms (" +
        getDiffPercents(results_main.sum.jitter_ms, results.sum.jitter_ms) +
        ")";
      const udp_sum_lost_percent =
        results.sum.lost_percent.toFixed(2) +
        "% (" +
        getDiffPercents(results_main.sum.lost_percent, results.sum.lost_percent) +
        ")";

      udp_output += `| ${udp_sum_bits_per_second} | ${udp_sum_jitter_ms} | ${udp_sum_lost_percent} |`;
    } else {
      throw new Error("Unknown test type");
    }
  }

  output += tcp_output + "\n" + udp_output;

  // Retrieve existing bot comments for the PR
  const { data: comments } = await github.rest.issues.listComments({
    owner: context.repo.ownerh
    repo: context.repo.repo,
    issue_number: context.issue.number,
  });

  const botComment = comments.find((comment) => {
    return comment.user.type === "Bot" && comment.body.includes(test_name);
  });

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
