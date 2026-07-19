#!/usr/bin/env bash
set -eu

torchaudio_version="${TORCHAUDIO_VERSION:-2.8.0}"
torchaudio_ref="${TORCHAUDIO_REF:-v${torchaudio_version}}"
torchaudio_build_jobs="${TORCHAUDIO_BUILD_JOBS:-${ADDON_BUILD_JOBS:-1}}"
numpy_version="${NUMPY_VERSION:-1.26.4}"

torch_fingerprint() {
    python - <<'PY'
import torch

print(torch.__version__)
print(torch.version.cuda)
PY
}

check_torch_unchanged() {
    before="$1"
    after="$(torch_fingerprint)"
    if [ "${before}" != "${after}" ]; then
        echo "PyTorch changed while finalizing CUDA Python stack." >&2
        echo "Before:" >&2
        echo "${before}" >&2
        echo "After:" >&2
        echo "${after}" >&2
        exit 1
    fi
}

validate_torchaudio() {
    python - <<'PY'
import torch
import torchaudio

print(f"torch {torch.__version__} cuda={torch.version.cuda}")
print(f"torchaudio {torchaudio.__version__}")
PY
}

build_torchaudio_from_source() {
    echo "Compiling torchaudio ${torchaudio_ref} from source for $(uname -m)."
    apt-get update
    apt-get install -y --no-install-recommends \
        libsndfile1-dev \
        libsox-dev \
        libsox-fmt-all
    rm -rf /var/lib/apt/lists/*

    workdir="$(mktemp -d)"
    git clone --branch "${torchaudio_ref}" --recursive https://github.com/pytorch/audio.git "${workdir}/audio" \
        || git clone --branch "release/${torchaudio_version%.*}" --recursive https://github.com/pytorch/audio.git "${workdir}/audio"

    cd "${workdir}/audio"
    python -m pip install --upgrade build wheel "setuptools<82" ninja cmake
    USE_CUDA=1 \
        USE_ROCM=0 \
        BUILD_SOX=1 \
        MAX_JOBS="${torchaudio_build_jobs}" \
        CMAKE_BUILD_PARALLEL_LEVEL="${torchaudio_build_jobs}" \
        python -m build --wheel --no-isolation

    set -- dist/torchaudio*.whl
    if [ ! -f "$1" ]; then
        echo "torchaudio source build produced no wheel." >&2
        exit 1
    fi

    python -m pip install --force-reinstall --no-deps "$@"
    cd /
    rm -rf "${workdir}"
}

ensure_torchaudio() {
    before="$(torch_fingerprint)"
    if validate_torchaudio; then
        check_torch_unchanged "${before}"
        return
    fi

    echo "Installing torchaudio ${torchaudio_version} without dependencies."
    if ! python -m pip install --no-cache-dir --no-deps "torchaudio==${torchaudio_version}" || ! validate_torchaudio; then
        python -m pip uninstall -y torchaudio || true
        build_torchaudio_from_source
        validate_torchaudio
    fi

    check_torch_unchanged "${before}"
}

validate_onnxruntime_cuda() {
    python - <<'PY'
import onnxruntime as ort

providers = ort.get_available_providers()
print(f"onnxruntime providers {providers}")
if "CUDAExecutionProvider" not in providers:
    raise SystemExit("onnxruntime is missing CUDAExecutionProvider")
PY
}

ensure_onnxruntime_cuda() {
    if validate_onnxruntime_cuda; then
        return
    fi

    echo "Restoring CUDA-enabled ONNX Runtime after addon installation."
    python -m pip uninstall -y onnxruntime onnxruntime-gpu || true
    ONNXRUNTIME_MODE="${ONNXRUNTIME_MODE:-source}" \
        ONNXRUNTIME_REF="${ONNXRUNTIME_REF:-v1.27.0}" \
        ONNXRUNTIME_BUILD_JOBS="${ONNXRUNTIME_BUILD_JOBS:-${ADDON_BUILD_JOBS:-1}}" \
        NUMPY_VERSION="${numpy_version}" \
        /usr/local/bin/install_onnxruntime.sh
    validate_onnxruntime_cuda
}

ensure_torchaudio
ensure_onnxruntime_cuda
python -m pip install --force-reinstall --no-deps "numpy==${numpy_version}"
