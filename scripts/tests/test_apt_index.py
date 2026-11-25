import base64
import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest


SOURCE = pathlib.Path(__file__).parents[1] / "apt-index.py"
SPEC = importlib.util.spec_from_file_location("apt_index", SOURCE)
apt_index = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(apt_index)


class IndexTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.metadata = self.root / "metadata"
        self.binary = self.metadata / "main" / "binary-amd64"
        self.binary.mkdir(parents=True)
        self.staged = self.root / "pool-stable"
        self.staged.mkdir()
        self.listing = self.root / "blobs.json"
        self.filename = "pool-stable/sample_1_amd64.deb"
        self.package = b"old"
        self.write_index()
        self.write_listing()

    def record(self, content):
        return (
            "Package: sample\n"
            "Version: 1\n"
            "Architecture: amd64\n"
            f"Filename: {self.filename}\n"
            f"Size: {len(content)}\n"
            f"MD5sum: {hashlib.md5(content).hexdigest()}\n"
            f"SHA256: {hashlib.sha256(content).hexdigest()}\n\n"
        )

    def write_index(self, omitted_hash=None):
        (self.binary / "Packages").write_text(self.record(self.package))
        (self.binary / "Packages.gz").write_bytes(b"compressed")
        (self.binary / "Release").write_text("Architecture: amd64\n")
        lines = ["Architectures: amd64", "Components: main", "SHA256:"]
        for name in ("Packages", "Packages.gz", "Release"):
            if name == omitted_hash:
                continue
            path = self.binary / name
            lines.append(
                f" {hashlib.sha256(path.read_bytes()).hexdigest()} "
                f"{path.stat().st_size} main/binary-amd64/{name}"
            )
        (self.metadata / "Release").write_text("\n".join(lines) + "\n")

    def write_listing(self, extra=False, missing=False):
        blobs = [] if missing else [
            {
                "name": self.filename,
                "properties": {
                    "contentLength": len(self.package),
                    "contentSettings": {
                        "contentMd5": base64.b64encode(hashlib.md5(self.package).digest()).decode()
                    },
                },
            }
        ]
        if extra:
            blobs.append({"name": "pool-stable/extra.deb", "properties": {"contentLength": 1}})
        self.listing.write_text(json.dumps(blobs))

    def check(self):
        return apt_index.check(self.metadata, self.listing, self.staged, "stable")

    def test_reuses_consistent_index(self):
        self.check()

    def test_ignores_legacy_release_self_checksum(self):
        with (self.metadata / "Release").open("a") as release:
            release.write(" " + "0" * 64 + " 1 Release\n")
        self.check()

    def test_missing_release_checksum_requires_rebuild(self):
        self.write_index(omitted_hash="Packages")
        with self.assertRaisesRegex(ValueError, "Missing checksums"):
            self.check()

    def test_extra_blob_requires_rebuild(self):
        self.write_listing(extra=True)
        with self.assertRaisesRegex(ValueError, "absent from published indices"):
            self.check()

    def test_missing_indexed_blob_fails_without_import(self):
        self.write_listing(missing=True)
        with self.assertRaises(FileNotFoundError):
            self.check()

    def test_same_version_import_replaces_old_record(self):
        self.write_listing(missing=True)
        (self.staged / pathlib.Path(self.filename).name).write_bytes(b"new")
        self.check()
        new_index = self.root / "new-Packages"
        new_index.write_text(self.record(b"new"))
        merged = self.root / "merged-Packages"
        apt_index.merge(self.binary / "Packages", new_index, merged, self.staged, self.root / "none")
        self.assertEqual(merged.read_text(), self.record(b"new"))

    def test_uploads_only_missing_or_changed_content(self):
        package = self.staged / pathlib.Path(self.filename).name
        package.write_bytes(self.package)
        skipped = self.root / "skipped"
        apt_index.uploads(self.listing, self.staged, skipped, "stable")
        self.assertEqual(list(skipped.iterdir()), [])

        package.write_bytes(b"new")
        changed = self.root / "changed"
        apt_index.uploads(self.listing, self.staged, changed, "stable")
        self.assertEqual((changed / package.name).read_bytes(), b"new")

        self.write_listing(missing=True)
        missing = self.root / "missing"
        apt_index.uploads(self.listing, self.staged, missing, "stable")
        self.assertEqual((missing / package.name).read_bytes(), b"new")


if __name__ == "__main__":
    unittest.main()
