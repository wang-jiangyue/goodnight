<#
    Draws the NightLock app icon and packs it into a multi size .ico.
    Every size is rendered natively; the smallest sizes use a simplified mark
    so the padlock stays readable at 16 px.
#>
Add-Type -AssemblyName System.Drawing

$outPath = Join-Path $PSScriptRoot 'nightlock.ico'
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$script:pngs = @()

function New-RoundPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [single]($R * 2)
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

foreach ($size in $sizes) {
    $s = $size / 256.0
    $small = ($size -le 32)

    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # ---- tile: deep navy to indigo, rounded corners ----
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $c1 = [System.Drawing.Color]::FromArgb(255, 12, 19, 36)
    $c2 = [System.Drawing.Color]::FromArgb(255, 38, 58, 104)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 65.0)
    $radius = [single](60 * $s)
    $tile = New-RoundPath -X 0 -Y 0 -W $size -H $size -R $radius
    $g.FillPath($brush, $tile)
    $brush.Dispose()

    # ---- soft light from the upper right ----
    if (-not $small) {
        $glow = [single](230 * $s)
        $glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $glowPath.AddEllipse([single]($size - $glow * 0.60), [single](-$glow * 0.45), $glow, $glow)
        $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($glowPath)
        $pgb.CenterColor = [System.Drawing.Color]::FromArgb(70, 160, 195, 255)
        $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 160, 195, 255))
        $g.FillPath($pgb, $glowPath)
        $pgb.Dispose()
        $glowPath.Dispose()
    }

    # ---- hairline inner edge for a crisp look ----
    if ($size -ge 48) {
        $edge = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(38, 255, 255, 255), [single](2 * $s))
        $edgePath = New-RoundPath -X ([single](1.5 * $s)) -Y ([single](1.5 * $s)) -W ([single]($size - 3 * $s)) -H ([single]($size - 3 * $s)) -R ([single]($radius - 1.5 * $s))
        $g.DrawPath($edge, $edgePath)
        $edge.Dispose()
        $edgePath.Dispose()
    }

    # ---- padlock geometry (bigger and simpler when small) ----
    if ($small) {
        $bodyX = 56; $bodyY = 116; $bodyW = 144; $bodyH = 92
        $shackleX = 84; $shackleY = 62; $shackleW = 88; $shackleH = 92
        $penWidth = 26
    } else {
        $bodyX = 64; $bodyY = 122; $bodyW = 128; $bodyH = 94
        $shackleX = 88; $shackleY = 66; $shackleW = 80; $shackleH = 92
        $penWidth = 21
    }

    $inkColor = [System.Drawing.Color]::FromArgb(255, 240, 245, 253)

    # shackle
    $pen = New-Object System.Drawing.Pen($inkColor, [single]([math]::Max(2.0, $penWidth * $s)))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($pen, [single]($shackleX * $s), [single]($shackleY * $s), [single]($shackleW * $s), [single]($shackleH * $s), 180, 180)
    $pen.Dispose()

    # body
    $bodyBrush = New-Object System.Drawing.SolidBrush($inkColor)
    $bodyPath = New-RoundPath -X ([single]($bodyX * $s)) -Y ([single]($bodyY * $s)) -W ([single]($bodyW * $s)) -H ([single]($bodyH * $s)) -R ([single](20 * $s))
    $g.FillPath($bodyBrush, $bodyPath)
    $bodyBrush.Dispose()
    $bodyPath.Dispose()

    # keyhole only when there is room for it
    if ($size -ge 32) {
        $hole = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 20, 31, 55))
        $g.FillEllipse($hole, [single](116 * $s), [single](148 * $s), [single](24 * $s), [single](24 * $s))
        $g.FillRectangle($hole, [single](123 * $s), [single](168 * $s), [single](10 * $s), [single](30 * $s))
        $hole.Dispose()
    }

    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $script:pngs += , @{ Size = $size; Bytes = $ms.ToArray(); Bitmap = $bmp }
    $ms.Dispose()
}

# ---- pack the ico container ----
$fs = [System.IO.File]::Create($outPath)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0)
$bw.Write([UInt16]1)
$bw.Write([UInt16]$script:pngs.Count)
$offset = 6 + 16 * $script:pngs.Count
foreach ($entry in $script:pngs) {
    $dim = if ($entry.Size -ge 256) { 0 } else { $entry.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)
    $bw.Write([byte]0);    $bw.Write([byte]0)
    $bw.Write([UInt16]1);  $bw.Write([UInt16]32)
    $bw.Write([UInt32]$entry.Bytes.Length)
    $bw.Write([UInt32]$offset)
    $offset += $entry.Bytes.Length
}
foreach ($entry in $script:pngs) { $bw.Write($entry.Bytes) }
$bw.Flush(); $bw.Dispose(); $fs.Dispose()

# ---- save previews so a human can eyeball them ----
$previewDir = Join-Path $PSScriptRoot 'icon-preview'
if (-not (Test-Path $previewDir)) { New-Item -ItemType Directory -Path $previewDir -Force | Out-Null }
foreach ($entry in $script:pngs) {
    $entry.Bitmap.Save((Join-Path $previewDir ('icon-' + $entry.Size + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
}

# ---- report simple quality signals ----
$report = @()
foreach ($entry in $script:pngs) {
    $b = $entry.Bitmap
    $w = $b.Width
    $opaque = 0; $bright = 0; $dark = 0
    for ($y = 0; $y -lt $w; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $p = $b.GetPixel($x, $y)
            if ($p.A -gt 40) {
                $opaque++
                $lum = ($p.R * 0.3 + $p.G * 0.6 + $p.B * 0.1)
                if ($lum -gt 170) { $bright++ }
                if ($lum -lt 70) { $dark++ }
            }
        }
    }
    $total = $w * $w
    $report += ('  {0,3}px  不透明 {1,5:N1}%  亮部 {2,4:N1}%  暗部 {3,4:N1}%' -f $w, (100 * $opaque / $total), (100 * $bright / $total), (100 * $dark / $total))
    $entry.Bitmap.Dispose()
}

Write-Output ('SAVED: ' + $outPath)
Write-Output ('size=' + (Get-Item $outPath).Length + ' bytes, entries=' + $script:pngs.Count)
Write-Output 'quality report:'
$report | ForEach-Object { Write-Output $_ }
Write-Output ('previews: ' + $previewDir)
