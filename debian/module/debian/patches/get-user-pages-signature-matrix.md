# NVIDIA 367.134 get_user_pages compatibility matrix

This fork consolidates the inherited 418.30, 520.56.06, 525.53, and 535.86.05
GUP patches into `0026-backport-get_user_pages-changes-from-418.30.patch`.
The 367.134 source only calls `NV_GET_USER_PAGES()` directly; the remote
wrapper is retained because it is part of the inherited `nv-mm.h` compatibility
surface and some kernels still expose only remote-style pinning APIs.

| Function | Argument list | Kernel transition | Conftest macro | Wrapper branch | Affected 367.134 call sites | Bookworm 6.1 | Trixie 6.12 |
|---|---|---|---|---|---|---|---|
| `get_user_pages` | `start, nr_pages, write, force, pages, vmas` | pre-gup_flags | `NV_GET_USER_PAGES_HAS_ARGS_WRITE_FORCE_VMAS` | converts flags back to write/force | core/DRM/UVM through `NV_GET_USER_PAGES` | no | no |
| `get_user_pages` | `tsk, mm, start, nr_pages, write, force, pages, vmas` | legacy task/mm form | `NV_GET_USER_PAGES_HAS_ARGS_TSK_WRITE_FORCE_VMAS` | uses `current/current->mm` | core/DRM/UVM through `NV_GET_USER_PAGES` | no | no |
| `get_user_pages` | `tsk, mm, start, nr_pages, flags, pages, vmas` | gup_flags before task/mm removal | `NV_GET_USER_PAGES_HAS_ARGS_TSK_FLAGS_VMAS` | uses `current/current->mm` | core/DRM/UVM through `NV_GET_USER_PAGES` | no | no |
| `get_user_pages` | `start, nr_pages, flags, pages, vmas` | gup_flags after task/mm removal | `NV_GET_USER_PAGES_HAS_ARGS_FLAGS_VMAS` | direct macro | core/DRM/UVM through `NV_GET_USER_PAGES` | no | no |
| `get_user_pages` | `start, nr_pages, flags, pages` | vmas removed by `7bbf9c8c99` | `NV_GET_USER_PAGES_HAS_ARGS_FLAGS` | drops wrapper `vmas` argument | core/DRM/UVM through `NV_GET_USER_PAGES` | yes | yes |
| `get_user_pages_remote` | `tsk, mm, start, nr_pages, write, force, pages, vmas` | initial remote API | `NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_WRITE_FORCE_VMAS` | converts flags back to write/force | retained wrapper surface | no | no |
| `get_user_pages_remote` | `tsk, mm, start, nr_pages, flags, pages, vmas` | gup_flags remote API | `NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS_VMAS` | passes `NULL` task and explicit `mm` | retained wrapper surface | no | no |
| `get_user_pages_remote` | `tsk, mm, start, nr_pages, flags, pages, vmas, locked` | locked argument added | `NV_GET_USER_PAGES_REMOTE_HAS_ARGS_TSK_FLAGS_LOCKED_VMAS` | passes `NULL` task, explicit `mm`, and `locked` | retained wrapper surface | no | no |
| `get_user_pages_remote` | `mm, start, nr_pages, flags, pages, vmas, locked` | task_struct removed by `64019a2e467a` | `NV_GET_USER_PAGES_REMOTE_HAS_ARGS_FLAGS_LOCKED_VMAS` | direct macro | retained wrapper surface | yes | no |
| `get_user_pages_remote` | `mm, start, nr_pages, flags, pages, locked` | vmas removed by `a4bde14d549` | `NV_GET_USER_PAGES_REMOTE_HAS_ARGS_FLAGS_LOCKED` | drops wrapper `vmas` argument | retained wrapper surface | no | yes |

## Semantics audit

* `task_struct`: only legacy remote signatures require it. The wrapper passes
  `NULL` for those signatures, matching the inherited NVIDIA compatibility path;
  modern Bookworm/Trixie signatures do not accept a task argument.
* `mm`: remote wrappers keep the caller-supplied `mm` explicit. Local wrappers
  continue to use the current task's address space where older signatures need
  `current/current->mm`.
* `locked`: forwarded only to signatures that accept it. Callers may pass `NULL`
  when they do not need the mmap lock dropped by GUP.
* `vmas`: preserved in wrapper signatures for 367.134 call sites and dropped only
  in branches whose conftest proves that the kernel no longer accepts it.
* `write/force`: 367.134 call sites now pass `FOLL_WRITE` where the previous code
  passed `write=1, force=0`; no call site gains `FOLL_FORCE`.
