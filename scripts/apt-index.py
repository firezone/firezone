#!/usr/bin/env python3

"""Reuse published APT package records when the blob pool matches them."""

import base64
import binascii
import hashlib
import json
import os
import pathlib
import sys


def records(path):
    if not path.is_file():
        raise ValueError(f"Missing index: {path}")
    result = {}
    for stanza in path.read_text().strip().split("\n\n"):
        if not stanza:
            continue
        fields = dict(
            line.split(": ", 1)
            for line in stanza.splitlines()
            if line and not line[0].isspace() and ": " in line
        )
        filename = fields.get("Filename")
        if not filename or filename in result:
            raise ValueError(f"Invalid package record in {path}: {filename}")
        result[filename] = (stanza, fields)
    return result


def release_fields(path):
    fields = {}
    for line in path.read_text().splitlines():
        if line and not line[0].isspace() and ": " in line:
            key, value = line.split(": ", 1)
            fields[key] = value
    return fields


def check(metadata, listing, staged, distribution):
    release = metadata / "Release"
    fields = release_fields(release)
    architectures = fields.get("Architectures", "").split()
    if not architectures or fields.get("Components") != "main":
        raise ValueError("Missing architectures or component in Release")

    hashes = release.read_text().split("SHA256:\n", 1)
    if len(hashes) != 2:
        raise ValueError("Missing SHA256 section in Release")
    verified = set()
    for line in hashes[1].splitlines():
        if not line.startswith(" "):
            break
        digest, size, name = line.split()
        name = name.removeprefix("./")
        if name == "Release":
            continue
        indexed = metadata / name
        if not indexed.is_file() or indexed.stat().st_size != int(size):
            raise ValueError(f"Missing or changed metadata file: {name}")
        if hashlib.sha256(indexed.read_bytes()).hexdigest() != digest:
            raise ValueError(f"Changed metadata file: {name}")
        verified.add(name)

    required = {
        f"main/binary-{arch}/{name}"
        for arch in architectures
        for name in ("Packages", "Packages.gz", "Release")
    }
    if not required <= verified:
        raise ValueError(f"Missing checksums for: {', '.join(sorted(required - verified))}")

    indexed_packages = {}
    for arch in architectures:
        index = metadata / "main" / f"binary-{arch}" / "Packages"
        for filename, (_, entry) in records(index).items():
            if not filename.startswith(f"pool-{distribution}/"):
                raise ValueError(f"Unexpected package path: {filename}")
            if filename in indexed_packages and indexed_packages[filename] != entry:
                raise ValueError(f"Conflicting package records: {filename}")
            indexed_packages[filename] = entry

    blobs = {}
    for blob in json.loads(listing.read_text()):
        name = blob["name"]
        if name.endswith(".deb"):
            blobs[name] = blob["properties"]

    for filename, entry in indexed_packages.items():
        if (staged / pathlib.Path(filename).name).is_file():
            continue
        blob = blobs.get(filename)
        if blob is None:
            raise FileNotFoundError(f"Indexed package is missing from Blob storage: {filename}")
        if int(entry["Size"]) != blob["contentLength"]:
            raise FileNotFoundError(f"Package size differs from index: {filename}")
        md5 = (blob.get("contentSettings") or {}).get("contentMd5")
        if md5 and entry.get("MD5sum", "").lower() != base64.b64decode(md5).hex():
            raise FileNotFoundError(f"Package hash differs from index: {filename}")

    if set(blobs) - set(indexed_packages) - {
        f"pool-{distribution}/{path.name}" for path in staged.glob("*.deb")
    }:
        raise ValueError("Pool contains packages absent from published indices")

    print(" ".join(architectures))


def merge(old, new, output, staged, old_all):
    previous = records(old) if old.is_file() else {}
    if not previous and old_all.is_file() and old != old_all:
        previous = records(old_all)
    changed = {f"{staged.name}/{path.name}" for path in staged.glob("*.deb")}
    current = records(new)
    if not set(current) <= changed:
        raise ValueError(f"Unexpected package in generated index: {new}")
    entries = [stanza for name, (stanza, _) in previous.items() if name not in changed]
    entries.extend(stanza for stanza, _ in current.values())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n\n".join(entries) + ("\n\n" if entries else ""))


def uploads(listing, staged, destination, distribution):
    blobs = {blob["name"]: blob["properties"] for blob in json.loads(listing.read_text())}
    destination.mkdir(parents=True, exist_ok=True)
    for path in staged.glob("*.deb"):
        remote = blobs.get(f"pool-{distribution}/{path.name}")
        if remote and remote["contentLength"] == path.stat().st_size:
            md5 = (remote.get("contentSettings") or {}).get("contentMd5")
            if md5 and base64.b64decode(md5).hex() == hashlib.md5(path.read_bytes()).hexdigest():
                continue
        os.link(path, destination / path.name)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "check":
            check(*(pathlib.Path(arg) for arg in sys.argv[2:5]), sys.argv[5])
        elif sys.argv[1] == "merge":
            merge(*(pathlib.Path(arg) for arg in sys.argv[2:]))
        elif sys.argv[1] == "uploads":
            uploads(*(pathlib.Path(arg) for arg in sys.argv[2:5]), sys.argv[5])
        else:
            raise ValueError("Expected check, merge, or uploads")
    except FileNotFoundError as exc:
        print(exc, file=sys.stderr)
        sys.exit(20)
    except (ValueError, KeyError, OSError, TypeError, binascii.Error) as exc:
        print(exc, file=sys.stderr)
        sys.exit(10)
