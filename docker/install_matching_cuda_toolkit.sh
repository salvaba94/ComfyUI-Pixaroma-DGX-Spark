#!/usr/bin/env bash
set -eu

if ! python - <<'PY'
import torch
print(torch.version.cuda or "")
PY
then
    echo "PyTorch is not importable; cannot check CUDA toolkit match." >&2
    exit 1
fi

torch_cuda="$(python - <<'PY'
import torch
print(torch.version.cuda or "")
PY
)"

ensure_nvidia_cuda_repo() {
    arch="$(dpkg --print-architecture)"
    . /etc/os-release

    if [ "${ID:-}" != "ubuntu" ]; then
        echo "Automatic NVIDIA CUDA apt repo setup currently supports Ubuntu only, got ${ID:-unknown}." >&2
        return 1
    fi

    ubuntu_version="${VERSION_ID//./}"
    case "${arch}" in
        arm64)
            repo_arch="sbsa"
            ;;
        amd64)
            repo_arch="x86_64"
            ;;
        *)
            echo "Unsupported architecture for NVIDIA CUDA apt repo: ${arch}" >&2
            return 1
            ;;
    esac

    repo_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${ubuntu_version}/${repo_arch}"
    list_file="/etc/apt/sources.list.d/cuda-ubuntu${ubuntu_version}-${repo_arch}.list"
    keyring="/usr/share/keyrings/cuda-archive-keyring.gpg"

    if [ ! -f "${keyring}" ]; then
        mkdir -p "$(dirname "${keyring}")"
        curl -fsSL "${repo_url}/cuda-archive-keyring.gpg" -o "${keyring}"
    fi

    if [ ! -f "${list_file}" ]; then
        echo "deb [signed-by=${keyring}] ${repo_url}/ /" > "${list_file}"
    fi
}

if [ -z "${torch_cuda}" ]; then
    echo "PyTorch is not CUDA-enabled; no CUDA toolkit match required."
    exit 0
fi

nvcc_bin=""
if command -v nvcc >/dev/null 2>&1; then
    nvcc_bin="$(command -v nvcc)"
elif [ -x /usr/local/cuda/bin/nvcc ]; then
    nvcc_bin=/usr/local/cuda/bin/nvcc
fi

nvcc_cuda=""
if [ -n "${nvcc_bin}" ]; then
    nvcc_cuda="$("${nvcc_bin}" --version | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p' | head -1)"
fi

if [ "${nvcc_cuda}" = "${torch_cuda}" ]; then
    echo "CUDA toolkit already matches PyTorch CUDA ${torch_cuda}."
    exit 0
fi

echo "PyTorch CUDA is ${torch_cuda}; nvcc CUDA is ${nvcc_cuda:-missing}. Installing/selecting matching toolkit."

cuda_dash="${torch_cuda/./-}"
cuda_dir="/usr/local/cuda-${torch_cuda}"

if [ ! -x "${cuda_dir}/bin/nvcc" ]; then
    apt-get update
    if ! apt-cache show "cuda-toolkit-${cuda_dash}" >/dev/null 2>&1; then
        ensure_nvidia_cuda_repo
        apt-get update
    fi
    if apt-cache show "cuda-toolkit-${cuda_dash}" >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends "cuda-toolkit-${cuda_dash}"
    elif apt-cache show "cuda-compiler-${cuda_dash}" >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends "cuda-compiler-${cuda_dash}" "cuda-cudart-dev-${cuda_dash}"
    else
        echo "No apt package found for CUDA toolkit ${torch_cuda}." >&2
        echo "Use an ARM64 base image whose nvcc matches torch.version.cuda=${torch_cuda}, or add the matching NVIDIA CUDA apt repository." >&2
        exit 1
    fi
    rm -rf /var/lib/apt/lists/*
fi

if [ ! -x "${cuda_dir}/bin/nvcc" ]; then
    echo "Installed toolkit did not provide ${cuda_dir}/bin/nvcc." >&2
    exit 1
fi

ln -sfn "${cuda_dir}" /usr/local/cuda
export PATH="/usr/local/cuda/bin:${PATH}"

new_nvcc_cuda="$(/usr/local/cuda/bin/nvcc --version | sed -n 's/.*release \([0-9]\+\.[0-9]\+\).*/\1/p' | head -1)"
if [ "${new_nvcc_cuda}" != "${torch_cuda}" ]; then
    echo "CUDA toolkit mismatch remains: nvcc=${new_nvcc_cuda}, torch=${torch_cuda}." >&2
    exit 1
fi

echo "CUDA toolkit now matches PyTorch CUDA ${torch_cuda}."
