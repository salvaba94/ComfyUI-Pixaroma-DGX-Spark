#!/usr/bin/env bash
set -eu

mode="${ONNXRUNTIME_MODE:-auto}"
ref="${ONNXRUNTIME_REF:-v1.27.0}"
arch="$(uname -m)"
numpy_version="${NUMPY_VERSION:-1.26.4}"
build_jobs="${ONNXRUNTIME_BUILD_JOBS:-${ADDON_BUILD_JOBS:-1}}"

if [ "${mode}" = "auto" ]; then
    case "${arch}" in
        x86_64|amd64)
            mode="wheel"
            ;;
        *)
            mode="source"
            ;;
    esac
fi

case "${mode}" in
    wheel)
        echo "Installing published onnxruntime-gpu wheel"
        uv pip install onnxruntime-gpu
        ;;
    cpu)
        echo "Installing CPU onnxruntime wheel"
        uv pip install onnxruntime
        ;;
    source)
        echo "Building CUDA-enabled ONNX Runtime from source for ${arch} with ${build_jobs} job(s)"
        export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
        export CUDNN_HOME="${CUDNN_HOME:-/usr}"
        export MAX_JOBS="${MAX_JOBS:-${build_jobs}}"
        export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-${build_jobs}}"

        workdir="$(mktemp -d)"
        git clone --branch "${ref}" --recursive https://github.com/microsoft/onnxruntime.git "${workdir}/onnxruntime"
        cd "${workdir}/onnxruntime"

        python -m pip install -r tools/ci_build/github/linux/python/requirements.txt
        uv pip install --force-reinstall --no-deps "numpy==${numpy_version}"
        ./build.sh \
            --allow_running_as_root \
            --build \
            --build_wheel \
            --config Release \
            --cuda_home "${CUDA_HOME}" \
            --cudnn_home "${CUDNN_HOME}" \
            --parallel "${build_jobs}" \
            --nvcc_threads "${build_jobs}" \
            --skip_tests \
            --update \
            --use_cuda \
            --cmake_extra_defines FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER

        python -m pip install --no-cache-dir build/Linux/Release/dist/onnxruntime_gpu-*.whl
        cd /
        rm -rf "${workdir}"
        ;;
    *)
        echo "Unknown ONNXRUNTIME_MODE: ${mode}" >&2
        exit 1
        ;;
esac

uv pip install --force-reinstall --no-deps "numpy==${numpy_version}"
