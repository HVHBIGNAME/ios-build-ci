"""Recheck protocol constants against the hashed IPA using read-only original tooling."""

import argparse
import json
from pathlib import Path
import struct
import sys
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-root", type=Path, required=True)
    options = parser.parse_args()
    sys.path.insert(0, str(options.evidence_root))
    from wgtool.audit_query import connect_audit
    from wgtool.binary import MachO
    from wgtool.storage import file_sha256

    expected = json.loads(Path(__file__).with_name("protocol-evidence.json").read_text(encoding="utf-8"))
    audit = options.evidence_root / "audit-full-3.1.1"
    manifest = json.loads((audit / "manifest.json").read_text(encoding="utf-8"))
    assert file_sha256(manifest["ipa"]) == manifest["ipa_sha256"] == expected["ipa_sha256"], "Original IPA hash differs"
    connection = connect_audit(audit)
    try:
        images = {row["id"]: row for row in connection.execute("SELECT * FROM images WHERE id IN (46,55)")}
    finally:
        connection.close()
    with zipfile.ZipFile(manifest["ipa"]) as archive:
        core = MachO(archive.read(images[46]["member"]), images[46]["base"])
        ui = MachO(archive.read(images[55]["member"]), images[55]["base"])

    def array(address):
        start = core.vm_offset(address)
        count = struct.unpack_from("<Q", core.data, start + 16)[0]
        assert 0 < count <= 512
        return core.data[start + 32:start + 32 + count]

    assert array(0x11437E0).hex() == expected["encoded_root_hex"]
    assert array(0x1143838).hex() == expected["mask_hex"]
    assert len(array(0x11438F8)) == 32, "Original application-key layout changed"
    assert array(0x1145398).hex() == expected["spki_prefixes"]["65"]
    assert array(0x11453E0).hex() == expected["spki_prefixes"]["97"]
    start = core.vm_offset(0x1145420)
    assert struct.unpack_from("<Q", core.data, start + 16)[0] == 4
    pins = []
    for index in range(4):
        lo, hi = struct.unpack_from("<QQ", core.data, start + 32 + index * 16)
        pointer = core.vm_offset((hi & 0x7FFFFFFFFFFFFFFF) + 32)
        pins.append(core.data[pointer:pointer + (lo & 0xFFFFFFFFFFFF)].decode("utf-8"))
    assert pins == expected["spki_pins"]
    key_start = ui.vm_offset(0x4BA09B0)
    assert ui.data[key_start:key_start + 44].decode("ascii") == expected["beta_public_key"]
    refresh = core.vm_offset(0x1F0008)
    assert core.data[refresh:refresh + 4].hex() == "c0035fd6", "Scammer refresh is no longer the audited RET"
    assert struct.unpack_from("<d", core.data, core.vm_offset(0xD53520))[0] == expected["registration_cache_seconds"]
    assert struct.unpack_from("<d", ui.data, ui.vm_offset(0x4945060))[0] == expected["beta_positive_cache_seconds"]
    for image, address, field in [(core, 0xDE78B0, "identity_keychain_tag"), (ui, 0x4BA2D10, "legacy_device_token_service"), (ui, 0x4BA2CF0, "legacy_device_token_account")]:
        offset = image.vm_offset(address)
        assert image.data[offset:offset + len(expected[field])].decode("ascii") == expected[field]
    print("PASS: hashed original IPA root/mask/key, all four pins, SPKI prefixes, beta public key/cache, registration TTL, scammer RET")


if __name__ == "__main__":
    main()
