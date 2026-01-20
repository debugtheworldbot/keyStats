# KeyStats Windows Build Script
# Usage: .\build.ps1 [Release|Debug]

param(
    [string]$Configuration = "Release"
)

# Set console output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"

# 获取脚本所在目录
# 使用 $PSScriptRoot（PowerShell 3.0+），如果不可用则回退到 $MyInvocation
$ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $ScriptDir) {
    Write-Host "Error: Cannot determine script directory. Please run this script from its location." -ForegroundColor Red
    exit 1
}

$ProjectDir = Join-Path $ScriptDir "KeyStats"
$ProjectFile = Join-Path $ProjectDir "KeyStats.csproj"
$OutputDir = Join-Path $ScriptDir "publish"
$DistDir = Join-Path $ScriptDir "dist"

Write-Host "=== KeyStats Windows Build Script ===" -ForegroundColor Cyan
Write-Host "Configuration: $Configuration" -ForegroundColor Yellow
Write-Host "Target Framework: .NET Framework 4.8" -ForegroundColor Yellow
Write-Host ""

# Check if project file exists
if (-not (Test-Path $ProjectFile)) {
    Write-Host "Error: Project file not found: $ProjectFile" -ForegroundColor Red
    exit 1
}

# Clean previous builds
Write-Host "Cleaning previous builds..." -ForegroundColor Cyan

# Try to stop running KeyStats processes
$processes = Get-Process -Name "KeyStats" -ErrorAction SilentlyContinue
if ($processes) {
    Write-Host "Stopping running KeyStats processes..." -ForegroundColor Yellow
    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

# Wait a bit for files to be released
Start-Sleep -Seconds 0.5

# Remove output directory with retry logic
if (Test-Path $OutputDir) {
    $retries = 3
    $retryCount = 0
    while ($retryCount -lt $retries) {
        try {
            Remove-Item -Path $OutputDir -Recurse -Force -ErrorAction Stop
            break
        }
        catch {
            $retryCount++
            if ($retryCount -lt $retries) {
                Write-Host "Retry ${retryCount}/${retries}: Waiting before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            else {
                Write-Host "Warning: Could not remove $OutputDir. Some files may be locked." -ForegroundColor Yellow
            }
        }
    }
}

# Remove dist directory with retry logic
if (Test-Path $DistDir) {
    $retries = 3
    $retryCount = 0
    while ($retryCount -lt $retries) {
        try {
            Remove-Item -Path $DistDir -Recurse -Force -ErrorAction Stop
            break
        }
        catch {
            $retryCount++
            if ($retryCount -lt $retries) {
                Write-Host "Retry ${retryCount}/${retries}: Waiting before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            else {
                Write-Host "Warning: Could not remove $DistDir. Some files may be locked." -ForegroundColor Yellow
            }
        }
    }
}

# Restore dependencies
Write-Host "Restoring dependencies..." -ForegroundColor Cyan
Push-Location $ScriptDir
try {
    dotnet restore $ProjectFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Restore failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host "Restore succeeded!" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Build project
Write-Host "Building project..." -ForegroundColor Cyan
Push-Location $ScriptDir
try {
    dotnet build $ProjectFile -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host "Build succeeded!" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Build and publish project
Write-Host "Building project..." -ForegroundColor Cyan
Write-Host "Target Framework: .NET Framework 4.8 (运行时已预装在 Windows 10/11)" -ForegroundColor Yellow
Write-Host "应用大小: 约 5-10 MB，开箱即用" -ForegroundColor Green

Push-Location $ScriptDir
try {
    dotnet build $ProjectFile -c $Configuration -o $OutputDir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed!" -ForegroundColor Red
        exit 1
    }
    
    # 复制输出文件
    $BinDir = Join-Path $ProjectDir "bin\$Configuration\net48"
    if (Test-Path $BinDir) {
        Copy-Item -Path "$BinDir\*" -Destination $OutputDir -Recurse -Force
    }
    
    Write-Host "Build succeeded!" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Create distribution package
Write-Host "Creating distribution package..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# Get version number (supports formats like 1.0.0, 1.15, 1.15-test, 1.15.0-beta)
$VersionMatch = Select-String -Path $ProjectFile -Pattern '<Version>([^<]+)</Version>'
if ($VersionMatch -and $VersionMatch.Matches.Groups[1].Value) {
    $Version = $VersionMatch.Matches.Groups[1].Value.Trim()
} else {
    $Version = "1.0.0"
}

# Determine zip name
$ZipName = "KeyStats-Windows-$Version-NetFramework48.zip"
$ZipPath = Join-Path $DistDir $ZipName

# Copy files to temporary directory
$TempDir = Join-Path $DistDir "KeyStats-$Version"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

Write-Host "Copying files..." -ForegroundColor Cyan
Copy-Item -Path "$OutputDir\*" -Destination $TempDir -Recurse -Force

# 创建 README
$ReadmeLines = @(
    "KeyStats for Windows",
    "Version: $Version",
    "",
    "Installation:",
    "1. Extract this ZIP file to any directory",
    "2. Run KeyStats.exe",
    "3. Grant necessary permissions on first run",
    "",
    "Note: This version uses .NET Framework 4.8, which is pre-installed on Windows 10/11.",
    "No additional installation required - ready to use!",
    ""
)

$ReadmeLines += @(
    "Data Storage:",
    "%LOCALAPPDATA%\KeyStats",
    "",
    "Uninstall:",
    "Simply delete the program folder. Data will remain in user data directory.",
    "",
    "System Requirements:",
    "- Windows 10 (1903+) or Windows 11",
    "- No .NET runtime installation required (uses pre-installed .NET Framework 4.8)"
)

$ReadmePath = Join-Path $TempDir "README.txt"
$ReadmeContent = $ReadmeLines -join "`r`n"
[System.IO.File]::WriteAllText($ReadmePath, $ReadmeContent, [System.Text.Encoding]::UTF8)

# Create ZIP file
Write-Host "Creating ZIP file..." -ForegroundColor Cyan
if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force
}

# Use .NET compression to create ZIP
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($TempDir, $ZipPath)

# Clean up temporary directory
Remove-Item -Path $TempDir -Recurse -Force

Write-Host ""
Write-Host "=== Build Complete ===" -ForegroundColor Green
Write-Host "Output file: $ZipPath" -ForegroundColor Cyan
Write-Host "File size: $([math]::Round((Get-Item $ZipPath).Length / 1MB, 2)) MB" -ForegroundColor Cyan
Write-Host ""
Write-Host "Published files location:" -ForegroundColor Yellow
Write-Host "  $OutputDir" -ForegroundColor White
Write-Host ""
Write-Host "Distribution package location:" -ForegroundColor Yellow
Write-Host "  $ZipPath" -ForegroundColor White
