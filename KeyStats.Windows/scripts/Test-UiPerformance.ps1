# Runs lifecycle/allocation regressions against an existing build, without launching
# the app, installing hooks, or reading/writing the user's statistics/settings.
param(
    [string]$AppDirectory = (Join-Path $PSScriptRoot '../KeyStats/bin/Release/net48'),
    [string]$Dotnet = 'dotnet',
    [string]$CompilerPath = ''
)
$ErrorActionPreference = 'Stop'
$AppDirectory = (Resolve-Path -LiteralPath $AppDirectory).Path
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $sdkLine = & $Dotnet --list-sdks | Select-Object -Last 1
    if ($sdkLine -notmatch '^(\S+) \[(.+)\]$') { throw 'A .NET SDK is required for the isolated UI tests.' }
    $sdkVersion = $Matches[1]
    $sdkRoot = $Matches[2]
    # Prefer the actual executable path: some hosts replace non-ASCII characters
    # with question marks in dotnet's redirected --list-sdks output.
    $dotnetDirectory = Split-Path -Parent (Get-Command $Dotnet -ErrorAction Stop).Source
    $localCompiler = Join-Path $dotnetDirectory ('sdk/' + $sdkVersion + '/Roslyn/bincore/csc.dll')
    $CompilerPath = if (Test-Path -LiteralPath $localCompiler) { $localCompiler }
        else { Join-Path $sdkRoot ($sdkVersion + '/Roslyn/bincore/csc.dll') }
}
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('KeyStatsUiTest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
try {
    Copy-Item -Path (Join-Path $AppDirectory '*') -Destination $testDirectory -Recurse
    $testExe = Join-Path $testDirectory 'UiPerformanceSmokeTest.exe'
    $references = @(
        'mscorlib.dll', 'System.dll', 'System.Core.dll', 'System.Xaml.dll',
        'WPF/WindowsBase.dll', 'WPF/PresentationCore.dll', 'WPF/PresentationFramework.dll'
    ) | ForEach-Object { '/reference:' + (Join-Path $framework $_) }
    & $Dotnet $CompilerPath /nologo /target:exe /optimize+ /langversion:10 /nullable:enable `
        "/out:$testExe" @references "/reference:$testDirectory/KeyStats.exe" `
        (Join-Path $PSScriptRoot 'tests/UiPerformanceSmokeTest.cs')
    if ($LASTEXITCODE -ne 0) { throw 'UI regression test compilation failed.' }
    & $testExe
    if ($LASTEXITCODE -ne 0) { throw 'UI performance regression test failed.' }
}
finally {
    # Only remove the unique directory created by this invocation.
    $resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolvedTestDirectory.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected test directory outside TEMP.'
    }
    Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
}
