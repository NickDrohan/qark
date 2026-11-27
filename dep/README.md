# dep/std - vendored Mach 7 port of std 9.5.0

These are plain files, not a submodule.

- **Origin:** upstream https://github.com/briar-systems/mach-std at tag v9.5.0 (MIT, see std/LICENSE, Copyright Briar Systems LLC), plus five local commits that port it to Mach 7:
  1. `mach migrate` of std 9.5.0 plus the manifest link-table key fix (12f6db4)
  2. cast u1 comparison results where 9.5 expected u8 (8a33593)
  3. #[library] names link-table keys, not DLL names, at 153 sites (d389903)
  4. RIP-relative argc/argv_ptrs in the windows x86_64 entry asm (05052dd)
  5. windows link tables use `include = "referenced"` (3a499a2)
- **Why vendored:** briar-systems/mach-std is read-only for us and published 9.x does not build on Mach 7, so the port commit 3a499a2 existed only on one machine and CI could not fetch it. Snapshot taken from that commit; its history is not preserved here.
- **Replacing it:** when Qark moves to upstream std 10.x (Mach 7 native), delete this directory and let `[dep.std]` in mach.toml resolve upstream.