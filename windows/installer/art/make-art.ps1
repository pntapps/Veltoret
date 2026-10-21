# Draws the installer artwork (wizard side panel and header logo) at every Windows DPI scale.
# Flat surfaces only, Veltoret palette, no gradients (same rules as the app). Run from any folder:
#   powershell -ExecutionPolicy Bypass -File installer\art\make-art.ps1
Add-Type -AssemblyName System.Drawing
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$fonts = Join-Path $here "..\..\src\Veltoret.App\Assets\Fonts"
$pfc = New-Object System.Drawing.Text.PrivateFontCollection
$pfc.AddFontFile((Resolve-Path (Join-Path $fonts "fraunces.ttf")))
$pfc.AddFontFile((Resolve-Path (Join-Path $fonts "inter.ttf")))
$serif = $pfc.Families | Where-Object { $_.Name -like "Fraunces*" } | Select-Object -First 1
$sans = $pfc.Families | Where-Object { $_.Name -like "Inter*" } | Select-Object -First 1

function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function B($hex) { New-Object System.Drawing.SolidBrush (C $hex) }

$bg = "#0B0B0D"; $text = "#F3EFE6"; $muted = "#9C9AA3"; $amber = "#E8A33D"; $outline = "#2C2C35"

function RoundRect($x, $y, $w, $h, $r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

# One flat "poster" like the onboarding illustration: a tinted tile with a simple motif and two caption bars.
function Poster($g, $x, $y, $w, $h, $k, $tile, $shape, $motif) {
    $path = RoundRect $x $y $w $h (7 * $k)
    $g.FillPath((B $tile), $path)
    $g.SetClip($path)
    $cx = $x + $w / 2; $cy = $y + $h * 0.42
    switch ($motif) {
        "sun" {
            $r = $w * 0.22
            $g.FillEllipse((B $shape), $cx - $r, $cy - $r - $h * 0.06, 2 * $r, 2 * $r)
            $m = [System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF ($x - 2), ($y + $h * 0.72)),
                (New-Object System.Drawing.PointF ($x + $w * 0.38), ($y + $h * 0.40)),
                (New-Object System.Drawing.PointF ($x + $w * 0.62), ($y + $h * 0.58)),
                (New-Object System.Drawing.PointF ($x + $w * 0.80), ($y + $h * 0.46)),
                (New-Object System.Drawing.PointF ($x + $w + 2), ($y + $h * 0.62)),
                (New-Object System.Drawing.PointF ($x + $w + 2), ($y + $h * 0.80)),
                (New-Object System.Drawing.PointF ($x - 2), ($y + $h * 0.80)))
            $g.FillPolygon((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 0, 0, 0))), $m)
        }
        "moon" {
            $r = $w * 0.26
            $g.FillEllipse((B $shape), $cx - $r * 0.6, $cy - $r, 2 * $r, 2 * $r)
            $g.FillEllipse((B $tile), $cx - $r * 1.25, $cy - $r * 0.55, 1.4 * $r, 1.4 * $r)
        }
        "figure" {
            $r = $w * 0.25
            $g.FillEllipse((B $shape), $cx - $r, $cy - $r, 2 * $r, 2 * $r)
            $hr = $w * 0.055
            $g.FillEllipse((B "#1B1206"), $cx - $hr, $cy - $r * 0.35 - $hr, 2 * $hr, 2 * $hr)
            $g.FillRectangle((B "#1B1206"), $cx - $w * 0.07, $cy - $r * 0.2, $w * 0.14, $h * 0.40)
        }
        "city" {
            $base = $y + $h * 0.70
            $bars = @(0.10, 0.34), @(0.27, 0.52), @(0.44, 0.26), @(0.60, 0.44), @(0.77, 0.32)
            foreach ($b in $bars) { $g.FillRectangle((B $shape), $x + $w * $b[0], $base - $h * $b[1], $w * 0.15, $h * $b[1]) }
            $r = $w * 0.07
            $g.FillEllipse((B $amber), $x + $w * 0.70, $y + $h * 0.12, 2 * $r, 2 * $r)
        }
    }
    $g.ResetClip()
    # Caption bars under the artwork.
    $g.FillRectangle((B $tile), $x, $y + $h * 0.80, $w, $h * 0.20 + 0.5)
    $g.FillPath((B "#00000040"), (RoundRect ($x + $w * 0.12) ($y + $h * 0.84) ($w * 0.62) ($h * 0.035) ($h * 0.017)))
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 243, 239, 230))), (RoundRect ($x + $w * 0.12) ($y + $h * 0.84) ($w * 0.62) ($h * 0.035) ($h * 0.017)))
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(80, 243, 239, 230))), (RoundRect ($x + $w * 0.12) ($y + $h * 0.90) ($w * 0.40) ($h * 0.03) ($h * 0.015)))
}

function New-Canvas($w, $h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"; $g.TextRenderingHint = "AntiAliasGridFit"; $g.InterpolationMode = "HighQualityBicubic"
    $g.Clear((C $bg))
    return $bmp, $g
}

# ---- Wizard side panel: 164 x 314 at 100% ----
$scales = 100, 125, 150, 175, 200, 225, 250
foreach ($s in $scales) {
    $k = $s / 100.0
    $W = [int][math]::Round(164 * $k); $H = [int][math]::Round(314 * $k)
    $bmp, $g = New-Canvas $W $H

    # Poster wall, two columns offset like a film strip, cropped by the panel edges.
    $pw = 62 * $k; $ph = 93 * $k; $gap = 8 * $k
    $cols = @(
        @{ x = -22 * $k; y = -38 * $k; items = @(@("#2A1E3A", "#B9A6C9", "moon"), @("#3A2516", "#D98E3A", "sun"), @("#162A2E", "#3E6B70", "city")) },
        @{ x = 48 * $k; y = -6 * $k; items = @(@("#3B1F17", "#E8A33D", "figure"), @("#1A2238", "#4C5E8C", "city"), @("#2E1A26", "#C98BA6", "moon")) },
        @{ x = 118 * $k; y = -52 * $k; items = @(@("#163029", "#E8A33D", "sun"), @("#33281A", "#C9B48A", "figure"), @("#241A33", "#8C7BB0", "sun")) }
    )
    foreach ($col in $cols) {
        $yy = $col.y
        foreach ($it in $col.items) { Poster $g $col.x $yy $pw $ph $k $it[0] $it[1] $it[2]; $yy += $ph + $gap }
    }

    # Play badge on the middle column, like the app's onboarding art.
    $pcx = 79 * $k; $pcy = 144 * $k; $pr = 17 * $k
    $ring = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(140, 232, 163, 61)), (1.5 * $k)
    $g.DrawEllipse($ring, $pcx - $pr * 1.35, $pcy - $pr * 1.35, $pr * 2.7, $pr * 2.7)
    $g.FillEllipse((B $amber), $pcx - $pr, $pcy - $pr, 2 * $pr, 2 * $pr)
    $tri = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF ($pcx - $pr * 0.32), ($pcy - $pr * 0.45)),
        (New-Object System.Drawing.PointF ($pcx + $pr * 0.50), $pcy),
        (New-Object System.Drawing.PointF ($pcx - $pr * 0.32), ($pcy + $pr * 0.45)))
    $g.FillPolygon((B "#1B1206"), $tri)

    # Flat title band.
    $bandY = 222 * $k
    $g.FillRectangle((B $bg), 0, $bandY, $W, $H - $bandY)
    $g.FillRectangle((B $outline), 0, $bandY, $W, [math]::Max(1, [int]$k))

    $titleFont = New-Object System.Drawing.Font ($serif, (25 * $k), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $tx = 16 * $k; $ty = $bandY + 18 * $k
    $g.DrawString("Veltoret", $titleFont, (B $text), $tx, $ty)
    $tw = $g.MeasureString("Veltoret", $titleFont, [System.Drawing.PointF]::Empty, [System.Drawing.StringFormat]::GenericTypographic).Width
    $dr = 3.2 * $k
    $g.FillEllipse((B $amber), $tx + $tw + 4 * $k, $ty + 22 * $k, 2 * $dr, 2 * $dr)

    $tagFont = New-Object System.Drawing.Font ($sans, (10.5 * $k), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $g.DrawString("Your movies and shows,", $tagFont, (B $muted), $tx + 1 * $k, $ty + 38 * $k)
    $g.DrawString("as a private cinema.", $tagFont, (B $muted), $tx + 1 * $k, $ty + 52 * $k)

    $g.Dispose()
    $bmp.Save((Join-Path $here "wizard-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# ---- Header logo: 55 x 55 at 100% (the app icon's mark) ----
foreach ($s in $scales) {
    $k = $s / 100.0
    $Sz = [int][math]::Round(55 * $k)
    $bmp, $g = New-Canvas $Sz $Sz
    $g.Clear([System.Drawing.Color]::Transparent)
    $u = $Sz / 108.0
    $g.FillPath((B $bg), (RoundRect 0 0 ($Sz - 1) ($Sz - 1) (24 * $u)))
    $g.DrawPath((New-Object System.Drawing.Pen (C $outline), ([math]::Max(1, $k))), (RoundRect 0 0 ($Sz - 1) ($Sz - 1) (24 * $u)))
    $z = 1.35
    function P($x, $y) { New-Object System.Drawing.PointF ((($x - 54) * $z + 54) * $u), ((($y - 56) * $z + 54) * $u) }
    $v = [System.Drawing.PointF[]]@((P 35 36), (P 42.5 36), (P 54 66.5), (P 65.5 36), (P 73 36), (P 57.2 76), (P 50.8 76))
    $g.FillPolygon((B $text), $v)
    $dot = P 76 70; $r = 4.5 * $z * $u
    $g.FillEllipse((B $amber), $dot.X - $r, $dot.Y - $r, 2 * $r, 2 * $r)
    $g.Dispose()
    $bmp.Save((Join-Path $here "header-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
"art written to $here"

