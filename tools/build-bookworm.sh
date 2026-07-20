#!/bin/sh
set -eu
out=${1:-../build-results/bookworm}
exec "$(dirname "$0")/build-in-container.sh" bookworm "$out"
