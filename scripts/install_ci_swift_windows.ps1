# Official tool installation on an ephemeral GitHub standard Windows runner.
# Never invoked by the app, regular preflight, or a customer install path.
$ErrorActionPreference = "Stop"
if (-not $IsWindows -or $env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ARCH -ne "X64") {
    throw "This bootstrap is restricted to a disposable GitHub Windows x64 runner."
}
$event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json
if ($event.repository.private -or $env:GITHUB_REPOSITORY -ne 'sj03090309/ContextOS') {
    throw "Expected the approved public ContextOS repository."
}
# Resolve only the pinned stable series from its official installation page.
$page = Invoke-WebRequest -Uri 'https://www.swift.org/install/windows/'
$links = @($page.Links.href | Where-Object { $_ -match '^https://download\.swift\.org/swift-6\.4(?:\.0)?-release/[^\s]+\.exe$' -and $_ -notmatch 'arm64' } | Select-Object -Unique)
if ($links.Count -ne 1) { throw "The official Swift 6.4 x64 installer link is not unambiguous. Stop for review." }
$installer = Join-Path $env:RUNNER_TEMP 'swift-6.4-windows.exe'
Invoke-WebRequest -Uri $links[0] -OutFile $installer
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid') { throw "Official Swift installer signature is not valid; installation refused." }
if ($signature.SignerCertificate.Subject -notmatch 'Swift|Apple') { throw "Unexpected Swift installer signer; installation refused." }
Write-Output ("Official installer SHA256: " + (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash)
$install = Start-Process -FilePath $installer -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
if ($install.ExitCode -notin @(0, 3010)) { throw "Swift installer failed: $($install.ExitCode)" }
foreach ($name in @('Path', 'SDKROOT', 'DEVELOPER_DIR')) {
    $machine = [Environment]::GetEnvironmentVariable($name, 'Machine')
    $user = [Environment]::GetEnvironmentVariable($name, 'User')
    # GITHUB_PATH prepends entries in the following step. Export only Swift
    # directories, never the full machine/user PATH (which would promote Store
    # execution aliases over the runner's existing Python/.NET locations).
    $swiftPaths = @()
    if ($name -eq 'Path') {
        $swiftPaths = @(("$machine;$user" -split ';') | Where-Object { $_ -match '(?i)[\\/]Swift[\\/]' } | Select-Object -Unique)
        if ($swiftPaths.Count -eq 0) { throw "The official installer did not register Swift directories." }
        $value = "$env:Path;" + ($swiftPaths -join ';')
    } else { $value = if ($user) { $user } else { $machine } }
    if ($value) {
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        if ($name -eq 'Path') { $swiftPaths | Add-Content -LiteralPath $env:GITHUB_PATH }
        else { "$name=$value" | Add-Content -LiteralPath $env:GITHUB_ENV }
    }
}
& swift --version
if ($LASTEXITCODE -ne 0) { throw "Installed official Swift toolchain is not available." }
