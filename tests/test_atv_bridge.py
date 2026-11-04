#!/usr/bin/env python3
"""Unit tests for the pyatv stdio JSON-RPC helper bridge."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import MagicMock

from pyatv.const import PairingRequirement, Protocol

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRIDGE_PATH = ROOT / "src" / "Helper" / "atv_bridge.py"

spec = importlib.util.spec_from_file_location("atv_bridge", BRIDGE_PATH)
assert spec is not None and spec.loader is not None
atv_bridge = importlib.util.module_from_spec(spec)
sys.modules["atv_bridge"] = atv_bridge
spec.loader.exec_module(atv_bridge)


class BridgeUnitTests(unittest.TestCase):
    def test_usb_hid_lookup_lowercase_and_uppercase(self) -> None:
        self.assertEqual(atv_bridge.usb_hid_lookup("a"), (4, False))
        self.assertEqual(atv_bridge.usb_hid_lookup("z"), (29, False))
        self.assertEqual(atv_bridge.usb_hid_lookup("A"), (4, True))
        self.assertEqual(atv_bridge.usb_hid_lookup("Z"), (29, True))

    def test_usb_hid_lookup_digits_and_symbols(self) -> None:
        self.assertEqual(atv_bridge.usb_hid_lookup("1"), (30, False))
        self.assertEqual(atv_bridge.usb_hid_lookup("0"), (39, False))
        self.assertEqual(atv_bridge.usb_hid_lookup(" "), (44, False))
        self.assertEqual(atv_bridge.usb_hid_lookup("?"), (56, True))
        self.assertIsNone(atv_bridge.usb_hid_lookup("🎬"))

    def test_canonical_identifier_prefers_uuid_over_mac(self) -> None:
        fake_conf = SimpleNamespace(
            all_identifiers=[
                "AA:BB:CC:DD:EE:FF",
                "00000000-1111-2222-3333-444444444444",
                "AABBCCDDEEFF",
            ],
            identifier="AA:BB:CC:DD:EE:FF",
            address="192.168.1.50",
        )
        self.assertEqual(
            atv_bridge.canonical_identifier(fake_conf),
            "00000000-1111-2222-3333-444444444444",
        )

    def test_required_pairing_protocols_prefers_companion_then_airplay(self) -> None:
        svc_companion = MagicMock()
        svc_companion.protocol = Protocol.Companion
        svc_companion.pairing = PairingRequirement.Mandatory

        svc_airplay = MagicMock()
        svc_airplay.protocol = Protocol.AirPlay
        svc_airplay.pairing = PairingRequirement.Mandatory

        fake_conf = SimpleNamespace(services=[svc_airplay, svc_companion])
        self.assertEqual(
            atv_bridge.required_pairing_protocols(fake_conf),
            ["Companion", "AirPlay"],
        )


if __name__ == "__main__":
    unittest.main()
