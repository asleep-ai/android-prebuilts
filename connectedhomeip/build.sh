#!/usr/bin/env bash
# Build the connectedhomeip Android controller library exactly the way upstream CI does.
#
# Runs inside the upstream Docker image (see UPSTREAM: build_image), which provides
# ANDROID_HOME, ANDROID_NDK_HOME, JAVA_HOME (17), kotlinc and the pigweed bootstrap deps.
#
# Inputs (env):
#   SRC_DIR   where to clone upstream        (default: <this dir>/upstream)
#   OUT_DIR   where to stage the outputs     (default: <this dir>/out)
# Outputs in OUT_DIR:
#   jars/*.jar             the 8 jars upstream stages for CHIPTool (copyToSrcAndroid)
#   jni/arm64-v8a/*.so     libCHIPController.so, libc++_shared.so (stripped, release)
#   LICENSE, NOTICE        upstream license files
#   build-info.env         commit, build seconds, .so sizes (consumed by the workflow summary)
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=UPSTREAM
source "$PKG_DIR/UPSTREAM"

SRC_DIR="${SRC_DIR:-$PKG_DIR/upstream}"
OUT_DIR="${OUT_DIR:-$PKG_DIR/out}"
TARGET="android-arm64-chip-tool"
ABI="arm64-v8a"

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

echo "==> build $TARGET (release)"
start="$(date +%s)"
./scripts/run_in_build_env.sh \
    "./scripts/build/build_examples.py --target $TARGET --build-profile release build"
end="$(date +%s)"
build_seconds=$((end - start))
echo "==> build took ${build_seconds}s"

build_out="out/$TARGET"
[ -d "$build_out/lib" ] || { echo "!! $build_out/lib missing" >&2; exit 1; }

echo "==> staging into $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/jars" "$OUT_DIR/jni/$ABI"
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
for so in libCHIPController.so libc++_shared.so; do
    cp -v "$build_out/lib/jni/$ABI/$so" "$OUT_DIR/jni/$ABI/"
done
cp LICENSE NOTICE "$OUT_DIR/"

{
    echo "upstream_tag=$upstream_tag"
    echo "upstream_commit=$upstream_commit"
    echo "build_image=$build_image"
    echo "build_seconds=$build_seconds"
    for so in "$OUT_DIR/jni/$ABI"/*.so; do
        echo "size_$(basename "$so" .so | tr -c 'A-Za-z0-9_\n' '_')=$(stat -c %s "$so")"
    done
} > "$OUT_DIR/build-info.env"
cat "$OUT_DIR/build-info.env"
