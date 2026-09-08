Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scripts = @(
    $PSCommandPath,
    (Join-Path $PSScriptRoot '..\..\install.ps1'),
    (Join-Path $PSScriptRoot 'New-PackageManifests.ps1'),
    (Join-Path $PSScriptRoot 'Stage-Payload.ps1'),
    (Join-Path $PSScriptRoot 'Test-PeMetadata.ps1'),
    (Join-Path $PSScriptRoot 'Test-Installer.ps1')
)
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        throw "PowerShell parse errors in ${script}: $($errors -join '; ')"
    }
}

$updateSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\update.rs') -Raw
if ($updateSource -notmatch 'include_str!\("\.\./install\.ps1"\)' -or
    $updateSource -notmatch '"-ExecutionPolicy",\s*\r?\n\s*"Bypass"' -or
    $updateSource -notmatch '\.prefix\("fortify-update-"\)' -or
    $updateSource -match '\.msi') {
    throw 'The Windows updater must embed the canonical ZIP installer, use its private temp prefix, and use no MSI path.'
}

$installerSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\install.ps1') -Raw
if ($installerSource -notmatch 'Net\.SecurityProtocolType\]::Tls12' -or
    $installerSource -notmatch "ProgressPreference = 'SilentlyContinue'" -or
    $installerSource -notmatch 'Invoke-WebRequest -UseBasicParsing') {
    throw 'The direct installer must retain its Windows PowerShell 5.1 download compatibility guards.'
}

. (Join-Path $PSScriptRoot '..\..\install.ps1')

if ((Resolve-FortifyVersion -RequestedVersion '1.2.3') -ne '1.2.3') {
    throw 'Version validation failed.'
}
foreach ($invalidVersion in @('v1.2.3', '1.2', '1.2.3-beta', '01.2.3', 'vv1.2.3', '../1.2.3')) {
    try {
        Resolve-FortifyVersion -RequestedVersion $invalidVersion | Out-Null
        throw "Malformed version was accepted: ${invalidVersion}"
    }
    catch {
        if ($_.Exception.Message -eq "Malformed version was accepted: ${invalidVersion}") { throw }
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("fortify-powershell-test-$([guid]::NewGuid())")
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $owned = Join-Path $testRoot 'owned'
    New-Item -ItemType Directory -Path $owned | Out-Null
    $legacyMarker = Join-Path $owned '.embrasure-install'
    Set-Content -LiteralPath $legacyMarker -Value 'EmbrasureAI.Embrasure' -Encoding ASCII
    if (-not (Test-OwnedInstallDirectory -Path $owned)) { throw 'Legacy ownership was rejected.' }
    Set-Content -LiteralPath $legacyMarker -Value 'EmbrasureAI.Fortify' -Encoding ASCII
    if (Test-OwnedInstallDirectory -Path $owned) { throw 'Mismatched ownership was accepted.' }
    Remove-Item -LiteralPath $legacyMarker
    Set-Content -LiteralPath (Join-Path $owned '.fortify-install') -Value 'EmbrasureAI.Fortify' -Encoding ASCII
    if (-not (Test-OwnedInstallDirectory -Path $owned)) { throw 'Fortify ownership was rejected.' }

    $manifests = Join-Path $testRoot 'manifests'
    & (Join-Path $PSScriptRoot 'New-PackageManifests.ps1') `
        -Version '0.6.0' -ArchiveSha256 ('a' * 64) -OutputDirectory $manifests
    $scoopdir = Join-Path $testRoot 'scoop'
    $globaldir = Join-Path $testRoot 'scoop-global'
    foreach ($package in @('fortify', 'embrasure')) {
        $other = if ($package -eq 'fortify') { 'embrasure' } else { 'fortify' }
        $manifest = Get-Content -LiteralPath (Join-Path $manifests "scoop\${package}.json") -Raw | ConvertFrom-Json
        if ($manifest.bin.Count -ne 2 -or $manifest.extract_dir -ne 'fortify-0.6.0-x86_64-pc-windows-msvc') {
            throw "Invalid ${package} package aliases or archive layout."
        }
        Invoke-Expression $manifest.pre_install
        foreach ($base in @($scoopdir, $globaldir)) {
            $conflict = Join-Path $base "apps\${other}\current"
            New-Item -ItemType Directory -Path $conflict -Force | Out-Null
            try {
                Invoke-Expression $manifest.pre_install
                throw 'Scoop accepted conflicting package ownership.'
            }
            catch {
                if ($_.Exception.Message -eq 'Scoop accepted conflicting package ownership.') { throw }
            }
            finally {
                Remove-Item -LiteralPath $conflict -Recurse -Force
            }
        }
    }

    $checksumFile = Join-Path $testRoot 'SHA256SUMS'
    $validHash = 'a' * 64
    Set-Content -LiteralPath $checksumFile -Value "${validHash}  artifact.zip" -Encoding ASCII
    if ((Read-ExpectedChecksum -ChecksumPath $checksumFile -FileName 'artifact.zip') -ne $validHash) {
        throw 'Checksum parsing failed.'
    }
    Add-Content -LiteralPath $checksumFile -Value "${validHash}  artifact.zip" -Encoding ASCII
    try {
        Read-ExpectedChecksum -ChecksumPath $checksumFile -FileName 'artifact.zip' | Out-Null
        throw 'Duplicate checksum was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Duplicate checksum was accepted.') { throw }
    }

    Set-Content -LiteralPath $checksumFile -Value 'not-a-hash  artifact.zip' -Encoding ASCII
    try {
        Read-ExpectedChecksum -ChecksumPath $checksumFile -FileName 'artifact.zip' | Out-Null
        throw 'Malformed checksum was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Malformed checksum was accepted.') { throw }
    }

    $hashFixture = Join-Path $testRoot 'artifact.zip'
    Set-Content -LiteralPath $hashFixture -Value 'original package' -Encoding ASCII
    $expectedHash = (Get-FileHash -LiteralPath $hashFixture -Algorithm SHA256).Hash
    Assert-FortifyHash -Path $hashFixture -Expected $expectedHash
    Add-Content -LiteralPath $hashFixture -Value 'mutation' -Encoding ASCII
    try {
        Assert-FortifyHash -Path $hashFixture -Expected $expectedHash
        throw 'Altered archive passed checksum verification.'
    }
    catch {
        if ($_.Exception.Message -eq 'Altered archive passed checksum verification.') { throw }
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unsafeArchive = Join-Path $testRoot 'unsafe.zip'
    $zip = [IO.Compression.ZipFile]::Open($unsafeArchive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        [void]$zip.CreateEntry('fortify-1.2.3-x86_64-pc-windows-msvc/../escape.txt')
    }
    finally {
        $zip.Dispose()
    }
    try {
        Assert-SafeZipArchive `
            -Path $unsafeArchive `
            -ExpectedRoot 'fortify-1.2.3-x86_64-pc-windows-msvc'
        throw 'Archive traversal path was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Archive traversal path was accepted.') { throw }
    }

    if (-not (Test-SamePath -Left 'C:\Tools\Fortify\bin\' -Right 'c:\tools\fortify\bin')) {
        throw 'Equivalent Windows PATH entries were not recognized.'
    }

    $safeUpdateDirectory = Join-Path ([IO.Path]::GetTempPath()) "fortify-update-$([guid]::NewGuid().ToString('N'))"
    $safeUpdateArchive = Join-Path $safeUpdateDirectory 'archive.zip'
    if (-not (Test-SamePath `
        -Left (Get-SafeUpdateCleanupDirectory -Path $safeUpdateArchive) `
        -Right $safeUpdateDirectory)) {
        throw 'The updater rejected its own temporary directory.'
    }
    try {
        Get-SafeUpdateCleanupDirectory -Path (Join-Path $testRoot 'archive.zip') | Out-Null
        throw 'The updater accepted an arbitrary cleanup directory.'
    }
    catch {
        if ($_.Exception.Message -eq 'The updater accepted an arbitrary cleanup directory.') { throw }
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
