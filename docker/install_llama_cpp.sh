#!/usr/bin/env bash
set -eu

mode="${LLAMA_CPP_MODE:-auto}"
repo="${LLAMA_CPP_REPO:-https://github.com/JamePeng/llama-cpp-python.git}"
arch="$(uname -m)"
numpy_version="${NUMPY_VERSION:-1.26.4}"

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
        echo "Installing CUDA llama-cpp-python wheel"
        uv pip install https://github.com/JamePeng/llama-cpp-python/releases/download/v0.3.33-cu128-Basic-linux-20260315/llama_cpp_python-0.3.33+cu128.basic-cp312-cp312-linux_x86_64.whl \
            || uv pip install https://github.com/JamePeng/llama-cpp-python/releases/download/v0.3.33-cu130-Basic-linux-20260315/llama_cpp_python-0.3.33+cu130.basic-cp312-cp312-linux_x86_64.whl
        ;;
    source)
        echo "Building llama-cpp-python with CUDA support for ${arch}"
        export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
        export FORCE_CMAKE=1
        export CMAKE_ARGS="${CMAKE_ARGS:-} -DGGML_CUDA=on"
        uv pip install --upgrade --force-reinstall --no-binary llama-cpp-python "llama-cpp-python @ git+${repo}"
        ;;
    cpu)
        echo "Installing CPU llama-cpp-python"
        uv pip install llama-cpp-python
        ;;
    *)
        echo "Unknown LLAMA_CPP_MODE: ${mode}" >&2
        exit 1
        ;;
esac

uv pip install --force-reinstall --no-deps "numpy==${numpy_version}"
