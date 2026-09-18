#!/usr/bin/env bash
# Build the connectedhomeip Android controller library with upstream's own toolchain and GN setup.
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

# Upstream CI runs `build_examples.py --target $TARGET build`, which (a) ninja-builds the whole GN
# `default` group -- on Android that includes every unit-test object because chip_build_tests
# defaults to true -- and (b) then compiles the CHIPTool demo APK with Gradle. We only need the
# controller library, so run upstream's `gen` step (identical gn args) and then ninja just the
# library targets. Same inputs, same compiler flags, a fraction of the work.
# gen also runs third_party/android_deps/gradlew (downloads a Gradle distribution and
# androidx.annotation) and third_party/java_deps/set_up_java_deps.sh (curl from Maven Central);
# both have failed transiently on hosted runners (connection reset, HTTP 429), so retry with backoff.
echo "==> gn gen $TARGET (release)"
for attempt in 1 2 3; do
    if ./scripts/run_in_build_env.sh \
        "./scripts/build/build_examples.py --target $TARGET --build-profile release gen"; then
        break
    fi
    [ "$attempt" -lt 3 ] || { echo "!! gn gen failed after $attempt attempts" >&2; exit 1; }
    echo "==> gn gen attempt $attempt failed, retrying in $((attempt * 60))s"
    sleep $((attempt * 60))
done

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
echo "==> ninja ${ninja_targets[*]}"
start="$(date +%s)"
./scripts/run_in_build_env.sh "ninja -C out/$TARGET ${ninja_targets[*]}"
end="$(date +%s)"
build_seconds=$((end - start))
echo "==> ninja took ${build_seconds}s"

# build_examples.py strips the release .so after its Gradle step; do the same here.
strip="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip"
for so in "out/$TARGET/lib/jni/$ABI"/*.so; do
    "$strip" -s "$so"
done

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
