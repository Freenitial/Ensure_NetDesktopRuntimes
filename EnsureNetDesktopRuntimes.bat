<# ::
    @echo off & setlocal
    title Ensure Windows Desktop Runtime - Launcher
    for %%A in ("/?" "-?" "--?" "/help" "-help" "--help") do if /I "%~1"=="%%~A" goto :help
    if exist %SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe   set "powershell=%SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe"
    if exist %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe  set "powershell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    set args=%*
    if defined args set "args=%args:"=\"%"
    :: PowerShell self-read, skipping batch part
    %powershell% -NoLogo -NoProfile -Ex Bypass -Command "$sb=[ScriptBlock]::Create([IO.File]::ReadAllText('%~f0'));& $sb @args" %args% -CD '%~dp0'
    exit /b %errorlevel%

    :HELP
    echo.
    echo  v1.0 - made by Léo Gillet / Freenitial on GitHub
    echo.
    echo  Ensure Windows Desktop Runtime installed
    echo  Can auto-detect setup files starting with 'windowsdesktop-runtime' in same script directory,
    echo  or give argument -setup paths, comma-separated
    echo.
    echo  Usage:
    echo    %~nx0 [options]
    echo.
    echo  Options:
    echo    -setup         [string] Setup files paths, comma-separated
    echo    -majorstrict   [switch] Check for exact major version match
    echo    -log           [string] Log file path or directory
    echo    -test          [switch] Just log without install
    echo.
    echo  Exit codes:
    echo    0  Installation completed successfully
    echo    2  Already installed
    echo    3  Installation failed
    echo    4  Setup file not found
    echo    5  Invalid arguments
    echo    6  Architecture incompatibility
    echo    7  Invalid setup configuration
    echo    8  Partial success
    echo    9  Parsing error
    echo.
    exit /b 0
#>

#Requires -Version 2.0
param(
    [string]$Setup = "",
    [switch]$MajorStrict,
    [string]$Log = "",
    [switch]$Test,
    [string]$CD = ""
)

# =================== SCRIPT VARIABLES ===================
$Script:ScriptDir = $CD
if ([string]::IsNullOrEmpty($Script:ScriptDir)) { $Script:ScriptDir = (Get-Location).Path }
$Script:LogFile = ""
$Script:OSArch = ""
$Script:IsWow64 = $false
$Script:Installers = @()

# =================== FUNCTIONS ===================

function Write-Log {
    param([string]$Message = "")
    $timestamp = [DateTime]::Now.ToString("dd/MM/yyyy HH:mm:ss")
    $line = if ([string]::IsNullOrEmpty($Message)) { "" } else { "[$timestamp] $Message" }
    [Console]::WriteLine($line)
    if (-not [string]::IsNullOrEmpty($Script:LogFile)) {
        try { [System.IO.File]::AppendAllText($Script:LogFile, "$line`r`n") }
        catch { }
    }
}

function Get-OSArchitecture {
    $processorArchW6432 = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITEW6432")
    $processorArch = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
    if ($processorArch -eq "AMD64" -or (-not [string]::IsNullOrEmpty($processorArchW6432))) { $Script:OSArch = "x64" }
    else                                                                                    { $Script:OSArch = "x86" }
    Write-Log "OS Architecture : $($Script:OSArch)"
    if ($Script:OSArch -eq "x64") {
        if ([System.IO.Directory]::Exists("$([Environment]::GetEnvironmentVariable('SystemRoot'))\Sysnative\")) {
               $Script:IsWow64 = $true   ;  Write-Log "Running as 32-bit process on 64-bit OS via WOW64"
        }
        else { $Script:IsWow64 = $false  ;  Write-Log "Running as 64-bit process on 64-bit OS" }
    } else   { $Script:IsWow64 = $false  ;  Write-Log "Running on 32-bit OS" }
}

function Get-SetupArchitecture {
    param([string]$FilePath)
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $last3    = if ($fileName.Length -ge 3) { $fileName.Substring($fileName.Length - 3) } else { "" }
    if ($last3 -ieq "x64") { return @{ Arch = "x64"; Source = "filename" } }
    if ($last3 -ieq "x86") { return @{ Arch = "x86"; Source = "filename" } }
    Write-Log "Architecture not found in filename, checking ProductName..."
    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FilePath)
        $productName = $versionInfo.ProductName
        if (-not [string]::IsNullOrEmpty($productName)) {
            Write-Log "ProductName : $productName"
            if ($productName -match '\(x64\)') { return @{ Arch = "x64"; Source = "ProductName" } }
            if ($productName -match '\(x86\)') { return @{ Arch = "x86"; Source = "ProductName" } }
        }
    }
    catch {
        Write-Log "ERROR : Failed to read file version info : $_"
    }
    return @{ Arch = ""; Source = "" }
}

function Get-SetupVersion {
    param([string]$FilePath)
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $segments = $fileName.Split('-')
    foreach ($segment in $segments) {
        if ($segment -match '^[0-9]+\.[0-9]+') {
            return @{ Version = $segment; Source = "filename" }
        }
    }
    Write-Log "Version not found in filename, checking file properties..."
    try {
        $versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($FilePath)
        $fileVersion = $versionInfo.FileVersion
        if (-not [string]::IsNullOrEmpty($fileVersion)) {
            return @{ Version = $fileVersion; Source = "FileVersion" }
        }
    }
    catch {
        Write-Log "ERROR : Failed to read file version : $_"
    }
    return @{ Version = ""; Source = "" }
}

function Split-Version {
    param([string]$Version)
    $parts = $Version.Split('.')
    $major = 0
    $minor = 0
    $patch = 0
    if ($parts.Length -ge 1) { [int]::TryParse($parts[0], [ref]$major) | Out-Null }
    if ($parts.Length -ge 2) { [int]::TryParse($parts[1], [ref]$minor) | Out-Null }
    if ($parts.Length -ge 3) { [int]::TryParse($parts[2], [ref]$patch) | Out-Null }
    return @{ Major = $major; Minor = $minor; Patch = $patch }
}

function Test-VersionMeetsRequirement {
    param([int]$InstMajor, [int]$InstMinor, [int]$InstPatch, [int]$ReqMajor, [int]$ReqMinor, [int]$ReqPatch, [bool]$StrictMajor)
    if ($StrictMajor) {
        if ($InstMajor -ne $ReqMajor) { return $false }
        if ($InstMinor -gt $ReqMinor) { return $true }
        if ($InstMinor -eq $ReqMinor -and $InstPatch -ge $ReqPatch) { return $true }
        return $false
    }
    else {
        if ($InstMajor -gt $ReqMajor) { return $true }
        if ($InstMajor -lt $ReqMajor) { return $false }
        if ($InstMinor -gt $ReqMinor) { return $true }
        if ($InstMinor -lt $ReqMinor) { return $false }
        if ($InstPatch -ge $ReqPatch) { return $true }
        return $false
    }
}

function Test-InstalledRuntime {
    param([string]$Arch, [int]$ReqMajor, [int]$ReqMinor, [int]$ReqPatch)
    Write-Log "Checking installed .NET Desktop Runtime for $Arch (requires $ReqMajor.$ReqMinor.$ReqPatch)..."
    $regPath = if ($Script:OSArch -eq "x64") { "SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" }
    else                                     { "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" }
    Write-Log "Registry path : HKLM\$regPath"
    try {
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($regPath)
        if ($null -eq $regKey) {
            Write-Log "Registry key not found."
            return $false
        }
        $subKeyNames = $regKey.GetSubKeyNames()
        foreach ($subKeyName in $subKeyNames) {
            try {
                $subKey = $regKey.OpenSubKey($subKeyName)
                if ($null -eq $subKey)                                          { continue }
                $systemComponent = $subKey.GetValue("SystemComponent")
                if ($null -ne $systemComponent -and $systemComponent -eq 1)     { $subKey.Close() ; continue }
                $displayName = $subKey.GetValue("DisplayName")
                if ([string]::IsNullOrEmpty($displayName))                      { $subKey.Close() ; continue }
                if ($displayName -notmatch "Microsoft Windows Desktop Runtime") { $subKey.Close() ; continue }
                if ($displayName -notmatch "\($Arch\)")                         { $subKey.Close() ; continue }
                $displayVersion = $subKey.GetValue("DisplayVersion")
                $subKey.Close()
                if ([string]::IsNullOrEmpty($displayVersion))                   { continue }
                Write-Log "Found   : $displayName"
                Write-Log "Version : $displayVersion"
                $ver   = Split-Version -Version $displayVersion
                $meets = Test-VersionMeetsRequirement `
                    -InstMajor $ver.Major -InstMinor $ver.Minor -InstPatch $ver.Patch `
                    -ReqMajor $ReqMajor -ReqMinor $ReqMinor -ReqPatch $ReqPatch `
                    -StrictMajor $MajorStrict
                if ($meets) {
                    Write-Log "Version $displayVersion meets requirements"
                    $regKey.Close()
                    return $true
                }
            }
            catch { }
        }
        $regKey.Close()
    }
    catch {
        Write-Log "ERROR : Failed to query registry : $_"
    }
    Write-Log "No compatible version found for $Arch major $ReqMajor."
    return $false
}

function Install-Runtime {
    param([string]$Arch, [string]$SetupPath, [string]$Version)
    $logDir   = [System.IO.Path]::GetDirectoryName($Script:LogFile)
    $logName  = [System.IO.Path]::GetFileNameWithoutExtension($Script:LogFile)
    $logExt   = [System.IO.Path]::GetExtension($Script:LogFile)
    $verClean = $Version -replace '[^0-9.]', ''
    $setupLog = [System.IO.Path]::Combine($logDir, "${logName}_Install_${Arch}_v${verClean}${logExt}")
    Write-Log "Installing $Arch runtime version $Version"
    Write-Log "Setup file : $SetupPath"
    Write-Log "Setup log  : $setupLog"
    if ($Test) {
        Write-Log "TEST MODE : Would execute installer with /install /quiet /norestart"
        return "success"
    }
    Write-Log "Executing installer..."
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = $SetupPath
        $psi.Arguments       = "/install /quiet /norestart /log `"$setupLog`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $process             = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        $exitCode            = $process.ExitCode
        $process.Close()
        Write-Log "Installation exit code : $exitCode"
        switch ($exitCode) {
            0       { Write-Log "$Arch v$Version runtime installed successfully."                      ; return "success" }
            3010    { Write-Log "$Arch v$Version runtime installed successfully. Reboot required."     ; return "success" }
            1638    { Write-Log "$Arch v$Version runtime : A newer version is already installed."      ; return "already" }
            1602    { Write-Log "$Arch v$Version installation was cancelled."                          ; return "cancelled" }
            default { Write-Log "ERROR : $Arch v$Version installation failed with exit code $exitCode" ; return "failed" }
        }
    }
    catch { Write-Log "ERROR : Failed to execute installer : $_" ; return "failed" }
}

function Initialize-LogFile {
    $logFileName = "Ensure_DotNet.log"
    $logFilePath = ""
    $logDir = ""
    if ([string]::IsNullOrEmpty($Log)) {
        $tempDir = [Environment]::GetEnvironmentVariable("TEMP")
        if ([string]::IsNullOrEmpty($tempDir)) { $tempDir = [Environment]::GetEnvironmentVariable("TMP") }
        if ([string]::IsNullOrEmpty($tempDir)) { $tempDir = "C:\Windows\Temp" }
        $logFilePath = $tempDir + "\" + $logFileName
        $logDir      = $tempDir
    }
    else {
        $pathToCheck = $Log.TrimEnd('\')
        if     ([System.IO.Directory]::Exists($pathToCheck)) { $logFilePath = $pathToCheck + "\" + $logFileName ; $logDir = $pathToCheck }
        elseif ($Log.EndsWith("\"))                          { $logFilePath = $pathToCheck + "\" + $logFileName ; $logDir = $pathToCheck }
        else {
            $logFilePath = $Log
            $lastSlash = $Log.LastIndexOf("\")
            if ($lastSlash -gt 0) { $logDir = $Log.Substring(0, $lastSlash) }
            else                  { $logDir = $Script:ScriptDir ; $logFilePath = $logDir + "\" + $Log }
        }
    }
    $Script:LogFile = $logFilePath
    if (-not [System.IO.Directory]::Exists($logDir)) {
        [Console]::WriteLine("ERROR : Log directory does not exist : $logDir")
        exit 5
    }
    $testFile = $logDir + "\__write_test_" + [Guid]::NewGuid().ToString("N") + ".tmp"
    try {
        [System.IO.File]::WriteAllText($testFile, "test")
        [System.IO.File]::Delete($testFile)
    }
    catch {
        [Console]::WriteLine("ERROR : Cannot write to log directory : $logDir")
        exit 5
    }
    if ([System.IO.File]::Exists($Script:LogFile)) {
        [System.IO.File]::AppendAllText($Script:LogFile, "`r`n================`r`n`r`n")
    }
}

function Find-SetupFiles {
    Write-Log "No -Setup argument provided, scanning script directory..."
    $pattern    = "windowsdesktop-runtime*.exe"
    $searchPath = $Script:ScriptDir
    $files      = [System.IO.Directory]::GetFiles($searchPath, $pattern)
    $count      = $files.Length
    if ($count -eq 0) {
        Write-Log "ERROR : No installer found matching windowsdesktop-runtime in $searchPath"
        Write-Log "Directory contents :"
        $allFiles = [System.IO.Directory]::GetFiles($searchPath)
        foreach ($f in $allFiles) { Write-Log "  $([System.IO.Path]::GetFileName($f))" }
        exit 4
    }
    Write-Log "Found $count installer file(s)"
    return ($files -join ",")
}

function Resolve-SetupPath {
    param([string]$FilePath)
    if ([System.IO.File]::Exists($FilePath)) { return $FilePath }
    $resolved = [System.IO.Path]::Combine($Script:ScriptDir, $FilePath)
    if ([System.IO.File]::Exists($resolved)) { return $resolved }
    return ""
}

function Test-InstallerDuplicates {
    $grouped = @{}
    foreach ($inst in $Script:Installers) {
        $key = "$($inst.Arch)"
        if ($MajorStrict) { $key = "$($inst.Arch)_$($inst.Major)" }
        if (-not $grouped.ContainsKey($key)) { $grouped[$key] = @() }
        $grouped[$key] += $inst
    }
    foreach ($key in $grouped.Keys) {
        $items = $grouped[$key]
        if ($items.Count -gt 1) {
            $arch = $items[0].Arch
            if ($MajorStrict) {
                $major = $items[0].Major
                Write-Log "ERROR : Multiple $arch installers specified for major version $major."
                Write-Log "When using -MajorStrict, only one installer per architecture per major version is allowed."
            }
            else {
                Write-Log "ERROR : Multiple $arch installers specified."
                Write-Log "Without -MajorStrict, only one installer per architecture is allowed."
                Write-Log "Use -MajorStrict to allow multiple installers with different major versions."
            }
            foreach ($item in $items) {
                Write-Log "  - $([System.IO.Path]::GetFileName($item.Path)) (v$($item.Version))"
            }
            exit 7
        }
    }
}

# =================== MAIN SCRIPT ===================

Initialize-LogFile

Write-Log "============================================"
Write-Log " Ensure DotNet Script Started"
Write-Log "============================================"
Write-Log ""

Write-Log "--- Detecting System Architecture ---"
Get-OSArchitecture
Write-Log ""

Write-Log "--- Setup File Discovery ---"
$setupArg = $Setup
if ([string]::IsNullOrEmpty($setupArg)) { $setupArg = Find-SetupFiles }

$setupFiles = $setupArg.Split(',')
$setupCount = $setupFiles.Length
Write-Log "Setup file count : $setupCount"

for ($i = 0; $i -lt $setupFiles.Length; $i++) {
    $currentFile = $setupFiles[$i].Trim()
    if ([string]::IsNullOrEmpty($currentFile)) { continue }
    Write-Log ""
    Write-Log "Processing setup file $($i + 1) : $currentFile"
    $resolvedPath = Resolve-SetupPath -FilePath $currentFile
    if ([string]::IsNullOrEmpty($resolvedPath)) {
        Write-Log "ERROR : Setup file not found : $currentFile"
        exit 4
    }
    if ($resolvedPath -ne $currentFile) { Write-Log "Resolved to : $resolvedPath" }
    $currentFile = $resolvedPath
    $archResult  = Get-SetupArchitecture -FilePath $currentFile
    if ([string]::IsNullOrEmpty($archResult.Arch)) {
        Write-Log "ERROR : Could not detect architecture for : $([System.IO.Path]::GetFileName($currentFile))"
        Write-Log "Expected filename ending with -x64.exe or -x86.exe"
        exit 9
    }
    Write-Log "Detected architecture : $($archResult.Arch) via $($archResult.Source)"
    $verResult = Get-SetupVersion -FilePath $currentFile
    if ([string]::IsNullOrEmpty($verResult.Version)) {
        Write-Log "ERROR : Could not extract version from : $([System.IO.Path]::GetFileName($currentFile))"
        exit 9
    }
    $verParts = Split-Version -Version $verResult.Version
    if ($verParts.Major -eq 0 -and $verParts.Minor -eq 0 -and $verParts.Patch -eq 0) {
        Write-Log "ERROR : Could not parse version from : $($verResult.Version)"
        exit 9
    }
    Write-Log "Extracted version : $($verResult.Version) as $($verParts.Major).$($verParts.Minor).$($verParts.Patch)"
    $installer = @{
        Path    = $currentFile
        Arch    = $archResult.Arch
        Version = $verResult.Version
        Major   = $verParts.Major
        Minor   = $verParts.Minor
        Patch   = $verParts.Patch
        Result  = "pending"
    }
    $Script:Installers += $installer
}

Write-Log ""
Write-Log "--- Validating Installer Configuration ---"
Test-InstallerDuplicates
Write-Log "Installer validation passed."

Write-Log ""
Write-Log "--- Architecture Compatibility Check ---"

$hasX64Installer = $false
foreach ($inst in $Script:Installers) {
    if ($inst.Arch -eq "x64") { $hasX64Installer = $true ; break }
}

if ($Script:OSArch -eq "x86" -and $hasX64Installer) {
    Write-Log "ERROR : Cannot install x64 runtime on 32-bit operating system."
    exit 6
}

Write-Log "Registered installers :"
foreach ($inst in $Script:Installers) {
    Write-Log "  $($inst.Arch) v$($inst.Version) : $([System.IO.Path]::GetFileName($inst.Path))"
}

Write-Log ""
Write-Log "--- Configuration Summary ---"
Write-Log "Script directory  : $($Script:ScriptDir)"
Write-Log "Log file          : $($Script:LogFile)"
Write-Log "OS architecture   : $($Script:OSArch)"
Write-Log "WOW64 context     : $($Script:IsWow64)"
Write-Log "Major strict mode : $MajorStrict"
Write-Log "Test mode         : $Test"
Write-Log "Installer count   : $($Script:Installers.Count)"
Write-Log "----------------------------"
Write-Log ""

if ($Test) {
    Write-Log "*** TEST MODE ENABLED - No installation will be performed ***"
    Write-Log ""
}

Write-Log "--- Checking Installed Versions ---"

$installersToRun = @()

for ($i = 0; $i -lt $Script:Installers.Count; $i++) {
    $inst = $Script:Installers[$i]
    Write-Log ""
    Write-Log "Checking $($inst.Arch) v$($inst.Major).$($inst.Minor).$($inst.Patch)..."
    $isInstalled = Test-InstalledRuntime -Arch $inst.Arch -ReqMajor $inst.Major -ReqMinor $inst.Minor -ReqPatch $inst.Patch
    if ($isInstalled) {
        $Script:Installers[$i].Result = "skip"
        Write-Log "Already installed, skipping."
    }
    else {
        $installersToRun += $i
        Write-Log "Installation required."
    }
}

Write-Log ""
Write-Log "--- Installation Requirements ---"

if ($installersToRun.Count -eq 0) {
    Write-Log "All required .NET Runtime versions are already installed."
    Write-Log "Script completed successfully."
    exit 2
}

Write-Log "Installers to run : $($installersToRun.Count)"

foreach ($idx in $installersToRun) {
    $inst = $Script:Installers[$idx]
    Write-Log ""
    Write-Log "--- Installing $($inst.Arch) v$($inst.Version) ---"
    $result = Install-Runtime -Arch $inst.Arch -SetupPath $inst.Path -Version $inst.Version
    $Script:Installers[$idx].Result = $result
}

Write-Log ""
Write-Log "============================================"
Write-Log " Installation Summary"
Write-Log "============================================"

$countSuccess = 0
$countFailed  = 0
$countSkipped = 0

foreach ($inst in $Script:Installers) {
    $label = "$($inst.Arch) v$($inst.Version)"
    switch ($inst.Result) {
        "success"   { Write-Log "$label : Installed successfully"             ; $countSuccess++ }
        "already"   { Write-Log "$label : Already installed, no action taken" ; $countSkipped++ }
        "skip"      { Write-Log "$label : Skipped, already met requirements"  ; $countSkipped++ }
        "cancelled" { Write-Log "$label : CANCELLED"                          ; $countFailed++ }
        "pending"   { Write-Log "$label : PENDING (unexpected)"               ; $countFailed++ }
        default     { Write-Log "$label : FAILED"                             ; $countFailed++ }
    }
}

Write-Log ""
Write-Log "Results : $countSuccess installed, $countFailed failed, $countSkipped skipped"
Write-Log ""

if ($countFailed -gt 0) {
    if ($countSuccess -gt 0) {
        Write-Log "Script completed with PARTIAL SUCCESS."
        Write-Log "Some installations failed, review log for details."
        exit 8
    }
    else {
        Write-Log "Script completed with ERRORS."
        exit 3
    }
}
elseif ($countSuccess -gt 0) {
    Write-Log "Script completed successfully."
    exit 0
}
else {
    Write-Log "Script completed. No installation was needed."
    exit 2
}
