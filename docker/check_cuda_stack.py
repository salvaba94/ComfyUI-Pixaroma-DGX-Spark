import os
import shutil
import subprocess

import torch


def run(command):
    executable = shutil.which(command[0])
    if executable is None:
        return "not found"
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()
    except subprocess.CalledProcessError as exc:
        return exc.output.strip()


print(f"torch: {torch.__version__}")
print(f"torch.version.cuda: {torch.version.cuda}")
print(f"torch.cuda.is_available: {torch.cuda.is_available()}")
print(f"CUDA_HOME: {os.environ.get('CUDA_HOME', '/usr/local/cuda')}")

nvcc_output = run(["nvcc", "--version"])
nvidia_smi_output = run(["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"])

print(f"nvcc: {nvcc_output.splitlines()[-1] if nvcc_output != 'not found' else 'not found'}")
print(f"nvidia-smi driver: {nvidia_smi_output.splitlines()[0] if nvidia_smi_output != 'not found' else 'not found'}")
