"""Offline original-constant and source contracts; native behavior lives in backend/*Tests.swift."""

import hashlib
import hmac
import json
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "cleanroom"
EVIDENCE = json.loads((HERE / "backend/protocol-evidence.json").read_text(encoding="utf-8"))


class ProtocolEvidenceTests(unittest.TestCase):
    def test_root_recovers_from_original_xor_array_and_key_is_configured(self):
        source = (SOURCE / "WhitegramBackendProtocol.swift").read_text(encoding="utf-8")
        mask = bytes.fromhex(EVIDENCE["mask_hex"])
        root = bytes(value ^ mask[index % len(mask)] for index, value in enumerate(bytes.fromhex(EVIDENCE["encoded_root_hex"]))).decode()
        self.assertEqual(root, EVIDENCE["api_root"])
        self.assertIn('URL(string: "' + root + '")!', source)
        self.assertIn('Bundle.main.object(forInfoDictionaryKey: "WhitegramBackendApplicationKey")', source)
        self.assertNotIn("encoded_application_key_hex", EVIDENCE)
        self.assertNotIn("let mask: [UInt8]", source)

    def test_signing_vectors_use_only_synthetic_keys(self):
        key = bytes.fromhex(EVIDENCE["synthetic_application_key_hex"])
        self.assertEqual(key, bytes(range(32, 64)))
        for vector in EVIDENCE["synthetic_vectors"]:
            with self.subTest(message=vector["message"]):
                self.assertEqual(hmac.new(key, vector["message"].encode(), hashlib.sha256).hexdigest(), vector["signature"])
                self.assertEqual(hmac.new(bytes(range(32)), vector["message"].encode(), hashlib.sha256).hexdigest(), vector["session_signature"])

    def test_pins_and_beta_public_key_match_original(self):
        protocol = (SOURCE / "WhitegramBackendProtocol.swift").read_text(encoding="utf-8")
        access = (SOURCE / "WhitegramBackendAccess.swift").read_text(encoding="utf-8")
        for pin in EVIDENCE["spki_pins"]:
            self.assertIn('"' + pin + '"', protocol)
        self.assertIn('"' + EVIDENCE["beta_public_key"] + '"', access)
        self.assertIn("isValidSignature(signature, for: Data(signedPayload.utf8))", access)

    def test_auth_session_and_streak_codecs_retain_original_field_names(self):
        auth = (SOURCE / "WhitegramBackendAuthentication.swift").read_text(encoding="utf-8")
        for key in ("user_id", "device_token", "build_mode", "client_uptime", "init_data", "device_pubkey"):
            self.assertIn('"' + key + '"', auth)
        event = (SOURCE / "WhitegramProfileStreakService.swift").read_text(encoding="utf-8")
        for key in ("peer_id", "event_timestamp", "timezone_offset"):
            self.assertIn('"' + key + '"', event)
        self.assertIn("secondsFromGMT(for: Date(timeIntervalSince1970: Double(timestamp)))", event)

    def test_provider_headers_cannot_replace_whitegram_authorization(self):
        source = (SOURCE / "WhitegramBackendClient.swift").read_text(encoding="utf-8")
        self.assertIn('request.setValue(providerKey, forHTTPHeaderField: "X-Provider-Key")', source)
        self.assertIn('!path.hasPrefix("/v1/proxy/")', source)
        self.assertNotIn('forHTTPHeaderField: "Authorization"', source)
        self.assertIn("WhitegramBackendProtocol.sign(&request", source)

    def test_device_identity_and_legacy_token_keys_match_original(self):
        source = (SOURCE / "WhitegramBackendCredentials.swift").read_text(encoding="utf-8")
        for key in ("identity_keychain_tag", "legacy_device_token_service", "legacy_device_token_account"):
            self.assertIn('"' + EVIDENCE[key] + '"', source)
        self.assertIn('read("wg_stableDeviceToken", service: legacyDeviceTokenService)', source)
        self.assertIn('guard try read("device-token") == data', source)

    def test_streak_events_never_capture_message_text_or_media(self):
        source = (SOURCE / "WhitegramBackendMessageBridge.swift").read_text(encoding="utf-8")
        event = (SOURCE / "WhitegramBackendMessageEvent.swift").read_text(encoding="utf-8")
        for guard in ("Namespaces.Message.Cloud", "Namespaces.Peer.CloudUser", "peer.botInfo == nil", "!message.containsSecretMedia", ".Failed", ".Unsent"):
            self.assertIn(guard, source)
        self.assertNotIn("message.text", source)
        self.assertNotIn("message.media", source)
        self.assertEqual(set(re.findall(r"public let (\w+):", event)), {"accountId", "peerId", "messageId", "timestamp", "direction"})


if __name__ == "__main__":
    unittest.main()
