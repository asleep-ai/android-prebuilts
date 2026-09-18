#!/usr/bin/env python3
"""Assemble an AAR from the staged build.sh outputs.

Upstream ships no AAR at v1.6.0.0 (examples/android/CHIPTool/chip-library is not part of the
scripted build), so this packs one by hand:

  AndroidManifest.xml     minimal library manifest
  classes.jar             the 8 upstream jars merged into one (duplicate entries must be identical)
  jni/arm64-v8a/*.so      controller JNI + libc++_shared
  META-INF/LICENSE|NOTICE upstream Apache-2.0 files
  R.txt                   empty (no resources)
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


def merge_jars(jar_dir: pathlib.Path) -> bytes:
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
    classes = sum(1 for k in seen if k.endswith(".class"))
    print(f"classes.jar: {classes} classes, {len(seen)} entries")
    return out.getvalue()


def _fixed(name: str) -> zipfile.ZipInfo:
    # Fixed timestamp so two builds of the same inputs produce byte-identical archives.
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, type=pathlib.Path, help="build.sh OUT_DIR")
    ap.add_argument("--output", required=True, type=pathlib.Path, help="path of the .aar to write")
    ap.add_argument("--abi", default="arm64-v8a")
    args = ap.parse_args()

    jni_dir = args.input / "jni" / args.abi
    sos = sorted(jni_dir.glob("*.so"))
    if not sos:
        sys.exit(f"no .so under {jni_dir}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.output, "w", zipfile.ZIP_DEFLATED) as aar:
        aar.writestr(_fixed("AndroidManifest.xml"), MANIFEST)
        aar.writestr(_fixed("classes.jar"), merge_jars(args.input / "jars"))
        aar.writestr(_fixed("R.txt"), "")
        for so in sos:
            aar.writestr(_fixed(f"jni/{args.abi}/{so.name}"), so.read_bytes())
            print(f"jni/{args.abi}/{so.name}: {so.stat().st_size} bytes")
        for lic in ("LICENSE", "NOTICE"):
            p = args.input / lic
            if p.is_file():
                aar.writestr(_fixed(f"META-INF/{lic}"), p.read_bytes())
    print(f"wrote {args.output} ({args.output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
