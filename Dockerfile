ARG BASE_IMAGE=nvidia/cuda:12.8.0-cudnn-devel-ubuntu24.04
FROM ${BASE_IMAGE}

ARG COMFYUI_REPO=https://github.com/Comfy-Org/ComfyUI.git
ARG COMFYUI_REF=master
ARG TORCH_VERSION=2.8.0
ARG TORCHVISION_VERSION=0.23.0
ARG TORCHAUDIO_VERSION=2.8.0
ARG TORCHAUDIO_BUILD_JOBS=""
ARG TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
ARG TORCH_INSTALL_MODE=auto
ARG UV_VERSION=0.9.7
ARG ONNXRUNTIME_MODE=auto
ARG ONNXRUNTIME_REF=v1.27.0
ARG ONNXRUNTIME_BUILD_JOBS=""
ARG LLAMA_CPP_MODE=auto
ARG LLAMA_CPP_REPO=https://github.com/JamePeng/llama-cpp-python.git
ARG INSTALL_ADDONS=""
ARG ADDON_BUILD_JOBS=1
ARG INSIGHTFACE_ACCEPT_LICENSE=1
ARG TRELLIS2_DOWNLOAD_DINOV3=0

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    UV_HTTP_TIMEOUT=300 \
    UV_CONCURRENT_DOWNLOADS=4 \
    UV_INSTALL_RETRIES=3 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    LD_LIBRARY_PATH=/opt/venv/lib/python3.12/site-packages/torch/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cudnn/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cublas/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cusparselt/lib:/opt/venv/lib/python3.12/site-packages/nvidia/nccl/lib:/opt/venv/lib/python3.12/site-packages/nvidia/nvshmem/lib:/usr/local/cuda/lib64:/usr/local/cuda/targets/sbsa-linux/lib:/usr/local/cuda/targets/aarch64-linux/lib:/usr/local/cuda/targets/x86_64-linux/lib:/usr/local/cuda-13.0/lib64:/usr/local/cuda-13.0/targets/sbsa-linux/lib:/usr/local/cuda-13.0/targets/aarch64-linux/lib:/usr/local/cuda-13.0/targets/x86_64-linux/lib:/usr/local/cuda-12.9/lib64:/usr/local/cuda-12.9/targets/sbsa-linux/lib:/usr/local/cuda-12.9/targets/aarch64-linux/lib:/usr/local/cuda-12.8/lib64:/usr/local/cuda-12.8/targets/sbsa-linux/lib:/usr/local/cuda-12.8/targets/aarch64-linux/lib:/usr/local/cuda-12.8/targets/x86_64-linux/lib:/usr/lib/aarch64-linux-gnu:/usr/lib/x86_64-linux-gnu \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    HF_HOME=/app/ComfyUI/models/.cache/huggingface \
    HUGGINGFACE_HUB_CACHE=/app/ComfyUI/models/.cache/huggingface/hub \
    TRANSFORMERS_CACHE=/app/ComfyUI/models/.cache/huggingface/transformers \
    TORCH_HOME=/app/ComfyUI/models/.cache/torch \
    AUX_ANNOTATOR_CKPTS_PATH=/app/ComfyUI/models/controlnet_aux/ckpts

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        ffmpeg \
        git \
        libavcodec-dev \
        libavdevice-dev \
        libavfilter-dev \
        libavformat-dev \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        libavutil-dev \
        libsndfile1 \
        libswresample-dev \
        libswscale-dev \
        libx11-dev \
        libxrandr-dev \
        libxinerama-dev \
        libxcursor-dev \
        libxi-dev \
        libgl1-mesa-dev \
        libsm6 \
        libxext6 \
        ninja-build \
        pkg-config \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        unzip \
        sox \
    && rm -rf /var/lib/apt/lists/*

ARG NUMPY_VERSION=1.26.4
ARG SCIPY_VERSION=1.15.3
ENV NUMPY_VERSION=${NUMPY_VERSION} \
    SCIPY_VERSION=${SCIPY_VERSION}

RUN python3 -m venv --system-site-packages /opt/venv \
    && python -m pip install --upgrade pip \
    && python -m pip install "uv==${UV_VERSION}"

COPY docker/install_torch.sh /usr/local/bin/install_torch.sh
RUN chmod +x /usr/local/bin/install_torch.sh \
    && TORCH_INSTALL_MODE="${TORCH_INSTALL_MODE}" \
       TORCH_VERSION="${TORCH_VERSION}" \
       TORCHVISION_VERSION="${TORCHVISION_VERSION}" \
       TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION}" \
       TORCH_INDEX_URL="${TORCH_INDEX_URL}" \
       /usr/local/bin/install_torch.sh

RUN git clone "${COMFYUI_REPO}" ComfyUI \
    && cd ComfyUI \
    && git checkout "${COMFYUI_REF}"

WORKDIR /app/ComfyUI

RUN uv pip install scikit-build-core onnx flet chardet==5.2.0 \
    && uv pip install \
        stringzilla==3.12.6 \
        transformers==4.57.6 \
        scipy==${SCIPY_VERSION} \
        pygit2 \
        av==16.0.1 \
    && if [ "${TORCH_INSTALL_MODE}" = "preinstalled" ]; then \
        grep -Evi "^(torch|torchvision|torchaudio|torchsde|kornia|spandrel|comfy-angle)([<>=~![:space:]]|$)" requirements.txt > /tmp/comfyui-requirements.txt; \
        uv pip install -r /tmp/comfyui-requirements.txt; \
        uv pip install trampoline kornia-rs; \
        uv pip install --no-deps torchsde "kornia==0.7.4" spandrel comfy-angle; \
        rm -f /tmp/comfyui-requirements.txt; \
    else \
        uv pip install -r requirements.txt; \
    fi \
    && uv pip install pylatexenc python-ffmpeg pydantic \
    && uv pip install --force-reinstall --no-deps "numpy==${NUMPY_VERSION}" "scipy==${SCIPY_VERSION}"

COPY docker/install_onnxruntime.sh /usr/local/bin/install_onnxruntime.sh
COPY docker/install_llama_cpp.sh /usr/local/bin/install_llama_cpp.sh
RUN chmod +x /usr/local/bin/install_onnxruntime.sh /usr/local/bin/install_llama_cpp.sh \
    && ONNXRUNTIME_MODE="${ONNXRUNTIME_MODE}" ONNXRUNTIME_REF="${ONNXRUNTIME_REF}" ONNXRUNTIME_BUILD_JOBS="${ONNXRUNTIME_BUILD_JOBS:-${ADDON_BUILD_JOBS}}" /usr/local/bin/install_onnxruntime.sh \
    && LLAMA_CPP_MODE="${LLAMA_CPP_MODE}" LLAMA_CPP_REPO="${LLAMA_CPP_REPO}" /usr/local/bin/install_llama_cpp.sh

COPY docker/install_custom_nodes.sh /usr/local/bin/install_custom_nodes.sh
COPY docker/disable_broken_flash_attn.py /usr/local/bin/disable_broken_flash_attn.py
COPY docker/install_matching_cuda_toolkit.sh /usr/local/bin/install_matching_cuda_toolkit.sh
COPY docker/install_matching_triton.py /usr/local/bin/install_matching_triton.py
COPY docker/check_cuda_stack.py /usr/local/bin/check_cuda_stack.py
COPY docker/check_cuda_install.sh /usr/local/bin/check_cuda_install.sh
COPY Helper-CEI-NEXT-unix.zip /tmp/Helper-CEI-NEXT-unix.zip
RUN chmod +x /usr/local/bin/install_custom_nodes.sh \
    /usr/local/bin/install_matching_cuda_toolkit.sh \
    /usr/local/bin/check_cuda_install.sh \
    && /usr/local/bin/install_custom_nodes.sh \
    && python /usr/local/bin/disable_broken_flash_attn.py \
    && python /usr/local/bin/install_matching_triton.py \
    && /usr/local/bin/install_matching_cuda_toolkit.sh

COPY docker/install_addons.sh /usr/local/bin/install_addons.sh
RUN chmod +x /usr/local/bin/install_addons.sh \
    && INSTALL_ADDONS="${INSTALL_ADDONS}" \
    ADDON_BUILD_JOBS="${ADDON_BUILD_JOBS}" \
    INSIGHTFACE_ACCEPT_LICENSE="${INSIGHTFACE_ACCEPT_LICENSE}" \
    TRELLIS2_DOWNLOAD_DINOV3="${TRELLIS2_DOWNLOAD_DINOV3}" \
    /usr/local/bin/install_addons.sh

COPY docker/finalize_cuda_python_stack.sh /usr/local/bin/finalize_cuda_python_stack.sh
RUN chmod +x /usr/local/bin/finalize_cuda_python_stack.sh \
    && TORCHAUDIO_VERSION="${TORCHAUDIO_VERSION}" \
    TORCHAUDIO_BUILD_JOBS="${TORCHAUDIO_BUILD_JOBS:-${ADDON_BUILD_JOBS}}" \
    ONNXRUNTIME_MODE="${ONNXRUNTIME_MODE}" \
    ONNXRUNTIME_REF="${ONNXRUNTIME_REF}" \
    ONNXRUNTIME_BUILD_JOBS="${ONNXRUNTIME_BUILD_JOBS:-${ADDON_BUILD_JOBS}}" \
    ADDON_BUILD_JOBS="${ADDON_BUILD_JOBS}" \
    /usr/local/bin/finalize_cuda_python_stack.sh

EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8188/', timeout=3)"

CMD ["python", "main.py", "--listen", "0.0.0.0", "--port", "8188"]
