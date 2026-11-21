#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${VASM:-}" ]; then assembler=$VASM
elif [ -x "$root/bin/vasmm68k_mot" ]; then assembler=$root/bin/vasmm68k_mot
else assembler=vasmm68k_mot; fi
case "$assembler" in
  /*) ;;
  */*) assembler=$PWD/$assembler ;;
  *) assembler=$(command -v "$assembler") || { echo 'vasm not found; run python bin/setup.py or set VASM' >&2; exit 1; } ;;
esac
mkdir -p "$root/build"
cd "$root"
"$assembler" -m68000 -Fhunkexe -kick1hunks -I. -o build/TankRenderLab tank_render_lab.s
python3 tools/make_adf.py build/TankRenderLab build/TankRenderLab.adf
