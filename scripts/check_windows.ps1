# Developer preflight only: no installation, account configuration or release.
# Requires an existing Swift Windows toolchain, Python 3 and .NET 10 SDK.
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
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("contextos-native-" + [guid]::NewGuid())
    $oldFixture = $env:CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT
    try {
        New-Item -ItemType Directory -Path "$fixture/project/Sources", "$fixture/outside" | Out-Null
        [IO.File]::WriteAllText("$fixture/project/Sources/valid.swift", "FIXTURE_BODY`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$fixture/outside/secret.txt", "DUMMY_OUTSIDE_BODY", [Text.UTF8Encoding]::new($false))
        New-Item -ItemType Junction -Path "$fixture/project/junction" -Value "$fixture/outside" | Out-Null
        New-Item -ItemType HardLink -Path "$fixture/project/hardlinked.txt" -Value "$fixture/outside/secret.txt" | Out-Null
        $env:CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT = $fixture
        & swift test --jobs 2 --no-parallel --filter 'PortableContractTests|WindowsPathPolicyTests|WindowsNativeFixtureTests'
        if ($LASTEXITCODE -ne 0) { throw "Shared/Windows native fixture tests failed." }
        $probe = Join-Path $fixture "contextos-native-probe.exe"
        & clang -std=c11 -Wall -Wextra -Werror -I Sources/CWindowsNative/include Sources/CWindowsNative/CWindowsNative.c Tests/WindowsNativeHarness/main.c -ladvapi32 -lbcrypt -o $probe
        if ($LASTEXITCODE -ne 0) { throw "Windows native harness compilation failed." }
        & $probe $fixture
        if ($LASTEXITCODE -ne 0) { throw "Native direct-call/ancestor/interprocess protection failed." }
    } finally {
        $env:CONTEXTOS_WINDOWS_NATIVE_TEST_ROOT = $oldFixture
        # Only this script's GUID-named disposable fixture is removed. Remove
        # the junction itself first so cleanup never traverses its target.
        if (Test-Path "$fixture/project/junction") { [IO.Directory]::Delete("$fixture/project/junction") }
        if (Test-Path $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    }
    $binaryDir = (& swift build --show-bin-path).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the Swift build directory." }
    & python scripts/verify_contract.py --cli "$binaryDir/contextos.exe" --mcp "$binaryDir/contextos-mcp.exe" --preparation --contract-output "$binaryDir/contextos-contract.json"
    if ($LASTEXITCODE -ne 0) { throw "CLI/MCP preparation contract check failed." }
    & python scripts/prepare_windows_gui.py --contract "$binaryDir/contextos-contract.json"
    if ($LASTEXITCODE -ne 0) { throw "Shared GUI identity generation failed." }
    & dotnet build Windows/ContextOS.Windows/ContextOS.Windows.csproj --configuration Debug --no-incremental
    if ($LASTEXITCODE -ne 0) { throw "Windows WPF compilation failed." }
    $guiDirectory = Join-Path $PWD "Windows/ContextOS.Windows/bin/Debug/net10.0-windows"
    $runtime = Join-Path $guiDirectory "runtime"
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    Copy-Item "$binaryDir/contextos.exe", "$binaryDir/contextos-mcp.exe" $runtime
    # Installed Swift runtime DLLs stay on this developer/CI host's PATH. This
    # output is not an installer or a redistributable customer package.
    $gui = Start-Process -FilePath "$guiDirectory/ContextOS.Windows.exe" -ArgumentList '--self-test' -PassThru -Wait
    if ($gui.ExitCode -ne 0) { throw "Windows GUI contract/layout self-test failed: $($gui.ExitCode)" }
    Write-Output '{"windows_preparation_build_passed":true,"native_fixture_passed":true,"gui_compile_passed":true,"gui_self_test_passed":true,"windows_product_ready":false}'
} finally {
    Pop-Location
}
