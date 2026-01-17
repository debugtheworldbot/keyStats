# KeyStats Windows Build Script
# Usage: .\build.ps1 [Release|Debug] [SelfContained|FrameworkDependent]

param(
    [string]$Configuration = "Release",
    [string]$PublishType = "SelfContained",
    [string]$Runtime = "win-x64"
)

# Set console output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"

# 获取脚本所在目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Join-Path $ScriptDir "KeyStats"
$ProjectFile = Join-Path $ProjectDir "KeyStats.csproj"
$OutputDir = Join-Path $ScriptDir "publish"
$DistDir = Join-Path $ScriptDir "dist"

Write-Host "=== KeyStats Windows Build Script ===" -ForegroundColor Cyan
Write-Host "Configuration: $Configuration" -ForegroundColor Yellow
Write-Host "Publish Type: $PublishType" -ForegroundColor Yellow
Write-Host "Runtime: $Runtime" -ForegroundColor Yellow
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

# Publish project
Write-Host "Publishing project..." -ForegroundColor Cyan
Push-Location $ScriptDir
try {
    $PublishArgs = @(
        "publish",
        $ProjectFile,
        "-c", $Configuration,
        "-r", $Runtime,
        "-o", $OutputDir
    )
    
    if ($PublishType -eq "SelfContained") {
        $PublishArgs += "--self-contained", "true"
        $PublishArgs += "-p:PublishSingleFile=true"
        $PublishArgs += "-p:IncludeNativeLibrariesForSelfExtract=true"
        Write-Host "Publish Type: Self-contained single file" -ForegroundColor Yellow
    } else {
        $PublishArgs += "--self-contained", "false"
        Write-Host "Publish Type: Framework-dependent" -ForegroundColor Yellow
    }
    
    dotnet @PublishArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Publish failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host "Publish succeeded!" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Create distribution package
Write-Host "Creating distribution package..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

# Get version number
$Version = (Select-String -Path $ProjectFile -Pattern '<Version>(\d+\.\d+\.\d+)</Version>').Matches.Groups[1].Value
if (-not $Version) {
    $Version = "1.0.0"
}

$ZipName = "KeyStats-Windows-$Version-$Runtime-$PublishType.zip"
$ZipPath = Join-Path $DistDir $ZipName

# Copy files to temporary directory
$TempDir = Join-Path $DistDir "KeyStats"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

Write-Host "Copying files..." -ForegroundColor Cyan
Copy-Item -Path "$OutputDir\*" -Destination $TempDir -Recurse -Force

# 创建 README
$RuntimeRequirement = if ($PublishType -eq "SelfContained") { 
    "No .NET runtime required" 
} else { 
    ".NET 8.0 Runtime required" 
}

$ReadmeLines = @(
    "KeyStats for Windows",
    "Version: $Version",
    "Runtime: $Runtime",
    "Publish Type: $PublishType",
    "",
    "Installation:",
    "1. Extract this ZIP file to any directory",
    "2. Run KeyStats.exe",
    "3. Grant necessary permissions on first run",
    "",
    "Data Storage:",
    "%LOCALAPPDATA%\KeyStats",
    "",
    "Uninstall:",
    "Simply delete the program folder. Data will remain in user data directory.",
    "",
    "System Requirements:",
    "- Windows 10 or Windows 11",
    "- $RuntimeRequirement"
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
