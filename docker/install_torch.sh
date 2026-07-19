#!/usr/bin/env bash
set -eu

mode="${TORCH_INSTALL_MODE:-auto}"
arch="$(uname -m)"

if [ "${mode}" = "auto" ]; then
    case "${arch}" in
        x86_64|amd64)
            mode="wheel"
            ;;
        *)
            mode="preinstalled"
            ;;
    esac
fi

check_torch() {
    python - <<'PY'
import sys

try:
    import torch
except Exception as exc:
    print(f"torch import failed: {exc}", file=sys.stderr)
    sys.exit(1)

print(f"torch {torch.__version__}")
print(f"torch.version.cuda {torch.version.cuda}")

if torch.version.cuda is None:
    print("torch is not a CUDA build", file=sys.stderr)
    sys.exit(1)
PY
}

case "${mode}" in
    wheel)
        echo "Installing PyTorch CUDA wheels from ${TORCH_INDEX_URL}"
        uv pip install \
            "torch==${TORCH_VERSION}" \
            "torchvision==${TORCHVISION_VERSION}" \
            "torchaudio==${TORCHAUDIO_VERSION}" \
            --index-url "${TORCH_INDEX_URL}"
        check_torch
        ;;
    cpu)
        echo "Installing PyTorch CPU wheels"
        uv pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu
        ;;
    preinstalled)
        echo "Using preinstalled PyTorch from base image"
        if ! check_torch; then
            cat >&2 <<'EOF'

No CUDA-enabled PyTorch was found in the base image.

On Linux ARM64/aarch64, PyTorch CUDA wheels are not generally published on the
standard PyTorch wheel indexes. Use the ARM64 compose override from this
repository so the build starts from an NVIDIA PyTorch CUDA image:

  docker compose -f docker-compose.yml -f docker-compose.arm64.yml build

That override sets:

  BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3
  TORCH_INSTALL_MODE=preinstalled

For Jetson, replace BASE_IMAGE with the NVIDIA L4T PyTorch image that matches
your JetPack release.
EOF
            exit 1
        fi
        ;;
    *)
        echo "Unknown TORCH_INSTALL_MODE: ${mode}" >&2
        exit 1
        ;;
esac
