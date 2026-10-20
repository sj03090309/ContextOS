# Developer preflight only: no installation, account configuration or release.
# Requires an existing Swift Windows toolchain and Python 3 on PATH.
$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "Run this preflight on Windows using PowerShell 7." }
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & swift --version
    if ($LASTEXITCODE -ne 0) { throw "Install/configure the official Swift Windows developer toolchain separately." }
    foreach ($product in @("contextos", "contextos-mcp")) {
        & swift build --jobs 2 --product $product
        if ($LASTEXITCODE -ne 0) { throw "Windows preparation build failed: $product" }
    }
    & swift test --jobs 2 --no-parallel --filter PortableContractTests
    if ($LASTEXITCODE -ne 0) { throw "Portable contract tests failed." }
    $binaryDir = (& swift build --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the Swift build directory." }
    & python scripts/verify_contract.py --cli "$binaryDir/contextos.exe" --mcp "$binaryDir/contextos-mcp.exe" --preparation --contract-output "$binaryDir/contextos-contract.json"
    if ($LASTEXITCODE -ne 0) { throw "CLI/MCP preparation contract check failed." }
    Write-Output "Preparation checks passed. Windows project access, connection management, file watching and GUI remain unavailable."
} finally {
    Pop-Location
}
