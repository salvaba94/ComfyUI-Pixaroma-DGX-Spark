#!/usr/bin/env bash
set -eu

cd /app/ComfyUI
mkdir -p custom_nodes custom_nodes/.disabled models/checkpoints

torch_constraints="/tmp/comfyui-docker-torch-constraints.txt"
numpy_version="${NUMPY_VERSION:-1.26.4}"
scipy_version="${SCIPY_VERSION:-1.15.3}"

restore_numpy_abi_pin() {
    echo "[Deps] Restoring numeric ABI pins: numpy==${numpy_version}, scipy==${scipy_version}"
    uv pip install --force-reinstall --no-deps "numpy==${numpy_version}" "scipy==${scipy_version}"
}

log_comfy3d() {
    echo "[Comfy3D] $*"
}

write_torch_constraints() {
    python - "${torch_constraints}" <<'PY'
from importlib import metadata
from pathlib import Path
import sys

packages = ("torch", "torchvision", "torchaudio", "triton")
lines = []
for name in packages:
    try:
        lines.append(f"{name}=={metadata.version(name)}")
    except metadata.PackageNotFoundError:
        pass

Path(sys.argv[1]).write_text("\n".join(lines) + ("\n" if lines else ""))
PY
}

write_torch_constraints

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
    python - "${torch_constraints}" <<'PY'
import importlib.metadata as metadata
import sys
from pathlib import Path

errors = []
for line in Path(sys.argv[1]).read_text().splitlines():
    if "==" not in line:
        continue
    name, expected = line.split("==", 1)
    try:
        current = metadata.version(name)
    except Exception as exc:
        errors.append(f"{name}: {exc}")
        continue
    if current != expected:
        errors.append(f"{name} changed from {expected} to {current}")

if errors:
    print("Docker CUDA/PyTorch stack changed during custom node dependency installation.", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    sys.exit(1)
PY
}

pin_torch_stack_if_needed() {
    if ! assert_supported_torch_stack; then
        echo "A custom node attempted to replace the Docker CUDA/PyTorch stack." >&2
        echo "Current stack:" >&2
        torch_stack_status >&2
        exit 1
    fi
}

filter_node_requirements() {
    local input="$1"
    local output="$2"

    grep -Evi "^(torch|torchvision|torchaudio|triton|xformers)([<>=~![:space:]]|$)" "${input}" \
        | grep -Evi "^(nvidia-|cuda-|cuda_|cuda-toolkit|cuda-bindings|cuda-pathfinder)([A-Za-z0-9_.-]*)([<>=~![:space:]]|$)" \
        | grep -vi "triton-windows" \
        | grep -vi "decord" \
        | grep -Evi "^onnxruntime([<>=~![:space:]]|$)" \
        | grep -vi "onnxruntime-gpu" \
        | grep -vi "onnxruntime-openvino" \
        | grep -vi "taichi" \
        | grep -Evi "^numpy([<>=~![:space:]]|$)" \
        | grep -vi "llama-cpp-python" > "${output}" || true
}

patch_node_install_script() {
    local folder="$1"
    local target="$2"
    local install_py="${target}/install.py"

    if [ ! -s "${install_py}" ]; then
        return
    fi

    case "${folder}" in
        ComfyUI-fish-audio-s2)
            python - "${install_py}" <<'PATCHPY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "DOCKER CUDA STACK PATCH" not in text:
    text = re.sub(
        r'(print_header\("PyTorch lost CUDA.*?)(\n\s*restore_pytorch_cuda\(\))',
        r'\1\n        print("[FishAudioS2] DOCKER CUDA STACK PATCH: skipping PyTorch restore during image build; CUDA is validated at runtime.")',
        text,
        flags=re.S,
    )
    text = re.sub(
        r'(\n\s*)restore_pytorch_cuda\(\)',
        r'\1print("[FishAudioS2] DOCKER CUDA STACK PATCH: skipping PyTorch restore during image build; CUDA is validated at runtime.")',
        text,
    )
    path.write_text(text)
PATCHPY
            ;;
    esac
}

run_node_install_script() {
    local folder="$1"
    local target="$2"
    local arch="$(uname -m)"

    case "${folder}" in
        ComfyUI-fish-audio-s2)
            if [ "${arch}" = "aarch64" ] || [ "${arch}" = "arm64" ]; then
                echo "[FishAudioS2] ARM64 Docker build: skipping upstream install.py because it rewrites PyTorch/torchaudio when no build-time GPU is visible."
                uv pip install --no-deps "descript-audiotools>=0.7.2" "descript-audio-codec"
                restore_numpy_abi_pin
                pin_torch_stack_if_needed
                return
            fi
            ;;
    esac

    python "${target}/install.py"
    restore_numpy_abi_pin
    pin_torch_stack_if_needed
}

install_fish_audio_s2_runtime_deps() {
    echo "[FishAudioS2] Pinning TensorBoard to match the Docker protobuf runtime."
    uv pip install --force-reinstall --no-deps "protobuf==5.29.6" "tensorboard==2.20.0"
    python - <<'PY'
import audiotools
import tensorboard.compat.proto.event_pb2
print("FishAudioS2 TensorBoard/protobuf validation passed.")
PY
}

install_decord_from_source_if_needed() {
    if python - <<'PY'
import decord
print(f"decord validation passed: {decord.__version__}")
PY
    then
        return
    fi

    echo "[RMBG] decord wheel is unavailable for this Python/ARM64 stack; compiling from source."
    local build_root="/tmp/decord-src"
    rm -rf "${build_root}"
    git clone --recursive https://github.com/dmlc/decord "${build_root}"

    python - "${build_root}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
common = root / "src" / "video" / "ffmpeg" / "ffmpeg_common.h"
text = common.read_text()
if "#include <libavcodec/bsf.h>" not in text:
    text = text.replace(
        "#include <libavcodec/avcodec.h>",
        "#include <libavcodec/avcodec.h>\n#include <libavcodec/bsf.h>",
    )
    common.write_text(text)

reader = root / "src" / "video" / "video_reader.cc"
text = reader.read_text()
text = text.replace("AVCodec *dec;", "const AVCodec *dec;")
text = text.replace("AVCodec* dec;", "const AVCodec* dec;")
reader.write_text(text)
PY

    mkdir -p "${build_root}/build"
    cd "${build_root}/build"
    if cmake .. \
        -DUSE_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCUDA_TOOLKIT_ROOT_DIR="${CUDA_HOME:-/usr/local/cuda}" \
        -DCMAKE_CUDA_ARCHITECTURES="${DECORD_CUDA_ARCHITECTURES:-87;90;120}" \
        && cmake --build . --parallel "${ADDON_BUILD_JOBS:-1}"
    then
        echo "[RMBG] decord CUDA build completed."
    else
        echo "[RMBG] decord CUDA build failed, likely because libnvcuvid/NVDEC headers are not present; building CPU decoder."
        rm -rf "${build_root}/build"
        mkdir -p "${build_root}/build"
        cd "${build_root}/build"
        cmake .. -DUSE_CUDA=OFF -DCMAKE_BUILD_TYPE=Release
        cmake --build . --parallel "${ADDON_BUILD_JOBS:-1}"
    fi

    cd "${build_root}/python"
    python -m pip install --no-cache-dir --no-warn-script-location .
    cd /app/ComfyUI
    python - <<'PY'
import decord
print(f"decord source build validation passed: {decord.__version__}")
PY
}

install_requirements_preserving_torch() {
    requirements="$1"
    local attempt=1
    local max_attempts="${UV_INSTALL_RETRIES:-3}"
    local install_args=()
    local arch="$(uname -m)"

    if [ "${arch}" = "aarch64" ] || [ "${arch}" = "arm64" ]; then
        install_args+=(--no-deps)
        echo "Installing ${requirements} without transitive dependency resolution on ARM64 to preserve the Docker CUDA/PyTorch stack."
    fi

    until uv pip install "${install_args[@]}" -r "${requirements}"; do
        if [ "${attempt}" -ge "${max_attempts}" ]; then
            echo "Dependency resolver could not satisfy ${requirements} while preserving the Docker CUDA/PyTorch stack." >&2
            echo "Refusing to continue because ARM builds must compile against the image CUDA stack." >&2
            exit 1
        fi

        attempt=$((attempt + 1))
        echo "Retrying dependency install for ${requirements} (${attempt}/${max_attempts}) after a transient failure."
        sleep 5
    done

    restore_numpy_abi_pin

    if ! assert_supported_torch_stack; then
        echo "A custom node dependency attempted to replace the Docker CUDA/PyTorch stack." >&2
        echo "Current stack:" >&2
        torch_stack_status >&2
        exit 1
    fi
}

filter_comfy3d_requirements() {
    local requirements="$1"
    local output="$2"
    local arch="$(uname -m)"

    filter_node_requirements "${requirements}" "${output}"
    local filtered="${output}.filtered"
    grep -Evi "^(cumm|spconv-cu[0-9]*)([<>=~![:space:]]|$)" "${output}" > "${filtered}" || true
    mv "${filtered}" "${output}"

    if [ "${arch}" = "aarch64" ] || [ "${arch}" = "arm64" ]; then
        local tmp_output="${output}.arm64"
        grep -Evi "^(open3d|xformers|gpytoolbox)([<>=~![:space:]]|$)" "${output}" > "${tmp_output}" || true
        mv "${tmp_output}" "${output}"
        echo "/tmp/gpytoolbox-arm64" >> "${output}"
    fi
}

install_comfy3d_cumm_arm64() {
    local arch="$(uname -m)"
    if [ "${arch}" != "aarch64" ] && [ "${arch}" != "arm64" ]; then
        return
    fi

    local cumm_ref="${COMFY3D_CUMM_REF:-v0.7.11}"
    local cumm_src="/tmp/cumm-arm64-source"
    local cumm_archs="${COMFY3D_CUMM_CUDA_ARCH_LIST:-8.0;8.6;9.0}"

    log_comfy3d "Building cumm ${cumm_ref} from source for ARM64 spconv support."
    python -m pip install --no-cache-dir --no-warn-script-location --no-deps ccimport
    rm -rf "${cumm_src}"
    git clone --depth 1 --branch "${cumm_ref}" https://github.com/FindDefinition/cumm "${cumm_src}"
    (
        cd "${cumm_src}"
        CUMM_DISABLE_JIT=1 \
        CUMM_CUDA_ARCH_LIST="${cumm_archs}" \
        CPATH="${cumm_src}/include${CPATH:+:${CPATH}}" \
        CPLUS_INCLUDE_PATH="${cumm_src}/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}" \
        MAX_JOBS="${MAX_JOBS:-${ADDON_BUILD_JOBS:-1}}" \
        python -m pip install --no-cache-dir --no-build-isolation --no-deps .
    )

    python - <<'PY'
from pathlib import Path
import site

site_packages = Path(site.getsitepackages()[0])
shim = site_packages / "sitecustomize.py"
snippet = r'''

# Compatibility shim for cumm 0.7.x pybind exports on Python 3.12/aarch64.
try:
    import sys
    import cumm.core_cc as _cumm_core_cc
    if hasattr(_cumm_core_cc, "cumm"):
        _nested = _cumm_core_cc.cumm
        if hasattr(_nested, "tensorview_bind") and not hasattr(_cumm_core_cc, "tensorview_bind"):
            _cumm_core_cc.tensorview_bind = _nested.tensorview_bind
            sys.modules.setdefault("cumm.core_cc.tensorview_bind", _nested.tensorview_bind)
        if hasattr(_nested, "csrc") and not hasattr(_cumm_core_cc, "csrc"):
            _cumm_core_cc.csrc = _nested.csrc
            sys.modules.setdefault("cumm.core_cc.csrc", _nested.csrc)
            if hasattr(_nested.csrc, "arrayref"):
                sys.modules.setdefault("cumm.core_cc.csrc.arrayref", _nested.csrc.arrayref)
except Exception:
    pass
'''

existing = shim.read_text() if shim.exists() else ""
if "Compatibility shim for cumm 0.7.x pybind exports" not in existing:
    shim.write_text(existing + snippet)
PY

    python - <<'PY'
import cumm.core_cc
import cumm.tensorview
print("cumm source build validation passed.")
PY
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

    local requirements="${target}/requirements.txt"
    if [ -s "${requirements}" ]; then
        local tmp_requirements="/tmp/${folder}.requirements.txt"
        filter_node_requirements "${requirements}" "${tmp_requirements}"
        if [ -s "${tmp_requirements}" ]; then
            install_requirements_preserving_torch "${tmp_requirements}"
        fi
        rm -f "${tmp_requirements}"
    fi

    if [ -s "${target}/install.py" ]; then
        patch_node_install_script "${folder}" "${target}"
        run_node_install_script "${folder}" "${target}"
    fi
}

prepare_gpytoolbox_arm64() {
    local arch="$(uname -m)"
    if [ "${arch}" != "aarch64" ] && [ "${arch}" != "arm64" ]; then
        return
    fi

    log_comfy3d "Preparing ARM64 gpytoolbox source patch."
    local gpy_target="/tmp/gpytoolbox-arm64"
    rm -rf "${gpy_target}"
    git clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/sgsellan/gpytoolbox.git "${gpy_target}"

    python - "${gpy_target}" <<'PATCHPY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
cmake = root / "CMakeLists.txt"
text = cmake.read_text()
replacements = {
    "# Include webgpu\ninclude(webgpu)\ninclude(glfw3webgpu)\nif(TARGET webgpu AND TARGET glfw3webgpu)\n\tadd_compile_definitions(GL_AVAILABLE)\n\tset(GL_LIBS webgpu glfw3webgpu)\nelse()\n\tset(GL_LIBS \"\")\nendif()\n": "set(GL_LIBS \"\")\n",
    "\tsrc/cpp/reach_for_the_arcs/outside_points_from_rasterization.h\n": "",
    "\tsrc/cpp/reach_for_the_arcs/outside_points_from_rasterization.cpp\n": "",
    '\t"${CMAKE_CURRENT_SOURCE_DIR}/src/cpp/reach_for_the_arcs/binding_outside_points_from_rasterization.cpp"\n': "",
    "# Manually copy wgpu to the right place\ntarget_copy_webgpu_binaries(gpytoolbox_bindings)\n": "",
}
for old, new in replacements.items():
    text = text.replace(old, new)
cmake.write_text(text)

core = root / "src/cpp/gpytoolbox_bindings_core.cpp"
text = core.read_text()
text = text.replace("void binding_outside_points_from_rasterization(py::module& m);\n", "")
text = text.replace("    binding_outside_points_from_rasterization(m);\n", "")
core.write_text(text)
PATCHPY
}

ensure_comfy3d_cuda_toolkit() {
    if [ -x /usr/local/bin/install_matching_cuda_toolkit.sh ]; then
        log_comfy3d "Ensuring CUDA toolkit matches the Docker CUDA runtime."
        /usr/local/bin/install_matching_cuda_toolkit.sh
    fi
}

configure_comfy3d_arm64_build_env() {
    local arch="$(uname -m)"
    if [ "${arch}" != "aarch64" ] && [ "${arch}" != "arm64" ]; then
        return
    fi

    export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
    export CUDA_PATH="${CUDA_PATH:-${CUDA_HOME}}"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    export CPATH="${CUDA_HOME}/include${CPATH:+:${CPATH}}"
    export C_INCLUDE_PATH="${CUDA_HOME}/include${C_INCLUDE_PATH:+:${C_INCLUDE_PATH}}"
    export CPLUS_INCLUDE_PATH="${CUDA_HOME}/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
    export LIBRARY_PATH="${CUDA_HOME}/lib64${LIBRARY_PATH:+:${LIBRARY_PATH}}"
    export LD_LIBRARY_PATH="${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    export TORCH_CUDA_ARCH_LIST="${COMFY3D_CUDA_ARCH_LIST:-${TORCH_CUDA_ARCH_LIST:-8.7;9.0}}"
    export MAX_JOBS="${MAX_JOBS:-${ADDON_BUILD_JOBS:-1}}"
    log_comfy3d "Configured ARM64 CUDA build env: CUDA_HOME=${CUDA_HOME}, TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST}, MAX_JOBS=${MAX_JOBS}."
}

patch_comfy3d_arm64_build_scripts() {
    local pack_root="$1"
    local arch="$(uname -m)"
    if [ "${arch}" != "aarch64" ] && [ "${arch}" != "arm64" ]; then
        return
    fi

    log_comfy3d "Patching upstream build scripts for ARM64 source compilation."
    python - "${pack_root}" <<'PATCHPY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
auto_build = root / "_Pre_Builds" / "_Build_Scripts" / "auto_build_all.py"
if auto_build.exists():
    text = auto_build.read_text()
    marker = "def build_python_wheel(dependency_dir, output_dir):\n"
    helper = r'''
def patch_arm64_dependency_sources(dependency_dir):
    if platform.machine() not in ("aarch64", "arm64"):
        return

    setup_py = os.path.join(dependency_dir, "setup.py")
    if not os.path.exists(setup_py):
        return

    with open(setup_py, "r", encoding="utf-8") as f:
        text = f.read()

    patched = text.replace(
        'os.environ["TORCH_CUDA_ARCH_LIST"] = ".".join(map(str, torch.cuda.get_device_capability()))',
        'os.environ.setdefault("TORCH_CUDA_ARCH_LIST", os.environ.get("COMFY3D_CUDA_ARCH_LIST", "8.7"))',
    )

    if patched != text:
        with open(setup_py, "w", encoding="utf-8") as f:
            f.write(patched)
        print(f"Patched ARM64 CUDA build probe in {setup_py}")

'''
    if "def patch_arm64_dependency_sources(" not in text and marker in text:
        text = text.replace(marker, helper + marker)
    call = '    patch_arm64_dependency_sources(dependency_dir)\n'
    if call not in text:
        text = text.replace(
            '    print(f"Checking {dependency_dir}")\n',
            '    print(f"Checking {dependency_dir}")\n' + call,
            1,
        )
    auto_build.write_text(text)

install_py = root / "install.py"
if install_py.exists():
    text = install_py.read_text()
    old = "    # Step 1: Try wheels first\n    wheels_success = try_wheels_first_approach()\n"
    new = '''    # Step 1: Try wheels first, except on ARM where upstream wheels are x86_64-only.
    if platform.machine() in ("aarch64", "arm64"):
        cstr("ARM64 detected; skipping prebuilt Comfy3D wheels and building from source against local CUDA.").warning.print()
        wheels_success = False
    else:
        wheels_success = try_wheels_first_approach()
'''
    if old in text and "ARM64 detected; skipping prebuilt Comfy3D wheels" not in text:
        text = text.replace(old, new)
    install_py.write_text(text)

build_config = root / "_Pre_Builds" / "_Build_Scripts" / "build_config.yaml"
if build_config.exists():
    text = build_config.read_text()
    text = text.replace('build_base_packages: ["torch", "torchvision", "torchaudio", "xformers"]', "build_base_packages: []")
    build_config.write_text(text)
PATCHPY
}

patch_kiui_python312_typing() {
    python - <<'PY'
import importlib.util
from pathlib import Path

spec = importlib.util.find_spec("kiui")
if not spec or not spec.submodule_search_locations:
    raise SystemExit(0)

op_py = Path(spec.submodule_search_locations[0]) / "op.py"
if not op_py.exists():
    raise SystemExit(0)

text = op_py.read_text()
if "def dot(x: Union" not in text:
    raise SystemExit(0)

lines = text.splitlines()
insert_at = 0
while insert_at < len(lines) and (lines[insert_at].startswith("#") or not lines[insert_at].strip()):
    insert_at += 1
imports = [
    "from typing import *",
    "from torch import Tensor",
    "from numpy import ndarray",
]
for line in reversed(imports):
    if line not in lines:
        lines.insert(insert_at, line)
op_py.write_text("\n".join(lines) + "\n")
print(f"Patched kiui Python 3.12 typing import: {op_py}")
PY
}

patch_comfy3d_python312_annotations() {
    local target="$1"
    python - "${target}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
if not root.exists():
    raise SystemExit(0)

for path in root.rglob("*.py"):
    text = path.read_text(errors="ignore")
    if "from __future__ import annotations" in text:
        continue

    lines = text.splitlines()
    insert_at = 0
    if lines and lines[0].startswith("#!"):
        insert_at = 1
    if insert_at < len(lines) and "coding" in lines[insert_at]:
        insert_at += 1
    lines.insert(insert_at, "from __future__ import annotations")
    path.write_text("\n".join(lines) + "\n")
print(f"Patched Comfy3D Python 3.12 annotations under: {root}")
PY
}

patch_comfy3d_arm64_runtime_config() {
    local target="$1"
    python - "${target}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
backend_config = root / "Gen_3D_Modules" / "Stable3DGen" / "trellis" / "backend_config.py"
if backend_config.exists():
    text = backend_config.read_text()
    text = text.replace("ATTN = 'xformers' # Default attention backend", "ATTN = 'flash_attn' # Default attention backend")
    text = text.replace('ATTN = "xformers" # Default attention backend', 'ATTN = "flash_attn" # Default attention backend')
    backend_config.write_text(text)
    print(f"Patched Comfy3D Stable3DGen attention backend: {backend_config}")

controlnetvae = root / "Gen_3D_Modules" / "Stable3DGen" / "stablex" / "controlnetvae.py"
if controlnetvae.exists():
    text = controlnetvae.read_text()
    text = text.replace(
        "from diffusers.models.controlnet import ControlNetOutput",
        "from diffusers.models.controlnets import ControlNetOutput",
    )
    controlnetvae.write_text(text)
    print(f"Patched Comfy3D diffusers ControlNet import: {controlnetvae}")
PY
}

install_comfy3d_runtime_compat_deps() {
    python -m pip install --no-cache-dir --no-warn-script-location --timeout=1000 --retries 200 \
        --no-deps \
        'typeguard>=2.13,<3' \
        'tifffile<2025' \
        scs
    python -m pip install --no-cache-dir --no-warn-script-location --timeout=1000 --retries 200 \
        dataclasses-json \
        deprecated \
        vtk \
        cyclopts \
        scooby \
        texttable \
        wadler-lindig \
        objprint \
        questionary \
        varname \
        moderngl \
        optimum-quanto
    env CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}" \
        CUDA_PATH="${CUDA_PATH:-${CUDA_HOME:-/usr/local/cuda}}" \
        FORCE_CUDA=1 \
        TORCH_CUDA_ARCH_LIST="${COMFY3D_CUDA_ARCH_LIST:-${TORCH_CUDA_ARCH_LIST:-8.7;9.0;12.0}}" \
        MAX_JOBS="${MAX_JOBS:-${ADDON_BUILD_JOBS:-1}}" \
        CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-${ADDON_BUILD_JOBS:-1}}" \
        python -m pip install --no-cache-dir --no-warn-script-location --timeout=1000 --retries 200 \
            --force-reinstall --no-binary diso --no-deps --no-build-isolation \
            diso==0.1.4
    python - <<'PY'
from diso import DiffDMC
print(f"diso CUDA extension validation passed: {DiffDMC}")
PY
}

install_comfy3d_pack() {
    local folder="ComfyUI-3D-Pack"
    local target="custom_nodes/${folder}"

    if [ -d "${target}" ]; then
        log_comfy3d "Skipping ${folder}; already exists."
        install_comfy3d_runtime_compat_deps
        patch_kiui_python312_typing
        patch_comfy3d_python312_annotations "${target}"
        patch_comfy3d_arm64_runtime_config "${target}"
        return
    fi

    log_comfy3d "Cloning ${folder}."
    git clone --depth 1 https://github.com/MrForExample/ComfyUI-3D-Pack "${target}"

    prepare_gpytoolbox_arm64

    local requirements="${target}/requirements.txt"
    if [ -s "${requirements}" ]; then
        local tmp_requirements="/tmp/${folder}.requirements.txt"
        log_comfy3d "Filtering requirements to preserve Docker CUDA/PyTorch and NumPy ABI pins."
        filter_comfy3d_requirements "${requirements}" "${tmp_requirements}"
        if [ -s "${tmp_requirements}" ]; then
            log_comfy3d "Installing filtered Python requirements."
            install_requirements_preserving_torch "${tmp_requirements}"
        else
            log_comfy3d "No Python requirements remain after filtering."
        fi
        rm -f "${tmp_requirements}"
    fi

    install_comfy3d_cumm_arm64

    if [ -s "${target}/install.py" ]; then
        log_comfy3d "Starting source build and wheel installation."
        ensure_comfy3d_cuda_toolkit
        configure_comfy3d_arm64_build_env
        patch_comfy3d_arm64_build_scripts "${target}"
        sed -i '/Comfy3D install failed/a\    if os.environ.get("COMFY3D_INSTALL_STRICT", "1") != "0":\n        sys.exit(1)' "${target}/install.py"
        sed -i '/Building wheels also failed/a\            if os.environ.get("COMFY3D_INSTALL_STRICT", "1") != "0":\n                sys.exit(1)' "${target}/install.py"
        COMFY3D_INSTALL_STRICT="${COMFY3D_INSTALL_STRICT:-1}" python "${target}/install.py"
        log_comfy3d "Restoring protected dependency pins after source build."
        restore_numpy_abi_pin
        pin_torch_stack_if_needed
        if python - <<'PY'
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("spconv") else 1)
PY
        then
            python - <<'PY'
import spconv
print(f"spconv validation passed: {spconv.__version__}")
PY
        fi
        install_comfy3d_runtime_compat_deps
        patch_kiui_python312_typing
        patch_comfy3d_python312_annotations "${target}"
        patch_comfy3d_arm64_runtime_config "${target}"
        log_comfy3d "Install completed."
    fi
}

install_addons_selects_comfy3d_pack() {
    local selected
    selected="$(printf '%s' "${INSTALL_ADDONS:-}" | tr -d '[:space:]')"
    selected=",${selected},"
    case "${selected}" in
        *,ComfyUI-3D-Pack,*|*,3D-Pack,*|*,Comfy3D,*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

should_install_comfy3d_pack() {
    install_addons_selects_comfy3d_pack
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

install_fish_audio_s2_runtime_deps
install_decord_from_source_if_needed

if should_install_comfy3d_pack; then
    log_comfy3d "Selected by INSTALL_ADDONS."
    install_comfy3d_pack
else
    log_comfy3d "Skipping; add ComfyUI-3D-Pack to INSTALL_ADDONS to enable it."
fi
