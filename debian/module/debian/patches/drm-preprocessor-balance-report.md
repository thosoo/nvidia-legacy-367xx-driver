# DRM output-poll conditional balance audit

## Target patch

- Changed patch: `0047-backport-drm_output_poll_changed-changes-from-535.21.patch`.
- Exact predecessor: `0046-backport-nv_get_kern_phys_address-changes-from-555.4.patch`.
- Exact successor: `0048-backport-cmd_symlink-changes-from-550.142.patch`.
- Files owned by the refreshed target patch: `conftest.sh`, `nvidia-drm/nvidia-drm-drv.c`, and `nvidia-drm/nvidia-drm.Kbuild`.
- Unmatched directive fixed: `#if defined(NV_DRM_OUTPUT_POLL_CHANGED_PRESENT)` immediately before `nvidia_drm_output_poll_changed()`.
- Corrective source location: `#endif /* NV_DRM_OUTPUT_POLL_CHANGED_PRESENT */` immediately after `nvidia_drm_output_poll_changed()` and before `nv_mode_config_funcs`.

## Downstream patch audit

Active successors after `0047` were pushed through the end of the generated UVM-enabled series. The downstream patches touching DRM guard-adjacent files were:

- `0055-backport-file_operations_fop_unsigned_offset_present.patch`: touches `conftest.sh`, `nvidia-drm/nvidia-drm-drv.c`, and `nvidia-drm/nvidia-drm.Kbuild`; retained the guarded `.fop_flags = FOP_UNSIGNED_OFFSET` initializer and did not alter the output-poll callback guard.
- `0064-backport-drm_driver_has_date-from-570.124.04.patch`: touches `conftest.sh`, `nvidia-drm/nvidia-drm-drv.c`, and `nvidia-drm/nvidia-drm.Kbuild`; retained the guarded `.date = "20160202"` initializer and did not alter the output-poll callback guard.
- `0067-backport-drm_connector_helper_funcs_mode_valid_has_c.patch`, `backport-timekeeping-scheduler-mmap-lock-api.patch`, and the build-system patches touch `conftest.sh` or Kbuild context only; none reintroduced a DRM preprocessor imbalance.

## Validation summary

- `0047` applied, reversed, and reapplied at the exact `0046` predecessor with `patch -p1 --fuzz=0`.
- Quilt target `pop`/`push --fuzz=0` succeeded.
- All active successors were pushed individually, with explicit cumulative checks after `0055`, after `0064`, and after the complete active series.
- Final `nvidia-drm/nvidia-drm-drv.c` has a balanced preprocessor stack, the output-poll callback guard closes before `nv_mode_config_funcs`, and the initializer keeps its separate balanced guard.
- Final `conftest.sh` passes `sh -n`, and the DRM conftest cases and Kbuild registrations are unique.
