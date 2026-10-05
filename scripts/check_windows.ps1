# Developer preflight only: no installation, account configuration or release.
# Requires an existing Swift Windows toolchain, Python 3 and .NET 10 SDK.
$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "Run this preflight on Windows using PowerShell 7." }
$failures = [Collections.Generic.List[string]]::new()
function Invoke-Validation {
    param([string]$Name, [scriptblock]$Check)
    Write-Host "Validation stage: $Name"
    try {
        & $Check | Out-Host
        Write-Host "Passed stage: $Name"
        return $true
    } catch {
        $failures.Add("${Name}: " + $_.Exception.Message)
        Write-Host "Failed stage: $Name - $($_.Exception.Message)"
        return $false
    }
}
Push-Location (Split-Path $PSScriptRoot -Parent)
try {
    & swift --version
    if ($LASTEXITCODE -ne 0) { throw "Install/configure the official Swift Windows developer toolchain separately." }
    & python --version
    if ($LASTEXITCODE -ne 0) { throw "Configure the existing Python 3 executable before running this preflight." }
    & dotnet --version
    if ($LASTEXITCODE -ne 0) { throw "Configure the existing .NET 10 SDK before running this preflight." }
    $buildPassed = $true
    foreach ($product in @("contextos", "contextos-mcp")) {
        $passed = Invoke-Validation "Swift build $product" {
            & swift build --jobs 2 --product $product
            if ($LASTEXITCODE -ne 0) { throw "Preparation compilation failed." }
        }
        if (-not $passed) { $buildPassed = $false }
    }
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("contextos-native-" + [guid]::NewGuid())
    $oldFixture = $env:CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT
    try {
        New-Item -ItemType Directory -Path "$fixture/project/Sources", "$fixture/outside" | Out-Null
        [IO.File]::WriteAllText("$fixture/project/Sources/valid.swift", "FIXTURE_BODY`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$fixture/outside/secret.txt", "DUMMY_OUTSIDE_BODY", [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Junction -Path "$fixture/project/junction" -Value "$fixture/outside" | Out-Null
        New-Item -ItemType HardLink -Path "$fixture/project/hardlinked.txt" -Value "$fixture/outside/secret.txt" | Out-Null
        $env:CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT = $fixture
        if ($buildPassed) {
            $null = Invoke-Validation "Shared and native Swift fixtures" {
                & swift test --jobs 2 --no-parallel --filter 'PortableContractTests|WindowsPathPolicyTests|WindowsNativeFixtureTests'
                if ($LASTEXITCODE -ne 0) { throw "Shared/native fixture tests failed." }
            }
        } else { Write-Host "Skipped dependent Swift tests: build failed." }
        $null = Invoke-Validation "Direct native calls, ancestor protection and interprocess lock" {
            $probe = Join-Path $fixture "contextos-native-probe.exe"
            & clang -std=c11 -Wall -Wextra -Werror -I Sources/CWindowsNative/include Sources/CWindowsNative/CWindowsNative.c Tests/WindowsNativeHarness/main.c -ladvapi32 -lbcrypt -o $probe
            if ($LASTEXITCODE -ne 0) { throw "Native harness compilation failed." }
            & $probe $fixture
            if ($LASTEXITCODE -ne 0) { throw "Native boundary/interprocess verification failed." }
        }
    } finally {
        $env:CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT = $oldFixture
        # Only this script's GUID-named disposable fixture is removed. Remove
        # the junction itself first so cleanup never traverses its target.
        if (Test-Path "$fixture/project/junction") { [IO.Directory]::Delete("$fixture/project/junction") }
        if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
    $contractPassed = $false
    if ($buildPassed) {
        $binaryDir = (& swift build --show-bin-path).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the Swift build directory." }
        $contractPassed = Invoke-Validation "CLI/MCP version, schemas and protected routes" {
            & python scripts/verify_contract.py --cli "$binaryDir/contextos.exe" --mcp "$binaryDir/contextos-mcp.exe" --preparation --contract-output "$binaryDir/contextos-contract.json"
            if ($LASTEXITCODE -ne 0) { throw "CLI/MCP preparation contract verification failed." }
        }
    }
    if ($contractPassed) {
        $guiBuilt = Invoke-Validation "Shared GUI identity and WPF compilation" {
            & python scripts/prepare_windows_gui.py --contract "$binaryDir/contextos-contract.json"
            if ($LASTEXITCODE -ne 0) { throw "Shared GUI identity generation failed." }
            & dotnet build Windows/ContextOS.Windows/ContextOS.Windows.csproj --configuration Debug --no-incremental
            if ($LASTEXITCODE -ne 0) { throw "WPF compilation failed." }
        }
        if ($guiBuilt) {
            $null = Invoke-Validation "WPF contract and headless layout self-test" {
                $guiDirectory = Join-Path $PWD "Windows/ContextOS.Windows/bin/Debug/net10.0-windows"
                $runtime = Join-Path $guiDirectory "runtime"
                New-Item -ItemType Directory -Path $runtime -Force | Out-Null
                Copy-Item "$binaryDir/contextos.exe", "$binaryDir/contextos-mcp.exe" $runtime
                # Developer DLLs stay on PATH. This is not customer packaging.
                $guiLogs = Join-Path ([IO.Path]::GetTempPath()) ("contextos-gui-" + [guid]::NewGuid())
                New-Item -ItemType Directory -Path $guiLogs | Out-Null
                try {
                    $gui = Start-Process -FilePath "$guiDirectory/ContextOS.Windows.exe" -ArgumentList '--self-test' -PassThru `
                        -RedirectStandardOutput "$guiLogs/stdout.txt" -RedirectStandardError "$guiLogs/stderr.txt"
                    if (-not $gui.WaitForExit(60_000)) {
                        # Stop only the self-test process created immediately above.
                        $gui.Kill(); $gui.WaitForExit()
                        throw "Owned GUI self-test exceeded its one-minute limit."
                    }
                    Get-Content "$guiLogs/stdout.txt", "$guiLogs/stderr.txt" | Write-Host
                    if ($gui.ExitCode -ne 0) { throw "GUI self-test failed: $($gui.ExitCode)" }
                } finally { Remove-Item -LiteralPath $guiLogs -Recurse -Force }
            }
        } else { Write-Host "Skipped dependent WPF self-test: GUI build failed." }
    } else { Write-Host "Skipped dependent GUI build: shared contract did not pass." }
    if ($failures.Count -gt 0) { throw ("Validation failures:`n" + ($failures -join "`n")) }
    Write-Output '{"windows_preparation_build_passed":true,"native_fixture_passed":true,"gui_compile_passed":true,"gui_self_test_passed":true,"windows_product_ready":false}'
} finally {
    Pop-Location
}
