#!/usr/bin/env python3
"""Check appearance contracts by executing bounded regions of the audited ARM64 IPA.

Run with the evidence environment (wgtool, Capstone and Unicorn). Neither the
audit nor the reference source is modified. The optional report is created once.
This executes original machine code, not the candidate Swift implementation.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import struct
import sys
import zipfile

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import (
    UC_ARM64_REG_CPACR_EL1, UC_ARM64_REG_D0, UC_ARM64_REG_D8,
    UC_ARM64_REG_D9, UC_ARM64_REG_D10, UC_ARM64_REG_D11,
    UC_ARM64_REG_S0, UC_ARM64_REG_S1, UC_ARM64_REG_X0,
    UC_ARM64_REG_X21, UC_ARM64_REG_PC,
)


IPA_SHA256 = "bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837"


def bits(value):
    return struct.unpack("<Q", struct.pack("<d", value))[0]


def double(value):
    return struct.unpack("<d", struct.pack("<Q", value))[0]


def single(value):
    return struct.unpack("<f", struct.pack("<I", value))[0]


def execute(image, start, stops, inputs, outputs, extra_regions=()):
    cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    pages = set()
    for lower, upper in [(start, max(stops) + 4), *extra_regions]:
        pages.update(range(lower & ~0xfff, (upper + 0xfff) & ~0xfff, 0x1000))
    for page in sorted(pages):
        offset = image.vm_offset(page)
        cpu.mem_map(page, 0x1000)
        cpu.mem_write(page, image.data[offset:offset + 0x1000])
    cpu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    for register, value in inputs.items():
        cpu.reg_write(register, value & ((1 << 64) - 1))
    reached = []

    def stop_at_boundary(machine, address, size, data):
        if address in stops:
            reached.append(address)
            machine.emu_stop()

    cpu.hook_add(UC_HOOK_CODE, stop_at_boundary)
    cpu.emu_start(start, 0, count=64)
    if len(reached) != 1:
        raise AssertionError(f"Original region {start:#x} did not reach a boundary: {cpu.reg_read(UC_ARM64_REG_PC):#x}")
    return reached[0], [cpu.reg_read(register) for register in outputs]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def swift_range(source, name):
    match = re.search(rf"let {name}: ClosedRange<\w+> = ([\d_.]+) \.\.\. ([\d_.]+)", source)
    require(match is not None, f"Missing candidate range {name}")
    return tuple(float(value.replace("_", "")) for value in match.groups())


def verify(core, ui, candidate):
    checks = []
    for name, start, end, original_default in (
        ("stickerSizeScale", 0x1f8e80, 0x1f8e8c, 1.0),
        ("tabBarScale", 0x204744, 0x204754, 100.0),
        ("tabBarWidthScale", 0x2048dc, 0x2048ec, 100.0),
    ):
        for stored in (0.0, 0.5, 1.0, 75.0, 150.0):
            _, result = execute(core, start, [end], {UC_ARM64_REG_D8: bits(stored)}, [UC_ARM64_REG_D0])
            require(double(result[0]) == (original_default if stored == 0 else stored), name)
        checks.append({"key": name, "getter_default": original_default, "region": [hex(start), hex(end)]})

    for stored in (0, 1, 9999, 9_999_999, (1 << 63) - 1):
        _, result = execute(core, 0x201880, [0x20188c], {UC_ARM64_REG_X21: stored}, [UC_ARM64_REG_X0])
        require(result[0] == (9999 if stored == 0 else stored), "Original Int64 Stars fallback")

    for key, start, end, input_register, output_register, extra in (
        ("tabBarWidthScale", 0x609c88, 0x609cb4, UC_ARM64_REG_D11, UC_ARM64_REG_D0, ()),
        ("tabBarScale", 0x20f116c, 0x20f1194, UC_ARM64_REG_D9, UC_ARM64_REG_D10, ((0x20f6ec8, 0x20f6ed8),)),
    ):
        for stored, factor in ((-1.0, 1.0), (0.0, 1.0), (1.0, 0.5), (50.0, 0.5), (75.0, 0.75), (100.0, 1.0), (150.0, 1.5), (900.0, 1.5)):
            _, result = execute(ui, start, [end], {input_register: bits(stored)}, [output_register], extra)
            require(double(result[0]) == factor, f"Original {key} clamp for {stored}")
        checks.append({"key": key, "render_percent_range": [50, 150], "region": [hex(start), hex(end)]})

    for name, start, end, expected in (
        ("sticker", 0xddc4bc, 0xddc4c8, (10, 200)),
        ("tabs", 0xde0298, 0xde02a8, (50, 150)),
    ):
        _, result = execute(ui, start, [end], {}, [UC_ARM64_REG_S0, UC_ARM64_REG_S1])
        require(tuple(single(value) for value in result) == expected, f"Original {name} slider range")
    stars_limit = single(struct.unpack_from("<I", ui.data, ui.vm_offset(0x497a740))[0])
    require(stars_limit == 9999, f"Unexpected original Stars slider maximum: {stars_limit}")

    for name, start, accepted, rejected, samples in (
        ("sticker", 0xe041fc, 0xe04208, 0xe04254, [(n, 10 <= n <= 200) for n in (-1, 0, 9, 10, 100, 200, 201)]),
        ("stars", 0xe05e70, 0xe05e88, 0xe05ec4, [(n, 1 <= n <= 9_999_999) for n in (-1, 0, 1, 9999, 9_999_999, 10_000_000, (1 << 63) - 1)]),
    ):
        for value, allowed in samples:
            reached, _ = execute(ui, start, [accepted, rejected], {UC_ARM64_REG_X21: value}, [])
            require((reached == accepted) == allowed, f"Original {name} custom boundary {value}")
        checks.append({"custom_input": name, "accepted": [n for n, allowed in samples if allowed], "rejected": [n for n, allowed in samples if not allowed]})
    for value, allowed in ((49.9, False), (50.0, True), (75.5, True), (100.0, True), (100.1, False), (150.0, False)):
        reached, _ = execute(ui, 0xe077d0, [0xe077ec, 0xe07828], {UC_ARM64_REG_D8: bits(value)}, [])
        require((reached == 0xe077ec) == allowed, f"Original height custom boundary {value}")

    _, result = execute(core, 0x204660, [0x212b34], {}, [UC_ARM64_REG_X0])
    require(result[0] == 0, "hideBottomTabBar is a disabled getter in this IPA")
    for enabled in (0, 1):
        reached, _ = execute(ui, 0x8228c0, [0x8228c4, 0x822a50], {UC_ARM64_REG_X0: enabled}, [])
        require(reached == (0x822a50 if enabled else 0x8228c4), "Original phone rows have an unconditional preference gate")
    policy = (candidate / "WhitegramAppearancePolicy.swift").read_text(encoding="utf-8")
    stars = (candidate / "WhitegramLocalStars.swift").read_text(encoding="utf-8")
    require(swift_range(policy, "stickerPercentRange") == (10, 200), "Candidate sticker range differs from original")
    require(swift_range(policy, "tabPercentRange") == (50, 150), "Candidate tab slider range differs from original")
    require(swift_range(policy, "tabHeightInputRange") == (50, 100), "Candidate height input range differs from original")
    require(swift_range(stars, "sliderRange") == (1, stars_limit), "Candidate Stars slider range differs from original")
    require(swift_range(stars, "inputRange") == (1, 9_999_999), "Candidate Stars input range differs from original")
    checks.append({"key": "localStarsCount", "getter_default": 9999, "slider_range": [1, int(stars_limit)], "custom_range": [1, 9_999_999]})
    checks.append({"key": "hideBottomTabBar", "getter_always": False, "region": ["0x204660", "0x212b30"]})
    checks.append({"key": "hidePhoneNumber", "scope": "all user profile phone rows", "branch": "55:0x8228c0"})
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.report is not None and (not args.report.parent.is_dir() or args.report.exists()):
        parser.error("--report must be a new file in an existing owned directory")
    sys.path.insert(0, str(args.evidence_root))
    from wgtool.binary import MachO
    audit = args.evidence_root / "audit-full-3.1.1"
    manifest = json.loads((audit / "manifest.json").read_text(encoding="utf-8"))
    with Path(manifest["ipa"]).open("rb") as stream:
        sha = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(chunk)
    require(sha.hexdigest() == IPA_SHA256 == manifest["ipa_sha256"], "Original IPA hash changed")
    connection = sqlite3.connect((audit / "audit.sqlite3").resolve().as_uri() + "?mode=ro", uri=True)
    try:
        connection.execute("PRAGMA query_only = ON")
        images = {}
        with zipfile.ZipFile(manifest["ipa"]) as archive:
            for image_id, framework in ((46, "TelegramCoreFramework"), (55, "TelegramUIFramework")):
                member, base = connection.execute("SELECT member, base FROM images WHERE id=?", (image_id,)).fetchone()
                require(framework in member, f"Wrong image {image_id}")
                images[image_id] = MachO(archive.read(member), base)
        candidate = Path(__file__).resolve().parents[2] / "cleanroom"
        checks = verify(images[46], images[55], candidate)
        search_sites = connection.execute("SELECT r.caller,r.site FROM string_refs r JOIN strings s ON s.image_id=r.image_id AND s.address=r.string_address WHERE r.image_id=55 AND s.text='wg_hideSearchBar'").fetchall()
        require((0x609548, 0x609a4c) in search_sites, "Original tab-bar search gate missing")
        checks.append({"key": "hideSearchBar", "scope": "TabBarComponent.Search", "site": "55:0x609a4c"})
    finally:
        connection.close()
    report = {"ipa_sha256": IPA_SHA256, "validation": "original ARM64 regions and candidate declared limits; not a Swift typecheck", "checks": checks}
    if args.report is not None:
        with args.report.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
