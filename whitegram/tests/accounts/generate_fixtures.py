"""Independent synthetic format oracle: CPython SQLite/ZIP, hashlib, and OpenSSL AES.

No Telegram connection, credentials, or original user session is used. The output is
created only at the caller's explicit test-artifact path.
"""

import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import zipfile


def b64(data):
    return base64.b64encode(data).decode("ascii")


def key_id(key):
    return int.from_bytes(hashlib.sha1(key).digest()[-8:], "little", signed=True)


def peer_id(user):
    value = (user & 0xFFFFFFFF) | ((user >> 32) << 35)
    return int.from_bytes(value.to_bytes(8, "little"), "little", signed=True)


def aes_ige(openssl, plaintext, key, iv):
    previous_cipher, previous_plain = iv[:16], iv[16:]
    output = bytearray()
    for start in range(0, len(plaintext), 16):
        block = plaintext[start:start + 16]
        mixed = bytes(a ^ b for a, b in zip(block, previous_cipher))
        encrypted = subprocess.run([openssl, "enc", "-aes-256-ecb", "-nopad", "-nosalt", "-K", key.hex()], input=mixed, capture_output=True, check=True).stdout
        assert len(encrypted) == 16
        cipher = bytes(a ^ b for a, b in zip(encrypted, previous_plain))
        output.extend(cipher)
        previous_cipher, previous_plain = cipher, block
    return bytes(output)


def encrypt_local(openssl, body, auth_key):
    plaintext = struct.pack("<I", len(body) + 4) + body
    plaintext += bytes((16 - len(plaintext) % 16) % 16)
    message_key = hashlib.sha1(plaintext).digest()[:16]
    a = hashlib.sha1(message_key + auth_key[8:40]).digest()
    b = hashlib.sha1(auth_key[40:56] + message_key + auth_key[56:72]).digest()
    c = hashlib.sha1(auth_key[72:104] + message_key).digest()
    d = hashlib.sha1(message_key + auth_key[104:136]).digest()
    key = a[:8] + b[8:20] + c[4:16]
    iv = a[8:20] + b[:8] + c[16:20] + d[:8]
    return message_key + aes_ige(openssl, plaintext, key, iv)


def qbytes(data):
    return struct.pack(">I", len(data)) + data


def container(body):
    version = struct.pack("<I", 5000000)
    checksum = hashlib.md5(body + struct.pack("<I", len(body)) + version + b"TDF$").digest()
    return b"TDF$" + version + body + checksum


def tdata_filename(name):
    return "".join(f"{byte & 15:X}{byte >> 4:X}" for byte in hashlib.md5(name.encode()).digest()[:8]) + "s"


def sqlite_session(key, with_user_id=False):
    connection = sqlite3.connect(":memory:")
    connection.executescript("""
        CREATE TABLE version (version integer primary key);
        INSERT INTO version VALUES (8);
        CREATE TABLE sessions (dc_id integer primary key, server_address text, port integer, auth_key blob, takeout_id integer, tmp_auth_key blob);
        CREATE TABLE entities (id integer primary key, hash integer not null, username text, phone integer, name text, date integer);
        CREATE TABLE sent_files (md5_digest blob, file_size integer, type integer, id integer, hash integer, primary key(md5_digest, file_size, type));
        CREATE TABLE update_state (id integer primary key, pts integer, qts integer, date integer, seq integer);
    """)
    connection.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, NULL, NULL)", (2, "149.154.167.51", 443, key))
    if with_user_id:
        connection.execute("ALTER TABLE sessions ADD COLUMN user_id integer")
        connection.execute("UPDATE sessions SET user_id = ?", (5481234567,))
    connection.commit()
    result = connection.serialize()
    connection.close()
    return result


def pyrogram_session(key, *, testing=False):
    connection = sqlite3.connect(":memory:")
    connection.executescript("""
        CREATE TABLE version (number integer primary key);
        INSERT INTO version VALUES (3);
        CREATE TABLE sessions (dc_id integer primary key, api_id integer, test_mode integer, auth_key blob, date integer not null, user_id integer, is_bot integer);
        CREATE TABLE peers (id integer primary key, access_hash integer, type integer not null, username text, phone_number text, last_update_on integer);
    """)
    connection.execute("INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?)", (2, 0, int(testing), key, 0, 5481234567, 0))
    connection.commit()
    result = connection.serialize()
    connection.close()
    return result


def zip_entry(name):
    entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    entry.compress_type = zipfile.ZIP_DEFLATED
    return entry


def fixtures(openssl):
    key = bytes(range(256))
    other_key = bytes(reversed(range(256)))
    notification = bytes((i * 7) % 256 for i in range(256))
    user_id = 5481234567
    backup = {
        "masterDatacenterId": 2, "peerId": peer_id(user_id), "masterDatacenterKey": b64(key),
        "masterDatacenterKeyId": key_id(key), "notificationEncryptionKeyId": b64(hashlib.sha1(notification).digest()[-8:]),
        "notificationEncryptionKey": b64(notification),
        "additionalDatacenterKeys": [1, {"id": 1, "keyId": key_id(other_key), "key": b64(other_key)}],
    }
    archive = {"name": "Synthetic Account", "date": 812000000.0, "accountRecord": {
        "id": "-123456789", "attributes": [{"backupData": {"data": b64(json.dumps(backup).encode())}}, {"environment": {"environment": 0}}, {"sortOrder": {"order": 3}}],
    }}
    salt = bytes(range(32))
    passcode = "synthetic-only-локальный"
    local_key = bytes((i * 13 + 3) % 256 for i in range(256))
    encrypted_info = encrypt_local(openssl, struct.pack(">IIII", 2, 0, 2, 0), local_key)
    tdata = {}
    for password in ("", passcode):
        derived = hashlib.pbkdf2_hmac("sha512", hashlib.sha512(salt + password.encode() + salt).digest(), salt, 100000 if password else 1, dklen=256)
        tdata["key_datas" if password else "unlocked_key_datas"] = container(qbytes(salt) + qbytes(encrypt_local(openssl, local_key, derived)) + qbytes(encrypted_info))
    for name, user, dc, auth_key in (("data", user_id, 2, key), ("data#3", 9876543210, 5, other_key)):
        auth = b"\xff" * 8 + struct.pack(">QII", user, dc, 1) + struct.pack(">I", dc) + auth_key + struct.pack(">I", 0)
        body = struct.pack(">I", 0x4B) + qbytes(auth)
        tdata[tdata_filename(name)] = container(qbytes(encrypt_local(openssl, body, local_key)))
    session = sqlite_session(key)
    sidecar = json.dumps({"id": user_id, "first_name": "Synthetic", "last_name": "Account", "phone": "10000000000"}).encode()
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive_zip:
        archive_zip.writestr(zip_entry("sessions/synthetic.session"), session)
        archive_zip.writestr(zip_entry("sessions/synthetic.json"), sidecar)
    bad_path = io.BytesIO()
    with zipfile.ZipFile(bad_path, "w") as archive_zip:
        archive_zip.writestr(zip_entry("../escape.session"), session)
    aes_key = bytes(range(32))
    aes_iv = bytes(range(32, 64))
    aes_plain = bytes(range(64, 128))
    return {
        "synthetic_only": True, "auth_key": b64(key), "auth_key_id": key_id(key), "user_id": user_id, "peer_id": peer_id(user_id),
        "session_archive": b64(json.dumps(archive).encode()), "telethon": b64(session), "telethon_with_user_id": b64(sqlite_session(key, True)), "sidecar": b64(sidecar),
        "pyrogram": b64(pyrogram_session(key)), "pyrogram_test": b64(pyrogram_session(key, testing=True)),
        "tdata_passcode": passcode, "tdata": {name: b64(data) for name, data in tdata.items()},
        "zip_deflate": b64(output.getvalue()), "zip_unsafe_path": b64(bad_path.getvalue()),
        "aes": {"key": b64(aes_key), "iv": b64(aes_iv), "plaintext": b64(aes_plain), "ciphertext": b64(aes_ige(openssl, aes_plain, aes_key, aes_iv))},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    openssl = shutil.which(args.openssl)
    if not openssl:
        parser.error("OpenSSL is required to create independent AES fixtures")
    if not args.output.parent.is_dir():
        parser.error("The fixture output parent must already exist")
    data = fixtures(openssl)
    args.output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"synthetic_fixtures": str(args.output.resolve()), "sha256": hashlib.sha256(args.output.read_bytes()).hexdigest()}))


if __name__ == "__main__":
    main()
