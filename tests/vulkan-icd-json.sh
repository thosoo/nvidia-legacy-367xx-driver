#!/bin/sh
set -eu
root=${1:-.}
python3 - "$root" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
checks = [
    (root / "glvnd" / "nvidia_icd.json", "libGLX_nvidia.so.0"),
    (root / "nonglvnd" / "nvidia_icd.json", "libGL.so.1"),
]
for path, expected in checks:
    text = path.read_text(encoding="utf-8")
    if "__NV_VK_ICD__" in text:
        raise SystemExit(f"placeholder remains in {path}")
    bad_markers = ["390" + ".157", "390" + "xx", "legacy-" + "390"]
    if any(marker in text for marker in bad_markers):
        raise SystemExit(f"390-series-only text remains in {path}")
    data = json.loads(text)
    libraries = []
    icd = data.get("ICD")
    if isinstance(icd, dict) and "library_path" in icd:
        libraries.append(icd["library_path"])
    layer = data.get("layer")
    if isinstance(layer, dict) and "library_path" in layer:
        libraries.append(layer["library_path"])
    if not libraries:
        raise SystemExit(f"no library_path entries found in {path}")
    for library in libraries:
        if library != expected:
            raise SystemExit(f"{path}: expected {expected}, found {library}")
PY
