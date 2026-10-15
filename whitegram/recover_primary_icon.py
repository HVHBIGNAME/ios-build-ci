"""Recover the original WGPrimary rasters. Requires Pillow 11.3.0 and lzfse 0.4.2."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zipfile

IPA_SHA256 = "ecc05aeff70eb2cc692ffcc07d0ee9c35a23b39b82b91d0803de1b54a10d0d6d"
CAR_SHA256 = "2f41721408f6d7606c36bfb8cf18ed718fa3464ddd1173864f978c74843c5ba9"
RENDITIONS = (
    ("Light", 12481280, "9529b92cb3b7f61df1d200789941c7e039180a53337e536d8bc95b010ed6c7b9"),
    ("Dark", 32748112, "27c77cf343789217805e51eefc449e9e38ccf1008fc6a36c69490f05c3c577c3"),
    ("Tinted", 53652944, "65924414400bc569f19686c7c635b371a48ece6d99c5072eb03f6e776bb68c30"),
)


def decode_rendition(catalog, offset):
    import lzfse
    from PIL import Image

    tag, version, flags, width, height, scale, pixels, space = struct.unpack_from("<4s7I", catalog, offset)
    if (tag, version, width, height, pixels, space) != (b"ISTC", 1, 1024, 1024, int.from_bytes(b"ARGB", "big"), 1):
        raise ValueError("Unexpected original icon rendition")
    tlv_length, _, _, length = struct.unpack_from("<4I", catalog, offset + 168)
    start = offset + 184 + tlv_length
    data = catalog[start:start + length]
    if struct.unpack_from("<4s3I", data) != (b"MLEC", 3, 4, 4):
        raise ValueError("Unsupported icon compression layout")
    cursor, rows = 16, 0
    raw = bytearray()
    for _ in range(4):
        tag, reserved1, reserved2, chunk_height, size = struct.unpack_from("<4s4I", data, cursor)
        if (tag, reserved1, reserved2) != (b"KCBC", 0, 0) or not 0 < chunk_height <= height - rows:
            raise ValueError("Invalid icon chunk")
        cursor += 20
        decoded = lzfse.decompress(data[cursor:cursor + size])
        cursor += size
        if len(decoded) != width * chunk_height * 4:
            raise ValueError("Icon chunk pixel length mismatch")
        raw.extend(decoded)
        rows += chunk_height
    if rows != height or cursor != len(data):
        raise ValueError("Incomplete icon image")
    image = Image.frombytes("RGBA", (width, height), bytes(raw), "raw", "BGRA")
    if image.getchannel("A").getextrema() != (255, 255):
        raise ValueError("Unexpected nonopaque source icon")
    return image, start, length


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("output", type=Path, help="New output directory")
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit("Output must not exist")
    with args.ipa.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != IPA_SHA256:
            raise ValueError("Source IPA identity mismatch")
    with zipfile.ZipFile(args.ipa) as archive:
        catalog = archive.read("Payload/Telegram.app/Assets.car")
    if hashlib.sha256(catalog).hexdigest() != CAR_SHA256:
        raise ValueError("Source icon catalog identity mismatch")
    images = []
    for appearance, offset, expected_pixels in RENDITIONS:
        image, start, length = decode_rendition(catalog, offset)
        if hashlib.sha256(image.tobytes()).hexdigest() != expected_pixels:
            raise ValueError("Decoded original icon pixels differ")
        images.append((appearance, image, offset, start, length, expected_pixels))
    args.output.mkdir(parents=True)
    entries = []
    for appearance, image, offset, start, length, pixels in images:
        name = "WGPrimary" + appearance + ".png"
        image.convert("RGB").save(args.output / name)
        entries.append({"file": name, "appearance": appearance.lower(), "width": 1024, "height": 1024,
                        "rendition_offset": offset, "payload_offset": start, "payload_bytes": length,
                        "rgba_sha256": pixels, "sha256": hashlib.sha256((args.output / name).read_bytes()).hexdigest()})
    manifest = {"source_ipa_sha256": IPA_SHA256, "source_catalog_sha256": CAR_SHA256,
                "source_catalog": "Payload/Telegram.app/Assets.car", "asset_name": "WGPrimary", "images": entries}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
