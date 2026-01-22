# **Ensure .NET Windows Desktop Runtime installed**

**Detects, validates, and installs silently provided _.NET Desktop Runtime_ setup files (x86 / x64).**

---

## Features ✨

* 🔍 **Auto-discovery**: Detects `windowsdesktop-runtime*.exe` installers in the script directory.
* 📦 **Multi-version support**: Handles multiple runtime versions and architectures.
* 🧠 **Version-aware detection**: Major / minor / patch comparison.
* 📐 **Strict mode**: Compare only exact major version to determine if already installed.
* 🧾 **Detailed logging**: Console + file logs, per-installer setup logs.

---

## Why this tool?

This script ensures:
* Accurate detection of installed runtimes
* Deterministic version comparison
* Installation of only what is missing

Designed for unattended and enterprise deployments (SCCM, Intune, SYSTEM context).

---

## Parameters 🛠️

| Parameter        | Type   | Description |
|------------------|--------|-------------|
| `-Setup`         | String | Comma-separated installer paths. If omitted, installers are auto-detected in the script directory. |
| `-MajorStrict`   | Switch | Enforces exact major version matching. Allows multiple major versions when enabled. |
| `-Log`           | String | Log file path or directory. Defaults to system TEMP if not specified. |
| `-Test`          | Switch | Test mode. Detection and logging only, no installation performed. |

---

## Installer Naming Convention 📛

Recommended format:

```
windowsdesktop-runtime-<version>-x64.exe
windowsdesktop-runtime-<version>-x86.exe
````

Architecture and version are resolved in this order:
1. Installer filename
2. File metadata (ProductName / FileVersion)

If detection fails, the script exits with an error.

---

## Usage Examples 📘

### Automatic discovery (same directory)

```bat
EnsureDotNetRuntime.bat
```

---

### Explicit installer paths

```bat
EnsureDotNetRuntime.bat ^
  -Setup windowsdesktop-runtime-8.0.1-x64.exe,windowsdesktop-runtime-6.0.25-x86.exe ^
  -Log C:\Logs
```

---

### Strict major version mode

```bat
EnsureDotNetRuntime.bat ^
  -Setup windowsdesktop-runtime-6.0.25-x64.exe,windowsdesktop-runtime-8.0.1-x64.exe ^
  -MajorStrict
```

---

### Test mode (no install, only log)

```bat
EnsureDotNetRuntime.bat -Test
```

---

## Return Codes 🔢

| Code | Meaning                                 |
| ---: | --------------------------------------- |
|    0 | Installation completed successfully     |
|    2 | All required runtimes already installed |
|    3 | Installation failed                     |
|    4 | Setup file not found                    |
|    5 | Invalid arguments or log path error     |
|    6 | Architecture incompatibility            |
|    7 | Invalid installer configuration         |
|    8 | Partial success                         |
|    9 | Parsing or version detection error      |

---

## How it Works 🔬

### 1) Bootstrap (Batch → PowerShell)

* Batch launcher bypass powershell policy
* The script self-reads and executes the embedded PowerShell logic.

---

### 2) Installer Discovery

* Uses `-Setup` if provided.
* Otherwise scans the script directory for:

  ```
  windowsdesktop-runtime*.exe
  ```

---

### 3) Metadata Extraction

For each installer:
* Architecture detected from filename or ProductName.
* Version extracted from filename or FileVersion.
* Version split into major, minor, and patch components.

---

### 4) Validation

* Prevents duplicate installers:
  * One per architecture by default
  * One per architecture and major version when `-MajorStrict` is enabled
* Fails on ambiguous or invalid configurations.

---

### 5) Installed Runtime Detection

* Queries Windows Uninstall registry keys.
* Filters by:
  * Runtime name
  * Architecture
* Compares installed versions against required versions.

---

### 6) Installation

* Executes installers silently with:

  ```
  /install /quiet /norestart
  ```
* Generates a dedicated installation log per runtime.
* Handles known installer exit codes (success, reboot required, already installed).

---

## Logging 🧾

* Default log file:

  ```
  %TEMP%\Ensure_DotNet.log
  ```
* Custom file or directory supported via `-Log`.
* Per-runtime install logs:

  ```
  Ensure_DotNet_Install_x64_v<version>.log
  ```

---

## Compatibility ✅

* **PowerShell**: 2.0+
* **Windows**: 7+
