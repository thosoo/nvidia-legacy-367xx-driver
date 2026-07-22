# Controlled core workqueue runtime validation

Do not run this procedure on a developer workstation without planning for GPU
unbind/rebind, display disruption, and recovery. The companion script
`tools/collect-workqueue-runtime.sh` refuses to run unless
`--acknowledge-module-load-risk` is supplied.

Expected controlled K620 validation goals:

1. record kernel release, command line, loaded NVIDIA/nouveau modules, and PCI
   binding before the test;
2. mark `dmesg`, run the limited NVIDIA userspace close path such as
   `nvidia-smi`, and collect warnings;
3. confirm the idle `nvidia-wq` task state after a configurable delay;
4. check for system-wide workqueue flush warnings, bad-frame-pointer/unwind
   warnings, Xid messages, and adapter initialization failures;
5. unload cleanly only in the controlled environment and verify restoration to
   `nouveau`.

The script intentionally does not edit display-manager state, initramfs,
bootloader configuration, Secure Boot policy, module blacklists, or package
installation state.
