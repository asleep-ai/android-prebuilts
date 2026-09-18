# patches/

Local patches on top of the pinned upstream tree, applied by `build.sh` in
lexical order right after the fetch and before submodules are checked out
(so a patch may also touch `.gitmodules`). Each one is `git format-patch`
output against the pinned upstream commit. `build.sh` runs `git apply --check`
first and fails the build if a patch no longer applies; the applied list is
written to `build-info.env` (`patches=`) and shown in the run summary and the
GitHub Release notes.

| Patch | What | Why | Drop when |
|---|---|---|---|
| `0001-android-ble-scan-timeout.patch` | `src/platform/android/java/chip/platform/AndroidBleManager.java` line 95: `BLE_TIMEOUT_MS` 10000 -> 60000. The constant arms `MSG_BLE_FAIL` when `onNewConnection()` starts the BLE scan (line 471) and is re-armed on every `connectBLE()` attempt (line 577); the retry logic is untouched. | On our hub, a commissionee's first advertisement showed up after ~29 s, so `pairDeviceWithCode()` timed out at 10 s. | Upstream makes the timeout configurable (or raises it), or the app stops commissioning over BLE. |

## Adding or rebasing a patch

```bash
git clone --depth 1 --branch <upstream_tag> --filter=blob:none --sparse \
    https://github.com/project-chip/connectedhomeip.git /tmp/chip
cd /tmp/chip && git sparse-checkout set <dir of the file>
# edit, then
git commit -am "<subject>" && git format-patch -1 --stdout > NNNN-short-description.patch
```

Number patches sequentially, describe what and why in the commit message,
add a row to the table above and a line in the root README, and bump the
build number (`connectedhomeip-v<tag>-<build+1>`) when publishing.
