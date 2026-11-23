# Draws the launcher's icon (tools\exe\app.ico): the window's dark background with
# the accent colour and "HQ". Run it again only to change the icon.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\exe\New-AppIcon.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot 'app.ico'
$sizes = @(256, 64, 48, 32, 16)
$images = foreach ($size in $sizes) {
    $bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.Clear([System.Drawing.Color]::Transparent)
        $radius = [Math]::Max(2, [int]($size * 0.18))
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $radius * 2; $r = $size - 1
        $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($r - $d, 0, $d, $d, 270, 90)
        $path.AddArc($r - $d, $r - $d, $d, $d, 0, 90); $path.AddArc(0, $r - $d, $d, $d, 90, 90); $path.CloseFigure()
        $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 21, 21, 30))), $path)
        $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 168, 255))), [int]($size * 0.18), [int]($size * 0.78), [int]($size * 0.64), [Math]::Max(1, [int]($size * 0.07)))
        $font = New-Object System.Drawing.Font('Segoe UI', [single]($size * 0.40), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $format = New-Object System.Drawing.StringFormat; $format.Alignment = 'Center'; $format.LineAlignment = 'Center'
        $g.DrawString('HQ', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, [single](-$size * 0.04), $size, $size)), $format)
    } finally { $g.Dispose() }
    $stream = New-Object IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
    , $stream.ToArray()
}
# ICO with PNG-compressed images (read by Windows Vista and later).
$file = New-Object IO.MemoryStream
$writer = New-Object IO.BinaryWriter($file)
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $writer.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $writer.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
    $offset += $images[$i].Length
}
foreach ($image in $images) { $writer.Write($image) }
$writer.Flush()
[IO.File]::WriteAllBytes($out, $file.ToArray())
Write-Output "Wrote $out ($($file.Length) bytes)"
