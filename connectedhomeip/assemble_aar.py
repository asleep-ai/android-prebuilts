#!/usr/bin/env python3
"""Assemble an AAR from the staged build.sh outputs.

Upstream ships no AAR at v1.6.0.0 (examples/android/CHIPTool/chip-library is not part of the
scripted build), so this packs one by hand:

  AndroidManifest.xml     minimal library manifest
  classes.jar             the 8 upstream jars merged into one (duplicate entries must be identical)
  jni/<abi>/*.so          controller JNI + libc++_shared, one directory per built ABI
  META-INF/LICENSE|NOTICE upstream Apache-2.0 files
  R.txt                   empty (no resources)

With --sources-output it also writes a -sources.jar from <input>/sources: every .java/.kt file is
re-rooted at its first chip/ or matter/ path segment, so the jar is package-relative regardless
of where build.sh copied the trees from. Coverage against classes.jar is printed, not enforced.
"""
import argparse
import io
import pathlib
import sys
import zipfile

MANIFEST = """<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="ai.asleep.matter.controller">
    <uses-sdk android:minSdkVersion="24" />
</manifest>
"""

JAR_MANIFEST = "Manifest-Version: 1.0\nCreated-By: asleep-ai/android-prebuilts\n"

# Order matters only for reproducibility; CHIPController first because it is the entry point.
JAR_ORDER = [
    "CHIPController.jar",
    "CHIPInteractionModel.jar",
    "CHIPClusters.jar",
    "CHIPClusterID.jar",
    "AndroidPlatform.jar",
    "OnboardingPayload.jar",
    "libMatterTlv.jar",
    "libMatterJson.jar",
]

SKIP_PREFIXES = ("META-INF/MANIFEST.MF", "META-INF/INDEX.LIST")
SKIP_SUFFIXES = (".SF", ".RSA", ".DSA")


def merge_jars(jar_dir: pathlib.Path) -> tuple[bytes, set[str]]:
    seen: dict[str, bytes] = {}
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as merged:
        merged.writestr(_fixed("META-INF/MANIFEST.MF"), JAR_MANIFEST)
        for name in JAR_ORDER:
            path = jar_dir / name
            if not path.is_file():
                sys.exit(f"missing jar: {path}")
            with zipfile.ZipFile(path) as src:
                for info in sorted(src.infolist(), key=lambda i: i.filename):
                    fn = info.filename
                    if fn.endswith("/") or fn.startswith(SKIP_PREFIXES) or fn.endswith(SKIP_SUFFIXES):
                        continue
                    data = src.read(info)
                    if fn in seen:
                        if seen[fn] != data:
                            sys.exit(f"conflicting entry {fn} in {name}")
                        continue
                    seen[fn] = data
                    merged.writestr(_fixed(fn), data)
    classes = {k[: -len(".class")] for k in seen if k.endswith(".class")}
    print(f"classes.jar: {len(classes)} classes, {len(seen)} entries")
    return out.getvalue(), classes


def sources_jar(src_dir: pathlib.Path, output: pathlib.Path, class_names: set[str]) -> None:
    files: dict[str, pathlib.Path] = {}
    for path in sorted(src_dir.rglob("*")):
        if path.suffix not in (".java", ".kt") or not path.is_file():
            continue
        parts = path.relative_to(src_dir).parts
        root = next((i for i, part in enumerate(parts) if part in ("chip", "matter")), None)
        if root is None or "tests" in parts[:root]:
            continue
        rel = "/".join(parts[root:])
        if rel in files and files[rel].read_bytes() != path.read_bytes():
            print(f"warning: two different sources for {rel}; keeping {files[rel]}")
            continue
        files.setdefault(rel, path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as jar:
        jar.writestr(_fixed("META-INF/MANIFEST.MF"), JAR_MANIFEST)
        for rel, path in files.items():
            jar.writestr(_fixed(rel), path.read_bytes())
    # Top-level classes whose source file (same package, same simple name) is present.
    stems = {rel.rsplit(".", 1)[0] for rel in files}
    top = {c for c in class_names if "$" not in c}
    covered = sum(1 for c in top if c in stems)
    print(f"sources.jar: {len(files)} files, source present for {covered}/{len(top)} top-level classes")
    print(f"wrote {output} ({output.stat().st_size} bytes)")


def _fixed(name: str) -> zipfile.ZipInfo:
    # Fixed timestamp so two builds of the same inputs produce byte-identical archives.
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, type=pathlib.Path, help="build.sh OUT_DIR")
    ap.add_argument("--output", required=True, type=pathlib.Path, help="path of the .aar to write")
    ap.add_argument("--sources-output", type=pathlib.Path, help="path of the -sources.jar to write")
    args = ap.parse_args()

    abi_dirs = sorted(d for d in (args.input / "jni").iterdir() if d.is_dir() and any(d.glob("*.so")))
    if not abi_dirs:
        sys.exit(f"no jni/<abi>/*.so under {args.input}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as aar:
        aar.writestr(_fixed("AndroidManifest.xml"), MANIFEST)
        classes, class_names = merge_jars(args.input / "jars")
        aar.writestr(_fixed("classes.jar"), classes)
        aar.writestr(_fixed("R.txt"), "")
        for abi_dir in abi_dirs:
            for so in sorted(abi_dir.glob("*.so")):
                aar.writestr(_fixed(f"jni/{abi_dir.name}/{so.name}"), so.read_bytes())
                print(f"jni/{abi_dir.name}/{so.name}: {so.stat().st_size} bytes")
        for lic in ("LICENSE", "NOTICE"):
            p = args.input / lic
            if p.is_file():
                aar.writestr(_fixed(f"META-INF/{lic}"), p.read_bytes())
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")
    if args.sources_output:
        sources_jar(args.input / "sources", args.sources_output, class_names)


if __name__ == "__main__":
    main()
