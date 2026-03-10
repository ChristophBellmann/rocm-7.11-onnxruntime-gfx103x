# ROCm 7.11 ONNX Runtime release helpers

This directory is the source of truth for the custom ROCm 7.11 packaging flow
for the `rocm-7.11-onnxruntime-gfx103x` fork.

Scope:
- build the custom `onnxruntime_rocm` wheel from this repo
- verify the ROCm provider shared object does not regress to STATIC_TLS / once-call TLS relocations
- promote the verified wheel to `/opt/rocm/wheels/onnxruntime_rocm711/`

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

## Typical flow

Build first against the repo-local custom ROCm output:

```bash
./tools/rocm_release/build_onnxruntime_rocm_wheel.sh \
  ROCM_PATH=/path/to/TheRock/build-stage2/dist/rocm
```

Then promote the verified wheel:

```bash
sudo ./tools/rocm_release/install_onnxruntime_rocm_wheel_to_opt.sh
```

Stable system alias after promotion:
- `/opt/rocm/wheels/onnxruntime_rocm711/onnxruntime-current.whl`
