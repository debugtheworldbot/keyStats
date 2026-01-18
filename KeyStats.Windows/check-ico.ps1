$bytes = [System.IO.File]::ReadAllBytes('D:\keyStats\KeyStats.Windows\KeyStats\Resources\Icons\app.ico')
Write-Host "File size: $($bytes.Length) bytes"
Write-Host "First 6 bytes:" (($bytes[0..5] | ForEach-Object { $_.ToString('X2') }) -join ' ')
$imageCount = [BitConverter]::ToUInt16($bytes, 4)
Write-Host "Image count: $imageCount"

# Check each image entry
for ($i = 0; $i -lt $imageCount; $i++) {
    $offset = 6 + ($i * 16)
    $width = $bytes[$offset]
    $height = $bytes[$offset + 1]
    $colorCount = $bytes[$offset + 2]
    $bpp = [BitConverter]::ToUInt16($bytes, $offset + 6)
    $size = [BitConverter]::ToUInt32($bytes, $offset + 8)

    $w = if ($width -eq 0) { 256 } else { $width }
    $h = if ($height -eq 0) { 256 } else { $height }

    Write-Host "  Image $($i+1): ${w}x${h}, $bpp bpp, $size bytes"
}
