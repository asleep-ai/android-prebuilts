# patches/

Empty by policy. The prebuilt is an **unmodified build of the pinned upstream
tag**: same sources, same GN configuration and toolchain as upstream CI, with
only the unit tests and the demo APK left out. `build.sh` has no patch step.

Patching upstream here is a last resort, to be decided by the product owner,
not by whoever hits a limitation first. Prefer, in order: solving it in the
app on top of the public API, an upstream issue or PR, or moving the pin to a
tag that already contains the fix. If a patch is ever unavoidable, add the
apply step to `build.sh` together with the patch (`git format-patch` output
against the pinned commit, `git apply --check` before applying, build fails
on a non-clean apply, applied list in the run summary), document it in the
root README with what, why and the drop condition, and bump the build number.
