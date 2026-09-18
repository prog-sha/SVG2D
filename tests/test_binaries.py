#!/usr/bin/env python3
"""配布用GDExtensionが参照する全バイナリの形式とCPUを検証する。"""

from __future__ import annotations

import configparser
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DESCRIPTOR = ROOT / "addons/svg2d/svg2d.gdextension"

EXPECTED = {
    "macos.debug": ("mach-o-universal", None),
    "macos.release": ("mach-o-universal", None),
    "windows.debug.x86_64": ("pe", 0x8664),
    "windows.release.x86_64": ("pe", 0x8664),
    "linux.debug.x86_64": ("elf", 62),
    "linux.release.x86_64": ("elf", 62),
    "linux.debug.arm64": ("elf", 183),
    "linux.release.arm64": ("elf", 183),
    "android.debug.arm64": ("elf", 183),
    "android.release.arm64": ("elf", 183),
    "ios.debug.arm64": ("mach-o-arm64", 0x0100000C),
    "ios.release.arm64": ("mach-o-arm64", 0x0100000C),
    "web.debug.wasm32": ("wasm", None),
    "web.release.wasm32": ("wasm", None),
}


def check_binary(path: Path, kind: str, machine: int | None) -> None:
    data = path.read_bytes()
    assert len(data) > 8, f"empty binary: {path}"

    if kind == "wasm":
        assert data[:8] == b"\0asm\x01\0\0\0", f"invalid WebAssembly header: {path}"
        return

    if kind == "elf":
        assert data[:4] == b"\x7fELF", f"invalid ELF header: {path}"
        assert data[4] == 2, f"ELF is not 64-bit: {path}"
        byte_order = "<" if data[5] == 1 else ">"
        assert struct.unpack_from(byte_order + "H", data, 16)[0] == 3, f"ELF is not shared: {path}"
        actual_machine = struct.unpack_from(byte_order + "H", data, 18)[0]
        assert actual_machine == machine, f"wrong ELF machine {actual_machine}: {path}"
        return

    if kind == "pe":
        assert data[:2] == b"MZ", f"invalid PE DOS header: {path}"
        pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
        assert data[pe_offset : pe_offset + 4] == b"PE\0\0", f"invalid PE header: {path}"
        actual_machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
        assert actual_machine == machine, f"wrong PE machine {actual_machine:#x}: {path}"
        return

    if kind == "mach-o-universal":
        assert data[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"), (
            f"Mach-O is not a universal binary: {path}"
        )
        byte_order = ">" if data[:4] == b"\xca\xfe\xba\xbe" else "<"
        count = struct.unpack_from(byte_order + "I", data, 4)[0]
        machines = {
            struct.unpack_from(byte_order + "I", data, 8 + index * 20)[0]
            for index in range(count)
        }
        assert {0x01000007, 0x0100000C}.issubset(machines), (
            f"Mach-O does not contain x86_64 and arm64: {path}"
        )
        return

    if kind == "mach-o-arm64":
        assert data[:4] == b"\xcf\xfa\xed\xfe", f"Mach-O is not little-endian 64-bit: {path}"
        actual_machine = struct.unpack_from("<I", data, 4)[0]
        file_type = struct.unpack_from("<I", data, 12)[0]
        assert actual_machine == machine, f"wrong Mach-O CPU {actual_machine:#x}: {path}"
        assert file_type == 6, f"Mach-O is not a dynamic library: {path}"
        return

    raise AssertionError(f"unknown binary kind: {kind}")


def main() -> None:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    config.read(DESCRIPTOR, encoding="utf-8")
    libraries = dict(config["libraries"])
    assert set(libraries) == set(EXPECTED), (
        f"GDExtension targets differ: expected {sorted(EXPECTED)}, got {sorted(libraries)}"
    )

    for key, (kind, machine) in EXPECTED.items():
        relative = libraries[key].strip('"').removeprefix("./")
        path = DESCRIPTOR.parent / relative
        assert path.is_file(), f"missing {key} binary: {path}"
        check_binary(path, kind, machine)
        print(f"PASS {key}: {path.relative_to(ROOT)} ({path.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
