#!/usr/bin/env bash
set -eu

archive="/tmp/Helper-CEI-NEXT-unix.zip"
easy_root="/app/ComfyUI-Easy-Install"
addons_arg="${INSTALL_ADDONS:-}"
addon_build_jobs="${ADDON_BUILD_JOBS:-1}"
numpy_version="${NUMPY_VERSION:-1.26.4}"
scipy_version="${SCIPY_VERSION:-1.15.3}"
insightface_accept_license="${INSIGHTFACE_ACCEPT_LICENSE:-1}"

# Nunchaku and similar CUDA add-ons can exhaust RAM when CMake/Ninja fan out.
# Keep the default conservative, but allow larger builders to opt in.
export MAX_JOBS="${MAX_JOBS:-${addon_build_jobs}}"
export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-${addon_build_jobs}}"
export NINJAFLAGS="${NINJAFLAGS:--j${addon_build_jobs}}"
export MAKEFLAGS="${MAKEFLAGS:--j${addon_build_jobs}}"

append_csv() {
    current="$1"
    item="$2"
    if [ -z "${current}" ]; then
        printf '%s' "${item}"
    else
        printf '%s,%s' "${current}" "${item}"
    fi
}

addon_selected() {
    needle="$1"
    raw="$2"
    old_ifs_selected="${IFS}"
    IFS=","
    for item in ${raw}; do
        IFS="${old_ifs_selected}"
        item="${item# }"
        item="${item% }"
        if [ "${item}" = "${needle}" ] || [ "${item}" = "${needle}.sh" ]; then
            IFS="${old_ifs_selected}"
            return 0
        fi
        IFS=","
    done
    IFS="${old_ifs_selected}"
    return 1
}

expand_addons() {
    raw="$1"
    expanded=""
    arch="$(uname -m)"
    old_ifs_expand="${IFS}"
    IFS=","
    for item in ${raw}; do
        IFS="${old_ifs_expand}"
        item="${item# }"
        item="${item% }"
        case "${item}" in
            ""|none|None|NONE)
                ;;
            all-cuda|cuda|all)
                runtime_addons="Insightface-NEXT,SageAttention-NEXT,FlashAttention,Trellis2,Nunchaku120-NEXT"
                old_ifs_runtime="${IFS}"
                IFS=","
                for runtime_addon in ${runtime_addons}; do
                    IFS="${old_ifs_runtime}"
                    expanded="$(append_csv "${expanded}" "${runtime_addon}")"
                    IFS=","
                done
                IFS="${old_ifs_expand}"
                ;;
            *)
                expanded="$(append_csv "${expanded}" "${item}")"
                ;;
        esac
        IFS=","
    done
    IFS="${old_ifs_expand}"
    printf '%s' "${expanded}"
}

addons_arg="$(expand_addons "${addons_arg}")"

mkdir -p "${easy_root}"

if [ -f "${archive}" ]; then
    workdir="$(mktemp -d)"
    unzip -q "${archive}" "ComfyUI-Easy-Install/Add-Ons/*" -d "${workdir}"
    rm -rf "${easy_root}/Add-Ons"
    cp -a "${workdir}/ComfyUI-Easy-Install/Add-Ons" "${easy_root}/Add-Ons"
    rm -rf "${workdir}"
fi

ln -sfn /app/ComfyUI "${easy_root}/ComfyUI"
mkdir -p "${easy_root}/python_embeded/bin"
ln -sfn /opt/venv/bin/python "${easy_root}/python_embeded/bin/python3"
ln -sfn /opt/venv/bin/python "${easy_root}/python_embeded/bin/python"

cat > "${easy_root}/python_embeded/python" <<'EOF'
#!/usr/bin/env sh
exec /opt/venv/bin/python "$@"
EOF
chmod +x "${easy_root}/python_embeded/python"

if [ -d "${easy_root}/Add-Ons" ]; then
    find "${easy_root}/Add-Ons" -type f -name "*.sh" -exec chmod +x {} +
else
    echo "No Add-Ons directory was found in ${archive}" >&2
fi

patch_docker_cuda_version_checks() {
    script="$1"
    if [ ! -f "${script}" ]; then
        return
    fi

    # Docker builds normally do not have a GPU attached, but source builds still
    # need the CUDA runtime that PyTorch was compiled against.
    sed -i \
        -e "s/torch.version.cuda if torch.cuda.is_available() else 'Not available'/torch.version.cuda or 'Not available'/g" \
        -e 's/\[\[ "\$CUDA_VERSION" != "12\.8" \]\]/[[ "$CUDA_VERSION" != "12.8" \&\& "$CUDA_VERSION" != "12.9" ]]/g' \
        -e 's/\[ "\$CUDA_VERSION" != "12\.8" \] && \[ "\$CUDA_VERSION" != "13\.0" \]/[ "$CUDA_VERSION" != "12.8" ] \&\& [ "$CUDA_VERSION" != "12.9" ] \&\& [ "$CUDA_VERSION" != "13.0" ]/g' \
        -e 's/\$CUDA_VERSION" != "12\.8" && "\$CUDA_VERSION" != "13\.0"/$CUDA_VERSION" != "12.8" \&\& "$CUDA_VERSION" != "12.9" \&\& "$CUDA_VERSION" != "13.0"/g' \
        -e 's/\$CUDA_VERSION" != "12\.4" && "\$CUDA_VERSION" != "12\.8" && "\$CUDA_VERSION" != "13\.0"/$CUDA_VERSION" != "12.4" \&\& "$CUDA_VERSION" != "12.8" \&\& "$CUDA_VERSION" != "12.9" \&\& "$CUDA_VERSION" != "13.0"/g' \
        -e 's/Supported version: 12\.8/Supported versions: 12.8, 12.9/g' \
        -e 's/Supported version: 12\.8, 13\.0/Supported versions: 12.8, 12.9, 13.0/g' \
        -e 's/Supported versions: 12\.8, 13\.0/Supported versions: 12.8, 12.9, 13.0/g' \
        -e 's/Supported versions: 12\.4, 12\.8, 13\.0/Supported versions: 12.4, 12.8, 12.9, 13.0/g' \
        "${script}"
}

for cuda_check_script in \
    "${easy_root}/Add-Ons/SageAttention-NEXT.sh" \
    "${easy_root}/Add-Ons/Nunchaku120-NEXT.sh" \
    "${easy_root}/Add-Ons/FlashAttention.sh" \
    "${easy_root}/Add-Ons/Trellis2.sh"
do
    patch_docker_cuda_version_checks "${cuda_check_script}"
done

insightface_script="${easy_root}/Add-Ons/Insightface-NEXT.sh"
if [ -f "${insightface_script}" ]; then
    sed -i \
        -e '/^# Main script execution/i clear_pip_cache() { :; }' \
        -e '/Torch is not installed/{n;s/WARNINGS=1$/if [ "${DOCKER_ADDON_ALLOW_MISSING_TORCH:-0}" != "1" ]; then WARNINGS=1; fi/;}' \
        -e "s/install --force-reinstall numpy /install --force-reinstall numpy==${numpy_version} /" \
        "${insightface_script}"
fi

nunchaku_script="${easy_root}/Add-Ons/Nunchaku120-NEXT.sh"
if [ -f "${nunchaku_script}" ]; then
    sed -i \
        -e '1a set -e' \
        -e 's/"$PYTHON_PATH" -m pip install dist\/nunchaku\*\.whl $PIP_ARGS/"$PYTHON_PATH" -m pip install --force-reinstall --no-deps dist\/nunchaku*.whl $PIP_ARGS/' \
        -e "s/numpy==1\\.26\\.4/numpy==${numpy_version}/g" \
        "${nunchaku_script}"
fi

flashattention_script="${easy_root}/Add-Ons/FlashAttention.sh"
if [ -f "${flashattention_script}" ]; then
    sed -i \
        -e '1a set -e' \
        -e 's/$PYTHON_PATH -I -m pip install --no-build-isolation flash-attn $PIPargs/$PYTHON_PATH -I -m pip install --no-build-isolation --no-deps "flash-attn==2.8.3.post1" $PIPargs/' \
        "${flashattention_script}"
fi

trellis2_script="${easy_root}/Add-Ons/Trellis2.sh"
if [ -f "${trellis2_script}" ]; then
    sed -i \
        -e '/WHEEL_DIR=/a if [ "$(uname -m)" != "x86_64" ]; then WHEEL_DIR="/tmp/trellis2-no-compatible-wheels"; fi' \
        -e '/^# Set model variables/i if [ "${TRELLIS2_DOWNLOAD_DINOV3:-0}" != "1" ]; then\n    echo "[Trellis2] Skipping DINOv3 model download during Docker build; mount or download it on demand under ../ComfyUI/models/facebook/dinov3-vitl16-pretrain-lvd1689m."\nelse' \
        -e '/was downloaded successfully/a fi' \
        -e 's@"$PYTHON_PATH" -I -m pip install -r ../ComfyUI/custom_nodes/ComfyUI-Trellis2/requirements.txt --no-deps $PIPargs@grep -Eiv '"'"'open3d([<>=~![:space:]]|$)'"'"' ../ComfyUI/custom_nodes/ComfyUI-Trellis2/requirements.txt > /tmp/trellis2-requirements-no-open3d.txt\n"$PYTHON_PATH" -I -m pip install -r /tmp/trellis2-requirements-no-open3d.txt --no-deps $PIPargs@' \
        "${trellis2_script}"
fi

validate_python_imports() {
    label="$1"
    shift
    python - "$label" "$@" <<'PY'
import importlib
import sys

label = sys.argv[1]
missing = []
for module in sys.argv[2:]:
    try:
        importlib.import_module(module)
    except Exception as exc:
        missing.append(f"{module}: {exc}")

if missing:
    print(f"{label} did not install cleanly.", file=sys.stderr)
    for item in missing:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

print(f"{label} validation passed.")
PY
}

validate_nunchaku() {
    label="$1"
    python - "$label" <<'PY'
import importlib
import importlib.metadata
import sys
import traceback

label = sys.argv[1]
checks = [
    ("nunchaku._C", lambda: importlib.import_module("nunchaku._C")),
    ("nunchaku metadata", lambda: importlib.metadata.version("nunchaku")),
    ("nunchaku", lambda: importlib.import_module("nunchaku")),
]

errors = []
for name, check in checks:
    try:
        result = check()
        if name == "nunchaku metadata":
            print(f"{label} {name}: {result}")
    except Exception as exc:
        errors.append(f"{name}: {exc}")
        traceback.print_exc()

if errors:
    print(f"{label} did not install cleanly.", file=sys.stderr)
    for item in errors:
        print(f"  - {item}", file=sys.stderr)
    sys.exit(1)

print(f"{label} validation passed.")
PY
}

python_imports_ok() {
    python - "$@" <<'PY'
import importlib
import sys

for module in sys.argv[1:]:
    try:
        importlib.import_module(module)
    except Exception:
        sys.exit(1)
PY
}

python_specs_ok() {
    python - "$@" <<'PY'
import importlib.util
import sys

for module in sys.argv[1:]:
    if importlib.util.find_spec(module) is None:
        sys.exit(1)
PY
}

without_pip_constraints() {
    env -u PIP_CONSTRAINT -u PIP_BUILD_CONSTRAINT "$@"
}

restore_numeric_abi_pins() {
    without_pip_constraints python -m pip install --force-reinstall --no-deps \
        "numpy==${numpy_version}" \
        "scipy==${scipy_version}"
}

insightface_license_accepted() {
    case "${insightface_accept_license}" in
        1|yes|YES|true|TRUE|y|Y)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

prepend_existing_ld_paths() {
    new_paths=""
    for path in "$@"; do
        if [ -d "${path}" ]; then
            case ":${new_paths}:${LD_LIBRARY_PATH:-}:" in
                *":${path}:"*)
                    ;;
                *)
                    new_paths="${new_paths}${new_paths:+:}${path}"
                    ;;
            esac
        fi
    done
    if [ -n "${new_paths}" ]; then
        LD_LIBRARY_PATH="${new_paths}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    fi
    export LD_LIBRARY_PATH
}

python_site_ld_paths() {
    python - <<'PY'
import site
import sysconfig

seen = set()
roots = []

for candidate in site.getsitepackages():
    roots.append(candidate)

purelib = sysconfig.get_paths().get("purelib")
if purelib:
    roots.append(purelib)

for root in roots:
    for suffix in (
        "torch/lib",
        "nvidia/cudnn/lib",
        "nvidia/cublas/lib",
        "nvidia/cusparselt/lib",
        "nvidia/nccl/lib",
        "nvidia/nvshmem/lib",
        "nvidia/cuda_runtime/lib",
    ):
        path = f"{root}/{suffix}"
        if path not in seen:
            seen.add(path)
            print(path)
PY
}

cuda_build_env() {
    cuda_home="${CUDA_HOME:-/usr/local/cuda}"
    if [ ! -x "${cuda_home}/bin/nvcc" ] && command -v nvcc >/dev/null 2>&1; then
        cuda_home="$(dirname "$(dirname "$(command -v nvcc)")")"
    fi
    if [ ! -x "${cuda_home}/bin/nvcc" ]; then
        echo "nvcc not found; cannot compile CUDA add-on sources." >&2
        exit 1
    fi

    export CUDA_HOME="${cuda_home}"
    export PATH="${CUDA_HOME}/bin:${PATH}"
    machine="$(uname -m)"
    case "${machine}" in
        aarch64|arm64)
            target_arch="sbsa-linux"
            compat_arch="aarch64-linux"
            ;;
        x86_64|amd64)
            target_arch="x86_64-linux"
            compat_arch="x86_64-linux"
            ;;
        *)
            target_arch="${machine}-linux"
            compat_arch="${machine}-linux"
            ;;
    esac
    prepend_existing_ld_paths \
        $(python_site_ld_paths) \
        /opt/venv/lib/python3.12/site-packages/torch/lib \
        /usr/local/lib/python3.12/dist-packages/torch/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/cudnn/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/cudnn/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/cu13/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/cu13/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/cublas/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/cublas/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/cusparselt/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/cusparselt/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/nccl/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/nccl/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/nvshmem/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/nvshmem/lib \
        /opt/venv/lib/python3.12/site-packages/nvidia/cuda_runtime/lib \
        /usr/local/lib/python3.12/dist-packages/nvidia/cuda_runtime/lib \
        "${CUDA_HOME}/lib64" \
        "${CUDA_HOME}/targets/${target_arch}/lib" \
        "${CUDA_HOME}/targets/${compat_arch}/lib" \
        /usr/local/cuda/lib64 \
        "/usr/local/cuda/targets/${target_arch}/lib" \
        "/usr/local/cuda/targets/${compat_arch}/lib" \
        /usr/local/cuda-13.0/lib64 \
        "/usr/local/cuda-13.0/targets/${target_arch}/lib" \
        "/usr/local/cuda-13.0/targets/${compat_arch}/lib" \
        /usr/local/cuda-12.9/lib64 \
        "/usr/local/cuda-12.9/targets/${target_arch}/lib" \
        "/usr/local/cuda-12.9/targets/${compat_arch}/lib" \
        /usr/local/cuda-12.8/lib64 \
        "/usr/local/cuda-12.8/targets/${target_arch}/lib" \
        "/usr/local/cuda-12.8/targets/${compat_arch}/lib" \
        "/usr/lib/${target_arch}"
    if [ -z "${TORCH_CUDA_ARCH_LIST:-}" ]; then
        TORCH_CUDA_ARCH_LIST="$(python - <<'PY'
import torch

if torch.cuda.is_available():
    major, minor = torch.cuda.get_device_capability(0)
    print(f"{major}.{minor}")
else:
    print("8.0;8.6;8.9;9.0;10.0;12.0")
PY
)"
        export TORCH_CUDA_ARCH_LIST
    fi
}

flashattention_cuda_archs() {
    if [ -n "${FLASH_ATTN_CUDA_ARCHS:-}" ]; then
        return
    fi

    FLASH_ATTN_CUDA_ARCHS="$(python - <<'PY'
import torch

supported = ("80", "90", "100", "120")

if torch.cuda.is_available():
    major, minor = torch.cuda.get_device_capability(0)
    capability = major * 10 + minor
    for arch in reversed(supported):
        if capability >= int(arch):
            print(arch)
            break
    else:
        print("80")
else:
    print(";".join(supported))
PY
)"
    export FLASH_ATTN_CUDA_ARCHS
}

build_nunchaku_from_source() {
    echo "Compiling Nunchaku from source for $(uname -m)."
    cuda_build_env
    build_root="/tmp/nunchaku-docker-source"
    src_dir="${build_root}/nunchaku"
    rm -rf "${build_root}"
    mkdir -p "${build_root}"
    git clone --recurse-submodules https://github.com/nunchaku-ai/nunchaku.git "${src_dir}"
    cd "${src_dir}"
    without_pip_constraints python -m pip install --upgrade build wheel "setuptools<82" ninja "cmake<4" pybind11
    without_pip_constraints env NUNCHAKU_INSTALL_MODE=ALL NUNCHAKU_BUILD_WHEELS=1 python -m build --wheel --no-isolation
    wheel_dir="$(pwd)/dist"
    set -- "${wheel_dir}"/nunchaku*.whl
    if [ ! -f "$1" ]; then
        echo "Nunchaku source build produced no nunchaku wheel." >&2
        find dist -maxdepth 1 -type f -print 2>/dev/null || true
        exit 1
    fi
    cd "${easy_root}"
    python -m pip install --force-reinstall --no-deps "$@"
    without_pip_constraints python -m pip install --upgrade "setuptools<81"
    without_pip_constraints python -m pip install --upgrade --no-deps "librosa>=0.10.2,<0.11"
    without_pip_constraints python -m pip install --force-reinstall --no-deps "transformers==4.57.6"
    without_pip_constraints python -m pip install --upgrade --no-deps "narwhals>=1.0"
    restore_numeric_abi_pins
    validate_nunchaku "Nunchaku source build"
    rm -rf "${build_root}"
}

install_insightface_noninteractive() {
    if ! insightface_license_accepted; then
        echo "[Insightface] License acceptance is required for non-interactive Docker installation." >&2
        echo "[Insightface] Read https://github.com/deepinsight/insightface#license, then rebuild with --build-arg INSIGHTFACE_ACCEPT_LICENSE=1 if you accept it." >&2
        exit 1
    fi

    echo "[Insightface] License acceptance provided; installing Insightface dependencies."
    without_pip_constraints python -m pip install --no-cache-dir --no-warn-script-location --timeout=1000 --retries 200 \
        --no-deps \
        insightface \
        filterpywhl \
        facexlib \
        filterpy
    restore_numeric_abi_pins
}

install_open3d_build_deps() {
    apt-get update
    apt-get install -y --no-install-recommends \
        gfortran \
        libassimp-dev \
        libblas-dev \
        libc++-dev \
        libc++abi-dev \
        libeigen3-dev \
        libglfw3-dev \
        libglu1-mesa-dev \
        libjpeg-dev \
        liblapack-dev \
        liblapacke-dev \
        libopenblas-dev \
        libpng-dev \
        libtbb-dev \
        libx11-dev \
        libwayland-dev \
        libxcursor-dev \
        libxext-dev \
        libxi-dev \
        libxinerama-dev \
        libxkbcommon-dev \
        libxrandr-dev \
        wayland-protocols \
        xorg-dev
    rm -rf /var/lib/apt/lists/*
}

install_open3d_runtime_deps() {
    without_pip_constraints python -m pip install --no-cache-dir --no-warn-script-location --timeout=1000 --retries 200 \
        addict \
        blinker \
        configargparse \
        dash \
        flask \
        itsdangerous \
        janus \
        nbformat \
        pyquaternion \
        pyyaml \
        retrying \
        scikit-learn \
        tqdm \
        werkzeug
    restore_numeric_abi_pins
}

install_trellis2_build_deps() {
    apt-get update
    apt-get install -y --no-install-recommends \
        libeigen3-dev
    rm -rf /var/lib/apt/lists/*
}

prepend_env_path() {
    var_name="$1"
    path="$2"
    eval "current_value=\${${var_name}:-}"
    case ":${current_value}:" in
        *":${path}:"*)
            ;;
        *)
            eval "export ${var_name}=\"${path}\${${var_name}:+:\${${var_name}}}\""
            ;;
    esac
}

trellis2_build_env() {
    install_trellis2_build_deps
    if [ -d /usr/include/eigen3 ]; then
        prepend_env_path CPATH /usr/include/eigen3
        prepend_env_path CPLUS_INCLUDE_PATH /usr/include/eigen3
    fi
}

build_open3d_from_source() {
    install_open3d_runtime_deps
    if python_imports_ok open3d; then
        return 0
    fi

    echo "Compiling Open3D from source for $(uname -m)."
    install_open3d_build_deps
    build_root="/tmp/open3d-docker-source"
    src_dir="${build_root}/Open3D"
    rm -rf "${build_root}"
    mkdir -p "${build_root}"
    git clone --recursive --depth 1 --branch v0.19.0 https://github.com/isl-org/Open3D.git "${src_dir}"
    cd "${src_dir}"
    without_pip_constraints python -m pip install --upgrade wheel "setuptools<82" "cmake<4" ninja
    mkdir -p build
    cd build
    cmake -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_CUDA_MODULE=OFF \
        -DBUILD_GUI=OFF \
        -DBUILD_WEBRTC=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_UNIT_TESTS=OFF \
        -DBUILD_BENCHMARKS=OFF \
        -DBUILD_PYTHON_MODULE=ON \
        -DBUILD_PYTORCH_OPS=OFF \
        -DBUILD_TENSORFLOW_OPS=OFF \
        -DBUNDLE_OPEN3D_ML=OFF \
        -DUSE_SYSTEM_BLAS=ON \
        -DUSE_SYSTEM_ASSIMP=ON \
        -DUSE_SYSTEM_EIGEN3=ON \
        -DUSE_SYSTEM_JPEG=ON \
        -DUSE_SYSTEM_TBB=ON \
        -DPython3_EXECUTABLE="$(command -v python)" \
        ..
    cmake --build . --target pip-package --parallel "${addon_build_jobs}"
    set -- lib/python_package/pip_package/open3d*.whl
    if [ ! -f "$1" ]; then
        echo "Open3D source build produced no open3d wheel." >&2
        find . -name "open3d*.whl" -print 2>/dev/null || true
        exit 1
    fi
    without_pip_constraints python -m pip install --force-reinstall --no-deps "$@"
    install_open3d_runtime_deps
    validate_python_imports "Open3D source build" open3d
    rm -rf "${build_root}"
    cd "${easy_root}"
}

build_trellis2_native_from_source() {
    echo "Compiling Trellis2 native dependencies from source for $(uname -m)."
    cuda_build_env
    trellis2_build_env
    without_pip_constraints python -m pip install --upgrade build wheel "setuptools<82" ninja "cmake<4" pybind11
    without_pip_constraints python -m pip install --no-cache-dir --no-warn-script-location --timeout=1000 --retries 200 --no-deps \
        meshlib requests pymeshlab opencv-python "scipy==${scipy_version}" plotly rembg plyfile
    restore_numeric_abi_pins
    build_open3d_from_source
    without_pip_constraints python -m pip install --no-cache-dir --no-build-isolation --no-deps \
        git+https://github.com/NVlabs/nvdiffrast.git
    without_pip_constraints python -m pip install --no-cache-dir --no-build-isolation --no-deps \
        git+https://github.com/visualbruno/CuMesh.git
    without_pip_constraints python -m pip install --no-cache-dir --no-build-isolation --no-deps \
        git+https://github.com/visualbruno/FlexGEMM.git
    without_pip_constraints python -m pip install --no-cache-dir --no-build-isolation --no-deps \
        git+https://github.com/JeffreyXiang/nvdiffrec.git@renderutils
    without_pip_constraints python -m pip install --no-cache-dir --no-build-isolation --no-deps \
        "git+https://github.com/microsoft/TRELLIS.2.git#subdirectory=o-voxel"
}

torch_cuda_available() {
    python - <<'PY'
import sys
import torch

sys.exit(0 if torch.cuda.is_available() else 1)
PY
}

validate_native_linkage() {
    label="$1"
    shift
    missing=0
    for so_path in "$@"; do
        if [ ! -f "${so_path}" ]; then
            echo "${label} native object not found: ${so_path}" >&2
            missing=1
            continue
        fi
        if ldd "${so_path}" | grep -q "not found"; then
            echo "${label} has unresolved native libraries: ${so_path}" >&2
            ldd "${so_path}" >&2 || true
            missing=1
        fi
    done
    if [ "${missing}" != "0" ]; then
        exit 1
    fi
}

trellis2_native_files_present() {
    set -- \
        /opt/venv/lib/python3.12/site-packages/flex_gemm/kernels/cuda.cpython-*-aarch64-linux-gnu.so \
        /opt/venv/lib/python3.12/site-packages/o_voxel/_C.cpython-*-aarch64-linux-gnu.so
    for so_path in "$@"; do
        if [ ! -f "${so_path}" ]; then
            return 1
        fi
    done
}

validate_trellis2() {
    label="$1"
    validate_python_imports "${label}" pymeshlab open3d cumesh nvdiffrast nvdiffrec_render.renderutils._C plyfile
    if ! python_specs_ok flex_gemm o_voxel || ! trellis2_native_files_present; then
        echo "${label} did not install cleanly." >&2
        echo "  - flex_gemm/o_voxel package or native extension files are missing" >&2
        exit 1
    fi

    if python_imports_ok flex_gemm o_voxel; then
        echo "${label} validation passed."
        return 0
    fi

    if torch_cuda_available; then
        validate_python_imports "${label}" flex_gemm o_voxel
        return 0
    fi

    echo "${label}: CUDA device is not visible during validation; checking native Trellis linkage instead."
    validate_native_linkage "${label}" \
        /opt/venv/lib/python3.12/site-packages/flex_gemm/kernels/cuda.cpython-*-aarch64-linux-gnu.so \
        /opt/venv/lib/python3.12/site-packages/o_voxel/_C.cpython-*-aarch64-linux-gnu.so
    echo "${label} validation passed."
}

addon_already_satisfied() {
    addon="$1"
    script="$2"
    script_base="$(basename "${script}")"

    case "${script_base}" in
        Nunchaku*.sh)
            [ -d /app/ComfyUI/custom_nodes/ComfyUI-nunchaku ] && \
                python_imports_ok nunchaku._C && \
                python_specs_ok nunchaku
            ;;
        Trellis2.sh|Trellis2-Install-Prebuilt.sh|Trellis2-Build-*.sh)
            [ -d /app/ComfyUI/custom_nodes/ComfyUI-Trellis2 ] && \
                python_imports_ok pymeshlab open3d cumesh nvdiffrast nvdiffrec_render.renderutils._C plyfile && \
                python_specs_ok flex_gemm o_voxel && \
                trellis2_native_files_present
            ;;
        *)
            return 1
            ;;
    esac
}

repair_addon_from_source_if_needed() {
    addon="$1"
    script="$2"
    script_base="$(basename "${script}")"

    case "${script_base}" in
        Insightface*.sh)
            if ! python_imports_ok insightface facexlib; then
                install_insightface_noninteractive
            fi
            ;;
        Nunchaku*.sh)
            restore_numeric_abi_pins
            if ! python_imports_ok nunchaku._C || ! python_specs_ok nunchaku; then
                build_nunchaku_from_source
            fi
            ;;
        Trellis2.sh|Trellis2-Install-Prebuilt.sh|Trellis2-Build-*.sh)
            if ! python_imports_ok pymeshlab open3d cumesh nvdiffrast nvdiffrec_render.renderutils._C plyfile || ! python_specs_ok flex_gemm o_voxel || ! trellis2_native_files_present; then
                build_trellis2_native_from_source
            fi
            ;;
    esac
}

validate_addon() {
    addon="$1"
    script="$2"
    script_base="$(basename "${script}")"

    case "${script_base}" in
        Insightface*.sh)
            validate_python_imports "${addon}" insightface facexlib
            ;;
        Nunchaku*.sh)
            validate_nunchaku "${addon}"
            ;;
        SageAttention*.sh|CachyOSSage*.sh)
            validate_python_imports "${addon}" sageattention
            ;;
        FlashAttention*.sh)
            validate_python_imports "${addon}" flash_attn
            ;;
        Trellis2.sh|Trellis2-Install-Prebuilt.sh|Trellis2-Build-*.sh)
            validate_trellis2 "${addon}"
            ;;
    esac
}

if [ -z "${addons_arg}" ]; then
    echo "[AddOns] Add-Ons extracted to ${easy_root}/Add-Ons; no add-ons selected for build-time installation."
    exit 0
fi

if addon_selected "Insightface-NEXT" "${addons_arg}" && ! insightface_license_accepted; then
    echo "[Insightface] Insightface-NEXT was selected in INSTALL_ADDONS, but INSIGHTFACE_ACCEPT_LICENSE is not enabled." >&2
    echo "[Insightface] Read https://github.com/deepinsight/insightface#license, then rebuild with --build-arg INSIGHTFACE_ACCEPT_LICENSE=1 if you accept it." >&2
    echo "[Insightface] To skip InsightFace, remove Insightface-NEXT from INSTALL_ADDONS." >&2
    exit 1
fi

cd "${easy_root}"
echo "[AddOns] Native build parallelism: ${addon_build_jobs} job(s)"
old_ifs="${IFS}"
IFS=","
for addon in ${addons_arg}; do
    IFS="${old_ifs}"
    addon="${addon# }"
    addon="${addon% }"
    case "${addon}" in
        ComfyUI-3D-Pack|3D-Pack|Comfy3D)
            echo "[Comfy3D] Docker add-on handled during custom node installation: ${addon}"
            IFS=","
            continue
            ;;
    esac
    case "${addon}" in
        *.sh)
            script="Add-Ons/${addon}"
            ;;
        *)
            script="Add-Ons/${addon}.sh"
            ;;
    esac

    if [ ! -f "${script}" ]; then
        echo "[AddOns] Requested add-on script not found: ${script}" >&2
        exit 1
    fi

    script_dir="$(dirname "${script}")"
    script_name="$(basename "${script}")"
    case "${script_name}" in
        SageAttention*.sh|CachyOSSage*.sh|FlashAttention*.sh|Nunchaku*.sh|Trellis2.sh|Trellis2-Install-Prebuilt.sh|Trellis2-Build-*.sh)
            cuda_build_env
            ;;
    esac
    case "${script_name}" in
        FlashAttention*.sh)
            flashattention_cuda_archs
            echo "[FlashAttention] CUDA archs: ${FLASH_ATTN_CUDA_ARCHS}"
            ;;
    esac

    if addon_already_satisfied "${addon}" "${script}"; then
        echo "[AddOns] Docker add-on already installed: ${script}"
        validate_addon "${addon}" "${script}"
        IFS=","
        continue
    fi

    echo "[AddOns] Installing Docker add-on: ${script}"
    if ! (cd "${script_dir}" && DOCKER_ADDON_ALLOW_MISSING_TORCH=1 bash "${script_name}" NoPause); then
        echo "[AddOns] Upstream add-on script failed; checking whether Docker source repair can satisfy ${addon}."
    fi
    repair_addon_from_source_if_needed "${addon}" "${script}"
    validate_addon "${addon}" "${script}"
    IFS=","
done
IFS="${old_ifs}"
