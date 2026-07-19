#!/usr/bin/env bash
set -euo pipefail

echo "Running CUDA / ONNX / PyTorch quick checks (non-fatal)."
python - <<'PY'
import sys
ok = True
try:
    import torch
    print('torch:', torch.__version__, 'cuda_available:', torch.cuda.is_available(), 'cuda_count:', torch.cuda.device_count())
except Exception as e:
    print('torch check failed:', e)
    ok = False
try:
    import onnxruntime
    ver = getattr(onnxruntime, '__version__', 'unknown')
    device = None
    try:
        # onnxruntime-python may expose get_device or inference session providers
        device = getattr(onnxruntime, 'get_device', lambda: 'unknown')()
    except Exception:
        device = 'unknown'
    print('onnxruntime:', ver, 'device:', device)
except Exception as e:
    print('onnxruntime check failed:', e)
    ok = False
try:
    import subprocess
    gpus = subprocess.check_output(['nvidia-smi','-L'], stderr=subprocess.DEVNULL).decode().strip()
    print('nvidia-smi output (first line):', gpus.splitlines()[0] if gpus else 'none')
except Exception:
    print('nvidia-smi not available or failed')

if not ok:
    print('One or more checks failed; these are informational during build.')
    sys.exit(0)
sys.exit(0)
PY

echo "CUDA / ONNX / PyTorch checks completed (non-fatal)."
