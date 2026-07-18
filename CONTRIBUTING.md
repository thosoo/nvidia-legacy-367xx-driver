# Contributing

Keep Debian packaging changes separate from NVIDIA kernel compatibility patches. Do not commit proprietary NVIDIA `.run` files, extracted payloads, or prebuilt `.ko` files. Regenerate generated files from templates and run `tests/no-baseline-leaks.sh` plus `debian/tests/dkms-kernel-matrix` when headers are available.
