#!/usr/bin/env python3
"""
Persistent JSON-over-stdio bridge around pyatv for TV Remote (macOS).

Reads newline-delimited JSON commands from stdin and emits newline-delimited
JSON responses and asynchronous push events to stdout. All diagnostics go to
stderr so stdout remains strictly machine-readable JSON.
"""

from __future__ import annotations

import asyncio
import base64
import importlib.metadata
import ipaddress
import json
import logging
import os
import re
import socket
import sys
import threading
import time
from contextlib import suppress
from typing import Any

import ifaddr
import pyatv
from pyatv import exceptions as atv_exceptions
from pyatv.const import (
    DeviceModel,
    DeviceState,
    FeatureName,
    FeatureState,
    InputAction,
    KeyboardFocusState,
    PairingRequirement,
    Protocol,
)
from pyatv.interface import (
    AppleTV,
    Audio,
    AudioListener,
    BaseConfig,
    DeviceListener,
    KeyboardListener,
    OutputDevice,
    PairingHandler,
    Playing,
    PushListener,
)
from pyatv.protocols.mrp import messages as mrp_messages

_LOG_LEVEL_NAME = os.environ.get("TVREMOTE_LOG_LEVEL", "WARNING").upper()
logging.basicConfig(
    level=getattr(logging, _LOG_LEVEL_NAME, logging.WARNING),
    format="[atv_bridge] %(levelname)s %(name)s: %(message)s",
    stream=sys.stderr,
)
LOGGER = logging.getLogger("atv_bridge")

APPLE_TV_MODELS = {
    DeviceModel.AppleTVGen1,
    DeviceModel.Gen2,
    DeviceModel.Gen3,
    DeviceModel.Gen4,
    DeviceModel.Gen4K,
    DeviceModel.AppleTV4KGen2,
    DeviceModel.AppleTV4KGen3,
}

PROTOCOL_BY_NAME: dict[str, Protocol] = {
    "Companion": Protocol.Companion,
    "MRP": Protocol.MRP,
    "AirPlay": Protocol.AirPlay,
    "DMAP": Protocol.DMAP,
    "RAOP": Protocol.RAOP,
}

_stdout_lock = threading.Lock()


def emit(payload: dict[str, Any]) -> None:
    """Write a single JSON message line to stdout."""
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    with _stdout_lock:
        sys.stdout.write(line)
        sys.stdout.flush()


def get_local_ipv4_addresses() -> set[str]:
    """Return all local IPv4 addresses instantly without blocking DNS."""
    ips: set[str] = {"127.0.0.1"}
    with suppress(Exception):
        for adapter in ifaddr.get_adapters():
            for ip in adapter.ips:
                if isinstance(ip.ip, str):
                    ips.add(ip.ip)
    return ips


async def _run_dnssd_capture(args: list[str], duration: float) -> str:
    """Run /usr/bin/dns-sd briefly to query macOS mDNSResponder cache/network."""
    proc = await asyncio.create_subprocess_exec(
        "/usr/bin/dns-sd",
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    chunks: list[bytes] = []

    async def _drain() -> None:
        assert proc.stdout is not None
        while True:
            data = await proc.stdout.read(4096)
            if not data:
                break
            chunks.append(data)

    drain_task = asyncio.create_task(_drain())
    try:
        await asyncio.sleep(duration)
    finally:
        with suppress(ProcessLookupError):
            proc.kill()
        with suppress(Exception):
            await asyncio.wait_for(proc.wait(), timeout=0.3)
        with suppress(Exception):
            await asyncio.wait_for(drain_task, timeout=0.2)
        if not drain_task.done():
            drain_task.cancel()

    return b"".join(chunks).decode("utf-8", errors="replace")


async def discover_bonjour_appletv_ips() -> set[str]:
    """
    Use macOS's native mDNSResponder (via dns-sd) to discover Companion / AirPlay
    instances and resolve their IPv4 addresses. Works reliably even on networks
    where raw Python UDP multicast sockets are filtered.
    """
    browse_services = ["_companion-link._tcp", "_mediaremotetv._tcp", "_airplay._tcp"]
    browse_outputs = await asyncio.gather(
        *[_run_dnssd_capture(["-B", svc, "local."], 1.1) for svc in browse_services],
        return_exceptions=True,
    )

    instances: set[tuple[str, str]] = set()
    for svc, output in zip(browse_services, browse_outputs):
        if not isinstance(output, str):
            continue
        for line in output.splitlines():
            if " Add " not in line or svc not in line:
                continue
            idx = line.find(svc)
            after = line[idx + len(svc) :].lstrip(". \t")
            instance_name = after.strip()
            if instance_name:
                instances.add((instance_name, svc))

    if not instances:
        return set()

    lookup_outputs = await asyncio.gather(
        *[
            _run_dnssd_capture(["-L", inst, svc, "local."], 0.7)
            for inst, svc in instances
        ],
        return_exceptions=True,
    )

    hostnames: set[str] = set()
    host_re = re.compile(r"can be reached at ([^\s:]+):\d+")
    for output in lookup_outputs:
        if not isinstance(output, str):
            continue
        if ("rpMd=Mac" in output or "model=Mac" in output) and "AppleTV" not in output:
            continue
        for match in host_re.finditer(output):
            host = match.group(1).rstrip(".")
            if host:
                hostnames.add(host)

    loop = asyncio.get_running_loop()
    local_ips = get_local_ipv4_addresses()
    ips: set[str] = set()

    async def _resolve(host: str) -> None:
        with suppress(Exception):
            infos = await asyncio.wait_for(
                loop.getaddrinfo(
                    host, None, family=socket.AF_INET, type=socket.SOCK_STREAM
                ),
                timeout=1.2,
            )
            for info in infos:
                addr = info[4][0]
                if addr not in local_ips and not addr.startswith("127."):
                    ips.add(addr)

    await asyncio.gather(*[_resolve(h) for h in hostnames])
    return ips


def is_apple_tv_config(conf: BaseConfig, local_ips: set[str]) -> bool:
    """Return True if a scanned pyatv config represents an Apple TV."""
    if str(conf.address) in local_ips:
        return False
    info = conf.device_info
    if info.model in APPLE_TV_MODELS:
        return True
    model_str = (info.model_str or "").lower()
    if "apple tv" in model_str or "appletv" in model_str:
        return True
    raw_model = str(info.raw_model or "").lower()
    if raw_model.startswith("appletv"):
        return True
    if any(tok in raw_model for tok in ("mac", "audioaccessory", "airport")):
        return False
    return any(s.protocol == Protocol.MRP for s in conf.services)


def required_pairing_protocols(conf: BaseConfig) -> list[str]:
    """
    Determine the ordered list of protocols to pair for full remote + metadata control.
    - Companion: HID D-pad, Select/Home hold, Control Center, volume buttons, app info
    - MRP (older tvOS) or AirPlay (tvOS 16+ tunnels MRP inside AirPlay): Now Playing,
      artwork, playback state, and absolute volume/mute when supported.
    """
    available: dict[Protocol, PairingRequirement] = {
        s.protocol: s.pairing for s in conf.services
    }
    needed: list[str] = []

    if available.get(Protocol.Companion) in (
        PairingRequirement.Mandatory,
        PairingRequirement.Optional,
    ):
        needed.append("Companion")

    if available.get(Protocol.MRP) in (
        PairingRequirement.Mandatory,
        PairingRequirement.Optional,
    ):
        needed.append("MRP")
    elif available.get(Protocol.AirPlay) in (
        PairingRequirement.Mandatory,
        PairingRequirement.Optional,
    ):
        needed.append("AirPlay")

    return needed


def canonical_identifier(conf: BaseConfig) -> str:
    """Choose a stable identifier across scans regardless of mDNS arrival order."""
    ids = [i for i in conf.all_identifiers if i]
    # Prefer UUID format (e.g. Companion rpMRtID) which is constant across services
    uuid_re = re.compile(
        r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
    )
    for ident in sorted(ids):
        if uuid_re.match(ident):
            return ident.upper()
    # Next prefer normalized 12-char MAC hex
    for ident in sorted(ids):
        stripped = ident.replace(":", "").replace("-", "").upper()
        if len(stripped) == 12 and all(c in "0123456789ABCDEF" for c in stripped):
            return stripped
    return conf.identifier or str(conf.address)


def serialize_config(conf: BaseConfig) -> dict[str, Any]:
    """Serialize a pyatv BaseConfig for Swift consumption."""
    model_str = conf.device_info.model_str
    if not model_str or model_str == "Unknown":
        model_str = conf.device_info.raw_model or "Apple TV"
    canon = canonical_identifier(conf)
    all_ids = list(dict.fromkeys([canon, *conf.all_identifiers]))
    return {
        "identifier": canon,
        "allIdentifiers": all_ids,
        "name": conf.name,
        "address": str(conf.address),
        "model": model_str,
        "osVersion": conf.device_info.version or "",
        "pairingProtocols": required_pairing_protocols(conf),
    }


USB_HID_SPECIAL_MAP: dict[str, tuple[int, bool]] = {
    " ": (44, False),
    "\n": (40, False),
    "\r": (40, False),
    "\t": (43, False),
    "!": (30, True),
    "@": (31, True),
    "#": (32, True),
    "$": (33, True),
    "%": (34, True),
    "^": (35, True),
    "&": (36, True),
    "*": (37, True),
    "(": (38, True),
    ")": (39, True),
    "-": (45, False),
    "_": (45, True),
    "=": (46, False),
    "+": (46, True),
    "[": (47, False),
    "{": (47, True),
    "]": (48, False),
    "}": (48, True),
    "\\": (49, False),
    "|": (49, True),
    ";": (51, False),
    ":": (51, True),
    "'": (52, False),
    '"': (52, True),
    "`": (53, False),
    "~": (53, True),
    ",": (54, False),
    "<": (54, True),
    ".": (55, False),
    ">": (55, True),
    "/": (56, False),
    "?": (56, True),
}


def usb_hid_lookup(ch: str) -> tuple[int, bool] | None:
    if "a" <= ch <= "z":
        return (4 + ord(ch) - ord("a"), False)
    if "A" <= ch <= "Z":
        return (4 + ord(ch) - ord("A"), True)
    if "1" <= ch <= "9":
        return (30 + ord(ch) - ord("1"), False)
    if ch == "0":
        return (39, False)
    return USB_HID_SPECIAL_MAP.get(ch)


class BridgeSession(PushListener, AudioListener, KeyboardListener, DeviceListener):
    """Manages discovery, pairing, persistent connection, and event streaming."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.atv: AppleTV | None = None
        self.connected_identifier: str | None = None
        self.connected_name: str | None = None
        self.pairing_handler: PairingHandler | None = None
        self.pairing_protocol: str | None = None
        self.pairing_identifier: str | None = None
        self.pairing_started_at: float = 0.0
        self._pairing_lock = asyncio.Lock()
        self._keyboard_lock = asyncio.Lock()
        self._is_muted: bool = False
        self._saved_volume: float = 30.0
        self._last_artwork_id: str | None = None
        self._last_artwork_b64: str | None = None
        self._now_playing_task: asyncio.Task[None] | None = None
        self._lock = asyncio.Lock()

    async def scan_configs(
        self,
        hosts: list[str] | None = None,
        include_all: bool = False,
    ) -> list[BaseConfig]:
        local_ips = get_local_ipv4_addresses()
        discovered_configs: dict[str, BaseConfig] = {}

        if not hosts:
            env_hosts = os.environ.get("TVREMOTE_DEFAULT_HOST", "").strip()
            if env_hosts:
                hosts = [h.strip() for h in env_hosts.split(",") if h.strip()]

        if hosts:
            valid_hosts = []
            for h in hosts:
                with suppress(ValueError):
                    ipaddress.ip_address(h)
                    valid_hosts.append(h)
            if valid_hosts:
                configs = await pyatv.scan(self.loop, hosts=valid_hosts, timeout=3.2)
                for c in configs:
                    if include_all or is_apple_tv_config(c, local_ips):
                        discovered_configs[canonical_identifier(c)] = c
                if discovered_configs:
                    return list(discovered_configs.values())

        bonjour_task = asyncio.create_task(discover_bonjour_appletv_ips())
        multicast_task = asyncio.create_task(pyatv.scan(self.loop, timeout=2.0))

        bonjour_ips, multicast_configs = await asyncio.gather(
            bonjour_task, multicast_task
        )

        for c in multicast_configs:
            if include_all or is_apple_tv_config(c, local_ips):
                discovered_configs[canonical_identifier(c)] = c

        missing_ips = [
            ip
            for ip in bonjour_ips
            if not any(str(c.address) == ip for c in discovered_configs.values())
        ]
        if missing_ips:
            unicast_configs = await pyatv.scan(
                self.loop, hosts=missing_ips, timeout=3.2
            )
            for c in unicast_configs:
                if include_all or is_apple_tv_config(c, local_ips):
                    discovered_configs[canonical_identifier(c)] = c

        return list(discovered_configs.values())

    async def find_device(
        self, identifier: str, address: str | None = None
    ) -> BaseConfig:
        if address:
            configs = await self.scan_configs(hosts=[address], include_all=True)
            for c in configs:
                if identifier in c.all_identifiers or str(c.address) == address:
                    return c

        configs = await self.scan_configs(include_all=False)
        for c in configs:
            if identifier in c.all_identifiers:
                return c

        raise LookupError(f"Apple TV '{identifier}' was not found on the local network.")

    async def start_pairing(
        self,
        identifier: str,
        protocol_name: str,
        address: str | None = None,
        client_name: str = "TV Remote",
    ) -> dict[str, Any]:
        async with self._pairing_lock:
            proto = PROTOCOL_BY_NAME.get(protocol_name)
            if proto is None:
                raise ValueError(f"Unsupported protocol: {protocol_name}")

            # Reuse an active, recent pairing session for the same device/protocol
            # so reopening the UI doesn't abort M1/M2 and trigger Apple TV BackOff.
            if (
                self.pairing_handler is not None
                and self.pairing_identifier == identifier
                and self.pairing_protocol == protocol_name
                and (time.monotonic() - self.pairing_started_at) < 75.0
            ):
                return {
                    "protocol": protocol_name,
                    "deviceProvidesPin": bool(self.pairing_handler.device_provides_pin),
                    "deviceName": self.connected_name or "Apple TV",
                }

            await self._cancel_pairing_unlocked()
            conf = await self.find_device(identifier=identifier, address=address)

            backoff_re = re.compile(r"BackOff=(\d+)s", re.IGNORECASE)
            last_exc: Exception | None = None

            for attempt in range(4):
                pairing = await pyatv.pair(conf, proto, self.loop, name=client_name)
                try:
                    await pairing.begin()
                    self.pairing_handler = pairing
                    self.pairing_protocol = protocol_name
                    self.pairing_identifier = identifier
                    self.pairing_started_at = time.monotonic()
                    return {
                        "protocol": protocol_name,
                        "deviceProvidesPin": bool(pairing.device_provides_pin),
                        "deviceName": conf.name,
                    }
                except Exception as exc:
                    last_exc = exc
                    with suppress(Exception):
                        await pairing.close()

                    msg = str(exc)
                    match = backoff_re.search(msg)
                    if match and attempt < 3:
                        wait_secs = min(int(match.group(1)), 70)
                        emit(
                            {
                                "type": "event",
                                "event": "pairing_backoff",
                                "data": {
                                    "seconds": wait_secs,
                                    "protocol": protocol_name,
                                },
                            }
                        )
                        await asyncio.sleep(wait_secs + 0.75)
                        continue
                    raise

            assert last_exc is not None
            raise last_exc

    async def finish_pairing(self, pin: str) -> dict[str, Any]:
        async with self._pairing_lock:
            if self.pairing_handler is None or self.pairing_protocol is None:
                raise RuntimeError("Pairing session expired. Click Retry to display a new PIN.")

            pairing = self.pairing_handler
            protocol_name = self.pairing_protocol
            clean_pin = pin.strip()
            if not clean_pin.isdigit() or len(clean_pin) != 4:
                raise ValueError("PIN must be 4 digits.")

            try:
                pairing.pin(int(clean_pin))
                await pairing.finish()
                paired = bool(pairing.has_paired)
                credentials = pairing.service.credentials if paired else None
            finally:
                with suppress(Exception):
                    await pairing.close()
                self.pairing_handler = None
                self.pairing_protocol = None
                self.pairing_identifier = None
                self.pairing_started_at = 0.0

            if not paired or not credentials:
                raise RuntimeError("Pairing was rejected. Check the PIN and try again.")

            return {
                "paired": True,
                "protocol": protocol_name,
                "credentials": credentials,
            }

    async def cancel_pairing(self) -> None:
        async with self._pairing_lock:
            await self._cancel_pairing_unlocked()

    async def _cancel_pairing_unlocked(self) -> None:
        if self.pairing_handler is not None:
            with suppress(Exception):
                await self.pairing_handler.close()
            self.pairing_handler = None
            self.pairing_protocol = None
            self.pairing_identifier = None
            self.pairing_started_at = 0.0

    async def connect(
        self,
        identifier: str,
        credentials: dict[str, str],
        address: str | None = None,
    ) -> dict[str, Any]:
        async with self._lock:
            await self._disconnect_unlocked()
            conf = await self.find_device(identifier=identifier, address=address)

            applied_any = False
            for proto_name, cred in (credentials or {}).items():
                proto = PROTOCOL_BY_NAME.get(proto_name)
                if proto and cred:
                    if conf.set_credentials(proto, cred):
                        applied_any = True

            required = required_pairing_protocols(conf)
            if required and not applied_any:
                raise PermissionError(
                    "Not paired with this Apple TV yet. Pair first to connect."
                )

            atv = await pyatv.connect(conf, self.loop)
            atv.listener = self
            with suppress(Exception):
                atv.audio.listener = self
            with suppress(Exception):
                atv.keyboard.listener = self
            with suppress(Exception):
                atv.push_updater.listener = self
                atv.push_updater.start()

            self.atv = atv
            self.connected_identifier = conf.identifier or identifier
            self.connected_name = conf.name
            self._is_muted = False
            self._last_artwork_id = None
            self._last_artwork_b64 = None

            await asyncio.sleep(0.35)
            return await self._build_state_snapshot(conf)

    async def disconnect(self) -> None:
        async with self._lock:
            await self._disconnect_unlocked()

    async def _disconnect_unlocked(self) -> None:
        if self._now_playing_task is not None:
            self._now_playing_task.cancel()
            self._now_playing_task = None
        if self.atv is not None:
            atv = self.atv
            self.atv = None
            with suppress(Exception):
                atv.push_updater.stop()
            with suppress(Exception):
                atv.close()
        self.connected_identifier = None
        self.connected_name = None

    def _capabilities(self) -> dict[str, Any]:
        atv = self.atv
        if atv is None:
            return {
                "volumeSupported": False,
                "setVolumeSupported": False,
                "volume": None,
                "isMuted": False,
                "controlCenterSupported": False,
                "longPressSelectSupported": False,
            }

        f = atv.features
        vol_step = f.in_state(
            FeatureState.Available, FeatureName.VolumeUp
        ) or f.in_state(FeatureState.Available, FeatureName.VolumeDown)
        set_vol = f.in_state(
            FeatureState.Available, FeatureName.SetVolume
        ) and f.in_state(FeatureState.Available, FeatureName.Volume)
        cc_supported = f.in_state(
            FeatureState.Available, FeatureName.ControlCenter
        ) or f.in_state(FeatureState.Available, FeatureName.Home)
        select_supported = f.in_state(FeatureState.Available, FeatureName.Select)

        volume_level: float | None = None
        if set_vol:
            with suppress(Exception):
                volume_level = float(atv.audio.volume)

        return {
            "volumeSupported": bool(vol_step or set_vol),
            "setVolumeSupported": bool(set_vol),
            "volume": volume_level,
            "isMuted": self._is_muted,
            "controlCenterSupported": bool(cc_supported),
            "longPressSelectSupported": bool(select_supported),
        }

    async def _extract_now_playing(
        self, playing: Playing | None = None
    ) -> dict[str, Any] | None:
        atv = self.atv
        if atv is None:
            return None

        try:
            if playing is None:
                playing = await asyncio.wait_for(atv.metadata.playing(), timeout=2.0)
        except Exception:
            return None

        state = playing.device_state
        state_name = state.name.lower() if state else "idle"
        title = playing.title or playing.series_name
        artist = playing.artist or playing.album

        app_name: str | None = None
        app_id: str | None = None
        with suppress(Exception):
            if atv.features.in_state(FeatureState.Available, FeatureName.App):
                app = atv.metadata.app
                if app:
                    app_name = app.name
                    app_id = app.identifier

        if state in (DeviceState.Idle, DeviceState.Stopped) and not title:
            return {
                "isActive": False,
                "deviceState": state_name,
                "title": None,
                "subtitle": None,
                "appName": app_name,
                "appId": app_id,
                "artworkBase64": None,
            }

        artwork_b64: str | None = None
        with suppress(Exception):
            if atv.features.in_state(FeatureState.Available, FeatureName.Artwork):
                art_id = atv.metadata.artwork_id
                if (
                    art_id
                    and art_id == self._last_artwork_id
                    and self._last_artwork_b64
                ):
                    artwork_b64 = self._last_artwork_b64
                else:
                    art = await asyncio.wait_for(
                        atv.metadata.artwork(width=160, height=160), timeout=2.0
                    )
                    if art and art.bytes:
                        artwork_b64 = base64.b64encode(art.bytes).decode("ascii")
                        self._last_artwork_id = art_id
                        self._last_artwork_b64 = artwork_b64

        return {
            "isActive": bool(
                title
                or state in (DeviceState.Playing, DeviceState.Paused, DeviceState.Loading)
            ),
            "deviceState": state_name,
            "title": title,
            "subtitle": artist,
            "appName": app_name,
            "appId": app_id,
            "position": playing.position,
            "totalTime": playing.total_time,
            "artworkBase64": artwork_b64,
        }

    async def _build_state_snapshot(self, conf: BaseConfig) -> dict[str, Any]:
        caps = self._capabilities()
        now_playing = await self._extract_now_playing()
        return {
            "device": serialize_config(conf),
            "capabilities": caps,
            "nowPlaying": now_playing,
        }

    def _get_mrp_protocol(self) -> Any | None:
        if self.atv is None:
            return None
        handlers = getattr(self.atv, "_protocol_handlers", None)
        if not isinstance(handlers, dict):
            return None
        mrp_setup = handlers.get(Protocol.MRP)
        if mrp_setup is None:
            return None
        mrp_audio = mrp_setup.interfaces.get(Audio)
        return getattr(mrp_audio, "protocol", None)

    async def _send_mrp_hid_mute(self) -> bool:
        """
        Send USB HID Consumer Mute (Page 0x0C = 12, Usage 0xE2 = 226) over MRP.
        tvOS translates this directly into HDMI-CEC Mute (same as Siri Remote Mute).
        """
        mrp_proto = self._get_mrp_protocol()
        if mrp_proto is None:
            return False

        await mrp_proto.send(mrp_messages.send_hid_event(12, 226, True))
        await asyncio.sleep(0.04)
        await mrp_proto.send(mrp_messages.send_hid_event(12, 226, False))
        return True

    async def _send_mrp_hid_key(self, usage: int, shift: bool = False) -> bool:
        """Send a USB HID Keyboard/Keypad Page (0x07) key press over MRP."""
        mrp_proto = self._get_mrp_protocol()
        if mrp_proto is None:
            return False

        if shift:
            await mrp_proto.send(mrp_messages.send_hid_event(7, 225, True))
            await asyncio.sleep(0.012)
        await mrp_proto.send(mrp_messages.send_hid_event(7, usage, True))
        await asyncio.sleep(0.018)
        await mrp_proto.send(mrp_messages.send_hid_event(7, usage, False))
        if shift:
            await asyncio.sleep(0.012)
            await mrp_proto.send(mrp_messages.send_hid_event(7, 225, False))
        await asyncio.sleep(0.012)
        return True

    async def send_keyboard_input(
        self, action: str, text: str = ""
    ) -> dict[str, Any]:
        """
        Send live keyboard input to Apple TV.
        Uses Companion RemoteTextInput (atv.keyboard) whenever a native tvOS text
        session (_tiD) is active, and falls back seamlessly to USB HID Keyboard
        Page 0x07 over MRP for custom app keyboards (such as YouTube's A-Z bar).
        """
        if self.atv is None:
            raise ConnectionError("Not connected to an Apple TV.")

        async with self._keyboard_lock:
            kb = self.atv.keyboard
            f = self.atv.features
            kb_supported = f.in_state(
                FeatureState.Available, FeatureName.TextAppend
            ) or f.in_state(FeatureState.Available, FeatureName.TextSet)

            if action == "append":
                if not text:
                    return {"sent": True}
                handled_by_rti = False
                if kb_supported:
                    with suppress(Exception):
                        await asyncio.wait_for(kb.text_append(text), timeout=2.5)
                        if kb.text_focus_state == KeyboardFocusState.Focused:
                            handled_by_rti = True

                if not handled_by_rti:
                    sent_any = False
                    for ch in text:
                        mapped = usb_hid_lookup(ch)
                        if mapped is not None:
                            ok = await self._send_mrp_hid_key(mapped[0], mapped[1])
                            sent_any = sent_any or ok
                    if not sent_any and not kb_supported:
                        raise atv_exceptions.NotSupportedError(
                            "Select a search or text field on your Apple TV first."
                        )
                return {"sent": True}

            if action == "backspace":
                handled_by_rti = False
                if kb_supported:
                    with suppress(Exception):
                        current = await asyncio.wait_for(kb.text_get(), timeout=2.5)
                        if current is not None:
                            handled_by_rti = True
                            if len(current) > 0:
                                await asyncio.wait_for(
                                    kb.text_set(current[:-1]), timeout=2.5
                                )
                if not handled_by_rti:
                    await self._send_mrp_hid_key(42, False)  # USB HID Backspace
                return {"sent": True}

            if action == "clear":
                handled_by_rti = False
                if kb_supported:
                    with suppress(Exception):
                        current = await asyncio.wait_for(kb.text_get(), timeout=2.5)
                        if current is not None:
                            handled_by_rti = True
                            await asyncio.wait_for(kb.text_clear(), timeout=2.5)
                if not handled_by_rti:
                    for _ in range(24):
                        if not await self._send_mrp_hid_key(42, False):
                            break
                return {"sent": True}

            if action == "return":
                sent_hid = await self._send_mrp_hid_key(40, False)  # USB HID Return
                if not sent_hid:
                    await self.atv.remote_control.select(InputAction.SingleTap)
                return {"sent": True}

            raise ValueError(f"Unknown keyboard action: {action}")

    async def execute_command(
        self, action: str, value: float | None = None
    ) -> dict[str, Any]:
        if self.atv is None:
            raise ConnectionError("Not connected to an Apple TV.")

        rc = self.atv.remote_control
        audio = self.atv.audio
        f = self.atv.features

        if action == "up":
            await rc.up(InputAction.SingleTap)
        elif action == "down":
            await rc.down(InputAction.SingleTap)
        elif action == "left":
            await rc.left(InputAction.SingleTap)
        elif action == "right":
            await rc.right(InputAction.SingleTap)
        elif action == "select":
            await rc.select(InputAction.SingleTap)
        elif action == "select_hold":
            await rc.select(InputAction.Hold)
        elif action == "menu":
            await rc.menu(InputAction.SingleTap)
        elif action == "home":
            await rc.home(InputAction.SingleTap)
        elif action in ("home_hold", "control_center"):
            if f.in_state(FeatureState.Available, FeatureName.ControlCenter):
                await rc.control_center()
            else:
                await rc.home(InputAction.Hold)
        elif action == "play_pause":
            await rc.play_pause()
        elif action == "previous":
            await rc.previous()
        elif action == "next":
            await rc.next()
        elif action == "volume_up":
            self._is_muted = False
            try:
                await asyncio.wait_for(rc.volume_up(), timeout=2.0)
            except (atv_exceptions.NotSupportedError, asyncio.TimeoutError):
                await asyncio.wait_for(audio.volume_up(), timeout=2.0)
        elif action == "volume_down":
            self._is_muted = False
            try:
                await asyncio.wait_for(rc.volume_down(), timeout=2.0)
            except (atv_exceptions.NotSupportedError, asyncio.TimeoutError):
                await asyncio.wait_for(audio.volume_down(), timeout=2.0)
        elif action == "set_volume":
            if value is None:
                raise ValueError("Missing volume value.")
            clamped = max(0.0, min(100.0, float(value)))
            await asyncio.wait_for(audio.set_volume(clamped), timeout=3.0)
            self._is_muted = clamped <= 0.5
        elif action == "toggle_mute":
            caps = self._capabilities()
            if not caps["volumeSupported"]:
                raise atv_exceptions.NotSupportedError(
                    "Volume control isn't supported for this TV's audio output (requires HDMI-CEC/eARC or HomePod)."
                )
            if caps["setVolumeSupported"]:
                current = float(audio.volume)
                if not self._is_muted and current > 0.5:
                    self._saved_volume = current
                    await asyncio.wait_for(audio.set_volume(0.0), timeout=3.0)
                    self._is_muted = True
                else:
                    restore = self._saved_volume if self._saved_volume > 0.5 else 25.0
                    await asyncio.wait_for(audio.set_volume(restore), timeout=3.0)
                    self._is_muted = False
            else:
                # HDMI-CEC relative volume mode: send Siri Remote HID Consumer Mute over MRP
                sent_hid_mute = await self._send_mrp_hid_mute()
                if sent_hid_mute:
                    self._is_muted = not self._is_muted
                else:
                    # Companion-only fallback: step down/up rapidly
                    if not self._is_muted:
                        for _ in range(16):
                            with suppress(Exception):
                                await asyncio.wait_for(rc.volume_down(), timeout=0.35)
                        self._is_muted = True
                    else:
                        for _ in range(12):
                            with suppress(Exception):
                                await asyncio.wait_for(rc.volume_up(), timeout=0.35)
                        self._is_muted = False
        else:
            raise ValueError(f"Unknown remote action: {action}")

        return {"capabilities": self._capabilities()}

    def playstatus_update(self, updater: Any, playstatus: Playing) -> None:
        if self._now_playing_task and not self._now_playing_task.done():
            self._now_playing_task.cancel()
        self._now_playing_task = self.loop.create_task(
            self._emit_playstatus(playstatus)
        )

    async def _emit_playstatus(self, playstatus: Playing) -> None:
        with suppress(asyncio.CancelledError, Exception):
            np = await self._extract_now_playing(playstatus)
            emit(
                {
                    "type": "event",
                    "event": "now_playing",
                    "data": {
                        "nowPlaying": np,
                        "capabilities": self._capabilities(),
                    },
                }
            )

    def playstatus_error(self, updater: Any, exception: Exception) -> None:
        LOGGER.debug("Push updater error: %s", exception)

    def volume_update(self, old_level: float, new_level: float) -> None:
        if new_level > 0.5 and self._is_muted:
            self._is_muted = False
        emit(
            {
                "type": "event",
                "event": "audio_update",
                "data": self._capabilities(),
            }
        )

    def volume_device_update(
        self, output_device: OutputDevice, old_level: float, new_level: float
    ) -> None:
        self.volume_update(old_level, new_level)

    def outputdevices_update(
        self, old_devices: list[OutputDevice], new_devices: list[OutputDevice]
    ) -> None:
        emit(
            {
                "type": "event",
                "event": "audio_update",
                "data": self._capabilities(),
            }
        )

    def focusstate_update(
        self, old_state: KeyboardFocusState, new_state: KeyboardFocusState
    ) -> None:
        LOGGER.debug("TV keyboard focus changed: %s -> %s", old_state, new_state)

    def connection_lost(self, exception: Exception) -> None:
        LOGGER.warning("Connection lost: %s", exception)
        self.atv = None
        emit(
            {
                "type": "event",
                "event": "connection_lost",
                "data": {"reason": str(exception)},
            }
        )

    def connection_closed(self) -> None:
        LOGGER.info("Connection closed")


async def handle_request(session: BridgeSession, req: dict[str, Any]) -> None:
    req_id = req.get("id")
    cmd = req.get("cmd")
    params = req.get("params") or {}

    try:
        if cmd == "ping":
            result: Any = {"pong": True}
        elif cmd == "scan":
            configs = await session.scan_configs(
                hosts=params.get("hosts"),
                include_all=bool(params.get("includeAll", False)),
            )
            result = {"devices": [serialize_config(c) for c in configs]}
        elif cmd == "start_pairing":
            result = await session.start_pairing(
                identifier=params["identifier"],
                protocol_name=params["protocol"],
                address=params.get("address"),
                client_name=params.get("name", "TV Remote"),
            )
        elif cmd == "finish_pairing":
            result = await session.finish_pairing(pin=str(params["pin"]))
        elif cmd == "cancel_pairing":
            await session.cancel_pairing()
            result = {"cancelled": True}
        elif cmd == "connect":
            result = await session.connect(
                identifier=params["identifier"],
                credentials=params.get("credentials") or {},
                address=params.get("address"),
            )
        elif cmd == "disconnect":
            await session.disconnect()
            result = {"disconnected": True}
        elif cmd == "status":
            result = {
                "connected": session.atv is not None,
                "identifier": session.connected_identifier,
                "name": session.connected_name,
                "capabilities": session._capabilities(),
            }
        elif cmd == "command":
            result = await session.execute_command(
                action=params["action"],
                value=params.get("value"),
            )
        elif cmd == "keyboard":
            result = await session.send_keyboard_input(
                action=params.get("action", "append"),
                text=str(params.get("text", "")),
            )
        else:
            raise ValueError(f"Unknown command: {cmd}")

        emit({"type": "response", "id": req_id, "ok": True, "result": result})

    except PermissionError as exc:
        emit(
            {
                "type": "response",
                "id": req_id,
                "ok": False,
                "error": {"code": "not_paired", "message": str(exc)},
            }
        )
    except atv_exceptions.AuthenticationError as exc:
        emit(
            {
                "type": "response",
                "id": req_id,
                "ok": False,
                "error": {
                    "code": "auth_failed",
                    "message": f"Authentication failed. Reset pairing and re-pair ({exc}).",
                },
            }
        )
    except atv_exceptions.NotSupportedError as exc:
        emit(
            {
                "type": "response",
                "id": req_id,
                "ok": False,
                "error": {"code": "not_supported", "message": str(exc)},
            }
        )
    except LookupError as exc:
        emit(
            {
                "type": "response",
                "id": req_id,
                "ok": False,
                "error": {"code": "device_offline", "message": str(exc)},
            }
        )
    except Exception as exc:
        LOGGER.exception("Command %s failed", cmd)
        emit(
            {
                "type": "response",
                "id": req_id,
                "ok": False,
                "error": {"code": "bridge_error", "message": str(exc)},
            }
        )


async def main() -> None:
    loop = asyncio.get_running_loop()
    session = BridgeSession(loop)

    try:
        version = importlib.metadata.version("pyatv")
    except Exception:
        version = "unknown"

    emit({"type": "ready", "pyatvVersion": version})

    line_queue: asyncio.Queue[str | None] = asyncio.Queue()

    def _stdin_reader() -> None:
        try:
            for raw_line in sys.stdin:
                loop.call_soon_threadsafe(line_queue.put_nowait, raw_line)
        except Exception:
            pass
        finally:
            loop.call_soon_threadsafe(line_queue.put_nowait, None)

    reader_thread = threading.Thread(target=_stdin_reader, daemon=True)
    reader_thread.start()

    active_tasks: set[asyncio.Task[None]] = set()
    try:
        while True:
            raw_line = await line_queue.get()
            if raw_line is None:
                break
            line = raw_line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except json.JSONDecodeError as exc:
                emit(
                    {
                        "type": "response",
                        "id": None,
                        "ok": False,
                        "error": {"code": "invalid_json", "message": str(exc)},
                    }
                )
                continue

            task = loop.create_task(handle_request(session, req))
            active_tasks.add(task)
            task.add_done_callback(active_tasks.discard)

        if active_tasks:
            await asyncio.gather(*list(active_tasks), return_exceptions=True)
    finally:
        await session.cancel_pairing()
        await session.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
