#!/usr/bin/env bash
set -eu

cd /app/ComfyUI
mkdir -p custom_nodes custom_nodes/.disabled

torch_constraints="/tmp/comfyui-docker-torch-constraints.txt"
cat > "${torch_constraints}" <<'EOF'
torch>=2.7,<2.13
torchvision<0.28
triton>=3.7,<3.8
EOF

torch_stack_status() {
    python - <<'PY'
import importlib.metadata as metadata
from packaging.version import Version

names = ("torch", "torchvision", "triton")
for name in names:
    try:
        print(f"{name}=={metadata.version(name)}")
    except metadata.PackageNotFoundError:
        print(f"{name}==<missing>")
PY
}

assert_supported_torch_stack() {
    python - <<'PY'
import importlib.metadata as metadata
import sys

checks = {
    "torch": ("2.7", "2.13"),
    "torchvision": ("0", "0.28"),
}

try:
    from packaging.version import Version
except Exception as exc:
    print(f"Cannot validate torch package versions: {exc}", file=sys.stderr)
    sys.exit(1)

errors = []
for name, (minimum, maximum) in checks.items():
    try:
        version = Version(metadata.version(name).split("+", 1)[0])
    except Exception as exc:
        errors.append(f"{name}: {exc}")
        continue
    if not (Version(minimum) <= version < Version(maximum)):
        errors.append(f"{name}=={version} is outside supported range >= {minimum}, < {maximum}")

if errors:
    print("Unsupported CUDA/PyTorch stack after custom node dependency installation.", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)
PY
}

pin_torch_stack_if_needed() {
    if ! assert_supported_torch_stack; then
        echo "Repairing CUDA/PyTorch stack to a supported Torch family."
        uv pip install -c "${torch_constraints}" torch torchvision triton
        assert_supported_torch_stack
    fi
}

install_requirements_preserving_torch() {
    requirements="$1"
    if ! uv pip install -c "${torch_constraints}" -r "${requirements}"; then
        echo "Dependency resolver could not satisfy ${requirements} with a supported Torch stack." >&2
        echo "Refusing to continue because dependencies must be fully installed without upgrading Torch to an unsupported version." >&2
        exit 1
    fi

    if ! assert_supported_torch_stack; then
        echo "A custom node dependency attempted to move Torch outside the supported range." >&2
        echo "Current stack:" >&2
        torch_stack_status >&2
        exit 1
    fi
}

install_node() {
    repo_url="$1"
    folder="$2"
    target="custom_nodes/${folder}"

    if [ -d "${target}" ]; then
        echo "Skipping ${folder}; already exists"
        return
    fi

    echo "Installing ${folder}"
    git clone --depth 1 "${repo_url}" "${target}"

    requirements="${target}/requirements.txt"
    if [ -s "${requirements}" ]; then
        tmp_requirements="/tmp/${folder}.requirements.txt"
        grep -Evi "^(torch|torchvision|torchaudio|triton)([<>=~![:space:]]|$)" "${requirements}" \
            | grep -vi "triton-windows" \
            | grep -vi "decord" \
            | grep -vi "onnxruntime-gpu" \
            | grep -vi "onnxruntime-openvino" \
            | grep -vi "taichi" \
            | grep -vi "llama-cpp-python" > "${tmp_requirements}" || true
        if [ -s "${tmp_requirements}" ]; then
            install_requirements_preserving_torch "${tmp_requirements}"
        fi
        rm -f "${tmp_requirements}"
    fi

    if [ -s "${target}/install.py" ]; then
        python "${target}/install.py"
        pin_torch_stack_if_needed
    fi
}

install_node https://github.com/Comfy-Org/ComfyUI-Manager comfyui-manager
install_node https://github.com/yolain/ComfyUI-Easy-Use ComfyUI-Easy-Use
install_node https://github.com/Fannovel16/comfyui_controlnet_aux comfyui_controlnet_aux
install_node https://github.com/rgthree/rgthree-comfy rgthree-comfy
install_node https://github.com/MohammadAboulEla/ComfyUI-iTools comfyui-itools
install_node https://github.com/city96/ComfyUI-GGUF ComfyUI-GGUF
install_node https://github.com/gseth/ControlAltAI-Nodes controlaltai-nodes
install_node https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch comfyui-inpaint-cropandstitch
install_node https://github.com/1038lab/ComfyUI-RMBG comfyui-rmbg
install_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite comfyui-videohelpersuite
install_node https://github.com/shiimizu/ComfyUI-TiledDiffusion ComfyUI-TiledDiffusion
install_node https://github.com/kijai/ComfyUI-KJNodes comfyui-kjnodes
install_node https://github.com/kijai/ComfyUI-WanVideoWrapper ComfyUI-WanVideoWrapper
install_node https://github.com/1038lab/ComfyUI-QwenVL ComfyUI-QwenVL
install_node https://github.com/flybirdxx/ComfyUI-Qwen-TTS qwen3-tts-comfyui
install_node https://github.com/Saganaki22/ComfyUI-FishAudioS2 ComfyUI-fish-audio-s2
install_node https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler seedvr2_videoupscaler
install_node https://github.com/chflame163/ComfyUI_LayerStyle comfyui_layerstyle
install_node https://github.com/kijai/ComfyUI-WanAnimatePreprocess ComfyUI-WanAnimatePreprocess
install_node https://gitlab.com/pixaroma/ComfyUI-Pixaroma.git ComfyUI-Pixaroma
install_node https://github.com/yolain/ComfyUI-Easy-Sam3 comfyui-easy-sam3
install_node https://github.com/kijai/ComfyUI-SCAIL-Pose ComfyUI-SCAIL-Pose
install_node https://github.com/kijai/ComfyUI-MelBandRoFormer ComfyUI-MelBandRoFormer
