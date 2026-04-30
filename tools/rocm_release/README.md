# ROCm 7.11 ONNX Runtime release helpers

This directory is the source of truth for the custom ROCm 7.11 packaging flow
for the `rocm-7.11-onnxruntime-gfx103x` fork.

Scope:
- build the custom `onnxruntime_rocm` wheel from this repo
- verify the ROCm provider shared object does not regress to STATIC_TLS / once-call TLS relocations
- verify the wheel-staged `libonnxruntime_providers_rocm.so` matches the freshly built `Release/libonnxruntime_providers_rocm.so`
- promote the verified wheel to `/opt/rocm/wheels/onnxruntime_rocm711/`
- allow launcher-based incremental build acceleration (for example `ccache`) via
  `CMAKE_C_COMPILER_LAUNCHER` / `CMAKE_CXX_COMPILER_LAUNCHER`

TheRock validation should consume the produced wheel and validate inference
first against the repo-local custom ROCm build, then against the promoted
system install under `/opt/rocm`.

## Layout

- `build_onnxruntime_rocm_wheel.sh`
- `install_onnxruntime_rocm_wheel_to_opt.sh`

Default local workspace:
- `./.rocm_release/builds/onnxruntime_rocm/`
- `./.rocm_release/wheels/onnxruntime_rocm711/`
- `./.rocm_release/venvs/ort_build/`
- `./.rocm_release/install-backups/`

Implementation notes:
- the build helper repairs the wheel after `setup.py bdist_wheel` if the staged
  `onnxruntime/capi/libonnxruntime_providers_rocm.so` diverges from the actual
  `Release/libonnxruntime_providers_rocm.so`
- the gfx1031 branch keeps the MIOpen convolution algorithm-search workspace at
  least at the historical `AlgoSearchWorkspaceSize` floor (32 MiB) even when
  `miopen_conv_use_max_workspace=true`, because some real Piper TTS shapes on
  ROCm 7.11 otherwise fall back to a zero-sized search buffer and emit
  `GemmFwdRest` workspace warnings
- new ONNX Runtime ROCm wheels are built against NumPy 2 by default via
  `NUMPY_SPEC='numpy>=2,<3'`; set `NUMPY_SPEC='numpy<2'` only to reproduce
  legacy NumPy-1 ABI wheels

## Typical flow

Build first against the repo-local custom ROCm output:

```bash
ROCM_PATH=/path/to/TheRock/build-stage2/dist/rocm \
CMAKE_C_COMPILER_LAUNCHER=ccache \
CMAKE_CXX_COMPILER_LAUNCHER=ccache \
./tools/rocm_release/build_onnxruntime_rocm_wheel.sh
```

Legacy NumPy-1 ABI reproduction, only when required for comparison:

```bash
NUMPY_SPEC='numpy<2' \
ROCM_PATH=/path/to/TheRock/build-stage2/dist/rocm \
./tools/rocm_release/build_onnxruntime_rocm_wheel.sh
```

Then promote the verified wheel:

```bash
sudo ./tools/rocm_release/install_onnxruntime_rocm_wheel_to_opt.sh
```

Stable system alias after promotion:
- `/opt/rocm/wheels/onnxruntime_rocm711/onnxruntime-current.whl`
