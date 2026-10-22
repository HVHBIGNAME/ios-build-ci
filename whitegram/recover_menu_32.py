"""Recover Beta 3.2's compiled menu and built-in translations with bounded emulation."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

from unicorn import Uc, UcError, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X30, UC_ARM64_REG_SP, UC_ARM64_REG_PC, UC_ARM64_REG_CPACR_EL1
from wgtool.binary import MachO
from wgtool.reflection import recover_types

IPA_SHA256 = "5cf287812de7707dd21256281e645c29a9a5c0da3f66910746254842fce5ffbf"
MEMBER = "Payload/Telegram.app/Frameworks/TelegramUIFramework.framework/TelegramUIFramework"
HEAP, STACK, RETURN = 0x20000000, 0x30000000, 0x40000000


def swift_string(machine, first, second):
    if second & (1 << 61):
        data = struct.pack("<QQ", first, second)[:(second >> 56) & 15]
    else:
        length = first & 0xFFFFFFFFFFFF
        if length > 65536:
            raise ValueError("Oversized Swift string")
        try:
            data = bytes(machine.mem_read((second & 0x0FFFFFFFFFFFFFFF) + 32, length))
        except UcError as error:
            raise ValueError(f"Unmapped Swift string: {first:#x}, {second:#x}") from error
    return data.decode("utf-8")


def machine_for(image):
    machine = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    for name, address, size, offset, stored in image.segments:
        if name == "__PAGEZERO" or not size:
            continue
        machine.mem_map(address, (size + 4095) & ~4095)
        if stored:
            machine.mem_write(address, image.data[offset:offset + stored])
    apply_rebases(image, machine)
    for address, size in ((HEAP, 0x100000), (STACK, 0x100000), (RETURN, 4096)):
        machine.mem_map(address, size)
    machine.reg_write(UC_ARM64_REG_SP, STACK + 0x80000)
    machine.reg_write(UC_ARM64_REG_X30, RETURN)
    machine.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    return machine


def apply_rebases(image, machine):
    offset, size = image.unpack("<II", image.commands[0x80000034] + 8)
    version, starts_offset, _, _, _, _, _ = image.unpack("<7I", offset)
    if version != 0:
        raise ValueError("Unsupported chained fixup version")
    starts = offset + starts_offset
    count = image.unpack("<I", starts)[0]
    for index in range(count):
        relative = image.unpack("<I", starts + 4 + index * 4)[0]
        if not relative:
            continue
        segment = starts + relative
        segment_size, page_size, pointer_format, vm_offset, _, pages = image.unpack("<IHHQIH", segment)
        if pointer_format != 6 or segment + segment_size > offset + size:
            raise ValueError("Unexpected original chained pointer format")
        for page in range(pages):
            displacement = image.unpack("<H", segment + 22 + page * 2)[0]
            if displacement == 0xFFFF:
                continue
            if displacement & 0x8000:
                raise ValueError("Multi-start chained pages require separate decoding")
            while True:
                if displacement + 8 > page_size:
                    raise ValueError("Chained pointer exceeds its page")
                address = image.image_base + vm_offset + page * page_size + displacement
                word = image.unpack("<Q", image.vm_offset(address))[0]
                if not word >> 63:
                    target = (word & ((1 << 36) - 1)) + image.image_base
                    target |= ((word >> 36) & 255) << 56
                    machine.mem_write(address, struct.pack("<Q", target))
                step = (word >> 51) & 0xFFF
                if not step:
                    break
                displacement += step * 4


def decode_translations(machine, address):
    count = struct.unpack("<Q", machine.mem_read(address + 16, 8))[0]
    if count != 1639:
        raise ValueError(f"Unexpected Beta 3.2 translation count: {count}")
    entries = {}
    for index in range(count):
        first, second, values = struct.unpack("<QQQ", machine.mem_read(address + 32 + index * 24, 24))
        key = swift_string(machine, first, second)
        if key in entries or struct.unpack("<Q", machine.mem_read(values + 16, 8))[0] != 3:
            raise ValueError(f"Invalid localization row: {key}")
        entries[key] = [swift_string(machine, *struct.unpack("<QQ", machine.mem_read(values + 32 + language * 16, 16))) for language in range(3)]
    return entries


def recover_translations(image):
    machine = machine_for(image)
    result = None
    allocations = []

    def hook(cpu, pc, size, data):
        nonlocal result
        if 0x35D94C0 <= pc < 0x35EC7C0:
            return
        if pc == 0x24C38:
            cpu.reg_write(UC_ARM64_REG_X0, HEAP + 0xF0000)
        elif pc == 0x542FB5C:
            requested = cpu.reg_read(UC_ARM64_REG_X1)
            if allocations or requested != 0x99C8:
                raise ValueError(f"Unexpected literal allocation: {requested:#x}")
            allocations.append(requested)
            cpu.reg_write(UC_ARM64_REG_X0, HEAP)
        elif pc == 0x542FEE0:
            cpu.reg_write(UC_ARM64_REG_X0, cpu.reg_read(UC_ARM64_REG_X1))
        elif pc == 0x542943C:
            result = decode_translations(cpu, cpu.reg_read(UC_ARM64_REG_X0))
            cpu.emu_stop()
            return
        else:
            raise ValueError(f"Unexpected translation initializer call: {pc:#x}")
        cpu.reg_write(UC_ARM64_REG_PC, cpu.reg_read(UC_ARM64_REG_X30))

    machine.hook_add(UC_HOOK_CODE, hook)
    machine.emu_start(0x35D94C0, RETURN, timeout=10000000, count=50000)
    if result is None:
        raise ValueError("Literal initializer did not finish")
    return result


def recover_menu(image):
    machine = machine_for(image)
    section_sets = {}
    allocations = []

    def hook(cpu, pc, size, data):
        if 0x10F32D8 <= pc < 0x10F4388:
            return
        if pc == RETURN:
            cpu.emu_stop()
            return
        if pc == 0x24C38:
            cpu.reg_write(UC_ARM64_REG_X0, HEAP + 0xF0000)
        elif pc == 0x542FB5C:
            requested = cpu.reg_read(UC_ARM64_REG_X1)
            if allocations or requested != 0x608:
                raise ValueError("Unexpected menu allocation")
            allocations.append(requested)
            cpu.reg_write(UC_ARM64_REG_X0, HEAP)
        elif pc == 0x35D911C:
            # Keep the original localization key as the output Swift string.
            swift_string(cpu, cpu.reg_read(UC_ARM64_REG_X0), cpu.reg_read(UC_ARM64_REG_X1))
        elif pc == 0x542FEE0:
            cpu.reg_write(UC_ARM64_REG_X0, cpu.reg_read(UC_ARM64_REG_X1))
        elif pc == 0xC29180:
            address = cpu.reg_read(UC_ARM64_REG_X0)
            count = struct.unpack("<Q", cpu.mem_read(address + 16, 8))[0]
            if not 1 <= count <= 32:
                raise ValueError(f"Unexpected section count: {count}")
            section_sets[address] = list(struct.unpack("<" + "i" * count, cpu.mem_read(address + 32, count * 4)))
        elif pc == 0x5420E2C:
            cpu.reg_write(UC_ARM64_REG_X0, 0)  # Inspect the default, non-classic menu.
        else:
            raise ValueError(f"Unexpected menu initializer call: {pc:#x}")
        cpu.reg_write(UC_ARM64_REG_PC, cpu.reg_read(UC_ARM64_REG_X30))

    machine.hook_add(UC_HOOK_CODE, hook)
    machine.emu_start(0x10F32D8, RETURN, timeout=10000000, count=10000)
    count = struct.unpack("<Q", machine.mem_read(HEAP + 16, 8))[0]
    if count != 27:
        raise ValueError(f"Unexpected menu count: {count}")
    result = []
    for index in range(count):
        words = struct.unpack("<7Q", machine.mem_read(HEAP + 32 + index * 56, 56))
        sections = section_sets.get(words[6], [])
        result.append({"icon": swift_string(machine, *words[0:2]), "title_key": swift_string(machine, *words[2:4]),
                       "description_key": swift_string(machine, *words[4:6]), "section_ids": sections})
    return result


def recover_row_layout(image):
    types, _ = recover_types(image)
    entry = next(item for item in types if item["name"] == "WhitegramEntry")
    names = [field["name"] for field in entry["fields"]]
    instructions = {pc: (mnemonic, operands) for pc, _, mnemonic, operands in image.disassemble(0x10D0D04)}
    offsets = image.data[image.vm_offset(0x55265F0):image.vm_offset(0x55265F0) + len(names)]
    rows = []
    for name, offset in zip(names, offsets):
        pc = 0x10D0D5C + offset * 4
        mnemonic, operands = instructions[pc]
        section = None
        if mnemonic == "mov" and operands.startswith("w0, #"):
            section = int(operands.split("#")[1], 0)
        elif pc == 0x10D0E58:
            section = 0
        elif mnemonic != "ldr":
            raise ValueError(f"Unrecognized section dispatch for {name}: {mnemonic} {operands}")
        rows.append({"id": name, "section": section, "section_dispatch": hex(pc)})
    # Stable list indices are returned by a separate compiled switch.
    order_instructions = {pc: (mnemonic, operands) for pc, _, mnemonic, operands in image.disassemble(0x10CFBD8)}
    for index, row in enumerate(rows):
        delta = image.unpack("<i", image.vm_offset(0x10D07B4 + index * 4))[0]
        pc = 0x10CFC1C + delta
        mnemonic, operands = order_instructions[pc]
        if mnemonic != "mov" or not operands.startswith("w0, #"):
            row["order"] = None
        else:
            row["order"] = int(operands.split("#")[1], 0)
    return rows


def recover(ipa):
    with ipa.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != IPA_SHA256:
        raise ValueError("IPA does not match the pinned original Beta 3.2")
    with zipfile.ZipFile(ipa) as archive:
        image = MachO(archive.read(MEMBER))
    if image.encrypted or image.cpu != 0x100000C:
        raise ValueError("Unencrypted ARM64 original required")
    entries = recover_translations(image)
    menu = recover_menu(image)
    for row in menu:
        row["titles"] = entries[row["title_key"]]
        row["descriptions"] = entries[row["description_key"]]
    return {"source_ipa_sha256": digest, "member": MEMBER, "localization_initializer": "0x35d94c0",
            "menu_initializer": "0x10f32d8", "entries": entries, "menu": menu, "rows": recover_row_layout(image),
            "limitations": ["Default non-classic compiled menu; runtime visibility and row predicates require separate validation."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = recover(args.ipa)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    print(json.dumps({"translations": len(result["entries"]), "menu": result["menu"]}, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
