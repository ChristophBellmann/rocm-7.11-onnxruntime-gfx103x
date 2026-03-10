#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_ROOT="${RELEASE_ROOT:-${ROOT}/.rocm_release}"
SRC_DIR="${SRC_DIR:-${RELEASE_ROOT}/wheels/onnxruntime_rocm711}"
DEST_DIR="${DEST_DIR:-/opt/rocm/wheels/onnxruntime_rocm711}"
BACKUP_ROOT="${BACKUP_ROOT:-${RELEASE_ROOT}/install-backups/$(date +%Y%m%d_%H%M%S)/onnxruntime_wheels}"
TS="$(date +%Y%m%d_%H%M%S)"

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

usage() {
  echo "Usage:"
  echo "  $0 [path/to/onnxruntime_rocm-*.whl]"
  echo "  $0 --restore [onnxruntime_rocm-*.whl]"
}

sanitize_wheel_rpaths_for_system_rocm() {
  local src_wheel="$1"
  local out_wheel="$2"
  local tmp_dir unpack_dir sys_rocm_rpath
  tmp_dir="$(mktemp -d)"
  unpack_dir="${tmp_dir}/wheel"
  mkdir -p "${unpack_dir}"
  sys_rocm_rpath="/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/lib/host-math/lib:/opt/rocm/lib/rocm_sysdeps/lib:/opt/rocm/llvm/lib"

  python3 - <<'PY' "${src_wheel}" "${unpack_dir}"
import sys
import zipfile

wheel, out_dir = sys.argv[1:3]
with zipfile.ZipFile(wheel) as zf:
    zf.extractall(out_dir)
PY

  local pybind_so rocm_so
  pybind_so="$(find "${unpack_dir}/onnxruntime/capi" -maxdepth 1 -type f -name 'onnxruntime_pybind11_state.so' | head -n1 || true)"
  rocm_so="$(find "${unpack_dir}/onnxruntime/capi" -maxdepth 1 -type f -name 'libonnxruntime_providers_rocm.so' | head -n1 || true)"

  if [[ -n "${pybind_so}" ]]; then
    patchelf --force-rpath --set-rpath "\$ORIGIN:${sys_rocm_rpath}" "${pybind_so}"
  fi
  if [[ -n "${rocm_so}" ]]; then
    patchelf --force-rpath --set-rpath "${sys_rocm_rpath}" "${rocm_so}"
  fi

  python3 - <<'PY' "${unpack_dir}" "${out_wheel}"
import os
import sys
import zipfile

src_dir, out_wheel = sys.argv[1:3]
with zipfile.ZipFile(out_wheel, "w", compression=zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(src_dir):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, src_dir)
            zf.write(full, rel)
PY

  rm -rf "${tmp_dir}"
}

verify_wheel_system_rpath_contract() {
  local wheel_path="$1"
  local tmp_dir
  tmp_dir="$(mktemp -d)"

  python3 - <<'PY' "${wheel_path}" "${tmp_dir}"
import sys
import zipfile

wheel, out_dir = sys.argv[1:3]
with zipfile.ZipFile(wheel) as zf:
    zf.extractall(out_dir)
PY

  local bad=0
  while IFS= read -r sofile; do
    local rp
    rp="$(patchelf --print-rpath "${sofile}" 2>/dev/null || true)"
    echo "RPATH $(basename "${sofile}") => ${rp}"
    if [[ "${rp}" == *"/build-stage2/dist/rocm"* ]]; then
      echo "System wheel check FAILED: stale in-tree RPATH remains in ${sofile}" >&2
      bad=1
    fi
  done < <(find "${tmp_dir}/onnxruntime/capi" -maxdepth 1 -type f -name '*.so' | sort)

  rm -rf "${tmp_dir}"
  [[ "${bad}" -eq 0 ]]
}

find_latest_wheel() {
  ls -1t "${SRC_DIR}"/onnxruntime_rocm-*.whl 2>/dev/null | head -n1 || true
}

restore_latest_backup() {
  local wheel_name="$1"
  local target="${DEST_DIR}/${wheel_name}"
  local latest
  latest="$(ls -1t "${target}".bak_* 2>/dev/null | head -n1 || true)"
  if [[ -z "${latest}" ]]; then
    echo "No backup found for ${target}" >&2
    exit 1
  fi
  echo "Restoring backup:"
  echo "  from: ${latest}"
  echo "  to:   ${target}"
  "${SUDO[@]}" cp -f "${latest}" "${target}"
  "${SUDO[@]}" sha256sum "${target}"
  ls -lh "${target}"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--restore" ]]; then
  if [[ -n "${2:-}" ]]; then
    restore_latest_backup "$(basename "${2}")"
  else
    latest="$(find_latest_wheel)"
    if [[ -z "${latest}" ]]; then
      echo "No wheel found in ${SRC_DIR}" >&2
      exit 1
    fi
    restore_latest_backup "$(basename "${latest}")"
  fi
  exit 0
fi

SRC_WHEEL="${1:-}"
if [[ -z "${SRC_WHEEL}" ]]; then
  SRC_WHEEL="$(find_latest_wheel)"
fi
if [[ -z "${SRC_WHEEL}" || ! -f "${SRC_WHEEL}" ]]; then
  echo "Source wheel not found: ${SRC_WHEEL:-<empty>}" >&2
  echo "Checked SRC_DIR=${SRC_DIR}" >&2
  usage >&2
  exit 1
fi

PATCHED_WHEEL="$(mktemp --suffix=.whl)"
sanitize_wheel_rpaths_for_system_rocm "${SRC_WHEEL}" "${PATCHED_WHEEL}"
verify_wheel_system_rpath_contract "${PATCHED_WHEEL}"

DEST_WHEEL="${DEST_DIR}/$(basename "${SRC_WHEEL}")"

echo "Source: ${SRC_WHEEL}"
echo "Target: ${DEST_WHEEL}"
echo "Backup root: ${BACKUP_ROOT}"

"${SUDO[@]}" mkdir -p "${DEST_DIR}"
mkdir -p "${BACKUP_ROOT}"

if [[ -d "${DEST_DIR}" ]]; then
  echo "Directory backup: ${BACKUP_ROOT}/$(basename "${DEST_DIR}")"
  "${SUDO[@]}" rsync -a "${DEST_DIR}/" "${BACKUP_ROOT}/$(basename "${DEST_DIR}")/"
fi

if [[ -f "${DEST_WHEEL}" ]]; then
  backup="${DEST_WHEEL}.bak_${TS}"
  echo "Backup: ${backup}"
  "${SUDO[@]}" cp -f "${DEST_WHEEL}" "${backup}"
fi

"${SUDO[@]}" cp -f "${PATCHED_WHEEL}" "${DEST_WHEEL}"
current_link="${DEST_DIR}/onnxruntime-current.whl"
"${SUDO[@]}" ln -sfn "$(basename "${DEST_WHEEL}")" "${current_link}"

echo
echo "SHA256:"
echo "Original:"
sha256sum "${SRC_WHEEL}"
"${SUDO[@]}" rm -f "${PATCHED_WHEEL}"
echo "Installed copy:"
"${SUDO[@]}" sha256sum "${DEST_WHEEL}"

echo
echo "Installed wheel:"
ls -lh "${DEST_WHEEL}" "${current_link}"
