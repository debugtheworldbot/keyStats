Add-Type -AssemblyName System.Drawing

$pngPath = 'D:\keyStats\KeyStats.Windows\KeyStats\Resources\Icons\tray-icon.png'
$icoPath = 'D:\keyStats\KeyStats.Windows\KeyStats\Resources\Icons\app.ico'

$png = [System.Drawing.Bitmap]::FromFile($pngPath)

$sizes = @(16, 32, 48, 256)
$pngDataList = New-Object System.Collections.ArrayList

foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.DrawImage($png, 0, 0, $s, $s)
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    [void]$pngDataList.Add(@{Size=$s; Data=$ms.ToArray()})
    $ms.Dispose()
    $bmp.Dispose()
}

$png.Dispose()

# Build ICO file
$icoMs = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($icoMs)

# Header
$writer.Write([UInt16]0)  # Reserved
$writer.Write([UInt16]1)  # Type (1 = ICO)
$writer.Write([UInt16]$pngDataList.Count)  # Image count

# Calculate first data offset
$dataOffset = 6 + ($pngDataList.Count * 16)

# Directory entries
foreach ($item in $pngDataList) {
    $s = $item.Size
    $data = $item.Data

    $w = if ($s -ge 256) { 0 } else { $s }
    $h = if ($s -ge 256) { 0 } else { $s }

    $writer.Write([byte]$w)      # Width
    $writer.Write([byte]$h)      # Height
    $writer.Write([byte]0)       # Color count
    $writer.Write([byte]0)       # Reserved
    $writer.Write([UInt16]1)     # Color planes
    $writer.Write([UInt16]32)    # Bits per pixel
    $writer.Write([UInt32]$data.Length)  # Size of image data
    $writer.Write([UInt32]$dataOffset)   # Offset to image data

    $dataOffset += $data.Length
}

# Image data
foreach ($item in $pngDataList) {
    $writer.Write($item.Data)
}

$writer.Flush()
[System.IO.File]::WriteAllBytes($icoPath, $icoMs.ToArray())

$writer.Dispose()
$icoMs.Dispose()

Write-Host "Multi-size ICO created: $icoPath"
Write-Host "Sizes: 16x16, 32x32, 48x48, 256x256"
