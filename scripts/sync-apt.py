#!/usr/bin/env python3
"""Publish the stable and preview APT repositories from their Azure import queues."""

import base64
import gzip
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime
from email.utils import format_datetime
from pathlib import Path
from tempfile import TemporaryDirectory

CHANNELS = ("stable", "preview")
RELEASE_FILES = ("Release.gpg", "Release", "InRelease")


class UnusableIndex(ValueError):
    """The published index cannot be reused. Rebuild it from the pool."""


class InconsistentPool(ValueError):
    """The published index references a missing or altered package."""


@dataclass(frozen=True)
class Blob:
    size: int
    md5_base64: str | None

    def md5(self) -> bytes | None:
        if not self.md5_base64:
            return None
        return base64.b64decode(self.md5_base64, validate=True)


@dataclass(frozen=True)
class PackageRecord:
    filename: str
    size: int
    md5: bytes
    stanza: str


@dataclass(frozen=True)
class ChannelResult:
    channel: str
    metadata: Path
    imports: tuple[str, ...]


def command_output(*args, cwd=None) -> bytes:
    return subprocess.check_output(args, cwd=cwd)


def file_digest(path: Path, algorithm: str) -> bytes:
    with path.open("rb") as file:
        return hashlib.file_digest(file, algorithm).digest()


class AptStorage:
    def __init__(self, account: str):
        self.account = account

    def command(self, operation: str, *args, output="none") -> bytes:
        return command_output(
            "az", "storage", "blob", operation, *args,
            "--auth-mode", "login", "--account-name", self.account,
            "--only-show-errors", "--output", output,
        )

    def list_pool(self, prefix: str) -> dict[str, Blob]:
        response = self.command(
            "list", "--container-name", "apt", "--prefix", prefix,
            "--num-results", "*", output="json",
        )
        entries = json.loads(response)
        if not isinstance(entries, list):
            raise ValueError(f"Invalid Azure blob listing for {prefix}")

        pool = {}
        for entry in entries:
            name = entry["name"]
            properties = entry["properties"]
            size = properties["contentLength"]
            if not isinstance(name, str) or type(size) is not int or size < 0:
                raise ValueError(f"Invalid Azure blob listing entry for {prefix}")
            if name.endswith(".deb"):
                md5 = (properties.get("contentSettings") or {}).get("contentMd5")
                pool[name] = Blob(size, md5)
        return pool

    def download(self, pattern: str, destination: Path) -> None:
        destination.mkdir(parents=True, exist_ok=True)
        self.command(
            "download-batch", "--source", "apt",
            "--pattern", pattern, "--destination", destination,
        )

    def upload_directory(self, source: Path, prefix: str) -> None:
        self.command(
            "upload-batch", "--source", source, "--destination", "apt",
            "--destination-path", prefix, "--overwrite",
        )

    def upload_file(self, source: Path, name: str) -> None:
        self.command(
            "upload", "--container-name", "apt", "--name", name,
            "--file", source, "--overwrite",
        )

    def delete_import(self, name: str) -> None:
        self.command("delete", "--container-name", "apt", "--name", name)


def build_keyring(work: Path, key_id: str, expiry: str) -> Path:
    key_listing = command_output("gpg", "--list-secret-keys", "--with-colons", key_id)
    fingerprint = next(
        (line.split(b":")[9].decode("ascii")
         for line in key_listing.splitlines() if line.startswith(b"fpr:")),
        None,
    )
    if not fingerprint:
        raise ValueError(f"No signing key fingerprint found for {key_id}")
    subprocess.run(("gpg", "--batch", "--quick-set-expire", fingerprint, expiry), check=True)

    version = expiry.replace("-", ".")
    package = work / f"firezone-archive-keyring_{version}_all.deb"
    root = work / "keyring"
    debian = root / "DEBIAN"
    keyrings = root / "usr/share/keyrings"
    debian.mkdir(parents=True)
    keyrings.mkdir(parents=True)
    for directory in (root, debian, root / "usr", keyrings.parent, keyrings):
        directory.chmod(0o755)

    public_key = keyrings / "firezone-archive-keyring.gpg"
    public_key.write_bytes(command_output("gpg", "--export", key_id))
    public_key.chmod(0o644)
    (debian / "control").write_text(
        f"""Package: firezone-archive-keyring
Version: {version}
Architecture: all
Maintainer: Firezone, Inc. <support@firezone.dev>
Section: misc
Priority: optional
Description: GnuPG key of the Firezone APT repository
""",
        encoding="utf-8",
    )

    # Existing installations use this path in their signed-by setting.
    postinst = debian / "postinst"
    postinst.write_text(
        """#!/bin/sh
set -e

if [ "$1" = "configure" ] && [ -e /etc/apt/keyrings/firezone.gpg ]; then
    install --mode 0644 /usr/share/keyrings/firezone-archive-keyring.gpg /etc/apt/keyrings/firezone.gpg
fi
""",
        encoding="utf-8",
    )
    postinst.chmod(0o755)
    subprocess.run(("dpkg-deb", "--root-owner-group", "--build", root, package), check=True)
    return package


def stage_imports(work: Path, import_prefix: str, staged_pool: Path) -> tuple[str, ...]:
    imports = []
    for package in sorted((work / import_prefix).rglob("*.deb")):
        if not package.is_file():
            continue
        fields = command_output(
            "dpkg-deb", "-f", package, "Package", "Version", "Architecture",
        ).decode("utf-8")
        control = dict(line.split(": ", 1) for line in fields.splitlines())
        name_parts = [control.get(field, "") for field in ("Package", "Version", "Architecture")]
        if any(not part or "/" in part for part in name_parts):
            raise ValueError(f"Could not read package, version and architecture from {package}")

        filename = "_".join(name_parts) + ".deb"
        logging.info("Staging %s as %s", package.name, filename)
        shutil.copyfile(package, staged_pool / filename)
        imports.append(package.relative_to(work).as_posix())
    return tuple(imports)


def verify_release_files(metadata: Path, release: str) -> list[str]:
    lines = release.splitlines()
    architectures = next(
        (line.removeprefix("Architectures: ").split()
         for line in lines if line.startswith("Architectures: ")),
        [],
    )
    if not architectures or any(
        not re.fullmatch(r"[a-z0-9][a-z0-9-]*", arch) for arch in architectures
    ):
        raise UnusableIndex("Release has missing or invalid architectures")
    if "Components: main" not in lines or "SHA256:" not in lines:
        raise UnusableIndex("Release is missing the main component or SHA256 checksums")

    verified = set()
    for line in lines[lines.index("SHA256:") + 1:]:
        if not line.startswith(" "):
            break
        fields = line.split(maxsplit=2)
        if len(fields) != 3:
            raise UnusableIndex("Malformed SHA256 entry in Release")
        digest, size, filename = fields
        filename = filename.removeprefix("./")
        if filename == "Release":
            continue  # Older releases included their own checksum before appending it.
        if not filename.startswith("main/") or ".." in filename or not size.isdecimal():
            raise UnusableIndex(f"Invalid SHA256 entry for {filename}")

        path = metadata / filename
        if not path.is_file() or path.stat().st_size != int(size):
            raise UnusableIndex(f"Missing or wrong-sized index file {filename}")
        if file_digest(path, "sha256").hex() != digest:
            raise UnusableIndex(f"SHA256 mismatch for {filename}")
        verified.add(filename)

    for arch in architectures:
        for filename in ("Packages", "Packages.gz", "Release"):
            path = f"main/binary-{arch}/{filename}"
            if path not in verified:
                raise UnusableIndex(f"Release is missing the checksum for {path}")
    return architectures


def read_package_index(index: Path, prefix: str) -> list[PackageRecord]:
    records = []
    for stanza in re.split(r"\n{2,}", index.read_text(encoding="utf-8").strip("\n")):
        if not stanza:
            continue
        fields = {}
        for line in stanza.splitlines():
            field, separator, value = line.partition(": ")
            if separator and field in ("Filename", "Size", "MD5sum"):
                fields[field] = value

        filename = fields.get("Filename", "")
        size = fields.get("Size", "")
        md5 = fields.get("MD5sum", "")
        if (
            not filename.startswith(prefix)
            or not size.isdecimal()
            or not re.fullmatch(r"[0-9a-fA-F]{32}", md5)
        ):
            raise UnusableIndex(f"Invalid package record in {index}")
        records.append(PackageRecord(filename, int(size), bytes.fromhex(md5), stanza))
    return records


def check_index(
    metadata: Path, prefix: str, remote: dict[str, Blob], staged: set[str],
) -> dict[str, list[PackageRecord]]:
    release = (metadata / "Release").read_text(encoding="utf-8")
    architectures = verify_release_files(metadata, release)
    indexes = {
        arch: read_package_index(metadata / "main" / f"binary-{arch}" / "Packages", prefix)
        for arch in architectures
    }

    indexed = {}
    for records in indexes.values():
        for record in records:
            identity = (record.size, record.md5)
            previous = indexed.setdefault(record.filename, identity)
            if previous != identity:
                raise UnusableIndex(f"Conflicting index entries for {record.filename}")

    for filename, (size, md5) in indexed.items():
        if filename in staged:
            continue
        blob = remote.get(filename)
        if blob is None:
            raise InconsistentPool(f"Missing indexed package: {filename}")
        if blob.size != size:
            raise InconsistentPool(f"Wrong size for indexed package: {filename}")
        try:
            remote_md5 = blob.md5()
        except ValueError as error:
            raise UnusableIndex(f"Invalid Azure MD5 for {filename}") from error
        if remote_md5 is not None and remote_md5 != md5:
            raise InconsistentPool(f"Wrong hash for indexed package: {filename}")

    unindexed = remote.keys() - indexed.keys() - staged
    if unindexed:
        raise UnusableIndex(f"Pool contains unindexed packages, including {min(unindexed)}")
    return indexes


def load_previous_index(
    metadata: Path, prefix: str, remote: dict[str, Blob], staged: set[str],
) -> dict[str, list[PackageRecord]] | None:
    release = metadata / "Release"
    try:
        if not release.is_file():
            raise UnusableIndex("No published Release file")
        subprocess.run(
            ("gpg", "--batch", "--verify", metadata / "Release.gpg", release),
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        signed_release = subprocess.check_output(
            ("gpg", "--batch", "--decrypt", metadata / "InRelease"),
            stderr=subprocess.DEVNULL,
        )
        if signed_release != release.read_bytes():
            raise UnusableIndex("InRelease differs from Release")
        return check_index(metadata, prefix, remote, staged)
    except (
        subprocess.CalledProcessError,
        FileNotFoundError,
        UnicodeDecodeError,
        UnusableIndex,
    ) as error:
        logging.info("Rebuilding %s from the full pool: %s", prefix, error)
        return None


def generate_metadata(
    channel: str, metadata: Path, pool: Path, key_id: str,
    previous: dict[str, list[PackageRecord]] | None, staged: set[str],
) -> None:
    architectures = set(previous or ())
    for package in sorted(pool.glob("*.deb")):
        architecture = command_output("dpkg-deb", "-f", package, "Architecture").decode().strip()
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", architecture):
            raise ValueError(f"Invalid architecture in {package}")
        architectures.add(architecture)
    if not architectures:
        raise ValueError(f"No packages for {channel}")

    for arch in sorted(architectures):
        binary_dir = metadata / "main" / f"binary-{arch}"
        binary_dir.mkdir(parents=True)
        new_records = command_output(
            "apt-ftparchive", "packages", "--arch", arch, pool.name, cwd=pool.parent,
        )
        packages = binary_dir / "Packages"
        with packages.open("wb") as index:
            if previous is not None:
                # A new or empty architecture index still needs the existing all-architecture packages.
                old_records = previous.get(arch) or previous.get("all", [])
                for record in old_records:
                    if record.filename not in staged:
                        index.write((record.stanza + "\n\n").encode("utf-8"))
            index.write(new_records)

        with packages.open("rb") as source, gzip.open(binary_dir / "Packages.gz", "wb") as target:
            shutil.copyfileobj(source, target)
        (binary_dir / "Release").write_text(
            f"Archive: {channel}\nComponent: main\nArchitecture: {arch}\n", encoding="utf-8",
        )

    # Compute checksums before writing Release so it doesn't hash itself.
    checksums = command_output("apt-ftparchive", "release", ".", cwd=metadata)
    header = f"""Origin: Firezone
Label: Firezone
Suite: {channel}
Codename: {channel}
Architectures: {' '.join(sorted(architectures))}
Components: main
Description: Firezone APT Repository
Date: {format_datetime(datetime.now(UTC))}
"""
    (metadata / "Release").write_bytes(header.encode("utf-8") + checksums)
    subprocess.run(
        ("gpg", "--default-key", key_id, "-abs", "-o", "Release.gpg", "Release"),
        cwd=metadata, check=True,
    )
    subprocess.run(
        ("gpg", "--default-key", key_id, "--clearsign", "-o", "InRelease", "Release"),
        cwd=metadata, check=True,
    )


def sync_channel(
    channel: str, work: Path, storage: AptStorage, keyring: Path, key_id: str,
) -> ChannelResult:
    pool_name = f"pool-{channel}"
    prefix = f"{pool_name}/"
    import_prefix = f"import-{channel}"
    dist = f"dists/{channel}"

    staged_pool = work / "staged" / pool_name
    staged_pool.mkdir(parents=True)
    storage.download(f"{import_prefix}/*.deb", work)
    imports = stage_imports(work, import_prefix, staged_pool)

    remote = storage.list_pool(prefix)
    if prefix + keyring.name not in remote:
        shutil.copyfile(keyring, staged_pool / keyring.name)
    staged_packages = sorted(staged_pool.glob("*.deb"))
    staged = {prefix + package.name for package in staged_packages}

    previous_dir = work / "previous"
    storage.download(f"{dist}/*", previous_dir)
    previous = load_previous_index(previous_dir / dist, prefix, remote, staged)

    # The incremental path scans just the staged packages. A rebuild scans the entire pool.
    pool = staged_pool
    if previous is not None:
        logging.info("Reusing published package indexes for %s", channel)
    else:
        rebuild_dir = work / "rebuild"
        storage.download(f"{prefix}*.deb", rebuild_dir)
        pool = rebuild_dir / pool_name
        pool.mkdir(exist_ok=True)
        for package in staged_packages:
            shutil.copyfile(package, pool / package.name)

    metadata = work / dist
    generate_metadata(channel, metadata, pool, key_id, previous, staged)
    check_index(metadata, prefix, remote, staged)

    upload = work / "upload"
    upload.mkdir()
    for package in staged_packages:
        blob = remote.get(prefix + package.name)
        if blob and blob.size == package.stat().st_size and blob.md5() == file_digest(package, "md5"):
            continue
        os.link(package, upload / package.name)
    if any(upload.iterdir()):
        storage.upload_directory(upload, pool_name)
    return ChannelResult(channel, metadata, imports)


def main() -> None:
    settings = {}
    for name in ("AZURE_STORAGE_ACCOUNT", "GPG_KEY_ID", "GPG_KEY_EXPIRY"):
        value = os.environ.get(name)
        if not value:
            raise ValueError(f"{name} not set")
        settings[name] = value

    storage = AptStorage(settings["AZURE_STORAGE_ACCOUNT"])
    key_id = settings["GPG_KEY_ID"]
    with TemporaryDirectory(prefix="sync-apt-") as directory:
        work = Path(directory)
        keyring = build_keyring(work, key_id, settings["GPG_KEY_EXPIRY"])
        with ThreadPoolExecutor(max_workers=len(CHANNELS), thread_name_prefix="apt") as workers:
            pending = [
                workers.submit(sync_channel, channel, work / channel, storage, keyring, key_id)
                for channel in CHANNELS
            ]
            results = [future.result() for future in pending]

        # Both package pools must be ready before either channel publishes its metadata.
        for result in results:
            logging.info("Publishing metadata for %s", result.channel)
            prefix = f"dists/{result.channel}"
            storage.upload_directory(result.metadata / "main", f"{prefix}/main")
            for filename in RELEASE_FILES:
                storage.upload_file(result.metadata / filename, f"{prefix}/{filename}")

        public_key = work / "key.gpg"
        public_key.write_bytes(command_output("gpg", "--armor", "--export", key_id))
        storage.upload_file(public_key, "key.gpg")

        # Imports added after the download are left for the next run.
        for result in results:
            for name in result.imports:
                storage.delete_import(name)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"APT sync failed: {error}") from error
