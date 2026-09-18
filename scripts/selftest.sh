#!/usr/bin/env bash
# Exercise the packaging path without a CHIP build: fabricate the inputs build.sh would stage,
# run assemble_aar.py, and publish the result to Maven Local. Used by the pr-check workflow and
# runnable locally (needs python3, JDK 17 and network for the Gradle wrapper).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/connectedhomeip"
WORK="${WORK:-$(mktemp -d)}"
OUT="$WORK/out"
mkdir -p "$OUT/jars" "$OUT/jni/arm64-v8a" "$OUT/jni/x86_64" "$OUT/sources/src_x/chip/devicecontroller" "$OUT/sources/gen/matter/tlv" "$OUT/paa"

# Eight tiny jars whose contents overlap on an identical entry (allowed) but not a conflicting one.
python3 - "$OUT" <<'PY'
import sys, zipfile, pathlib
out = pathlib.Path(sys.argv[1])
jars = ["CHIPController", "CHIPInteractionModel", "OnboardingPayload", "AndroidPlatform",
        "libMatterJson", "libMatterTlv", "CHIPClusters", "CHIPClusterID"]
for i, name in enumerate(jars):
    with zipfile.ZipFile(out / "jars" / f"{name}.jar", "w") as z:
        z.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
        z.writestr(f"chip/devicecontroller/Fake{i}.class", b"\xca\xfe\xba\xbe" + bytes([i]))
        z.writestr("chip/shared/Same.class", b"\xca\xfe\xba\xbe same")   # identical in every jar
    (out / "jni" / "arm64-v8a" / f"lib{name}.so").write_bytes(b"\x7fELF" + name.encode()) if i < 1 else None
(out / "jni" / "arm64-v8a" / "libCHIPController.so").write_bytes(b"\x7fELF arm64")
(out / "jni" / "arm64-v8a" / "libc++_shared.so").write_bytes(b"\x7fELF arm64 cxx")
(out / "jni" / "x86_64" / "libCHIPController.so").write_bytes(b"\x7fELF x86_64")
(out / "jni" / "x86_64" / "libc++_shared.so").write_bytes(b"\x7fELF x86_64 cxx")
(out / "sources/src_x/chip/devicecontroller/Fake0.java").write_text("package chip.devicecontroller; class Fake0 {}\n")
(out / "sources/gen/matter/tlv/Reader.kt").write_text("package matter.tlv\nclass Reader\n")
(out / "LICENSE").write_text("Apache-2.0 (fixture)\n")
for n in ("dcld_mirror_CN_Fixture_PAA_vid_0x0001.der", "dcld_mirror_CN_Fixture_PAA_vid_0x0002.der"):
    (out / "paa" / n).write_bytes(b"\x30\x82 fixture " + n.encode())
(out / "NOTICE").write_text("fixture\n")
PY
rm -f "$OUT/jni/arm64-v8a/libCHIPController.so.tmp"

python3 "$PKG/assemble_aar.py" --input "$OUT" \
    --output "$WORK/dist/x-0.0.0-selftest.aar" --sources-output "$WORK/dist/x-0.0.0-selftest-sources.jar" \
    --upstream-tag v0.0.0-selftest

echo "==> AAR entries"
python3 - "$WORK/dist/x-0.0.0-selftest.aar" "$WORK/dist/x-0.0.0-selftest-sources.jar" <<'PY'
import sys, zipfile
aar = sorted(zipfile.ZipFile(sys.argv[1]).namelist())
print("\n".join(aar))
need = {"AndroidManifest.xml", "classes.jar", "R.txt", "META-INF/LICENSE", "META-INF/NOTICE",
        "jni/arm64-v8a/libCHIPController.so", "jni/arm64-v8a/libc++_shared.so",
        "jni/x86_64/libCHIPController.so", "jni/x86_64/libc++_shared.so",
        "assets/matter/paa/README.md", "assets/matter/paa/dcld_mirror_CN_Fixture_PAA_vid_0x0001.der",
        "assets/matter/paa/dcld_mirror_CN_Fixture_PAA_vid_0x0002.der"}
missing = need - set(aar)
assert not missing, f"missing AAR entries: {missing}"
import io
classes = zipfile.ZipFile(io.BytesIO(zipfile.ZipFile(sys.argv[1]).read("classes.jar"))).namelist()
assert classes.count("chip/shared/Same.class") == 1, classes
assert sum(1 for c in classes if c.startswith("chip/devicecontroller/Fake")) == 8, classes
src = zipfile.ZipFile(sys.argv[2]).namelist()
assert "chip/devicecontroller/Fake0.java" in src and "matter/tlv/Reader.kt" in src, src
print("assemble_aar.py: OK")
PY

echo "==> publishToMavenLocal"
"$PKG/publish/gradlew" -q -p "$PKG/publish" publishToMavenLocal \
    -Pversion=0.0.0-selftest -Paar="$WORK/dist/x-0.0.0-selftest.aar" \
    -Psources="$WORK/dist/x-0.0.0-selftest-sources.jar" \
    -PupstreamTag=v0.0.0 -PupstreamCommit=0000000
m2="$HOME/.m2/repository/ai/asleep/matter-controller-android/0.0.0-selftest"
ls "$m2"
grep -q "<packaging>aar</packaging>" "$m2"/*.pom
grep -q "<artifactId>kotlin-stdlib</artifactId>" "$m2"/*.pom
[ -f "$m2/matter-controller-android-0.0.0-selftest-sources.jar" ]
rm -rf "$m2"
echo "selftest: OK ($WORK)"
