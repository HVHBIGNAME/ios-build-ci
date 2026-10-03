"""Recover the original compiled localization literal using bounded ARM64 emulation."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import (
    UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X30,
    UC_ARM64_REG_SP, UC_ARM64_REG_PC, UC_ARM64_REG_CPACR_EL1,
)
from wgtool.binary import MachO


IPA_SHA256 = "bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837"
MEMBER = "Payload/Telegram.app/Frameworks/TelegramUIFramework.framework/TelegramUIFramework"
ENTRY, END = 0x324F5E4, 0x32620F0
HEAP, STACK, RETURN = 0x20000000, 0x30000000, 0x40000000


def page_size(value: int) -> int:
    return (value + 4095) & ~4095


def swift_string(machine: Uc, first: int, second: int) -> str:
    if second & (1 << 61):
        length = (second >> 56) & 15
        data = struct.pack("<QQ", first, second)[:length]
    else:
        length = first & 0xFFFFFFFFFFFF
        if length > 65536:
            raise ValueError(f"Unexpected Swift string length: {length}")
        address = (second & 0x0FFFFFFFFFFFFFFF) + 32
        data = bytes(machine.mem_read(address, length))
    return data.decode("utf-8")


def decode_table(machine: Uc, address: int) -> dict:
    count = struct.unpack("<Q", machine.mem_read(address + 16, 8))[0]
    if count != 1597:
        raise ValueError(f"Original table count changed: {count}")
    result = {}
    for index in range(count):
        first, second, values = struct.unpack("<QQQ", machine.mem_read(address + 32 + index * 24, 24))
        key = swift_string(machine, first, second)
        languages = struct.unpack("<Q", machine.mem_read(values + 16, 8))[0]
        if languages != 3 or key in result:
            raise ValueError(f"Unexpected localization literal for {key!r}")
        strings = []
        for language in range(languages):
            pair = struct.unpack("<QQ", machine.mem_read(values + 32 + language * 16, 16))
            strings.append(swift_string(machine, *pair))
        result[key] = strings
    return result


def recover(image: MachO) -> dict:
    machine = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    for name, address, size, offset, stored in image.segments:
        if name == "__PAGEZERO" or size == 0:
            continue
        if address % 4096:
            raise ValueError("Unaligned original segment")
        machine.mem_map(address, page_size(size))
        if stored:
            machine.mem_write(address, image.data[offset:offset + stored])
    machine.mem_map(HEAP, 0x100000)
    machine.mem_map(STACK, 0x100000)
    machine.mem_map(RETURN, 4096)
    machine.reg_write(UC_ARM64_REG_SP, STACK + 0x80000)
    machine.reg_write(UC_ARM64_REG_X30, RETURN)
    machine.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    table = None
    allocations = []

    def hook(cpu: Uc, pc: int, size: int, user_data) -> None:
        nonlocal table
        if ENTRY <= pc < END:
            return
        if pc == 0x24C38:
            cpu.reg_write(UC_ARM64_REG_X0, HEAP + 0xF0000)
        elif pc == 0x492D3C0:
            requested = cpu.reg_read(UC_ARM64_REG_X1)
            if allocations or requested != 0x95D8:
                raise ValueError(f"Unexpected allocation: {requested}")
            allocations.append(requested)
            cpu.reg_write(UC_ARM64_REG_X0, HEAP)
        elif pc == 0x492D708:
            cpu.reg_write(UC_ARM64_REG_X0, cpu.reg_read(UC_ARM64_REG_X1))
        elif pc == 0x4927438:
            table = decode_table(cpu, cpu.reg_read(UC_ARM64_REG_X0))
            cpu.emu_stop()
            return
        else:
            raise ValueError(f"Unexpected call outside the literal initializer: {pc:#x}")
        cpu.reg_write(UC_ARM64_REG_PC, cpu.reg_read(UC_ARM64_REG_X30))

    machine.hook_add(UC_HOOK_CODE, hook)
    machine.emu_start(ENTRY, RETURN, timeout=10000000, count=30000)
    if table is None:
        raise ValueError("Localization initializer did not reach its dictionary construction")
    return table


def quote_swift(value: str) -> str:
    escaped = []
    for character in value:
        if character in {'\\', '"'}:
            escaped.append('\\' + character)
        elif character == '\n':
            escaped.append('\\n')
        elif character == '\r':
            escaped.append('\\r')
        elif character == '\t':
            escaped.append('\\t')
        elif ord(character) < 32 or character in '\u2028\u2029':
            escaped.append(f'\\u{{{ord(character):x}}}')
        else:
            escaped.append(character)
    return '"' + ''.join(escaped) + '"'


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--swift", type=Path, required=True)
    args = parser.parse_args()
    for output in (args.json, args.swift):
        if output.exists() or not output.parent.is_dir():
            raise SystemExit(f"Output must be new and its parent must exist: {output}")
    with args.ipa.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != IPA_SHA256:
        raise SystemExit("The original IPA does not match the pinned reference")
    with zipfile.ZipFile(args.ipa) as archive:
        image = MachO(archive.read(MEMBER))
    if image.encrypted or image.cpu != 0x100000C:
        raise SystemExit("Recovery requires the unencrypted original ARM64 image")
    table = recover(image)
    with args.json.open("x", encoding="utf-8") as stream:
        json.dump({"ipa_sha256": digest, "initializer": hex(ENTRY), "entries": table}, stream, ensure_ascii=False, indent=2)
    lines = [
        "import Foundation", "",
        "// Recovered from the original IPA's 0x324f5e4 literal initializer.",
        "// Columns preserve the original Russian, Ukrainian and English order.",
        "public enum WhitegramLocalizationStrings {",
        "    public static let values: [String: [String]] = [",
    ]
    for key, values in table.items():
        lines.append("        " + quote_swift(key) + ": [" + ", ".join(quote_swift(value) for value in values) + "],")
    lines.extend(["    ]", "}", ""])
    with args.swift.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(lines))
    print(json.dumps({"entries": len(table), "sample": dict(list(table.items())[:6]), "swift": str(args.swift)}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
