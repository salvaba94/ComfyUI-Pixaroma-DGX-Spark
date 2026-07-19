#!/usr/bin/env python3
"""Disable preinstalled flash_attn builds that do not match the active torch."""

from __future__ import annotations

import importlib
import pathlib
import shutil
import site
import sys


def candidate_roots() -> list[pathlib.Path]:
    roots = {pathlib.Path(p) for p in site.getsitepackages()}
    roots.add(pathlib.Path(sys.prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages")
    roots.add(pathlib.Path("/usr/local/lib") / f"python{sys.version_info.major}.{sys.version_info.minor}" / "dist-packages")
    return [p for p in roots if p.exists()]


def disable_path(path: pathlib.Path) -> None:
    disabled_root = path.parent.with_name(f"{path.parent.name}.disabled")
    disabled_root.mkdir(exist_ok=True)
    target = disabled_root / f"{path.name}.disabled"
    if target.exists():
        if target.is_dir():
            shutil.rmtree(target)
        else:
            target.unlink()
    shutil.move(str(path), str(target))
    print(f"Disabled broken flash_attn artifact: {path}")


try:
    importlib.import_module("flash_attn")
except Exception as exc:
    print(f"flash_attn import failed; disabling stale artifacts: {exc}")
    for root in candidate_roots():
        for path in sorted(root.glob("flash_attn*")):
            disable_path(path)
else:
    print("flash_attn imports successfully; leaving it enabled.")
