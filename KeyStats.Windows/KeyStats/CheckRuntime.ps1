# KeyStats Runtime Check Script
# Check if .NET 8.0 Desktop Runtime is installed

$ErrorActionPreference = "Continue"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Check .NET Runtime
function Test-DotNetRuntime {
    try {
        $output = & dotnet --list-runtimes 2>&1
        if ($LASTEXITCODE -eq 0 -and $output) {
            $hasDesktopRuntime = $output | Where-Object { $_ -match "Microsoft\.WindowsDesktop\.App\s+8\.0" }
            return $null -ne $hasDesktopRuntime
        }
        return $false
    }
    catch {
        return $false
    }
}

# Show modern dialog
function Show-ModernDialog {
    param(
        [string]$Title,
        [string]$Message,
        [string]$PrimaryButtonText = "Yes",
        [string]$SecondaryButtonText = "No"
    )

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$Title"
        Width="420" Height="200"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize">
    <Border Background="#FAFAFA" CornerRadius="8" BorderBrush="#E0E0E0" BorderThickness="1">
        <Border.Effect>
            <DropShadowEffect BlurRadius="20" ShadowDepth="2" Opacity="0.2"/>
        </Border.Effect>
        <Grid Margin="24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Title -->
            <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="24"
                           Foreground="#D97706" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBlock Text="$Title" FontSize="16" FontWeight="SemiBold"
                           Foreground="#1F1F1F" VerticalAlignment="Center"/>
            </StackPanel>

            <!-- Message -->
            <TextBlock Grid.Row="1" Text="$Message" FontSize="14" Foreground="#424242"
                       TextWrapping="Wrap" LineHeight="22"/>

            <!-- Buttons -->
            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
                <Button x:Name="SecondaryButton" Content="$SecondaryButtonText" Width="90" Height="32"
                        Background="Transparent" Foreground="#1F1F1F" BorderBrush="#D0D0D0"
                        BorderThickness="1" Margin="0,0,10,0" Cursor="Hand">
                    <Button.Resources>
                        <Style TargetType="Border">
                            <Setter Property="CornerRadius" Value="4"/>
                        </Style>
                    </Button.Resources>
                </Button>
                <Button x:Name="PrimaryButton" Content="$PrimaryButtonText" Width="90" Height="32"
                        Background="#0067C0" Foreground="White" BorderThickness="0" Cursor="Hand">
                    <Button.Resources>
                        <Style TargetType="Border">
                            <Setter Property="CornerRadius" Value="4"/>
                        </Style>
                    </Button.Resources>
                </Button>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $result = $false

    $primaryButton = $window.FindName("PrimaryButton")
    $secondaryButton = $window.FindName("SecondaryButton")

    $primaryButton.Add_Click({
        $script:result = $true
        $window.Close()
    })

    $secondaryButton.Add_Click({
        $script:result = $false
        $window.Close()
    })

    # Allow dragging the window
    $window.Add_MouseLeftButtonDown({
        $window.DragMove()
    })

    $window.ShowDialog() | Out-Null
    return $result
}

# Check runtime
if (-not (Test-DotNetRuntime)) {
    $clicked = Show-ModernDialog `
        -Title ".NET 8.0 Required" `
        -Message "KeyStats requires .NET 8.0 Desktop Runtime to run.`n`nWould you like to open the download page?" `
        -PrimaryButtonText "Download" `
        -SecondaryButtonText "Cancel"

    if ($clicked) {
        Start-Process "https://dotnet.microsoft.com/download/dotnet/8.0"
    }

    exit 1
}

# Runtime installed, launch app
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $scriptPath "KeyStats.exe"

if (Test-Path $exePath) {
    Start-Process -FilePath $exePath
} else {
    Show-ModernDialog `
        -Title "Error" `
        -Message "KeyStats.exe not found." `
        -PrimaryButtonText "OK" `
        -SecondaryButtonText "Cancel" | Out-Null
    exit 1
}
