#!/bin/sh
set -eu
suite=${1:-bookworm}
out_arg=${2:-../build-results/$suite}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$out_arg" in
    /*) out=$out_arg ;;
    *) mkdir -p "$(dirname -- "$out_arg")"; out=$(CDPATH= cd -- "$(dirname -- "$out_arg")" && pwd)/$(basename -- "$out_arg") ;;
esac
mkdir -p "$out"
if command -v docker >/dev/null 2>&1; then
    runtime=docker
    runtime_args=
elif command -v podman >/dev/null 2>&1; then
    runtime=podman
    runtime_args="--network=host --cgroups=disabled"
else
    echo 'docker or podman is required' >&2
    exit 127
fi
exec "$runtime" run --rm $runtime_args \
    -v "$repo:/repo:ro" \
    -v "$out:/out:rw" \
    "debian:$suite" \
    sh /repo/tools/build-in-debian.sh "$suite" /repo /out
