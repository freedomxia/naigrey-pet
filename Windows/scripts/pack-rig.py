#!/usr/bin/env python3
"""Losslessly compress Swift's raw channel maps; browser DecompressionStream reverses this."""
import gzip
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'assets' / 'rig'
for source in root.glob('*.rgba'):
    source.with_suffix('.rgba.gz').write_bytes(gzip.compress(source.read_bytes(), mtime=0))
    source.unlink()
