# -------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
# --------------------------------------------------------------------------

# This file can be modified by setup.py when building a manylinux2010 wheel
# When modified, it will preload some libraries needed for the python C extension

import ctypes
import ctypes.util
import os
from pathlib import Path


def _try_dlopen(lib_candidates):
    for lib in lib_candidates:
        if not lib:
            continue
        try:
            ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)
            return True
        except OSError:
            continue
    return False


def _rocm_candidate_paths(lib_name):
    rocm_home = os.environ.get("ROCM_PATH", "/opt/rocm")
    candidates = [
        str(Path(rocm_home) / "lib" / lib_name),
        str(Path(rocm_home) / "lib" / "llvm" / "lib" / lib_name),
        str(Path(rocm_home) / "lib64" / lib_name),
        lib_name,
        ctypes.util.find_library(lib_name.replace("lib", "").split(".so")[0]),
    ]
    return candidates


if os.name == "posix":
    # Load these as early as possible to avoid late dlopen TLS allocation failures
    # when the ROCm provider is loaded.
    _try_dlopen(["libstdc++.so.6", ctypes.util.find_library("stdc++")])
    _try_dlopen(_rocm_candidate_paths("libomp.so"))
