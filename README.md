# android-prebuilts

Build recipes for third-party Android libraries that asleep-ai has to compile
itself, published as Maven artifacts on GitHub Packages
(`https://maven.pkg.github.com/asleep-ai/android-prebuilts`).

Nothing built lives in git. Each package folder pins an upstream tag, holds the
build script and optional patches, and has a workflow that builds once per tag
on a clean GitHub-hosted runner and publishes the result. The recipes here are
Apache-2.0; each artifact keeps the license of its upstream project.

## Packages

| Folder | Artifact | Upstream | Contents |
|---|---|---|---|
| [`connectedhomeip/`](connectedhomeip/) | `ai.asleep:matter-controller-android` | [project-chip/connectedhomeip](https://github.com/project-chip/connectedhomeip) (CSA Matter SDK) | Android Matter controller AAR, arm64-v8a |

## Layout convention

```
<package>/
  UPSTREAM         upstream_repo / upstream_tag / upstream_commit / build_image (shell key=value)
  build.sh         reproduces upstream's own build steps, stages outputs into out/
  patches/         NNNN-*.patch applied after clone (README explains when they are empty)
  assemble_*.py    turns staged outputs into the publishable artifact (optional)
  publish/         small Gradle project: maven-publish of the artifact + POM, no AGP
.github/workflows/<package>.yml   tag-triggered build + publish
```

## Tag convention

`<package>-v<upstream version>-<build>`, published as `<upstream version>-<build>`.

| Tag | Published version |
|---|---|
| `connectedhomeip-v1.6.0.0-1` | `ai.asleep:matter-controller-android:1.6.0.0-1` |

The trailing `-<build>` is our build number: bump it when the recipe changes for
the same upstream tag (patch, packaging fix). Bump the upstream part only
together with `UPSTREAM`; the workflow refuses a tag whose upstream version
does not match the pinned `upstream_tag`. Workflows run only on such tags (or a
manual `workflow_dispatch` naming an existing tag), never on pushes to `main`.

## Consuming

Same setup as [asleep-ai/hue-ble-android](https://github.com/asleep-ai/hue-ble-android/blob/main/docs/publishing.md):
`gpr.user` / `gpr.token` (PAT with `read:packages`) in `~/.gradle/gradle.properties`,
or `GITHUB_ACTOR` / `GITHUB_TOKEN` in CI.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        maven {
            name = "AsleepPrebuilts"
            url = uri("https://maven.pkg.github.com/asleep-ai/android-prebuilts")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull ?: System.getenv("GITHUB_ACTOR") ?: ""
                password = providers.gradleProperty("gpr.token").orNull ?: System.getenv("GITHUB_TOKEN") ?: ""
            }
        }
    }
}

// build.gradle.kts
dependencies {
    implementation("ai.asleep:matter-controller-android:1.6.0.0-1")
}
```

## Adding a package

1. Create `<package>/UPSTREAM` with the repo, tag, commit and the exact build
   image or toolchain upstream's own CI uses at that tag (read their workflow;
   do not guess).
2. Write `build.sh` that follows upstream's documented build steps and stages
   outputs into `out/`. Verify the checked-out commit against the pin.
3. Add `publish/` (copy `connectedhomeip/publish`, change the coordinates and
   POM) and, if upstream ships no Maven-ready artifact, an assembler script.
4. Add `.github/workflows/<package>.yml` triggered by `<package>-v*` tags plus
   `workflow_dispatch`. Record build time and artifact sizes in the run summary.
5. Push the tag, wait for green, resolve the artifact from a throwaway project
   and record consumer notes in this README.

## Cutting a release

```bash
git tag connectedhomeip-v1.6.0.0-1
git push origin connectedhomeip-v1.6.0.0-1
```

---

## connectedhomeip

Android controller library of the Matter SDK, built from
`project-chip/connectedhomeip` at the tag pinned in
[`connectedhomeip/UPSTREAM`](connectedhomeip/UPSTREAM), inside the Docker
image upstream CI used at that tag. `build.sh` runs upstream's own submodule
checkout and bootstrap, then upstream's
`scripts/build/build_examples.py --target android-arm64-chip-tool --build-profile release gen`
for the GN configuration (identical args to upstream's
`.github/workflows/smoketest-android.yaml`), and then ninja-builds only the
controller library targets. Upstream's `build` step would instead build the
whole GN `default` group (on Android that includes every unit-test object,
because `chip_build_tests` defaults to true) and then the CHIPTool demo APK;
neither is part of the artifact. arm64-v8a only. No caching between runs;
one clean build per tag.

Upstream ships no AAR at this tag (`examples/android/CHIPTool/chip-library` is
not part of the scripted build), so `assemble_aar.py` packs one from the eight
jars and two shared objects that upstream's `copyToSrcAndroid()` stages for the
CHIPTool app:

| AAR entry | Source |
|---|---|
| `classes.jar` | `CHIPController.jar`, `CHIPInteractionModel.jar`, `CHIPClusters.jar`, `CHIPClusterID.jar`, `AndroidPlatform.jar`, `OnboardingPayload.jar`, `libMatterTlv.jar`, `libMatterJson.jar` merged |
| `jni/arm64-v8a/libCHIPController.so` | controller JNI, stripped (release profile) |
| `jni/arm64-v8a/libc++_shared.so` | NDK r28c libc++ runtime |
| `META-INF/LICENSE`, `META-INF/NOTICE` | upstream Apache-2.0 files |

POM dependencies (`compile`): `androidx.annotation:annotation:1.1.0` (upstream's
only Android dependency) and `org.jetbrains.kotlin:kotlin-stdlib:2.1.10` (the
Kotlin jars are compiled with the image's kotlinc 2.1.10).

### Consumer notes (1.6.0.0-1 vs `com.google.matter:matter-android-demo-sdk:1.0`)

Verified 2026-09-18 by resolving `ai.asleep:matter-controller-android:1.6.0.0-1`
from a throwaway AGP 8.11 library project and diffing `javap -public` output
against the demo AAR. Build: ninja 6 min, whole build job 11 min on
`ubuntu-latest`; `libCHIPController.so` 4.67 MB stripped (demo: 26.5 MB),
`libc++_shared.so` 1.25 MB, AAR 10.9 MB, 9298 classes.

Packaging differences:

- **arm64-v8a only.** The demo carried armeabi-v7a, x86 and x86_64 too. An
  x86_64 emulator cannot load this artifact; add `abiFilters` or an ABI split so
  the app does not silently ship without the native library.
- **One `classes.jar`** instead of three jars under `libs/`; no code change needed.
- **`chip.setuppayload.*` is gone.** Upstream replaced it with the Kotlin package
  `matter.onboardingpayload.*` (`OnboardingPayloadParser.parseQrCode`,
  `parseManualPairingCode`, `getQrCodeFromPayload`,
  `getManualPairingCodeFromPayload`; exceptions `OnboardingPayloadException`,
  `UnrecognizedQrCodeException`, `InvalidManualPairingCodeFormatException`).
  `libSetupPayloadParser.so` no longer exists; the JNI moved into
  `libCHIPController.so`.
- **`minSdk 24`** (demo: 27). `kotlin-stdlib` 2.1.10 and
  `androidx.annotation` 1.1.0 come in as POM dependencies.

API differences the consumer will hit:

| Area | Demo AAR | This artifact |
|---|---|---|
| `AndroidChipPlatform` constructor | 7 args (`BleManager, KeyValueStoreManager, ConfigurationManager, ServiceResolver, ServiceBrowser, ChipMdnsCallback, DiagnosticDataProvider`) | 8 args: a `NfcCommissioningManager` is inserted as the **second** argument (`AndroidNfcCommissioningManager()` is the stock implementation) |
| `AndroidBleManager` | `()` only | `(Context)` and `()` |
| `BleManager.onNewConnection` | `(int)` | `(int connId, boolean isLongDiscriminator, long discriminator, long setupPin)`; custom `BleManager` implementations must update the override |
| `ChipDeviceController.pairDeviceWithCode` | absent | present: `(long deviceId, String setupCode, boolean discoverOnce, boolean useOnlyOnNetworkDiscovery, byte[] csrNonce, NetworkCredentials)`, plus `ICDRegistrationInfo` and `CommissionParameters` overloads |
| `pairDevice(BluetoothGatt, ...)` / `pairDeviceWithAddress` | present | same signatures kept, plus `ICDRegistrationInfo` / `CommissionParameters` overloads and `pairDeviceThroughBLE`, `pairDeviceThroughNfc` |
| `ControllerParams.Builder.setSkipAttestationCertificateValidation(boolean)` | absent | present (also `setEnableServerInteractions`) |
| `readAttributePath` / `readEventPath` / `readPath` | `(callback, deviceId, paths[, ...])` | every overload gained a trailing `int imTimeoutMs`; `readPath` also has a `DataVersionFilter` variant |
| `subscribeToAttributePath` / `subscribeToEventPath` / `subscribeToPath` | `(..., minInterval, maxInterval[, ...])` | trailing `int imTimeoutMs` added; `subscribeToEventPath` / `subscribeToPath` also take an optional `Long eventMin` |
| `write` / `invoke` | present | present, same shape (`WriteAttributesCallback` / `InvokeCallback`, timed and IM timeouts) |
| `openPairingWindowWithPIN[Callback]` | present | removed; use `openPairingWindowWithPINCallback` replacements on the commissioning window opener (`AndroidCommissioningWindowOpener` JNI) or the `AdministratorCommissioning` cluster |
| `onNOCChainGeneration`, `extractSkidFromPaaCert` | public | no longer public on the controller |
| Callback shims `onPairingComplete`, `onPairingDeleted`, `onCommissioningComplete`, `onCommissioningStatusUpdate`, `onScanNetworks*` | public methods on the controller | no longer public; only `CompletionListener` receives them |

Everything else in `ChipDeviceController` (`setCompletionListener`,
`establishPaseConnection`, `unpairDevice`, `getConnectedDevicePointer`,
`NetworkCredentials.forWiFi`/`forThread`) is signature-identical.

Licensing: the AAR carries upstream's `LICENSE` and `NOTICE` under `META-INF/`
(Apache-2.0). `libc++_shared.so` is the NDK's LLVM libc++ (Apache-2.0 with LLVM
exception). "Matter" and "CHIP" are Connectivity Standards Alliance trademarks;
the artifact name is descriptive, and nothing here claims certification.
