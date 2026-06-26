param([switch]$OpenGui)

# ponytail: GetCurrentProcess handles both .ps1 and PS2EXE-compiled .exe (PSScriptRoot points to temp dir in exe)
$ScriptDir = Split-Path ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -Parent
if(-not $ScriptDir){$ScriptDir=(Get-Location).Path}
$ConfigFile = Join-Path $ScriptDir "display-config.json"

$DpiMap = @{ 0=100; 1=125; 2=150; 3=175; 4=200 }
$DpiRev = @{ 100=0; 125=1; 150=2; 175=3; 200=4 }

# ── Native interop ──────────────────────────────────────────────
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class N {
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    public struct DD { public uint cb; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dn; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string ds; public uint sf; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string did; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=128)] public string dk; }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    public struct DM { [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dn; public ushort sv,dv,sz,de; public uint fld; public int px,py; public uint ro,fo; public short cl,du,yr,tt,co; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string fm; public ushort lp; public uint bp,w,h,df,fr; }

    public const uint DM_W=0x80000, DM_H=0x100000, DM_F=0x400000;
    public const int CDS_UPDATEREGISTRY = 0x01;
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int EnumDisplayDevices(IntPtr d,uint i,ref DD l,uint f);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int EnumDisplaySettings(IntPtr d,int i,ref DM m);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(IntPtr d,ref DM m,IntPtr h,int fl,IntPtr p);
}
'@

# ── Reg helper ─────────────────────────────────────────────────
function Set-PerMonitorDpi($edidFilter, $dpiPercent){
    $dpiVal = if($DpiRev.ContainsKey($dpiPercent)){ $DpiRev[$dpiPercent] }else{ 0 }
    # HKCU PerMonitorSettings
    $hcu = "HKCU:\Control Panel\Desktop\PerMonitorSettings"
    $hk = Get-ChildItem $hcu -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*$edidFilter*" } | Select-Object -First 1
    if($hk){ Set-ItemProperty -Path $hk.PSPath -Name "DpiValue" -Value $dpiVal -Force }
    # Try HKLM too
    $hlm = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\ScaleFactors"
    $lk = Get-ChildItem $hlm -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*$edidFilter*" } | Select-Object -First 1
    if($lk){
        try { Set-ItemProperty -Path $lk.PSPath -Name "DpiValue" -Value $dpiVal -Force -ErrorAction Stop } catch {}
    }
}

function Get-PerMonitorDpi($edidFilter){
    $hcu = "HKCU:\Control Panel\Desktop\PerMonitorSettings"
    $hk = Get-ChildItem $hcu -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*$edidFilter*" } | Select-Object -First 1
    if($hk){
        $val = (Get-ItemProperty $hk.PSPath -Name "DpiValue" -ErrorAction SilentlyContinue).DpiValue
        if($null -ne $val -and $DpiMap.ContainsKey($val)){ return $DpiMap[$val] }
    }
    return 100
}

# ── Monitor data ───────────────────────────────────────────────
function Get-MonitorData {
    $wmiNames = @{}
    try {
        Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
            $name = -join ($_.UserFriendlyName | Where-Object {$_ -gt 0} | ForEach-Object {[char]$_})
            $inst = $_.InstanceName
            $edid = ''; if($inst -match 'DISPLAY\\([A-Z0-9]+)\\'){ $edid = $Matches[1] }
            $wmiNames[$edid] = $name
        }
    } catch {}

    $list = @(); $i = 0
    while($true){
        $a = New-Object N+DD; $a.cb = [Runtime.InteropServices.Marshal]::SizeOf($a)
        if([N]::EnumDisplayDevices([IntPtr]::Zero, $i, [ref]$a, 0) -eq 0){ break }
        if($a.sf -band 1){
            $b = New-Object N+DD; $b.cb = [Runtime.InteropServices.Marshal]::SizeOf($b)
            [N]::EnumDisplayDevices([Runtime.InteropServices.Marshal]::StringToHGlobalUni($a.dn), 0, [ref]$b, 0)|Out-Null
            $cm = New-Object N+DM; $cm.sz = [Runtime.InteropServices.Marshal]::SizeOf($cm)
            [N]::EnumDisplaySettings([Runtime.InteropServices.Marshal]::StringToHGlobalUni($a.dn), -1, [ref]$cm)|Out-Null
            $edid = '?'
            if($b.did -match 'MONITOR\\([A-Z0-9]+)\\'){ $edid = $Matches[1] }
            elseif($b.did -match 'DISPLAY\\([A-Z0-9]+)\\'){ $edid = $Matches[1] }
            $wName = $wmiNames[$edid]
            $displayName = if($wName){ $wName }elseif($b.ds -ne 'Generic PnP Monitor'){ $b.ds }else{ "$($b.ds) [$edid]" }
            $list += @{
                Dev=$a.dn; Name=$displayName; EDID=$edid
                CurW=$cm.w; CurH=$cm.h; CurF=$cm.fr
                Prim=($a.sf -band 4) -ne 0
            }
        }
        $i++
    }
    $list
}

function Get-AllResolutions($dev){
    $seen = @{}; $l = @(); $j = 0
    while($true){
        $m = New-Object N+DM; $m.sz = [Runtime.InteropServices.Marshal]::SizeOf($m)
        if([N]::EnumDisplaySettings([Runtime.InteropServices.Marshal]::StringToHGlobalUni($dev), $j, [ref]$m) -eq 0){ break }
        $k = "$($m.w)x$($m.h)@$($m.fr)"
        if(!$seen.ContainsKey($k)){ $seen[$k] = $true; $l += @{W=$m.w; H=$m.h; F=$m.fr; Label=$k} }
        $j++
    }
    $l | Sort-Object { -$_.W }, { -$_.F }
}

function Set-Display($dev, $w, $h, $fr){
    $m = New-Object N+DM; $m.sz = [Runtime.InteropServices.Marshal]::SizeOf($m)
    $m.fld = [N]::DM_W -bor [N]::DM_H -bor [N]::DM_F
    $m.w = $w; $m.h = $h; $m.fr = $fr
    $null = [N]::ChangeDisplaySettingsEx(
        [Runtime.InteropServices.Marshal]::StringToHGlobalUni($dev),
        [ref]$m, [IntPtr]::Zero, [N]::CDS_UPDATEREGISTRY, [IntPtr]::Zero)
}

function Apply-Profile($dev, $edid, $w, $h, $fr, $dpiPercent){
    Set-Display $dev $w $h $fr
    Set-PerMonitorDpi $edid $dpiPercent
    # Re-apply mode to trigger Windows to read new scale
    Start-Sleep -Milliseconds 300
    Set-Display $dev $w $h $fr
}

# ── CLI toggle mode ────────────────────────────────────────────
if(-not $OpenGui -and (Test-Path $ConfigFile)){
    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    $mons = Get-MonitorData
    $mon = $mons | Where-Object { $_.EDID -eq $cfg.EDID } | Select-Object -First 1
    if(-not $mon){ Write-Error "Configured monitor (EDID=$($cfg.EDID)) not found."; exit 1 }
    $inA = ($mon.CurW -eq $cfg.A.W -and $mon.CurH -eq $cfg.A.H)
    $t = if($inA){ $cfg.B }else{ $cfg.A }
    Write-Host "Switching $($mon.Name) to $($t.W)x$($t.H)@$($t.F)Hz @ $($t.Dpi)%..."
    Apply-Profile $mon.Dev $mon.EDID $t.W $t.H $t.F $t.Dpi
    Write-Host "Done."
    exit 0
}

# ── GUI mode ───────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$mons = Get-MonitorData
if(!$mons){ [Windows.Forms.MessageBox]::Show("No active monitors"); exit 1 }

$loadedCfg = $null
if(Test-Path $ConfigFile){ try{ $loadedCfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json }catch{} }

$f = New-Object Windows.Forms.Form
$f.Text = "Display Switcher"; $f.Size = [Drawing.Size]::new(450, 250)
$f.StartPosition = "CenterScreen"; $f.TopMost = $true
$f.FormBorderStyle = "FixedDialog"; $f.MaximizeBox = $false

$y = 12

# ── Monitor ────────────────────────────────────────────────────
[void]$f.Controls.Add((New-Object Windows.Forms.Label -Property @{
    Text="Monitor:"; Location=[Drawing.Point]::new(12,$y+3); AutoSize=$true
    Font=[Drawing.Font]::new("Segoe UI",9,[Drawing.FontStyle]::Bold)}))
$cbMon = New-Object Windows.Forms.ComboBox
$cbMon.Location = [Drawing.Point]::new(85,$y); $cbMon.Width = 340; $cbMon.DropDownStyle = "DropDownList"
foreach($mo in $mons){
    $s = "$($mo.Name)  [$($mo.EDID)]"; if($mo.Prim){ $s = "* $s" }
    [void]$cbMon.Items.Add($s)
}
$sel = 0
if($loadedCfg){ $sel = [Math]::Max(0, [Array]::FindIndex($mons, [Predicate[object]]{ $args[0].EDID -eq $loadedCfg.EDID })) }
else{ $sel = [Math]::Max(0, [Array]::FindIndex($mons, [Predicate[object]]{ $args[0].Prim })) }
$cbMon.SelectedIndex = $sel
$f.Controls.Add($cbMon)

# ── Current ────────────────────────────────────────────────────
$y += 30
$lblCur = New-Object Windows.Forms.Label
$lblCur.Location = [Drawing.Point]::new(14,$y); $lblCur.AutoSize = $true
$lblCur.Font = [Drawing.Font]::new("Segoe UI", 8.5)
$f.Controls.Add($lblCur)

# ── State ──────────────────────────────────────────────────────
$resolutions = @()

function Refresh-UI {
    $i = $cbMon.SelectedIndex; if($i -lt 0){ return }
    $mo = $mons[$i]
    $dpi = Get-PerMonitorDpi $mo.EDID
    $cfgInfo = "?"; if($loadedCfg -and $loadedCfg.EDID -eq $mo.EDID){ $cfgInfo = "$($loadedCfg.A.Dpi)% / $($loadedCfg.B.Dpi)%" }
    $lblCur.Text = "Now: $($mo.CurW)x$($mo.CurH) @ $($mo.CurF)Hz  |  DPI: $dpi%  |  Config: $cfgInfo  |  EDID: $($mo.EDID)"
    $script:resolutions = Get-AllResolutions $mo.Dev
    $cmbA.Items.Clear(); $cmbB.Items.Clear()
    foreach($r in $resolutions){
        [void]$cmbA.Items.Add($r.Label); [void]$cmbB.Items.Add($r.Label)
    }
    $defA = 0; $defB = 0
    if($loadedCfg -and $loadedCfg.EDID -eq $mo.EDID){
        $defA = [Math]::Max(0, ([Array]::FindIndex($resolutions, [Predicate[object]]{ $args[0].W -eq $loadedCfg.A.W -and $args[0].H -eq $loadedCfg.A.H -and $args[0].F -eq $loadedCfg.A.F })))
        $defB = [Math]::Max(0, ([Array]::FindIndex($resolutions, [Predicate[object]]{ $args[0].W -eq $loadedCfg.B.W -and $args[0].H -eq $loadedCfg.B.H -and $args[0].F -eq $loadedCfg.B.F })))
        $scA.SelectedIndex = [Math]::Max(0, [Array]::IndexOf(@(100,125,150,175,200), $loadedCfg.A.Dpi))
        $scB.SelectedIndex = [Math]::Max(0, [Array]::IndexOf(@(100,125,150,175,200), $loadedCfg.B.Dpi))
    }
    if($cmbA.Items.Count -gt 0){ $cmbA.SelectedIndex = $defA }
    if($defB -gt 0 -and $defB -ne $defA){ $cmbB.SelectedIndex = $defB }
    elseif($cmbB.Items.Count -gt 1){ $cmbB.SelectedIndex = [Math]::Min(1, $cmbB.Items.Count-1) }
    elseif($cmbB.Items.Count -gt 0){ $cmbB.SelectedIndex = 0 }
}

$cbMon.add_SelectedIndexChanged({ Refresh-UI })

function Do-Apply($w,$h,$fr,$dpi){
    $i = $cbMon.SelectedIndex; $mo = $mons[$i]
    Apply-Profile $mo.Dev $mo.EDID $w $h $fr $dpi
    $mo.CurW = $w; $mo.CurH = $h; $mo.CurF = $fr
    Refresh-UI
}

# ── Profile A ──────────────────────────────────────────────────
$y += 28
[void]$f.Controls.Add((New-Object Windows.Forms.Label -Property @{
    Text="Profile A:"; Location=[Drawing.Point]::new(12,$y+3); AutoSize=$true}))
$cmbA = New-Object Windows.Forms.ComboBox
$cmbA.Location = [Drawing.Point]::new(85,$y); $cmbA.Width = 195; $cmbA.DropDownStyle = "DropDownList"
$f.Controls.Add($cmbA)
$scA = New-Object Windows.Forms.ComboBox
$scA.Location = [Drawing.Point]::new(288,$y); $scA.Width = 62; $scA.DropDownStyle = "DropDownList"
100,125,150,175,200 | ForEach-Object { [void]$scA.Items.Add("$_%") }
$scA.SelectedIndex = 2
$f.Controls.Add($scA)
$btnA = New-Object Windows.Forms.Button
$btnA.Text = "Apply"; $btnA.Location = [Drawing.Point]::new(358,$y-1); $btnA.Width = 62; $btnA.Height = 22
$btnA.Add_Click({
    $i = $cbMon.SelectedIndex; $si = $cmbA.SelectedIndex
    if($i -lt 0 -or $si -lt 0){ return }
    $r = $resolutions[$si]; $sc = [int]$scA.Text.TrimEnd('%')
    Do-Apply $r.W $r.H $r.F $sc
})
$f.Controls.Add($btnA)

# ── Profile B ──────────────────────────────────────────────────
$y += 28
[void]$f.Controls.Add((New-Object Windows.Forms.Label -Property @{
    Text="Profile B:"; Location=[Drawing.Point]::new(12,$y+3); AutoSize=$true}))
$cmbB = New-Object Windows.Forms.ComboBox
$cmbB.Location = [Drawing.Point]::new(85,$y); $cmbB.Width = 195; $cmbB.DropDownStyle = "DropDownList"
$f.Controls.Add($cmbB)
$scB = New-Object Windows.Forms.ComboBox
$scB.Location = [Drawing.Point]::new(288,$y); $scB.Width = 62; $scB.DropDownStyle = "DropDownList"
100,125,150,175,200 | ForEach-Object { [void]$scB.Items.Add("$_%") }
$scB.SelectedIndex = 0
$f.Controls.Add($scB)
$btnB = New-Object Windows.Forms.Button
$btnB.Text = "Apply"; $btnB.Location = [Drawing.Point]::new(358,$y-1); $btnB.Width = 62; $btnB.Height = 22
$btnB.Add_Click({
    $i = $cbMon.SelectedIndex; $si = $cmbB.SelectedIndex
    if($i -lt 0 -or $si -lt 0){ return }
    $r = $resolutions[$si]; $sc = [int]$scB.Text.TrimEnd('%')
    Do-Apply $r.W $r.H $r.F $sc
})
$f.Controls.Add($btnB)

# ── Toggle + Save ──────────────────────────────────────────────
$y += 34
$btnToggle = New-Object Windows.Forms.Button
$btnToggle.Text = "TOGGLE"; $btnToggle.Location = [Drawing.Point]::new(85,$y)
$btnToggle.Width = 130; $btnToggle.Height = 34
$btnToggle.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$btnToggle.Add_Click({
    $i = $cbMon.SelectedIndex; $siA = $cmbA.SelectedIndex; $siB = $cmbB.SelectedIndex
    if($i -lt 0 -or $siA -lt 0 -or $siB -lt 0){ return }
    $mo = $mons[$i]; $rA = $resolutions[$siA]; $rB = $resolutions[$siB]
    if($mo.CurW -eq $rA.W -and $mo.CurH -eq $rA.H){
        Do-Apply $rB.W $rB.H $rB.F ([int]$scB.Text.TrimEnd('%'))
    }else{
        Do-Apply $rA.W $rA.H $rA.F ([int]$scA.Text.TrimEnd('%'))
    }
})
$f.Controls.Add($btnToggle)

$btnSave = New-Object Windows.Forms.Button
$btnSave.Text = "Save Config"; $btnSave.Location = [Drawing.Point]::new(225,$y)
$btnSave.Width = 110; $btnSave.Height = 34
$btnSave.Add_Click({
    $i = $cbMon.SelectedIndex; $siA = $cmbA.SelectedIndex; $siB = $cmbB.SelectedIndex
    if($i -lt 0 -or $siA -lt 0 -or $siB -lt 0){
        [Windows.Forms.MessageBox]::Show("Select monitor and both profiles first.", "Error"); return
    }
    $mo = $mons[$i]; $rA = $resolutions[$siA]; $rB = $resolutions[$siB]
    $cfg = @{
        EDID = $mo.EDID; Name = $mo.Name
        A = @{ W=$rA.W; H=$rA.H; F=$rA.F; Dpi=[int]$scA.Text.TrimEnd('%') }
        B = @{ W=$rB.W; H=$rB.H; F=$rB.F; Dpi=[int]$scB.Text.TrimEnd('%') }
    }
    $cfg | ConvertTo-Json -Depth 3 | Set-Content $ConfigFile -Encoding UTF8
    $script:loadedCfg = $cfg
    [Windows.Forms.MessageBox]::Show("Saved! Double-click script to toggle. Use -OpenGui for settings.", "Config Saved")
    Refresh-UI
})
$f.Controls.Add($btnSave)

# Init
Refresh-UI
$f.ShowDialog() | Out-Null
