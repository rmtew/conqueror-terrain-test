#!/usr/bin/env python3
"""Build the pinned vasm snapshot into this directory (Python 3.12+)."""
from hashlib import sha256
from pathlib import Path
import os
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory


BIN = Path(__file__).resolve().parent
ARCHIVE = BIN / "vasm-2.0f.tar.gz"
SHA256 = "c84b2de1cbb87831795fe64a85c5d9a7002a766e3a7c30b0a2d7d5e99d878f49"


def main():
    if sha256(ARCHIVE.read_bytes()).hexdigest() != SHA256:
        raise SystemExit(f"Checksum mismatch: {ARCHIVE.name}")

    windows = os.name == "nt"
    make = shutil.which("mingw32-make" if windows else "make")
    if not make or not shutil.which("gcc"):
        raise SystemExit("Install MinGW-w64 GCC and mingw32-make (Windows), or GCC and make (Linux), and add them to PATH.")

    with TemporaryDirectory(prefix="terrain-vasm-") as temp:
        with tarfile.open(ARCHIVE, "r:gz") as archive:
            archive.extractall(temp, filter="data")
        source = Path(temp) / "vasm"
        args = [make, "CPU=m68k", "SYNTAX=mot", "CC=gcc"]
        output = "vasmm68k_mot"
        if windows:
            args += ["-f", "Makefile.Win32FromLinux", "LD=gcc"]
            output += "_win32.exe"
        (source / ("obj_win32" if windows else "obj")).mkdir(exist_ok=True)
        subprocess.run([*args, output], cwd=source, check=True)
        target = BIN / ("vasmm68k_mot.exe" if windows else "vasmm68k_mot")
        shutil.copy2(source / output, target)
        print(f"Built {target}")


if __name__ == "__main__":
    main()
