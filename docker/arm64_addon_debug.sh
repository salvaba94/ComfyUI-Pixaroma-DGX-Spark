#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

addons="${INSTALL_ADDONS:-SageAttention-NEXT,Trellis2,Nunchaku120-NEXT}"
addon_build_jobs="${ADDON_BUILD_JOBS:-1}"
base_tag="${BASE_TAG:-comfyui-easy-install:arm64-base}"
final_tag="${FINAL_TAG:-comfyui-easy-install:cuda}"
container_name="${ADDON_CONTAINER_NAME:-comfyui-addon-build}"
runtime_ld_path="/opt/venv/lib/python3.12/site-packages/torch/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cudnn/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cublas/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cusparselt/lib:/opt/venv/lib/python3.12/site-packages/nvidia/nccl/lib:/opt/venv/lib/python3.12/site-packages/nvidia/nvshmem/lib:/usr/local/cuda/lib64:/usr/local/cuda/targets/sbsa-linux/lib:/usr/local/cuda/targets/aarch64-linux/lib:/usr/local/cuda/targets/x86_64-linux/lib:/usr/local/cuda-13.0/lib64:/usr/local/cuda-13.0/targets/sbsa-linux/lib:/usr/local/cuda-13.0/targets/aarch64-linux/lib:/usr/local/cuda-13.0/targets/x86_64-linux/lib:/usr/local/cuda-12.9/lib64:/usr/local/cuda-12.9/targets/sbsa-linux/lib:/usr/local/cuda-12.9/targets/aarch64-linux/lib:/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/sbsa-linux/lib:/usr/local/cuda-12.8/targets/aarch64-linux/lib:/usr/local/cuda-12.8/targets/x86_64-linux/lib:/usr/lib/aarch64-linux-gnu:/usr/lib/x86_64-linux-gnu"

compose_files=(-f docker-compose.yml -f docker-compose.arm64.yml)

if [ "${REUSE_BASE_IMAGE:-0}" = "1" ]; then
    echo "Reusing existing ARM64 base image: ${base_tag}"
else
    echo "Building ARM64 base image without add-ons."
    INSTALL_ADDONS="" docker compose "${compose_files[@]}" build \
        --progress=plain \
        --build-arg INSTALL_ADDONS="" \
        --build-arg ADDON_BUILD_JOBS="${addon_build_jobs}"

    docker tag "${final_tag}" "${base_tag}"
fi

echo "Creating reusable add-on build container: ${container_name}"
docker rm -f "${container_name}" >/dev/null 2>&1 || true
docker create \
    --name "${container_name}" \
    --gpus all \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    -v "${repo_root}/models:/app/ComfyUI/models" \
    -v "${repo_root}/input:/app/ComfyUI/input" \
    -v "${repo_root}/output:/app/ComfyUI/output" \
    -v "${repo_root}/user:/app/ComfyUI/user" \
    -e INSTALL_ADDONS="${addons}" \
    -e ADDON_BUILD_JOBS="${addon_build_jobs}" \
    -e LD_LIBRARY_PATH="${runtime_ld_path}" \
    "${base_tag}" \
    sleep infinity >/dev/null

docker start "${container_name}" >/dev/null
docker cp docker/install_addons.sh "${container_name}:/usr/local/bin/install_addons.sh"
docker exec "${container_name}" chmod +x /usr/local/bin/install_addons.sh

echo "Installing add-ons inside ${container_name}: ${addons}"
docker exec "${container_name}" bash -lc \
    "INSTALL_ADDONS='${addons}' ADDON_BUILD_JOBS='${addon_build_jobs}' /usr/local/bin/install_addons.sh"

echo "Validating add-on imports inside ${container_name}."
docker exec "${container_name}" env INSTALL_ADDONS="${addons}" python - <<'PY'
import importlib
import os

selected = {item.strip() for item in os.environ["INSTALL_ADDONS"].split(",") if item.strip()}
modules = []

if any(item.startswith(("SageAttention", "CachyOSSage")) for item in selected):
    modules.append("sageattention")
if any(item.startswith("FlashAttention") for item in selected):
    modules.append("flash_attn")
if any(item.startswith("Insightface") for item in selected):
    modules.extend(["insightface", "facexlib"])
if any(item.startswith("Trellis2") for item in selected):
    modules.extend([
        "open3d",
        "nvdiffrast",
        "cumesh",
        "flex_gemm",
        "nvdiffrec_render.renderutils._C",
        "o_voxel",
    ])
if any(item.startswith("Nunchaku") for item in selected):
    modules.extend(["nunchaku._C", "nunchaku"])

for module in modules:
    importlib.import_module(module)
    print(f"{module}: ok")
PY

echo "Committing successful add-on image to ${final_tag}."
docker commit --change "ENV LD_LIBRARY_PATH=${runtime_ld_path}" "${container_name}" "${final_tag}" >/dev/null

echo "Starting ComfyUI from ${final_tag}."
docker compose "${compose_files[@]}" up -d --no-build --force-recreate
