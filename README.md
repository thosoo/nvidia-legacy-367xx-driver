# nvidia-graphics-drivers-legacy-367xx

Debian packaging fork for NVIDIA proprietary driver 367.134 targeting NVIDIA GRID K1 (`10de:0ff2`, Kepler GK107, CUDA compute capability 3.0) and CUDA Toolkit 8.0.44. The package ships driver-side CUDA components from the NVIDIA 367.134 runfile (for example `libcuda.so.367.134`) but does not bundle the CUDA Toolkit.

## Status

This repository is an in-progress Debian baseline packaging fork converted to the distinct `legacy-367xx` namespace and amd64-only architecture scope. Proprietary NVIDIA runfiles and extracted binary payloads are intentionally not committed.

## Build prerequisites

Install `build-essential debhelper-compat devscripts dpkg-dev dh-dkms dkms quilt xz-utils linux-headers-amd64 sbuild schroot lintian autopkgtest curl ca-certificates`.

## Fetch/import upstream payload

Run `debian/scripts/fetch-367.134-runfile /path/to/import /path/to/output`. It downloads the exact 367.134 amd64 runfile into the import directory, verifies SHA-256 `c621c6068c1d09a88a4159963093fa1a28b45c7c989280c273c7d7a2b566c62f`, extracts non-interactively, stages `amd64/NVIDIA-Linux-x86_64-367.134.run`, and atomically creates `/path/to/output/nvidia-graphics-drivers-legacy-367xx_367.134.orig-amd64.tar.xz`. The convenience wrapper `tools/create-orig.sh /path/to/output` uses `/path/to/output/import` as scratch space and verifies the tarball layout.

## Build

After placing the orig tarball next to the source tree, run `make -f debian/rules debian/control` and `dpkg-buildpackage -us -uc -b`.

## DKMS and kernels

The DKMS source is installed under `/usr/src/nvidia-legacy-367xx-367.134/`. Debian `dh-dkms` handles add/build/install, depmod, initramfs integration, and automatic rebuilds when new kernels and matching headers are installed. Inspect failures with `dkms status` and `/var/lib/dkms/nvidia-legacy-367xx/367.134/*/build/make.log`. Run `debian/tests/dkms-kernel-matrix` to compile against all installed kernel header trees.

## Secure Boot

The package uses Debian's normal DKMS signing path. It does not disable Secure Boot or create firmware keys. Enroll a local MOK key using Debian's DKMS/Secure Boot documentation when signature enforcement is enabled, or boot with Secure Boot disabled.

## nouveau prevention

Install the generated `nvidia-legacy-367xx-kernel-support`/alternative packages so Debian's NVIDIA blacklist and module-loading integration prevents nouveau from binding GRID K1 before NVIDIA modules load.

## CUDA smoke testing

On a GRID K1 host with CUDA 8.0.44, compile smoke tests with `nvcc -std=c++11 -gencode arch=compute_30,code=sm_30 vector_add.cu -o vector_add`, then test every GPU and simultaneous contexts. Check `dmesg` and `journalctl -k` for oopses, UVM fatal errors, DMA errors, and persistent warnings.

## New kernel compatibility patches

Submit minimal patches under `debian/module/debian/patches/` with headers documenting origin, upstream status, original source driver, target driver, reason, affected kernels, semantic changes, and testing. Prefer `conftest.sh` feature probes over distro checks.
