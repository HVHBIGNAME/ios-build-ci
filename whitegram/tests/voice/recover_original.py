"""Print bounded original audio constant tables; never alter the IPA or evidence root.

Run with the read-only evidence root's Python (wgtool/capstone installed).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import zipfile

EXPECTED_IPA = "bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence_root", type=Path)
    parser.add_argument("--verify-fixture", type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.evidence_root))
    from wgtool.audit_query import audit_query
    from wgtool.binary import MachO

    audit = args.evidence_root / "audit-full-3.1.1"
    manifest = json.loads((audit / "manifest.json").read_text(encoding="utf-8"))
    with Path(manifest["ipa"]).open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != EXPECTED_IPA or manifest["ipa_sha256"] != EXPECTED_IPA:
        raise ValueError("Original IPA hash mismatch")
    images = audit_query(audit, "SELECT id,member,base FROM images WHERE id IN (46,55)")
    result = {"ipa_sha256": digest, "tables": {}}
    recovered_presets = [[0.0] * 7]
    with zipfile.ZipFile(manifest["ipa"]) as archive:
        for record in images:
            image = MachO(archive.read(record["member"]), record["base"])
            def unpack(address, fmt):
                return list(struct.unpack_from(fmt, image.data, image.vm_offset(address)))
            if record["id"] == 46:
                result["tables"]["voicePresetJumpTargets"] = [hex(0x2d675c + n * 4) for n in unpack(0xd68a50, "<11B")]
                result["tables"]["voiceParameters"] = {hex(address): unpack(address, "<2d") for address in range(0xd688b0, 0xd68a50, 16)}
                result["tables"]["voiceScalars"] = {hex(address): unpack(address, "<d")[0] for address in range(0xd68800, 0xd68890, 8)}
                result["tables"]["profanityRefreshSeconds"] = unpack(0xd626e0, "<d")[0]
                for target in result["tables"]["voicePresetJumpTargets"][1:]:
                    address = int(target, 16)
                    vectors = {1: [0, 0], 2: unpack(0xd688b0, "<2d"), 3: [0, 0]}
                    noise = 0.0
                    if address != 0x2d688c:
                        pages = {}
                        offset = image.vm_offset(address)
                        for _, _, mnemonic, operands in image.engine.disasm_lite(image.data[offset:offset + 80], address):
                            if mnemonic == "b" or mnemonic == "stp":
                                break
                            if mnemonic == "adrp":
                                register, page = operands.split(", #")
                                pages[register] = int(page, 16)
                            elif mnemonic == "ldr":
                                match = re.fullmatch(r"([qd])(\d+), \[(x\d+), #(0x[0-9a-f]+)\]", operands)
                                if not match:
                                    raise ValueError("Unexpected preset instruction: " + operands)
                                kind, register, base, displacement = match.groups()
                                source = pages[base] + int(displacement, 16)
                                if kind == "q":
                                    vectors[int(register)] = unpack(source, "<2d")
                                else:
                                    noise = unpack(source, "<d")[0]
                        recovered_presets.append([vectors[3][0], vectors[3][1] * 100, vectors[2][0] * 100, vectors[2][1] * 100, *vectors[1], noise])
                    else:
                        recovered_presets.append([0, 0, *[n * 100 for n in vectors[2]], 0, 0, 0])
            else:
                result["tables"]["equalizerPresets"] = {hex(address): unpack(address + 32, "<10f") for address in range(0x5e47ab8, 0x5e47c48 + 1, 80)}
                result["tables"]["bleep"] = {hex(address): unpack(address, "<d")[0] for address in (0x4953918, 0x49471c8, 0x4945050, 0x4953920, 0x4953928)}
    if args.verify_fixture:
        fixture = json.loads(args.verify_fixture.read_text(encoding="utf-8"))
        if fixture["ipa_sha256"] != digest:
            raise ValueError("Fixture provenance differs")
        for expected, actual in zip(fixture["voice_presets"], recovered_presets, strict=True):
            if any(abs(a - b) > 1e-9 for a, b in zip(expected, actual, strict=True)):
                raise ValueError(f"Preset fixture differs: {expected} != {actual}")
        for name, address in zip(("bass", "treble", "pop", "rock", "jazz", "classical"), result["tables"]["equalizerPresets"], strict=True):
            if fixture["equalizer_presets"][name] != result["tables"]["equalizerPresets"][address]:
                raise ValueError("Equalizer fixture differs: " + name)
        for key, address in (("minimum_word_duration", "0x4953918"), ("fallback_word_duration", "0x49471c8"), ("left_edge_fraction", "0x49471c8"), ("right_edge_fraction", "0x4945050"), ("tone_peak", "0x4953928")):
            if fixture["bleep_constants"][key] != result["tables"]["bleep"][address]:
                raise ValueError("Selective bleep fixture differs: " + key)
        print("PASS: original IPA hash, all 11 voice presets, 6 equalizer presets and selective-bleep constants match the native fixture")
        print("Original profanity refresh interval:", result["tables"]["profanityRefreshSeconds"])
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
