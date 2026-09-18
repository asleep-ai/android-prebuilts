# patches/

Empty on purpose. connectedhomeip v1.6.0.0 builds unmodified.

If a future pin needs a fix, drop `NNNN-short-description.patch` files here
(`git format-patch` output against the pinned upstream commit). `build.sh`
applies them in lexical order with `git apply` right after the clone, before
submodules are checked out, so a patch may also touch `.gitmodules`.
