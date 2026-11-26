#!/usr/bin/env python3
"""Package an already Apple-built, ad-hoc-signed dylib. Never builds or installs."""
import argparse
import gzip
import hashlib
import io
import json
import os
import plistlib
import sys
import tarfile
from pathlib import Path, PurePosixPath

sys.dont_write_bytecode = True
from verify import (DYLIB, FILTER, RESOURCES, PREFS, PREFEXE, LOADER, SPRINGBOARD_FILTER, VerificationError,
                    control_fields, inspect_deb, inspect_macho, require)

BUILD = Path(__file__).resolve().parent
PORT = BUILD.parent


def add_tree(files, source, destination):
    require(source.is_dir() and not source.is_symlink(), f"missing/linked resource directory: {source}")
    for path in sorted(source.rglob("*")):
        require(not path.is_symlink(), f"resource symlink is forbidden: {path}")
        require(path.is_dir() or path.is_file(), f"special resource file: {path}")
        if path.is_dir() or path.name == ".DS_Store":
            continue
        relative = path.relative_to(source).as_posix()
        require("\n" not in relative and "\r" not in relative, "newline in resource filename")
        name = destination + "/" + relative
        require(name not in files, f"duplicate packaged resource: {name}")
        files[name] = path.read_bytes()


def tar_gzip(files, epoch, include_directories):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        dirs = set()
        if include_directories:
            dirs = {str(p) for name in files for p in PurePosixPath(name).parents if str(p) != "."}
        for name in sorted(dirs):
            member = tarfile.TarInfo("./" + name)
            member.type, member.mode, member.mtime = tarfile.DIRTYPE, 0o755, epoch
            member.uid = member.gid = 0
            member.uname = member.gname = "root"
            archive.addfile(member)
        for name, data in sorted(files.items()):
            member = tarfile.TarInfo("./" + name)
            member.size, member.mtime = len(data), epoch
            member.mode = 0o755 if name in (DYLIB, PREFEXE) else 0o644
            member.uid = member.gid = 0
            member.uname = member.gname = "root"
            archive.addfile(member, io.BytesIO(data))
    result = io.BytesIO()
    with gzip.GzipFile(filename="", fileobj=result, mode="wb", compresslevel=9, mtime=epoch) as compressed:
        compressed.write(buffer.getvalue())
    return result.getvalue()


def ar(members, epoch):
    result = bytearray(b"!<arch>\n")
    for name, data in members:
        require(len(name) <= 15, "ar member name too long")
        header = f"{name + '/':<16}{epoch:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode("ascii")
        require(len(header) == 60, "ar header field overflow")
        result.extend(header)
        result.extend(data)
        if len(data) % 2:
            result.extend(b"\n")
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dylib", required=True, type=Path)
    parser.add_argument("--products", type=Path, help="Xcode build-products directory, for sibling SPM .bundle resources")
    parser.add_argument("--resources", type=Path, default=PORT / "Resources")
    parser.add_argument("--control", type=Path, default=PORT / "control")
    parser.add_argument("--output-dir", type=Path, default=BUILD / "output")
    args = parser.parse_args()
    try:
        output_dir = args.output_dir.resolve()
        require(BUILD in output_dir.parents, "package output must be strictly inside Port/Build")
        epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
        require(0 <= epoch <= 0x7FFFFFFF, "invalid SOURCE_DATE_EPOCH")
        require(args.dylib.name == "LetterpressSB.dylib" and not args.dylib.is_symlink(),
                "supply the actual LetterpressSB.dylib product, not an app or symlink")
        binary = args.dylib.read_bytes()
        inspect_macho(binary)  # Must pass before even constructing a package.
        control = args.control.read_bytes()
        fields = control_fields(control)
        require(":" not in fields["Version"], "epoch versions need an explicit output filename policy")
        files = {DYLIB: binary, FILTER: plistlib.dumps(SPRINGBOARD_FILTER, sort_keys=True)}
        add_tree(files, args.resources, RESOURCES)
        info_path = RESOURCES + "/Info.plist"
        if info_path not in files:
            files[info_path] = plistlib.dumps({
                "CFBundleIdentifier": "dev.letterpress.springboard.resources",
                "CFBundleName": "LetterpressSB",
                "CFBundlePackageType": "BNDL",
                "CFBundleVersion": "1",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleDevelopmentRegion": "en",
            }, sort_keys=True)
        products = args.products or args.dylib.parent
        require(products.is_dir(), "missing Xcode build-products directory")
        prefs = products / "LetterpressSBPrefs.bundle"
        inspect_macho((prefs / "LetterpressSBPrefs").read_bytes(), preferences=True)
        add_tree(files, prefs, PREFS)
        files[LOADER] = (PORT / "Preferences/Resources/preference-loader.plist").read_bytes()
        for bundle in sorted(products.glob("*.bundle")):
            if bundle.name == "LetterpressSBPrefs.bundle":
                continue
            # Static SwiftPM resources may need a custom runtime lookup adapter.
            add_tree(files, bundle, "Library/MobileSubstrate/DynamicLibraries/" + bundle.name)
        sums = "".join(hashlib.md5(data).hexdigest() + "  " + name + "\n"
                       for name, data in sorted(files.items())).encode("utf-8")
        package = ar([
            ("debian-binary", b"2.0\n"),
            ("control.tar.gz", tar_gzip({"control": control, "md5sums": sums}, epoch, False)),
            ("data.tar.gz", tar_gzip(files, epoch, True)),
        ], epoch)
        report = inspect_deb(package, control)
        output_dir.mkdir(parents=True, exist_ok=True)
        name = f"LetterpressSB_{fields['Version']}_iphoneos-arm64e.deb"
        target = output_dir / name
        temporary = target.with_suffix(".deb.tmp")
        temporary.write_bytes(package)
        temporary.replace(target)
        (output_dir / (name + ".verification.json")).write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (output_dir / "SHA256SUMS").write_text(report["sha256"] + "  " + name + "\n", encoding="ascii")
        print(target)
        print("Structural checks passed; this does not prove device/RootHide compatibility.")
    except (OSError, ValueError, VerificationError, plistlib.InvalidFileException, tarfile.TarError) as error:
        print(f"PACKAGE FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
