@echo off
REM KeyStats Windows 打包脚本 (批处理版本)
REM 用法: build.bat [Release|Debug] [SelfContained|FrameworkDependent]

setlocal enabledelayedexpansion

set CONFIGURATION=%1
if "%CONFIGURATION%"=="" set CONFIGURATION=Release

set PUBLISH_TYPE=%2
if "%PUBLISH_TYPE%"=="" set PUBLISH_TYPE=SelfContained

set RUNTIME=win-x64

echo === KeyStats Windows 打包脚本 ===
echo 配置: %CONFIGURATION%
echo 发布类型: %PUBLISH_TYPE%
echo 运行时: %RUNTIME%
echo.

REM 检查 PowerShell 是否可用
where powershell >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo 错误: 找不到 PowerShell
    exit /b 1
)

REM 调用 PowerShell 脚本
powershell -ExecutionPolicy Bypass -File "%~dp0build.ps1" -Configuration %CONFIGURATION% -PublishType %PUBLISH_TYPE% -Runtime %RUNTIME%

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo 打包失败!
    pause
    exit /b 1
)

echo.
echo 打包完成!
pause
