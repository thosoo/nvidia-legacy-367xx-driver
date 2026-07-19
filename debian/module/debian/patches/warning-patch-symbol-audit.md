# Warning patch symbol audit for NVIDIA 367.134

This audit records the static decisions for the warning/UVM block around
patches `0049` through `0057`. It is intentionally conservative: warning-only
or UVM semantic changes are not activated unless the target file and symbol are
present in 367.134 and the change can be justified without changing ownership,
locking, page lifetime, or cross-translation-unit linkage.

## Decisions

- The 396.18 Volta access-counter patch is inactive because NVIDIA 367.134 does
  not contain `nvidia-uvm/uvm8_volta_access_counter_buffer.c`.
- The 415.13 UVM warning patch remains active and applies strictly.
- The 418.30 UVM batch is inactive: it mixes present-file removals with absent
  Volta sources. Function removal requires a complete UVM caller/declaration
  audit before activation.
- The 430.09 warning patch is inactive because 367.134 lacks
  `nvidia/nv-kthread-q.c`.
- The 435.17, 510.39.01, 0050, 0052, 0054, and 0057 UVM batches remain inactive
  until compiler evidence or authoritative source comparison proves the specific
  hunk is required and safe.
- Patch 0051 was split: present local static conversions are retained, while
  absent later-driver and non-amd64-only hunks are omitted.
- Patch 0053 was split: present warning cleanups are retained, while the
  `nvidia/nv-gpu-numa.c` dir-context callback hunk is omitted because the file
  is absent in 367.134.

See `warning-patch-symbol-audit.tsv` for the per-symbol table.
