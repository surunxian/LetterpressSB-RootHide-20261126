#!/usr/bin/env python3
"""Fail-closed structural verifier. Not a device or signature-trust test."""
import argparse
import hashlib
import importlib.util
import io
import json
import plistlib
import re
import struct
import sys
import tarfile
import zlib
from pathlib import Path, PurePosixPath

_signature_spec = importlib.util.spec_from_file_location(
    "letterpress_macho_codesign", Path(__file__).with_name("macho_codesign.py"))
_signature_module = importlib.util.module_from_spec(_signature_spec)
_signature_spec.loader.exec_module(_signature_module)
verify_embedded_signature = _signature_module.verify_signature

DYLIB = "Library/MobileSubstrate/DynamicLibraries/LetterpressSB.dylib"
FILTER = "Library/MobileSubstrate/DynamicLibraries/LetterpressSB.plist"
RESOURCES = "Library/Application Support/LetterpressSB.bundle"
PREFS = "Library/PreferenceBundles/LetterpressSBPrefs.bundle"
PREFEXE = PREFS + "/LetterpressSBPrefs"
LOADER = "Library/PreferenceLoader/Preferences/com.82flex.letterpress.plist"
SPRINGBOARD_FILTER = {"Filter": {"Bundles": ["com.apple.springboard"]}}
MACH_MAGICS = {bytes.fromhex(s) for s in
               ("cffaedfe", "feedfacf", "cefaedfe", "feedface",
                "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
MAX_BYTES = 512 * 1024 * 1024


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# test6: alpha-only rounded derivatives of the pinned test5-packfix artwork.
# Tuple: size, rounded PNG SHA256, original PNG SHA256, original decoded RGB
# SHA256, deterministic 16x16-coverage corner-alpha SHA256. No Pillow dependency.
PREFERENCES_ICONS = {
    "icon.png": (29,
        "23436342295c4ddc59ce6d3de0ab00943de39513bbf221b3ff002bd53237b1a2",
        "c29bc984a7b3e056482d90c98e5a63141f4c168e15c1439c3122ec9f1ce4409b",
        "ff9e331e0c764146bea9993760d788a9fc8110a9eb2c46a047c39ea842eee7d5",
        "85380cdae772d268aff863cc121f042ccf4b69f034940ff064881b0d0ed07f66"),
    "icon@2x.png": (58,
        "c8af9801dbec88ddfcf44256251cc224bdd6e8a8a1e8aa02ffe9d628e832c9e8",
        "59135ba77ea52a390b333ac5edfbb74b210867ee856c3b525dc594891c4b6f6d",
        "22cbe68845f8381a047cbc303a7f739f19e2094514703017edd87b0b0c499598",
        "87ca211660dc793fbf269f0eaa637309dcb4cfdf6cb08f6e6405b4058663dadf"),
    "icon@3x.png": (87,
        "4cf6ff27bd1e557cb4a2a34941a8bfdae9663bfc1c035ce18dfc9e7a00467a68",
        "a0663ea7c72a32202d5733651b3ea35917f68261f92bacdbb6307d11dbd193b3",
        "b40115e4426b15d2971bbcbe403208a5c31fe1c50c455cb5a4905881082d4d34",
        "d4875d0abb7d82f83d5e9e4aff684def36b7fd55787ded438cbdee3c4b312e28"),
}


def inspect_preferences_icon(name, data):
    require(name in PREFERENCES_ICONS, "unknown preferences icon")
    n, png_hash, source_hash, rgb_hash, alpha_hash = PREFERENCES_ICONS[name]
    require(data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 33
            and struct.unpack(">II", data[16:24]) == (n, n),
            "missing or invalid original-app icon size")
    require(sha256(data) == png_hash, f"unreviewed rounded original-app icon: {name}")
    require(data[12:16] == b"IHDR" and data[24:29] == bytes((8, 6, 0, 0, 0)),
            "icon must retain 8-bit RGBA alpha, noninterlaced")
    offset, compressed, ended = 8, bytearray(), False
    while offset < len(data):
        require(offset + 12 <= len(data), "truncated icon chunk")
        length = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + length
        require(end <= len(data), "icon chunk extends beyond PNG")
        kind = data[offset + 4:offset + 8]
        chunk = data[offset + 8:end - 4]
        require(zlib.crc32(kind + chunk) & 0xFFFFFFFF == struct.unpack(">I", data[end - 4:end])[0],
                "icon PNG CRC mismatch")
        if kind == b"IDAT":
            compressed.extend(chunk)
        if kind == b"IEND":
            require(length == 0 and end == len(data), "invalid PNG end")
            ended = True
        offset = end
    require(ended and compressed, "incomplete icon PNG")
    stride = n * 4
    expected = n * (stride + 1)
    inflater = zlib.decompressobj()
    try:
        raw = inflater.decompress(bytes(compressed), expected + 1)
    except zlib.error as error:
        raise VerificationError(f"invalid icon compression: {name}") from error
    require(len(raw) == expected and inflater.eof and not inflater.unused_data
            and not inflater.unconsumed_tail, "invalid icon pixel stream")
    pixels, previous = bytearray(), bytearray(stride)
    for y in range(n):
        start = y * (stride + 1)
        method = raw[start]
        require(0 <= method <= 4, "invalid icon PNG row filter")
        row = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            up = previous[x]
            upper_left = previous[x - 4] if x >= 4 else 0
            if method == 0:
                predictor = 0
            elif method == 1:
                predictor = left
            elif method == 2:
                predictor = up
            elif method == 3:
                predictor = (left + up) // 2
            else:
                p = left + up - upper_left
                a, b, c = abs(p-left), abs(p-up), abs(p-upper_left)
                predictor = left if a <= b and a <= c else up if b <= c else upper_left
            row[x] = (row[x] + predictor) & 255
        pixels.extend(row)
        previous = row
    rgb = bytes(value for index, value in enumerate(pixels) if index % 4 != 3)
    alpha = bytes(pixels[3::4])
    require(sha256(rgb) == rgb_hash, "icon RGB differs from pinned original artwork")
    require(sha256(alpha) == alpha_hash, "icon alpha differs from reviewed rounded mask")
    require(all(alpha[i] == 0 for i in (0, n-1, n*(n-1), n*n-1))
            and alpha[(n//2)*n+n//2] == 255, "icon lacks transparent corners/opaque center")
    return {"size": [n, n], "sha256": png_hash, "original_png_sha256": source_hash,
            "original_rgb_sha256": rgb_hash, "rounded_alpha_sha256": alpha_hash,
            "original_rgb_preserved": True, "transparent_corners": True}


def text(data, start, end):
    require(0 <= start < end <= len(data), "invalid Mach-O string range")
    stop = data.find(b"\0", start, end)
    require(stop >= 0, "unterminated Mach-O string")
    return data[start:stop].decode("utf-8", errors="strict")


def version(value):
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def _slice(data, expected=None, require_signature=True, preferences=False):
    require(len(data) >= 32 and data[:4] == b"\xcf\xfa\xed\xfe",
            "expected little-endian 64-bit Mach-O")
    _, cpu, subtype, kind, ncmds, cmdbytes, flags, reserved = struct.unpack_from("<8I", data)
    require(cpu == 0x100000C, "non-ARM64 CPU in dylib")
    base = subtype & 0xFFFFFF
    require(base in (0, 2), f"unsupported ARM64 subtype {subtype:#x}")
    arch = "arm64e" if base == 2 else "arm64"
    # The iOS 16 baseline must not accept the unversioned legacy arm64e ABI.
    # This is a rejection gate only: a header cannot prove ptrauth codegen or provenance.
    if arch == "arm64e":
        require(subtype == 0x80000002,
                f"arm64e: expected reviewed versioned ptrauth ABI (0x80000002), got {subtype:#010x}")
    else:
        require(subtype == 0, f"unreviewed arm64 capability bits: {subtype:#010x}")
    expected_kind = 8 if preferences else 6
    expected_name = "MH_BUNDLE" if preferences else "MH_DYLIB"
    require(kind == expected_kind, f"{arch}: expected {expected_name} (filetype {kind})")
    if expected:
        require((cpu, subtype) == expected, "fat entry does not match slice CPU/subtype")
    require(ncmds > 0 and ncmds <= 100000 and 32 + cmdbytes <= len(data),
            "invalid load command table")
    pos, commands, ids, deps, rpaths, platforms, signatures = 32, [], [], [], [], [], []
    executable_text = False
    for _ in range(ncmds):
        require(pos + 8 <= 32 + cmdbytes, "truncated load command")
        cmd, size = struct.unpack_from("<II", data, pos)
        end = pos + size
        require(size >= 8 and size % 8 == 0 and end <= 32 + cmdbytes,
                "malformed load command size")
        entry = {"command": f"0x{cmd:08x}", "size": size}
        if cmd in (0xC, 0xD, 0x80000018, 0x8000001F, 0x80000023, 0x20):
            require(size >= 24, "short dylib load command")
            nameoff, timestamp, current, compatibility = struct.unpack_from("<4I", data, pos + 8)
            require(24 <= nameoff < size, "invalid dylib name offset")
            name = text(data, pos + nameoff, end)
            entry.update(name=name, current_version=version(current),
                         compatibility_version=version(compatibility))
            (ids if cmd == 0xD else deps).append(name)
        elif cmd == 0x8000001C:
            require(size >= 16, "short rpath command")
            off = struct.unpack_from("<I", data, pos + 8)[0]
            require(12 <= off < size, "invalid rpath string offset")
            path = text(data, pos + off, end)
            rpaths.append(path)
            entry["path"] = path
        elif cmd == 0x32:
            require(size >= 24, "short build-version command")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", data, pos + 8)
            require(size >= 24 + 8 * tools, "truncated build tool versions")
            platforms.append((platform, minimum, sdk))
            entry.update(platform=platform, minimum_os=version(minimum), sdk=version(sdk))
        elif cmd == 0x25:
            require(size >= 16, "short minimum iOS version command")
            minimum, sdk = struct.unpack_from("<II", data, pos + 8)
            platforms.append((2, minimum, sdk))
            entry.update(platform=2, minimum_os=version(minimum), sdk=version(sdk))
        elif cmd == 0x19:
            require(size >= 72, "short segment command")
            name = data[pos + 8:pos + 24].split(b"\0")[0].decode("ascii")
            fileoff, filesize = struct.unpack_from("<QQ", data, pos + 40)
            initprot, sections = struct.unpack_from("<II", data, pos + 60)
            require(fileoff + filesize <= len(data), "segment extends beyond slice")
            require(size >= 72 + 80 * sections, "truncated section table")
            entry.update(segment=name, file_offset=fileoff, file_size=filesize)
            for index in range(sections):
                sec = pos + 72 + 80 * index
                section = data[sec:sec + 16].split(b"\0")[0]
                secsize = struct.unpack_from("<Q", data, sec + 40)[0]
                if name == "__TEXT" and section == b"__text" and secsize and initprot & 4:
                    executable_text = True
        elif cmd == 0x1D:
            require(size >= 16, "short signature command")
            off, count = struct.unpack_from("<II", data, pos + 8)
            require(count > 0 and off + count <= len(data), "invalid code signature range")
            require(data[off:off + 4] == bytes.fromhex("fade0cc0"), "not a code-signature superblob")
            hash_report = verify_embedded_signature(data, off, count)
            signatures.append({"offset": off, "size": count, "hash_verification": hash_report})
            entry.update(offset=off, bytes=count)
        require(cmd not in (0x80000028, 0xE), "executable-only load command in dylib")
        commands.append(entry)
        pos = end
    require(pos == 32 + cmdbytes, "load commands do not fill declared command bytes")
    expected_id = "@rpath/LetterpressSB.dylib"
    if preferences:
        require(not ids, f"settings bundle must not have a dylib install name: {ids}")
    else:
        require(ids == [expected_id], f"unexpected install name: {ids}")
    require(executable_text, "missing nonempty executable __TEXT,__text section")
    require(len(platforms) == 1 and platforms[0][0] == 2, "expected device-iOS build, not simulator")
    require(platforms[0][1] == 16 << 16 and platforms[0][2] >= 16 << 16,
            "deployment target must be exactly iOS 16.0 with an iOS 16+ SDK")
    require(len(signatures) <= 1, "duplicate signature commands")
    require(not require_signature or signatures, "missing ad-hoc signature")
    for dep in deps:
        allowed = dep.startswith(("/System/Library/Frameworks/", "/System/Library/PrivateFrameworks/", "/usr/lib/"))
        allowed |= bool(re.fullmatch(r"@rpath/libswift[A-Za-z0-9_]+\.dylib", dep))
        require(allowed and ".." not in PurePosixPath(dep).parts,
                f"unpackaged or host-only dependency: {dep}")
    require(all(p in ("/usr/lib/swift", "@loader_path") for p in rpaths),
            f"unexpected runtime search path: {rpaths}")
    return {"arch": arch, "cpu": cpu, "subtype_raw": f"0x{subtype:08x}",
            "filetype": expected_name, "flags": f"0x{flags:08x}", "bytes": len(data),
            "sha256": sha256(data), "dependencies": deps, "rpaths": rpaths,
            "signature_blobs": signatures, "load_commands": commands}


def inspect_macho(data, require_signature=True, preferences=False):
    require(0 < len(data) <= MAX_BYTES, "invalid Mach-O file size")
    magic = data[:4]
    formats = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
               b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    require(magic in formats, "expected universal binary with separate arm64 and arm64e slices")
    endian, wide = formats[magic]
    require(len(data) >= 8, "short fat header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    require(count == 2, "exactly arm64 and arm64e slices are required")
    entry_size, entries, spans, slices = (32 if wide else 20), [], [], []
    table_end = 8 + count * entry_size
    require(table_end <= len(data), "truncated fat table")
    for i in range(count):
        off = 8 + i * entry_size
        fmt = endian + ("IIQQII" if wide else "IIIII")
        entry = struct.unpack_from(fmt, data, off)
        cpu, subtype, start, size, align = entry[:5]
        require(align <= 31 and start % (1 << align) == 0, "invalid fat slice alignment")
        require(start >= table_end and size >= 32 and start + size <= len(data), "invalid fat slice range")
        spans.append((start, start + size))
        parsed = _slice(data[start:start + size], (cpu, subtype), require_signature, preferences)
        parsed["file_offset"] = start
        slices.append(parsed)
    spans.sort()
    require(spans[0][1] <= spans[1][0], "overlapping Mach-O slices")
    require({s["arch"] for s in slices} == {"arm64", "arm64e"}, "missing true arm64e or arm64 slice")
    require(set(slices[0]["dependencies"]) == set(slices[1]["dependencies"]),
            "architecture-dependent dylib dependencies need explicit review")
    return {"sha256": sha256(data), "bytes": len(data), "slices": slices,
            "signature_check": "embedded CodeDirectory page/blob hashes verified; not Apple trust validation",
            "provenance_limit": "headers alone cannot prove compiler provenance or arm64e ABI; retain build logs"}


def control_fields(data):
    fields = {}
    last = None
    for line in data.decode("utf-8").splitlines():
        if not line:
            continue
        if line[0].isspace():
            require(last is not None, "orphan control continuation")
            fields[last] += "\n" + line
            continue
        require(":" in line, "malformed control line")
        key, value = line.split(":", 1)
        require(re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", key) and key not in fields,
                "invalid/duplicate control field")
        fields[key], last = value.strip(), key
    for name in ("Package", "Name", "Version", "Architecture", "Description", "Maintainer", "Depends"):
        require(fields.get(name), f"missing control field {name}")
    require(re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", fields["Package"]), "invalid package identifier")
    require(re.fullmatch(r"[0-9][A-Za-z0-9.+:~\-]*", fields["Version"]), "invalid package version")
    require(fields["Architecture"] == "iphoneos-arm64e", "package must use RootHide iphoneos-arm64e architecture")
    return fields


def _ar(data):
    require(data.startswith(b"!<arch>\n"), "not an ar/deb archive")
    pos, result = 8, {}
    while pos < len(data):
        require(pos + 60 <= len(data), "truncated ar header")
        header = data[pos:pos + 60]
        require(header[58:60] == b"`\n", "bad ar header trailer")
        name = header[:16].decode("ascii").strip().removesuffix("/")
        size = int(header[48:58].decode("ascii").strip())
        pos += 60
        require(name and name not in result and 0 <= size <= MAX_BYTES and pos + size <= len(data),
                "invalid or duplicate ar member")
        result[name] = data[pos:pos + size]
        pos += size
        if pos % 2:
            require(data[pos:pos + 1] == b"\n", "bad ar padding")
            pos += 1
    require(set(result) == {"debian-binary", "control.tar.gz", "data.tar.gz"},
            "unexpected deb members (only the draft gzip format is supported)")
    require(result["debian-binary"] == b"2.0\n", "unsupported deb version")
    return result


def _tar(data):
    files, dirs, names, total = {}, set(), set(), 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for item in archive:
            require(len(names) < 20000, "too many tar members")
            name = item.name
            if name.startswith("./"):
                name = name[2:]
            if name in ("", "."):
                require(item.isdir(), "invalid root tar entry")
                continue
            path = PurePosixPath(name)
            require(not path.is_absolute() and ".." not in path.parts and str(path) == name.rstrip("/"),
                    f"unsafe tar path: {name}")
            name = str(path)
            require(name not in names and not any(p.casefold() == "applications" for p in path.parts),
                    f"duplicate or Applications path: {name}")
            require(item.uid == 0 and item.gid == 0 and not (item.mode & 0o7000), "unsafe tar ownership/mode")
            require(item.isdir() or item.isfile(), "links and special tar entries are forbidden")
            names.add(name)
            if item.isdir():
                require(item.mode == 0o755, "directories must have mode 0755")
                dirs.add(name)
            else:
                total += item.size
                require(0 <= item.size <= MAX_BYTES and total <= MAX_BYTES, "oversized package payload")
                require(item.mode == (0o755 if name in (DYLIB, PREFEXE) else 0o644), f"unexpected mode on {name}")
                content = archive.extractfile(item).read()
                require(len(content) == item.size, "short tar file")
                files[name] = content
    return files, dirs


def inspect_resources(files):
    prefix = RESOURCES + "/"
    require(prefix + "Info.plist" in files, "missing LetterpressSB resource bundle Info.plist")
    info = plistlib.loads(files[prefix + "Info.plist"])
    require(info.get("CFBundlePackageType") == "BNDL" and "CFBundleExecutable" not in info,
            "LetterpressSB resources must be a non-executable bundle")
    resources = [n for n in files if n.startswith(prefix)]
    fonts = [n for n in resources if n.lower().endswith((".ttf", ".otf"))]
    strings = [n for n in resources if re.search(r"\.lproj/Localizable\.strings$", n)]
    require(fonts, "resource bundle has no fonts (.ttf/.otf)")
    require(strings, "resource bundle has no localized Localizable.strings")
    return {"bundle_id": info.get("CFBundleIdentifier"), "fonts": fonts, "localizations": strings}


def inspect_deb(data, expected_control=None):
    require(0 < len(data) <= MAX_BYTES, "invalid deb size")
    members = _ar(data)
    controls, control_dirs = _tar(members["control.tar.gz"])
    require(set(controls) == {"control", "md5sums"} and not control_dirs,
            "only control and md5sums are allowed; no maintainer/restart scripts")
    fields = control_fields(controls["control"])
    require(fields.get("Package") == "com.82flex.letterpress", "incorrect Letterpress package ID")
    require(fields.get("Name") == "Letterpress" and fields.get("Author") == "82Flex"
            and fields.get("Maintainer") == "82Flex", "incorrect user-requested display identity")
    require(fields.get("Conflicts") == "dev.letterpress.springboard"
            and fields.get("Replaces") == "dev.letterpress.springboard", "missing legacy package replacement")
    if expected_control is not None:
        require(fields == control_fields(expected_control), "deb control differs from supplied control")
    files, dirs = _tar(members["data.tar.gz"])
    require(DYLIB in files and FILTER in files, "missing tweak dylib or injection filter")
    require(plistlib.loads(files[FILTER]) == SPRINGBOARD_FILTER, "filter must select ONLY com.apple.springboard")
    root = "Library/MobileSubstrate/DynamicLibraries/"
    spm_bundles = set()
    for name, content in files.items():
        if name in (DYLIB, FILTER, PREFEXE, LOADER):
            continue
        allowed = name.startswith((RESOURCES + "/", PREFS + "/"))
        if name.startswith(root):
            relative = name[len(root):]
            bundle = relative.split("/", 1)[0]
            if re.fullmatch(r"[A-Za-z0-9_.-]+\.bundle", bundle) and "/" in relative:
                allowed = True
                spm_bundles.add(bundle)
        require(allowed, f"unexpected installed file: {name}")
        require(not any(p.endswith((".app", ".framework", ".dylib")) for p in PurePosixPath(name).parts),
                f"executable wrapper in resources: {name}")
        require(content[:4] not in MACH_MAGICS, f"Mach-O file in resource payload: {name}")
        if name.endswith("/Info.plist"):
            require(name == PREFS + "/Info.plist" or "CFBundleExecutable" not in plistlib.loads(content), "executable resource bundle")
    allowed_dirs = {str(p) for name in files for p in PurePosixPath(name).parents if str(p) != "."}
    require(dirs <= allowed_dirs, f"unexpected installed directory: {sorted(dirs - allowed_dirs)}")
    actual_md5 = {}
    for line in controls["md5sums"].decode("utf-8").splitlines():
        require(re.fullmatch(r"[0-9a-f]{32}  .+", line), "malformed md5sums")
        digest, name = line.split("  ", 1)
        require(name not in actual_md5, "duplicate md5sums member")
        actual_md5[name] = digest
    require(actual_md5 == {n: hashlib.md5(c).hexdigest() for n, c in files.items()}, "md5sums mismatch")
    require(PREFEXE in files and LOADER in files, "missing settings bundle or loader entry")
    prefs_info = plistlib.loads(files.get(PREFS + "/Info.plist", b""))
    require(prefs_info.get("CFBundleExecutable") == "LetterpressSBPrefs", "wrong settings bundle executable")
    require(PREFS + "/Root.plist" in files, "missing settings Root.plist")
    require(prefs_info.get("CFBundleIdentifier") == "com.82flex.letterpress.preferences"
            and prefs_info.get("CFBundleDisplayName") == "Letterpress", "wrong preferences identity")
    loader = plistlib.loads(files[LOADER]).get("entry", {})
    require(loader.get("label") == "Letterpress" and loader.get("icon") == "icon.png"
            and loader.get("bundle") == "LetterpressSBPrefs", "wrong settings entry/icon")
    root_plist = plistlib.loads(files[PREFS + "/Root.plist"])
    require(root_plist.get("title") == "Letterpress" and root_plist.get("defaults") == "com.82flex.letterpress",
            "wrong root title or preferences filename/domain")
    for item in root_plist.get("items", []):
        if item.get("key"):
            require(item.get("defaults") == "com.82flex.letterpress", "mixed preference domains")
    icon_report = {name: inspect_preferences_icon(name, files.get(PREFS + "/" + name, b""))
                   for name in PREFERENCES_ICONS}
    prefs_report = inspect_macho(files[PREFEXE], preferences=True)
    resources = inspect_resources(files)
    return {"sha256": sha256(data), "bytes": len(data), "control": fields,
            "preferences_macho": prefs_report, "macho": inspect_macho(files[DYLIB]), "resources": resources,
            "preferences_icons": icon_report,
            "spm_resource_bundles": sorted(spm_bundles),
            "payload_sha256": {n: sha256(c) for n, c in sorted(files.items())},
            "checks": {"springboard_only": True, "no_applications": True,
                       "unprefixed_roothide_layout": True, "no_maintainer_scripts": True},
            "not_tested": ["device injection", "RootHide loader compatibility", "resource lookup at runtime"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--macho", type=Path, help="universal LetterpressSB.dylib")
    parser.add_argument("--deb", type=Path, help="draft gzip-format deb")
    parser.add_argument("--control", type=Path, help="compare deb metadata to this control")
    parser.add_argument("--allow-unsigned", action="store_true", help="pre-sign Mach-O check only; never relaxes deb checks")
    parser.add_argument("--output", type=Path, help="write JSON report as well as stdout")
    args = parser.parse_args()
    parser.error("supply --macho and/or --deb") if not (args.macho or args.deb) else None
    try:
        result = {"verification": "structural only", "status": "pass"}
        if args.macho:
            result["macho"] = inspect_macho(args.macho.read_bytes(), not args.allow_unsigned)
        if args.deb:
            result["deb"] = inspect_deb(args.deb.read_bytes(), args.control.read_bytes() if args.control else None)
        output = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output:
            # Verifier writes only inside this build directory, never an arbitrary path.
            base = Path(__file__).resolve().parent
            target = args.output.resolve()
            require(base in target.parents, "report output must be under Port/Build")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(output, encoding="utf-8")
        print(output, end="")
    except (VerificationError, OSError, ValueError, UnicodeError, struct.error, tarfile.TarError, plistlib.InvalidFileException) as error:
        print(f"VERIFY FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
