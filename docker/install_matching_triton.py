import importlib.metadata
import subprocess
import sys

try:
    metadata = importlib.metadata.metadata("torch")
except importlib.metadata.PackageNotFoundError:
    sys.exit(0)

for requirement in metadata.get_all("Requires-Dist") or []:
    if requirement.startswith("triton") and "==" in requirement:
        version = requirement.split("==", 1)[1].split(";", 1)[0].strip()
        subprocess.check_call(
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "--no-cache-dir",
                "--upgrade",
                "--force-reinstall",
                f"triton=={version}",
            ]
        )
        break
