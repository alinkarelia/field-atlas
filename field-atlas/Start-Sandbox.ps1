param([ValidateRange(1024,65535)][int]$Port = 8879, [string]$PythonPath = '')
$ErrorActionPreference = 'Stop'
$atlasRoot = $PSScriptRoot
if (-not $PythonPath) {
    $venvPython = Join-Path $atlasRoot '.venv/Scripts/python.exe'
    if (Test-Path -LiteralPath $venvPython) { $PythonPath = $venvPython }
}
if (-not $PythonPath) {
    $bundledPython = Get-ChildItem -Path "$env:ProgramFiles/WindowsApps/OpenAI.CodexPrimaryRuntime.*/dependencies/python/python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if ($bundledPython) { $PythonPath = $bundledPython.FullName }
}
if (-not $PythonPath) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCommand -and $pythonCommand.Source -notlike '*Microsoft/WindowsApps*') { $PythonPath = $pythonCommand.Source }
}
if (-not $PythonPath) { throw 'Укажите Python 3.12+: ./Start-Sandbox.ps1 -PythonPath C:/path/python.exe' }
& $PythonPath -c 'import numpy, PIL'
if ($LASTEXITCODE -ne 0) { throw "Установите зависимости: & '$PythonPath' -m pip install -r '$atlasRoot/requirements.txt'" }
Push-Location -LiteralPath $atlasRoot
try {
    Write-Host "Откройте http://127.0.0.1:$Port . Окно сервера оставьте открытым. Остановка: Ctrl+C."
    & $PythonPath -m server.app --port $Port
} finally { Pop-Location }
