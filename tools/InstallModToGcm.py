#!/usr/bin/env python3
"""
Import a mod folder into a GameCube GCM/ISO (same behavior as GCFT
"Add/Replace Files From Folder"). Uses LagoLunatic/gclib.
https://github.com/LagoLunatic/GCFT
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys


def bootstrap_gclib(extra_paths: list[str]):
    for p in extra_paths:
        if not p:
            continue
        ap = os.path.abspath(p)
        if os.path.isdir(ap) and ap not in sys.path:
            sys.path.insert(0, ap)
    try:
        from gclib.gcm import GCM  # type: ignore
        return GCM
    except ImportError as exc:
        msg = (
            "Could not import gclib.\n"
            "Install GCFT from https://github.com/LagoLunatic/GCFT/releases\n"
            "or clone GCFT with submodules next to this app, then run:\n"
            '  py -3.12 -m pip install "gclib @ git+https://github.com/LagoLunatic/gclib.git"'
        )
        raise SystemExit(msg) from exc


ALLOWED_SYS_FILES = frozenset(
    {"apploader.img", "bi2.bin", "boot.bin", "fst.bin", "main.dol"}
)
RISKY_SYS_FILES = frozenset({"boot.bin", "main.dol", "fst.bin", "bi2.bin"})
BLOCKED_EXTENSIONS = frozenset(
    {
        ".exe",
        ".bat",
        ".cmd",
        ".com",
        ".scr",
        ".ps1",
        ".vbs",
        ".js",
        ".msi",
        ".reg",
        ".lnk",
        ".dll",
    }
)


def _normalize_zip_entry(name: str) -> str:
    return name.replace("\\", "/").strip("/")


def _zip_entry_is_safe(name: str) -> bool | str:
    n = _normalize_zip_entry(name)
    if not n:
        return True
    if ".." in n.split("/"):
        return "path traversal (..)"
    if ":" in n.split("/")[0]:
        return "absolute or drive path"
    if n.startswith("/"):
        return "absolute path"
    return True


def validate_mod_folder(
    source_root: str, gcm_path: str | None, extra_paths: list[str]
) -> tuple[list[str], list[str], dict]:
    """Return (errors, warnings, stats). errors block install; warnings need user OK."""
    errors: list[str] = []
    warnings: list[str] = []
    stats: dict = {
        "mod_root": source_root,
        "files_count": 0,
        "sys_files": [],
        "replace_count": 0,
        "add_count": 0,
    }

    source_root = os.path.abspath(source_root)
    try:
        root_names = set(os.listdir(source_root))
    except OSError as err:
        errors.append(f"Cannot read mod folder: {err}")
        return errors, warnings, stats

    if not {"files", "sys"}.issubset(root_names):
        errors.append("Mod root must contain 'files' and 'sys' folders.")
        return errors, warnings, stats
    extra = root_names - {"files", "sys"}
    if extra:
        errors.append(
            "Unexpected items at mod root (only files/ and sys/ allowed): "
            + ", ".join(sorted(extra)[:8])
        )

    files_dir = os.path.join(source_root, "files")
    sys_dir = os.path.join(source_root, "sys")
    if not os.path.isdir(files_dir):
        errors.append("'files' must be a folder.")
    if not os.path.isdir(sys_dir):
        errors.append("'sys' must be a folder.")

    game_files = 0
    if os.path.isdir(files_dir):
        for dirpath, _dirnames, filenames in os.walk(files_dir):
            for fn in filenames:
                game_files += 1
                ext = os.path.splitext(fn)[1].lower()
                if ext in BLOCKED_EXTENSIONS:
                    rel = os.path.relpath(os.path.join(dirpath, fn), source_root)
                    errors.append(f"Blocked file type in mod: {rel}")
    stats["files_count"] = game_files
    if game_files == 0:
        errors.append("No files under files/ — not a usable texture/mod pack for ISO import.")

    sys_files: list[str] = []
    if os.path.isdir(sys_dir):
        for fn in os.listdir(sys_dir):
            fp = os.path.join(sys_dir, fn)
            if os.path.isfile(fp):
                sys_files.append(fn)
                if fn.lower() not in ALLOWED_SYS_FILES:
                    errors.append(
                        f"Invalid sys file '{fn}' (GCFT only allows: "
                        + ", ".join(sorted(ALLOWED_SYS_FILES))
                        + ")"
                    )
                elif fn.lower() in RISKY_SYS_FILES:
                    warnings.append(
                        f"Mod replaces risky system file sys/{fn} — wrong file can break the game."
                    )
    stats["sys_files"] = sys_files

    if gcm_path and not errors:
        GCM = bootstrap_gclib(extra_paths)
        gcm = GCM(os.path.abspath(gcm_path))
        gcm.read_entire_disc()
        replace_paths, add_paths = gcm.collect_files_to_replace_and_add_from_disk(
            source_root
        )
        stats["replace_count"] = len(replace_paths)
        stats["add_count"] = len(add_paths)
        if not replace_paths and not add_paths:
            errors.append(
                "No paths in this mod match the ISO (nothing to replace or add)."
            )
        if len(add_paths) > 500:
            warnings.append(
                f"Mod adds {len(add_paths)} new files to the ISO — unusually large."
            )

    return errors, warnings, stats


def resolve_gcm_source_folder(path: str) -> str:
    """Folder whose root contains only files/ and sys/ (GCFT requirement)."""
    path = os.path.abspath(path)
    if not os.path.isdir(path):
        raise SystemExit(f"Source is not a folder: {path}")

    def valid_root(candidate: str) -> bool:
        try:
            names = set(os.listdir(candidate))
        except OSError as err:
            raise SystemExit(f"Cannot read folder: {candidate}") from err
        if not {"files", "sys"}.issubset(names):
            return False
        if names - {"files", "sys"}:
            return False
        return all(
            os.path.isdir(os.path.join(candidate, n)) for n in ("files", "sys")
        )

    if valid_root(path):
        return path

    try:
        entries = os.listdir(path)
    except OSError as err:
        raise SystemExit(f"Cannot read folder: {path}") from err
    subdirs = [
        os.path.join(path, n)
        for n in entries
        if os.path.isdir(os.path.join(path, n))
    ]
    if len(subdirs) == 1 and valid_root(subdirs[0]):
        return subdirs[0]

    raise SystemExit(
        "Mod folder must contain only 'files' and 'sys' at the top level "
        "(or inside one wrapper folder). This matches GCFT's import layout."
    )


def run_import(GCM, gcm_path: str, source_root: str, output_path: str) -> None:
    gcm = GCM(os.path.abspath(gcm_path))
    gcm.read_entire_disc()

    replace_paths, add_paths = gcm.collect_files_to_replace_and_add_from_disk(
        source_root
    )
    print(f"Files to replace: {len(replace_paths)}")
    print(f"Files to add: {len(add_paths)}")
    if not replace_paths and not add_paths:
        raise SystemExit(
            "No matching files to import. Check that paths inside the mod "
            "match the ISO (files/... and sys/...)."
        )

    for _progress in gcm.import_files_from_disk_by_paths(replace_paths, add_paths):
        pass

    gcm.recalculate_file_entry_indexes()

    out_abs = os.path.abspath(output_path)
    in_abs = os.path.abspath(gcm_path)
    if os.path.normcase(out_abs) == os.path.normcase(in_abs):
        raise SystemExit("Output path must differ from input GCM.")

    for _progress in gcm.export_disc_to_iso_with_changed_files(out_abs):
        pass

    print(f"Wrote: {out_abs}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Install mod folder into GameCube ISO/GCM")
    parser.add_argument("--gcm", help="Input .iso / .gcm path")
    parser.add_argument("--source", help="Extracted mod folder (or zip contents)")
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Check mod safety / ISO match; do not write ISO",
    )
    parser.add_argument(
        "--output",
        help="Output ISO path (default: <gcm>.patched.gcm next to input)",
    )
    parser.add_argument(
        "--in-place",
        action="store_true",
        help="Replace the input GCM (creates .bak backup first)",
    )
    parser.add_argument(
        "--gclib-path",
        action="append",
        default=[],
        help="Extra folder to add to PYTHONPATH (GCFT or gclib clone)",
    )
    args = parser.parse_args()

    if not args.source:
        raise SystemExit("--source is required")

    source_root = resolve_gcm_source_folder(args.source)
    print(f"MOD_ROOT={source_root}")

    if args.validate_only:
        gcm_path = os.path.abspath(args.gcm) if args.gcm else None
        if gcm_path and not os.path.isfile(gcm_path):
            raise SystemExit(f"GCM/ISO not found: {gcm_path}")
        errors, warnings, stats = validate_mod_folder(
            source_root, gcm_path, list(args.gclib_path)
        )
        for w in warnings:
            print(f"WARN={w}")
        for e in errors:
            print(f"ERR={e}")
        print(f"STAT_FILES={stats['files_count']}")
        print(f"STAT_REPLACE={stats['replace_count']}")
        print(f"STAT_ADD={stats['add_count']}")
        if errors:
            print("VALIDATE_OK=0")
            return 1
        print("VALIDATE_OK=1")
        return 0

    if not args.gcm:
        raise SystemExit("--gcm is required for install")

    GCM = bootstrap_gclib(list(args.gclib_path))
    print(f"Using mod root: {source_root}")

    gcm_path = os.path.abspath(args.gcm)
    if not os.path.isfile(gcm_path):
        raise SystemExit(f"GCM/ISO not found: {gcm_path}")

    if args.in_place:
        backup = gcm_path + ".bak"
        if not os.path.isfile(backup):
            print(f"Creating backup: {backup}")
            shutil.copy2(gcm_path, backup)
        temp_out = gcm_path + ".tmp"
        if os.path.isfile(temp_out):
            os.remove(temp_out)
        run_import(GCM, gcm_path, source_root, temp_out)
        os.replace(temp_out, gcm_path)
        print(f"Updated in place: {gcm_path}")
    else:
        out = args.output
        if not out:
            base, _ext = os.path.splitext(gcm_path)
            out = base + ".patched.gcm"
        run_import(GCM, gcm_path, source_root, out)

    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
