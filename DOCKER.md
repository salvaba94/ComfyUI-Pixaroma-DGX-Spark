# Docker Usage

This is the Dockerized Linux/NVIDIA install path for ComfyUI-Easy-Install.
It builds ComfyUI with CUDA support, bakes in the curated Pixaroma/default
custom-node set, and keeps user data in host-mounted folders.

The default Docker profile targets CUDA 12.8 for standard x86_64 NVIDIA Linux
hosts because that is the stable path most likely to build cleanly with the
packaged PyTorch CUDA wheels. CUDA 13 remains available as an explicit advanced
build profile. Native ARM64 uses a separate override because PyTorch CUDA wheels
are not published for ARM64 in the same way.

## NVIDIA GPU

On a normal Linux host, install the NVIDIA driver and NVIDIA Container Toolkit
first. Verify the host GPU before building:

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

Then build and start ComfyUI:

```bash
cd ComfyUI-Easy-Install
docker compose up --build
```

The default CUDA Compose profile builds with:

```text
INSTALL_ADDONS=all-cuda
```

That installs the runtime CUDA add-ons from the helper archive: InsightFace,
SageAttention, FlashAttention, Nunchaku, and Trellis2. If an ARM64 wheel is not
available, the Docker build compiles the native dependency from source and then
validates the import. Missing add-ons or missing native modules are build
failures, not silent fallbacks.

On native ARM64, do not use the default plain CUDA image. Use the ARM64 override
shown below so the build starts from a PyTorch CUDA image.

Open:

```text
http://localhost:8188
```

Check the CUDA stack inside the image:

```bash
docker compose run --rm comfyui python /usr/local/bin/check_cuda_stack.py
```

Expected CUDA check output includes `torch.cuda.is_available: True`, a CUDA
version from torch, `nvcc` from the devel image, and an NVIDIA driver version
from `nvidia-smi`.

## What Is Baked In

The image installs ComfyUI, CUDA PyTorch, ComfyUI requirements, GPU helper
packages, and the curated custom-node baseline used by ComfyUI-Easy-Install.
This includes ComfyUI Manager, Easy-Use, ControlNet Aux, rgthree, iTools, GGUF,
ControlAltAI, Inpaint CropAndStitch, RMBG, VideoHelperSuite, TiledDiffusion,
KJNodes, WanVideoWrapper, QwenVL, Qwen TTS, FishAudioS2, SeedVR2, LayerStyle,
WanAnimatePreprocess, Pixaroma, Easy-Sam3, SCAIL-Pose, and MelBandRoFormer.

The default CUDA Compose profile also requests the curated runtime CUDA add-on
set with `INSTALL_ADDONS=all-cuda`. That set includes InsightFace,
SageAttention, FlashAttention, Nunchaku, and Trellis2. On ARM64, native
dependencies are compiled from source when a compatible wheel is not available.

To build only the baseline image, override the add-on list:

```bash
INSTALL_ADDONS="" docker compose build
```

The helper archive is still extracted into the image at:

```text
/app/ComfyUI-Easy-Install/Add-Ons
```

To run add-on installers during the Docker build, pass a comma-separated list
of script names without the `Add-Ons/` prefix:

```bash
docker compose build --build-arg INSTALL_ADDONS=SageAttention-NEXT,Nunchaku120-NEXT
```

Use `INSTALL_ADDONS=""` to build only the baseline custom-node image, or
`INSTALL_ADDONS=all-cuda` to request the curated CUDA add-on set.

Add-on scripts run from `/app/ComfyUI-Easy-Install` with `ComfyUI` linked to
`/app/ComfyUI` and `python_embeded/python` wrapped to `/opt/venv/bin/python`.
Some add-ons are still platform-sensitive and may require matching CUDA,
PyTorch, GPU architecture, or extra model/license setup. The Docker add-on
wrapper validates native add-ons after each installer runs; if an add-on leaves
missing Python modules behind, the image build fails instead of producing a
container that starts with broken nodes.

Nunchaku may compile from source on ARM64. The Docker add-on wrapper limits
native build parallelism to one job by default to avoid RAM exhaustion during
that compile. On a larger builder, raise it explicitly:

```bash
docker compose build \
  --build-arg INSTALL_ADDONS=Nunchaku120-NEXT \
  --build-arg ADDON_BUILD_JOBS=2
```

Trellis2 is especially sensitive on ARM64. The packaged Trellis2 Linux wheels
inside the helper archive are currently `linux_x86_64` wheels, so an ARM64 build
must successfully build/install Trellis2 native modules such as `cumesh`,
`nvdiffrast`, `flex_gemm`, and `o_voxel` from source. If compilation or import
validation fails, the Docker build fails rather than leaving a half-installed
`ComfyUI-Trellis2` node.

## Persistent Data

The Compose file mounts these folders from the repo directory:

- `models`
- `input`
- `output`
- `user`
- `workflows`

The default custom nodes are baked into the image. Avoid mounting
`custom_nodes` unless you intentionally want to replace the baked-in node set.

The `workflows` folder is mounted to:

```text
/app/ComfyUI/user/default/workflows
```

Model files should live under `models`, which is mounted to:

```text
/app/ComfyUI/models
```

Runtime auto-download caches are also redirected into `models` so Hugging Face,
Transformers, Torch Hub, and ControlNet Aux downloads persist on the host:

```text
HF_HOME=/app/ComfyUI/models/.cache/huggingface
HUGGINGFACE_HUB_CACHE=/app/ComfyUI/models/.cache/huggingface/hub
TRANSFORMERS_CACHE=/app/ComfyUI/models/.cache/huggingface/transformers
TORCH_HOME=/app/ComfyUI/models/.cache/torch
AUX_ANNOTATOR_CKPTS_PATH=/app/ComfyUI/models/controlnet_aux/ckpts
```

## Build Arguments

The Dockerfile supports these build arguments:

- `BASE_IMAGE`
- `COMFYUI_REPO`
- `COMFYUI_REF`
- `TORCH_VERSION`
- `TORCHVISION_VERSION`
- `TORCHAUDIO_VERSION`
- `TORCH_INDEX_URL`
- `TORCH_INSTALL_MODE`: `auto`, `wheel`, `preinstalled`, or `cpu`
- `UV_VERSION`
- `ONNXRUNTIME_MODE`: `auto`, `wheel`, `source`, or `cpu`
- `ONNXRUNTIME_REF`
- `LLAMA_CPP_MODE`: `auto`, `wheel`, `source`, or `cpu`
- `LLAMA_CPP_REPO`
- `INSTALL_ADDONS`: comma-separated add-on script names to run at build time
- `ADDON_BUILD_JOBS`: native build jobs for add-ons; defaults to `1` for low-memory Nunchaku builds

The default CUDA 12.8 profile uses:

```text
BASE_IMAGE=nvidia/cuda:12.8.0-cudnn-devel-ubuntu24.04
TORCH_VERSION=2.8.0
TORCHVISION_VERSION=0.23.0
TORCHAUDIO_VERSION=2.8.0
TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
```

Build with a different ComfyUI ref if needed:

```bash
docker compose build --build-arg COMFYUI_REF=master
```

## CUDA 13 Profile

Use CUDA 13 only when the host NVIDIA driver supports it and the selected
PyTorch CUDA 13 wheels are available for your platform.

```bash
docker compose build \
  --build-arg BASE_IMAGE=nvidia/cuda:13.0.1-cudnn-devel-ubuntu24.04 \
  --build-arg TORCH_VERSION=2.9.1 \
  --build-arg TORCHVISION_VERSION=0.24.1 \
  --build-arg TORCHAUDIO_VERSION=2.9.1 \
  --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu130
```

## ARM64 / aarch64

On x86_64, `TORCH_INSTALL_MODE=auto` installs CUDA PyTorch wheels from
`TORCH_INDEX_URL`. On ARM64/aarch64, `auto` expects CUDA-enabled PyTorch to
already exist in `BASE_IMAGE`, because the normal PyTorch CUDA wheel indexes do
not publish the same Linux ARM64 CUDA wheels.

For native ARM64 CUDA, use the provided override:

```bash
docker compose -f docker-compose.arm64.yml build
docker compose -f docker-compose.arm64.yml up
```

The override uses:

```text
BASE_IMAGE=nvcr.io/nvidia/pytorch:25.06-py3
TORCH_INSTALL_MODE=preinstalled
ONNXRUNTIME_MODE=source
```

The ARM64 override compiles CUDA-enabled ONNX Runtime from source. The source
build passes `FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER` so ONNX Runtime uses
its fetched protobuf/utf8 dependencies instead of the NVIDIA base image system
CMake packages, which can reference missing `utf8_range` archives. In
`TORCH_INSTALL_MODE=preinstalled`, ComfyUI requirements are installed so the
NVIDIA base image PyTorch stack is preserved instead of pulling PyPI torch.

If you see `Using preinstalled PyTorch from base image` followed by
`No module named torch`, you are building natively on ARM64 with a plain CUDA
base image. Use the ARM64 override above, or provide another ARM64 base image
that already contains CUDA-enabled PyTorch.

For Jetson, replace `BASE_IMAGE` in `docker-compose.arm64.yml` with the NVIDIA
L4T PyTorch image that matches your JetPack release.

## GPU Helper Packages

`ONNXRUNTIME_MODE=auto` installs the published `onnxruntime-gpu` wheel on
x86_64. On ARM64/aarch64 it compiles CUDA-enabled ONNX Runtime from source,
because PyPI does not publish Linux ARM64 GPU wheels for Python 3.12.

The source build can take a long time and needs a CUDA devel image with `nvcc`
and cuDNN headers. Override `BASE_IMAGE` if your platform needs a different
NVIDIA CUDA image.

`LLAMA_CPP_MODE=auto` installs a CUDA wheel on x86_64. On ARM64 or other
platforms it builds `llama-cpp-python` from source with `GGML_CUDA=on`. Use
`LLAMA_CPP_MODE=source` to force a CUDA source build on x86_64 too.

## Proxmox LXC

If Docker runs inside a Proxmox LXC, configure GPU passthrough on the Proxmox
host first. The LXC should be privileged, nesting should be enabled, and
`/dev/nvidia*` devices must be visible inside the LXC.

You can use:

```bash
sudo bash setup-gpu-passthrough.sh <container_id>
```

Inside the LXC, verify:

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

Then run:

```bash
docker compose up --build
```

## CPU Only

CPU mode is much slower, but useful for smoke testing:

```bash
docker compose -f docker-compose.cpu.yml up --build
```

## Validation Checklist

Run these checks after changing Docker dependencies:

```bash
docker compose build --no-cache
docker compose run --rm comfyui python /usr/local/bin/check_cuda_stack.py
docker compose up
```

Then confirm the UI loads at `http://localhost:8188`, ComfyUI Manager appears,
the baked custom nodes are available, and files placed under `models`, `input`,
`output`, or `user` survive container recreation.
