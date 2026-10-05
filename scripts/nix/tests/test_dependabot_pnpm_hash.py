"""Regression tests for the privileged writer's trust boundary."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location(
    "pnpm_hash", Path(__file__).parents[1] / "dependabot-pnpm-hash.py"
)
hashbot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hashbot)

SHA = "a" * 40
HASH = "sha256-" + "A" * 43 + "="
NEW_HASH = "sha256-" + "B" * 43 + "="
REPO = "firezone/firezone"


def archive(payload, name="hash.json"):
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as target:
        target.writestr(name, json.dumps(payload))
    return data.getvalue()


class TrustBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.pr = {
            "state": "open", "user": {"login": "dependabot[bot]"},
            "base": {"ref": "main", "sha": "b" * 40, "repo": {"full_name": REPO}},
            "head": {"ref": "dependabot/npm_and_yarn/rust/gui-client/update", "sha": SHA,
                     "repo": {"full_name": REPO}},
            "number": 123,
        }
        self.run = {
            "event": "pull_request", "conclusion": "success", "path": hashbot.WORKFLOW,
            "workflow_id": 1, "head_repository": {"full_name": REPO},
            "head_branch": self.pr["head"]["ref"], "head_sha": SHA,
        }
        self.files = [{"filename": hashbot.LOCKFILE, "status": "modified"}]

    def validate(self):
        hashbot.validate_pr(self.pr, self.run, REPO, self.files)

    def test_expected_pr_is_accepted(self):
        self.validate()

    def test_wrong_owner_fork_base_branch_or_stale_head_is_rejected(self):
        cases = [
            ("user", "login", "attacker"), ("head", "sha", "c" * 40),
            ("head", "ref", "other-branch"), ("base", "ref", "release"),
        ]
        for section, key, value in cases:
            with self.subTest(section=section, key=key):
                original = copy.deepcopy(self.pr)
                self.pr[section][key] = value
                with self.assertRaises(ValueError):
                    self.validate()
                self.pr = original
        self.pr["head"]["repo"]["full_name"] = "attacker/firezone"
        with self.assertRaises(ValueError):
            self.validate()

    def test_unexpected_file_rename_or_missing_lockfile_is_rejected(self):
        for files in [
            self.files + [{"filename": ".github/workflows/ci.yml", "status": "modified"}],
            [{"filename": hashbot.LOCKFILE, "status": "renamed"}],
            [{"filename": "rust/gui-client/package.json", "status": "modified"}],
        ]:
            with self.subTest(files=files), self.assertRaises(ValueError):
                hashbot.validate_pr(self.pr, self.run, REPO, files)

    def test_artifact_rejects_wrong_commit_paths_fields_and_hash_injection(self):
        payload = {"sha": SHA, "hash": HASH}
        self.assertEqual(hashbot.decode_artifact(archive(payload), SHA), HASH)
        for bad in [
            {"sha": "c" * 40, "hash": HASH},
            {"sha": SHA, "hash": HASH, "branch": "main"},
            {"sha": SHA, "hash": HASH + '\nrun evil'},
            {"sha": SHA, "hash": 1},
        ]:
            with self.subTest(payload=bad), self.assertRaises(ValueError):
                hashbot.decode_artifact(archive(bad), SHA)
        with self.assertRaises(ValueError):
            hashbot.decode_artifact(archive(payload, "../hash.json"), SHA)

    def test_replacement_changes_only_one_hash(self):
        original = f'# Comment\nhash = "{HASH}";\nother = 1;\n'
        updated = hashbot.replace_pin(original, NEW_HASH)
        self.assertEqual(updated.replace(NEW_HASH, HASH), original)
        with self.assertRaises(ValueError):
            hashbot.replace_pin(original + original, NEW_HASH)

    def client(self, original=None):
        test = self

        class FakeClient:
            repository = REPO

            def repo(self, path, **kwargs):
                if path == "actions/runs/42":
                    return test.run
                if path == "actions/workflows/1":
                    return {"path": hashbot.WORKFLOW}
                if path == "pulls/123":
                    return test.pr
                if path == "actions/runs/42/artifacts?per_page=100":
                    return {"artifacts": [{"name": "dependabot-pnpm-hash", "expired": False, "id": 9}]}
                if path == "actions/artifacts/9/zip":
                    return archive({"sha": SHA, "hash": NEW_HASH})
                if path == f"git/commits/{SHA}":
                    return {"tree": {"sha": "tree"}}
                raise AssertionError(path)

            def pages(self, path):
                return test.files if path.endswith("/files") else [test.pr]

            def text(self, path, sha):
                if sha == SHA and original is not None:
                    return original
                return f'hash = "{HASH}";'

        return FakeClient()

    def test_frontend_code_change_is_rejected_before_app_credentials(self):
        with patch.object(hashbot, "app_client") as app:
            with self.assertRaises(ValueError):
                hashbot.commit({"workflow_run": {"id": 42}}, self.client(f'hash = "{HASH}"; evil = true;'))
            app.assert_not_called()

    def test_writer_updates_only_frontend_and_never_force_pushes(self):
        calls = []

        class Writer:
            def repo(self, path, **kwargs):
                calls.append((path, kwargs))
                return {"sha": "new-tree" if path == "git/trees" else "new-commit"}

            def request(self, path, **kwargs):
                calls.append((path, kwargs))

        with patch.object(hashbot, "app_client", return_value=Writer()):
            hashbot.commit({"workflow_run": {"id": 42}}, self.client())
        tree = calls[0][1]["body"]["tree"]
        self.assertEqual(len(tree), 1)
        self.assertEqual(tree[0]["path"], hashbot.FRONTEND)
        self.assertEqual(calls[1][1]["body"]["parents"], [SHA])
        self.assertFalse(calls[2][1]["body"]["force"])
        self.assertEqual(calls[-1][0], "/installation/token")

    def test_correct_hash_does_not_mint_write_credentials(self):
        client = self.client()
        original_repo = client.repo

        def repo(path, **kwargs):
            if path == "actions/artifacts/9/zip":
                return archive({"sha": SHA, "hash": HASH})
            return original_repo(path, **kwargs)

        client.repo = repo
        with patch.object(hashbot, "app_client") as app:
            hashbot.commit({"workflow_run": {"id": 42}}, client)
            app.assert_not_called()

    def test_head_changed_after_validation_revokes_token_without_writing(self):
        client = self.client()
        original_repo = client.repo
        reads = 0

        def repo(path, **kwargs):
            nonlocal reads
            if path == "pulls/123":
                reads += 1
                if reads == 2:
                    self.pr["head"]["sha"] = "c" * 40
            return original_repo(path, **kwargs)

        client.repo = repo
        from unittest.mock import Mock
        writer = Mock()
        with patch.object(hashbot, "app_client", return_value=writer):
            with self.assertRaises(ValueError):
                hashbot.commit({"workflow_run": {"id": 42}}, client)
        writer.repo.assert_not_called()
        writer.request.assert_called_once_with("/installation/token", method="DELETE", raw=True)

    def test_app_token_is_repository_scoped_and_short_lived(self):
        from unittest.mock import Mock
        import base64

        jwt_client = Mock()
        jwt_client.repo.return_value = {"id": 7}
        jwt_client.request.return_value = {"token": "installation-token"}
        signed = Mock(stdout=b"signature")
        with patch.dict("os.environ", {"NIX_HASH_APP_ID": "123", "NIX_HASH_APP_PRIVATE_KEY": "test-key"}):
            with patch.object(hashbot.subprocess, "run", return_value=signed):
                with patch.object(hashbot, "GitHub", side_effect=[jwt_client, Mock()]) as github:
                    hashbot.app_client(REPO)
        jwt = github.call_args_list[0].args[1]
        claims_segment = jwt.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(claims_segment + "=" * (-len(claims_segment) % 4)))
        self.assertEqual(claims["iss"], "123")
        self.assertEqual(claims["exp"] - claims["iat"], 600)
        jwt_client.request.assert_called_once_with(
            "/app/installations/7/access_tokens",
            body={"repositories": ["firezone"], "permissions": {"contents": "write"}},
        )
        self.assertEqual(github.call_args_list[1].args, (REPO, "installation-token"))

    def test_wrong_workflow_is_rejected_before_credentials(self):
        self.run["path"] = ".github/workflows/evil.yml"
        with patch.object(hashbot, "app_client") as app:
            with self.assertRaises(ValueError):
                hashbot.commit({"workflow_run": {"id": 42}}, self.client())
            app.assert_not_called()


if __name__ == "__main__":
    unittest.main()
