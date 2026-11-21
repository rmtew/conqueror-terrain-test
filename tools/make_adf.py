#!/usr/bin/env python3
"""Master an 880 KiB OFS floppy using amitools; no Amiga OS files included."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('executable', type=Path)
    parser.add_argument('image', type=Path)
    args = parser.parse_args()
    executable, image = args.executable.resolve(), args.image.resolve()
    if not executable.is_file():
        parser.error(f'executable does not exist: {executable}')
    image.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        startup = Path(tmp) / 'Startup-Sequence'
        startup.write_bytes(b'SYS:TankRenderLab\n')
        # Create a fresh image; do not accidentally modify an unrelated image.
        staged = Path(tmp) / 'disk.adf'
        cmd = [sys.executable, '-m', 'amitools.tools.xdftool', str(staged),
               'format', 'TankRenderLab', 'ofs', '+', 'boot', 'install', 'boot1x',
               '+', 'makedir', 's', '+', 'write', str(startup), 's/Startup-Sequence',
               '+', 'write', str(executable), 'TankRenderLab']
        subprocess.run(cmd, check=True)
        image.write_bytes(staged.read_bytes())
    print(f'Created {image}')


if __name__ == '__main__':
    main()
