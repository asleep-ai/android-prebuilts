#!/usr/bin/env bash
# Build the connectedhomeip Android controller library with upstream's own toolchain and GN setup.
#
# Runs inside the upstream Docker image (see UPSTREAM: build_image), which provides
# ANDROID_HOME, ANDROID_NDK_HOME, JAVA_HOME (17), kotlinc and the pigweed bootstrap deps.
#
# Inputs (env):
#   SRC_DIR   where to clone upstream        (default: <this dir>/upstream)
#   OUT_DIR   where to stage the outputs     (default: <this dir>/out)
#   ABIS      space-separated Android ABIs   (default: "arm64-v8a x86_64")
# Outputs in OUT_DIR:
#   jars/*.jar             the 8 jars upstream stages for CHIPTool (copyToSrcAndroid), from the first ABI
#   jni/<abi>/*.so         libCHIPController.so, libc++_shared.so per ABI (stripped, release)
#   sources/               Java/Kotlin sources of those jars (hand-written + build-generated)
#   paa/*.der              upstream credentials/production/paa-root-certs (production PAA roots)
#   LICENSE, NOTICE        upstream license files
#   build-info.env         commit, build seconds, .so sizes (consumed by the workflow summary)
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=UPSTREAM
source "$PKG_DIR/UPSTREAM"

SRC_DIR="${SRC_DIR:-$PKG_DIR/upstream}"
OUT_DIR="${OUT_DIR:-$PKG_DIR/out}"
ABIS="${ABIS:-arm64-v8a x86_64}"

# Upstream target name per ABI (scripts/build/builders/android.py AndroidBoard).
target_for_abi() {
    case "$1" in
        arm64-v8a) echo "android-arm64-chip-tool" ;;
        x86_64) echo "android-x64-chip-tool" ;;
        armeabi-v7a) echo "android-arm-chip-tool" ;;
        x86) echo "android-x86-chip-tool" ;;
        *) echo "!! unknown ABI $1" >&2; return 1 ;;
    esac
}

echo "==> upstream $upstream_repo @ $upstream_tag ($upstream_commit)"
git config --global --add safe.directory '*'

if [ ! -d "$SRC_DIR/.git" ]; then
    git clone --depth 1 --branch "$upstream_tag" "$upstream_repo" "$SRC_DIR"
fi
cd "$SRC_DIR"
head="$(git rev-parse HEAD)"
if [ "$head" != "$upstream_commit" ]; then
    echo "!! tag $upstream_tag resolved to $head, expected $upstream_commit (UPSTREAM pin is stale or the tag moved)" >&2
    exit 1
fi

shopt -s nullglob
for p in "$PKG_DIR"/patches/*.patch; do
    echo "==> applying $(basename "$p")"
    git apply --verbose "$p"
done
shopt -u nullglob

# Same steps as upstream .github/actions/checkout-submodules and .github/actions/bootstrap,
# minus their buildjet cache (not available here) and the TSAN sysctl step (not needed).
echo "==> submodules"
scripts/checkout_submodules.py --allow-changing-global-git-config --shallow --platform android

echo "==> bootstrap"
PW_NO_CIPD_CACHE_DIR=1 PW_ENVSETUP_NO_BANNER=1 bash -c 'source scripts/bootstrap.sh -p all,android'

# Upstream smoketest-android.yaml: the pigweed ARM cross toolchain is unused (NDK compilers
# are used) and android CI otherwise runs out of disk.
rm -rf .environment/cipd/packages/arm || true

# Upstream CI runs `build_examples.py --target <target> build`, which (a) ninja-builds the whole GN
# `default` group -- on Android that includes every unit-test object because chip_build_tests
# defaults to true -- and (b) then compiles the CHIPTool demo APK with Gradle. We only need the
# controller library, so run upstream's `gen` step (identical gn args) and then ninja just the
# library targets. Same inputs, same compiler flags, a fraction of the work.
#
# Labels mirror what copyToSrcAndroid() in scripts/build/builders/android.py stages for CHIPTool.
# src/controller/java:java data_deps build/chip/java:shared_cpplib, which copies libc++_shared.so.
ninja_targets=(
    src/controller/java:jni
    src/controller/java:java
    src/controller/java:android_chip_im
    src/controller/java:chipclusterID
    src/controller/java:chipcluster
    src/controller/java:onboarding_payload
    src/controller/java:tlv
    src/controller/java:jsontlv
    src/platform/android:java
)

# build_abi <abi>: gen + ninja + strip; sets $build_out to the GN out dir.
build_abi() {
    local abi="$1" target
    target="$(target_for_abi "$abi")"

    # gen also runs third_party/android_deps/gradlew (downloads a Gradle distribution and
    # androidx.annotation) and third_party/java_deps/set_up_java_deps.sh (curl from Maven Central);
    # both have failed transiently on hosted runners (connection reset, HTTP 429), so retry with backoff.
    echo "==> gn gen $target (release)"
    local attempt
    for attempt in 1 2 3; do
        if ./scripts/run_in_build_env.sh \
            "./scripts/build/build_examples.py --target $target --build-profile release gen"; then
            break
        fi
        [ "$attempt" -lt 3 ] || { echo "!! gn gen failed after $attempt attempts" >&2; return 1; }
        echo "==> gn gen attempt $attempt failed, retrying in $((attempt * 60))s"
        sleep $((attempt * 60))
    done

    # build_examples.py names the GN out dir after the target plus the build profile
    # (out/android-arm64-chip-tool-release); locate it rather than hardcode the suffix.
    build_out=""
    local candidate
    for candidate in out/"${target}"*/; do
        [ -f "$candidate/build.ninja" ] && { build_out="${candidate%/}"; break; }
    done
    [ -n "$build_out" ] || { echo "!! no GN out dir under out/ for $target" >&2; ls out || true; return 1; }
    echo "==> GN out dir: $build_out"

    echo "==> ninja ${ninja_targets[*]}"
    ./scripts/run_in_build_env.sh "ninja -C $build_out ${ninja_targets[*]}"

    # build_examples.py strips the release .so after its Gradle step; do the same here.
    local strip="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
    local so
    for so in "$build_out/lib/jni/$abi"/*.so; do
        "$strip" -s "$so"
    done
}

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/jars"
start="$(date +%s)"
first_abi=""
for ABI in $ABIS; do
    build_abi "$ABI"
    mkdir -p "$OUT_DIR/jni/$ABI"
    for so in libCHIPController.so libc++_shared.so; do
        cp -v "$build_out/lib/jni/$ABI/$so" "$OUT_DIR/jni/$ABI/"
    done
    [ -n "$first_abi" ] && continue
    first_abi="$ABI"
    echo "==> staging jars from $build_out"
    # Jar list mirrors scripts/build/builders/android.py copyToSrcAndroid() at this tag.
    for jar in \
        src/controller/java/CHIPController.jar \
        src/controller/java/CHIPInteractionModel.jar \
        src/controller/java/OnboardingPayload.jar \
        src/platform/android/AndroidPlatform.jar \
        src/controller/java/libMatterJson.jar \
        src/controller/java/libMatterTlv.jar \
        src/controller/java/CHIPClusters.jar \
        src/controller/java/CHIPClusterID.jar; do
        cp -v "$build_out/lib/$jar" "$OUT_DIR/jars/"
    done

    # Sources for the -sources.jar: hand-written trees plus whatever the build generated
    # (ZAP cluster wrappers land under the GN out dir). assemble_aar.py re-roots every file
    # at its first chip/ or matter/ path segment, so directory shapes here do not matter.
    echo "==> staging sources"
    mkdir -p "$OUT_DIR/sources"
    for root in src/controller/java/src src/controller/java/generated/java src/platform/android/java; do
        [ -d "$root" ] && cp -r "$root" "$OUT_DIR/sources/$(echo "$root" | tr / _)"
    done
    if [ -d "$build_out/gen" ]; then
        (cd "$build_out/gen" && find . \( -name '*.java' -o -name '*.kt' \) -print0 \
            | tar --null -T - -cf - ) | tar -xf - -C "$OUT_DIR/sources" 2>/dev/null || true
    fi
done
end="$(date +%s)"
build_seconds=$((end - start))
echo "==> build ($ABIS) took ${build_seconds}s"
cp LICENSE NOTICE "$OUT_DIR/"

# Production PAA root certificates (DCL mirror) from the same upstream tag; the AAR ships them
# under assets/matter/paa/ for the consumer's AttestationTrustStoreDelegate.
mkdir -p "$OUT_DIR/paa"
cp credentials/production/paa-root-certs/*.der "$OUT_DIR/paa/"
paa_count="$(find "$OUT_DIR/paa" -name '*.der' | wc -l)"
echo "==> staged $paa_count PAA root certs"

{
    echo "upstream_tag=$upstream_tag"
    echo "upstream_commit=$upstream_commit"
    echo "build_image=$build_image"
    echo "build_seconds=$build_seconds"
    echo "abis=$ABIS"
    echo "paa_count=$paa_count"
    for so in "$OUT_DIR"/jni/*/*.so; do
        abi="$(basename "$(dirname "$so")" | tr -c 'A-Za-z0-9_\n' '_')"
        echo "size_${abi}_$(basename "$so" .so | tr -c 'A-Za-z0-9_\n' '_')=$(stat -c %s "$so")"
    done
} > "$OUT_DIR/build-info.env"
cat "$OUT_DIR/build-info.env"
