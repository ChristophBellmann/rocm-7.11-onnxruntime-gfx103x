#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_ROOT="${RELEASE_ROOT:-${ROOT}/.rocm_release}"
WORK_ROOT="${WORK_ROOT:-${RELEASE_ROOT}/builds/onnxruntime_rocm}"
BUILD_DIR="${BUILD_DIR:-${WORK_ROOT}/build-gfx1031-tlsfix-wheel}"
LOG_FILE="${LOG_FILE:-${WORK_ROOT}/ort_build_live.log}"
WHEEL_OUT_DIR="${WHEEL_OUT_DIR:-${RELEASE_ROOT}/wheels/onnxruntime_rocm711}"
VENV_DIR="${VENV_DIR:-${RELEASE_ROOT}/venvs/ort_build}"

ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
ROCM_VERSION="${ROCM_VERSION:-7.11.0}"
HIP_ARCH="${HIP_ARCH:-gfx1031}"
HIP_PLATFORM="${HIP_PLATFORM:-amd}"
USE_MIGRAPHX="${USE_MIGRAPHX:-0}"
MIGRAPHX_HOME="${MIGRAPHX_HOME:-${ROCM_PATH}}"
PARALLEL="${PARALLEL:-$(nproc)}"
DO_UPDATE="${DO_UPDATE:-1}"
PYTHON_BIN="${PYTHON_BIN:-}"
ORT_REF="${ORT_REF:-}"

TLS_C_FLAGS="${TLS_C_FLAGS:--ftls-model=global-dynamic}"
TLS_CXX_FLAGS="${TLS_CXX_FLAGS:--ftls-model=global-dynamic}"
TLS_LINK_FLAGS="${TLS_LINK_FLAGS:--Wl,--no-as-needed}"

usage() {
  cat <<USAGE
Usage:
  $0 [--help]

Environment:
  ROCM_PATH=/opt/rocm
  WORK_ROOT=.rocm_release/builds/onnxruntime_rocm
  WHEEL_OUT_DIR=.rocm_release/wheels/onnxruntime_rocm711
  VENV_DIR=.rocm_release/venvs/ort_build
  DO_UPDATE=1|0
  USE_MIGRAPHX=1|0
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

for var_name in RELEASE_ROOT WORK_ROOT BUILD_DIR LOG_FILE WHEEL_OUT_DIR VENV_DIR ROCM_PATH MIGRAPHX_HOME; do
  var_value="${!var_name}"
  if [[ "${var_value}" != /* ]]; then
    printf -v "${var_name}" '%s/%s' "${ROOT}" "${var_value}"
  fi
done

if [[ ! -e "${ROOT}/.git" ]]; then
  echo "ERROR: expected a git checkout at ${ROOT}" >&2
  exit 1
fi
if [[ ! -d "${ROCM_PATH}" ]]; then
  echo "ERROR: ROCM_PATH does not exist: ${ROCM_PATH}" >&2
  exit 1
fi

DEFAULT_BUILD_DIR="${WORK_ROOT}/build-gfx1031-tlsfix-wheel"
if [[ "${USE_MIGRAPHX}" == "1" && "${BUILD_DIR}" == "${DEFAULT_BUILD_DIR}" ]]; then
  BUILD_DIR="${WORK_ROOT}/build-gfx1031-tlsfix-wheel-migraphx"
fi

mkdir -p "${WORK_ROOT}" "${WHEEL_OUT_DIR}" "$(dirname "${LOG_FILE}")" "${RELEASE_ROOT}/venvs"

ensure_python() {
  if [[ -n "${PYTHON_BIN}" ]]; then
    if [[ -x "${PYTHON_BIN}" ]]; then
      echo "${PYTHON_BIN}"
      return 0
    fi
    local resolved
    resolved="$(command -v "${PYTHON_BIN}" 2>/dev/null || true)"
    if [[ -n "${resolved}" && -x "${resolved}" ]]; then
      echo "${resolved}"
      return 0
    fi
    echo "ERROR: Python not found/executable: ${PYTHON_BIN}" >&2
    exit 1
  fi

  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    /usr/bin/python3 -m venv "${VENV_DIR}"
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip setuptools wheel >/dev/null
  fi
  echo "${VENV_DIR}/bin/python"
}

PY="$(ensure_python)"
"${PY}" -m pip install -q "numpy<2" packaging >/dev/null

verify_wheel_tls() {
  local wheel_path="$1"
  local tmp_dir so_path
  tmp_dir="$(mktemp -d)"
  cleanup() { rm -rf "${tmp_dir}"; }
  trap cleanup RETURN

  "${PY}" -c 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); n=[x for x in z.namelist() if x.endswith("onnxruntime/capi/libonnxruntime_providers_rocm.so")][0]; z.extract(n, sys.argv[2])' "${wheel_path}" "${tmp_dir}"
  so_path="$(find "${tmp_dir}" -name libonnxruntime_providers_rocm.so | head -n1 || true)"
  if [[ -z "${so_path}" || ! -f "${so_path}" ]]; then
    echo "Could not extract provider .so from wheel: ${wheel_path}" >&2
    return 2
  fi

  if readelf -dW "${so_path}" | grep -q "STATIC_TLS"; then
    echo "TLS check FAILED: provider contains STATIC_TLS" >&2
    return 3
  fi

  if readelf -rW "${so_path}" | grep -Eq "_ZSt11__once_call|_ZSt15__once_callable|R_X86_64_TPOFF64"; then
    echo "TLS check FAILED: provider still has once/TPOFF TLS relocations" >&2
    return 4
  fi

  echo "TLS check OK (no STATIC_TLS / no once-call TLS relocations)."
}

cd "${ROOT}"

if ! git config --get-all remote.origin.fetch | grep -q 'refs/heads/\*'; then
  git config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
fi

if [[ "${DO_UPDATE}" == "1" ]]; then
  echo "[ORT] Fetch updates"
  git fetch origin --tags --prune
  git fetch upstream --tags --prune || true
fi

current_branch="$(git branch --show-current || true)"
if [[ -n "${ORT_REF}" ]]; then
  echo "[ORT] Checkout ${ORT_REF}"
  if git show-ref --verify --quiet "refs/remotes/origin/${ORT_REF}"; then
    git checkout -B "${ORT_REF}" "origin/${ORT_REF}"
  else
    git checkout "${ORT_REF}"
  fi
  if [[ "${DO_UPDATE}" == "1" ]]; then
    git pull --ff-only || true
    git submodule sync --recursive
    git submodule update --init --recursive
  fi
  current_branch="$(git branch --show-current || true)"
fi
if [[ -n "${current_branch}" ]]; then
  echo "[ORT] Current branch ${current_branch}"
fi

export HIP_PLATFORM
export PYTHONNOUSERSITE=1

BUILD_ARGS=()
if [[ "${DO_UPDATE}" == "1" ]]; then
  BUILD_ARGS+=(--update)
fi
if [[ "${USE_MIGRAPHX}" == "1" ]]; then
  if [[ " ${BUILD_ARGS[*]} " != *" --update "* ]]; then
    BUILD_ARGS+=(--update)
  fi
  BUILD_ARGS+=(--use_migraphx --migraphx_home "${MIGRAPHX_HOME}")
fi

CMAKE_CACHE="${BUILD_DIR}/Release/CMakeCache.txt"
if [[ -f "${CMAKE_CACHE}" ]]; then
  cached_src="$(sed -n 's#^CMAKE_HOME_DIRECTORY:INTERNAL=##p' "${CMAKE_CACHE}" | head -n1 || true)"
  expected_src="${ROOT}/cmake"
  if [[ -n "${cached_src}" && "${cached_src}" != "${expected_src}" ]]; then
    echo "[ORT] Removing stale build dir due to source mismatch:"
    echo "  cached:   ${cached_src}"
    echo "  expected: ${expected_src}"
    rm -rf "${BUILD_DIR}"
    CMAKE_CACHE="${BUILD_DIR}/Release/CMakeCache.txt"
  fi
fi
if [[ ! -f "${CMAKE_CACHE}" ]] || ! grep -q '^Python_NumPy_INCLUDE_DIR:' "${CMAKE_CACHE}" 2>/dev/null; then
  if [[ " ${BUILD_ARGS[*]} " != *" --update "* ]]; then
    BUILD_ARGS+=(--update)
  fi
fi

echo "== ONNX Runtime ROCm wheel build =="
echo "ROOT=${ROOT}"
echo "WORK_ROOT=${WORK_ROOT}"
echo "BUILD_DIR=${BUILD_DIR}"
echo "WHEEL_OUT_DIR=${WHEEL_OUT_DIR}"
echo "PYTHON=${PY}"
echo "ROCM_PATH=${ROCM_PATH}"
echo "ROCM_VERSION=${ROCM_VERSION}"
echo "HIP_ARCH=${HIP_ARCH}"
echo "HIP_PLATFORM=${HIP_PLATFORM}"
echo "USE_MIGRAPHX=${USE_MIGRAPHX}"
echo "MIGRAPHX_HOME=${MIGRAPHX_HOME}"
echo "PARALLEL=${PARALLEL}"
echo "DO_UPDATE=${DO_UPDATE}"
echo "LOG_FILE=${LOG_FILE}"

"${PY}" tools/ci_build/build.py \
  --build_dir "${BUILD_DIR}" \
  --config Release \
  "${BUILD_ARGS[@]}" \
  --build \
  --build_wheel \
  --enable_pybind \
  --skip_tests \
  --parallel "${PARALLEL}" \
  --use_rocm \
  --rocm_home "${ROCM_PATH}" \
  --rocm_version "${ROCM_VERSION}" \
  --cmake_extra_defines \
    "CMAKE_HIP_ARCHITECTURES=${HIP_ARCH}" \
    "onnxruntime_USE_COMPOSABLE_KERNEL=OFF" \
    "onnxruntime_BUILD_UNIT_TESTS=OFF" \
    "onnxruntime_DISABLE_CONTRIB_OPS=ON" \
    "CMAKE_C_FLAGS=${TLS_C_FLAGS}" \
    "CMAKE_CXX_FLAGS=${TLS_CXX_FLAGS}" \
    "CMAKE_SHARED_LINKER_FLAGS=${TLS_LINK_FLAGS}" \
  2>&1 | tee "${LOG_FILE}"

WHEEL_PATH="$(find "${BUILD_DIR}/Release/dist" -maxdepth 1 -type f -name 'onnxruntime_rocm-*.whl' | head -n1 || true)"
if [[ -z "${WHEEL_PATH}" ]]; then
  echo "No wheel found under ${BUILD_DIR}/Release/dist" >&2
  exit 2
fi

verify_wheel_tls "${WHEEL_PATH}"
cp -f "${WHEEL_PATH}" "${WHEEL_OUT_DIR}/"

echo
echo "Built wheel:"
echo "${WHEEL_PATH}"
echo "Copied to:"
ls -lh "${WHEEL_OUT_DIR}"/onnxruntime_rocm-*.whl
