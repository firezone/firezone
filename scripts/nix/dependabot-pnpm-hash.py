#!/usr/bin/env python3
"""Compute untrusted hash data, or apply it using trusted workflow code only."""

import base64
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

FRONTEND = "scripts/nix/packages/firezone-gui-client/frontend.nix"
LOCKFILE = "rust/gui-client/pnpm-lock.yaml"
ALLOWED_FILES = {LOCKFILE, "rust/gui-client/package.json", FRONTEND}
WORKFLOW = ".github/workflows/dependabot-nix-pnpm.yml"
HASH_RE = re.compile(r'sha256-[A-Za-z0-9+/]{43}=')
PIN_RE = re.compile(r'(\bhash\s*=\s*")(sha256-[A-Za-z0-9+/]{43}=)("\s*;)')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pin(text):
    matches = list(PIN_RE.finditer(text))
    require(len(matches) == 1, "Expected exactly one pnpm hash pin")
    return matches[0]


def replace_pin(text, value):
    require(isinstance(value, str) and HASH_RE.fullmatch(value), "Invalid SHA-256 SRI")
    require(len(base64.b64decode(value[7:], validate=True)) == 32, "Invalid hash size")
    match = pin(text)
    return text[: match.start(2)] + value + text[match.end(2) :]


def validate_pr(pr, run, repository, files):
    require(pr["state"] == "open", "PR is no longer open")
    require(pr["user"]["login"] == "dependabot[bot]", "Not a Dependabot PR")
    require(pr["base"]["ref"] == "main", "Unexpected base branch")
    require(pr["base"]["repo"]["full_name"] == repository, "Unexpected base repository")
    require(pr["head"]["repo"]["full_name"] == repository, "Fork PRs are not supported")
    require(pr["head"]["ref"].startswith("dependabot/"), "Unexpected head branch")
    require(pr["head"]["ref"] == run["head_branch"], "Run branch does not match PR")
    require(pr["head"]["sha"] == run["head_sha"], "PR changed since computation")
    names = {item["filename"] for item in files}
    require(LOCKFILE in names and names <= ALLOWED_FILES, "Unexpected PR file changes")
    require(all(item["status"] == "modified" for item in files), "Only modified files allowed")


def decode_artifact(data, sha):
    require(len(data) <= 65536, "Artifact archive is too large")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        require(len(entries) == 1, "Expected one artifact file")
        entry = entries[0]
        require(entry.filename == "hash.json" and entry.file_size <= 1024, "Invalid artifact file")
        payload = json.loads(archive.read(entry))
    require(isinstance(payload, dict) and set(payload) == {"sha", "hash"}, "Invalid payload")
    require(payload["sha"] == sha, "Artifact commit does not match run")
    replace_pin('hash = "sha256-' + "A" * 43 + '=";', payload["hash"])
    return payload["hash"]


class GitHub:
    def __init__(self, repository, token):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
        self.repository = repository
        self.token = token

    def request(self, path, body=None, method=None, raw=False):
        request = urllib.request.Request(
            "https://api.github.com" + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "Authorization": "Bearer " + self.token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            },
        )
        # urllib strips authorization when following cross-host redirects only
        # with custom handling; artifact redirects must use a fresh request.
        opener = urllib.request.build_opener(NoRedirect)
        try:
            response = opener.open(request, timeout=30)
        except urllib.error.HTTPError as error:
            if raw and error.code == 302:
                location = error.headers["Location"]
                require(location.startswith("https://"), "Insecure artifact redirect")
                with urllib.request.urlopen(location, timeout=30) as redirected:
                    data = redirected.read(65537)
                return data
            raise
        with response:
            data = response.read(65537 if raw else 4 * 1024 * 1024)
        return data if raw else json.loads(data)

    def repo(self, path, **kwargs):
        return self.request(f"/repos/{self.repository}/{path}", **kwargs)

    def pages(self, path):
        result = []
        for page in range(1, 11):
            batch = self.repo(f"{path}?per_page=100&page={page}")
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise ValueError("Too many results")

    def text(self, path, sha):
        item = self.repo(f"contents/{path}?ref={sha}")
        require(item["type"] == "file" and item["encoding"] == "base64", "Not a regular file")
        return base64.b64decode(item["content"]).decode()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def app_client(repository):
    def b64(data):
        return base64.urlsafe_b64encode(data).rstrip(b"=")

    now = int(time.time())
    header = b64(b'{"alg":"RS256","typ":"JWT"}')
    claims = b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": os.environ["NIX_HASH_APP_ID"]}).encode())
    signing_input = header + b"." + claims
    with tempfile.TemporaryDirectory() as directory:
        key = Path(directory) / "key.pem"
        key.write_text(os.environ["NIX_HASH_APP_PRIVATE_KEY"])
        key.chmod(0o600)
        signature = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(key)],
            input=signing_input, capture_output=True, check=True,
        ).stdout
    client = GitHub(repository, (signing_input + b"." + b64(signature)).decode())
    installation = client.repo("installation")
    token = client.request(
        f'/app/installations/{installation["id"]}/access_tokens',
        body={"repositories": [repository.split("/")[1]], "permissions": {"contents": "write"}},
    )["token"]
    return GitHub(repository, token)


def commit(event, client):
    run_id = event["workflow_run"]["id"]
    run = client.repo(f"actions/runs/{run_id}")
    require(run["event"] == "pull_request" and run["conclusion"] == "success", "Unexpected run")
    require(run["path"] == WORKFLOW, "Unexpected source workflow")
    require(run["head_repository"]["full_name"] == client.repository, "Unexpected run repository")
    require(re.fullmatch(r"[0-9a-f]{40}", run["head_sha"]), "Invalid commit SHA")
    workflow = client.repo(f'actions/workflows/{run["workflow_id"]}')
    require(workflow["path"] == WORKFLOW, "Unexpected workflow ID")
    prs = client.pages(f'commits/{run["head_sha"]}/pulls')
    matches = [pr for pr in prs if pr["state"] == "open" and pr["head"]["sha"] == run["head_sha"]]
    require(len(matches) == 1, "Expected exactly one open PR for run commit")
    number = matches[0]["number"]
    pr = client.repo(f"pulls/{number}")
    files = client.pages(f"pulls/{number}/files")
    validate_pr(pr, run, client.repository, files)
    original = client.text(FRONTEND, run["head_sha"])
    base = client.text(FRONTEND, pr["base"]["sha"])
    require(replace_pin(original, pin(base).group(2)) == base, "Frontend has changes outside hash pin")
    artifacts = client.repo(f"actions/runs/{run_id}/artifacts?per_page=100")
    matches = [a for a in artifacts["artifacts"] if a["name"] == "dependabot-pnpm-hash" and not a["expired"]]
    require(len(matches) == 1, "Expected one hash artifact")
    data = client.repo(f'actions/artifacts/{matches[0]["id"]}/zip', raw=True)
    value = decode_artifact(data, run["head_sha"])
    updated = replace_pin(original, value)
    if updated == original:
        print("Hash already correct; no commit needed")
        return
    writer = app_client(client.repository)
    try:
        latest = client.repo(f"pulls/{number}")
        validate_pr(latest, run, client.repository, files)
        parent = client.repo(f'git/commits/{run["head_sha"]}')
        tree = writer.repo("git/trees", body={
            "base_tree": parent["tree"]["sha"],
            "tree": [{"path": FRONTEND, "mode": "100644", "type": "blob", "content": updated}],
        })
        new_commit = writer.repo("git/commits", body={
            "message": "fix(nix): refresh GUI pnpm dependency hash [dependabot skip]",
            "tree": tree["sha"], "parents": [run["head_sha"]],
        })
        # Fast-forward only: a concurrently updated PR cannot be overwritten.
        writer.repo(f'git/refs/heads/{pr["head"]["ref"]}', method="PATCH", body={
            "sha": new_commit["sha"], "force": False,
        })
        print(f'Updated PR #{number}: {new_commit["sha"]}')
    finally:
        writer.request("/installation/token", method="DELETE", raw=True)


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if sys.argv[1] == "compute":
        sha = event["pull_request"]["head"]["sha"]
        value = pin(Path(FRONTEND).read_text()).group(2)
        Path(sys.argv[2]).write_text(json.dumps({"sha": sha, "hash": value}) + "\n")
    elif sys.argv[1] == "commit":
        commit(event, GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"]))
    else:
        raise ValueError("Expected compute or commit")


if __name__ == "__main__":
    main()
