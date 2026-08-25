param(
    [string]$SshHost = "rk3588",
    [string]$RemoteRoot = "/userdata/photo-restore-v2"
)

$ErrorActionPreference = "Stop"
$SshOptions = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3")
$Python = "${RemoteRoot}/venv/bin/python"

ssh @SshOptions $SshHost "'${Python}' -c 'from PIL import Image; print(Image.__version__)'" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "Installing Pillow 11.3.0 into the isolated board venv..."
    ssh @SshOptions $SshHost "'${Python}' -m pip install --only-binary=:all: 'Pillow==11.3.0'"
    if ($LASTEXITCODE -ne 0) {
        throw "Installing Pillow on RK3588 failed"
    }
}

ssh @SshOptions $SshHost "'${Python}' -c 'import numpy; import PIL; from rknnlite.api import RKNNLite; print(\"numpy=\" + numpy.__version__); print(\"Pillow=\" + PIL.__version__); print(\"RKNNLITE_IMPORT_OK\")'"
if ($LASTEXITCODE -ne 0) {
    throw "Board image dependency verification failed"
}

Write-Output "RESULT=PASS_BOARD_IMAGE_DEPS"

