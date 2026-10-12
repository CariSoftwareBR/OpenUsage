<#
  Floating Claude / Codex / Cursor usage widget.
  Plain PowerShell + WPF (built into Windows): nothing to download.
  Data comes from ..\scripts\usage-json.ts, run with Node (>= 22.6).

  Run:  double-click widget\usage-widget.vbs
#>
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$RefreshMinutes = 5
$StateDir = Join-Path $env:APPDATA 'usage-widget'
$StatePath = Join-Path $StateDir 'widget.json'
$ProviderNames = [ordered]@{ claude = 'Claude'; codex = 'Codex'; cursor = 'Cursor'; 'opencode-go' = 'OpenCode Go' }
$Icons = @{ claude = [string][char]0x273B; codex = [string][char]0x25CE; cursor = [string][char]0x2B21; 'opencode-go' = [string][char]0x25A3 }

# ---- single instance ----------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\usage-widget')
# A second launch asks the running instance to show itself instead of silently exiting.
$showEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\usage-widget-show')
if (-not $mutex.WaitOne(0)) { $showEvent.Set() | Out-Null; exit }

# ---- persisted state ----------------------------------------------------------
function Get-State {
  try { return Get-Content $StatePath -Raw | ConvertFrom-Json } catch { return [pscustomobject]@{} }
}
function Set-State([hashtable]$patch) {
  $s = @{}
  (Get-State).PSObject.Properties | ForEach-Object { $s[$_.Name] = $_.Value }
  foreach ($k in $patch.Keys) { $s[$k] = $patch[$k] }
  New-Item -ItemType Directory -Force $StateDir | Out-Null
  $s | ConvertTo-Json | Set-Content -Encoding UTF8 $StatePath
}
$state = Get-State
$script:display = if ($state.display) { $state.display } else { 'used' }
$script:layout = if ($state.layout -eq 'compact') { 'compact' } else { 'normal' }
# Providers switched off in settings: not fetched and not shown. Every provider is on by default.
$script:hiddenProviders = @($state.hiddenProviders | Where-Object { $_ })

# ---- theme (follows Windows light/dark) ---------------------------------------
$light = $false
try { $light = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme) -eq 1 } catch {}
$C = if ($light) {
  @{ Bg = '#FBFAF8'; Border = '#E2DDD7'; Divider = '#ECE8E3'; Text = '#1F1C1A'; Muted = '#857D76'; Warn = '#C46D12'; Error = '#C9362D'; Ok = '#2E8B57'; Track = '#E4DED7'; Hover = '#F1EDE8'; Card = '#F3F0EB'; CardBorder = '#E8E3DD' }
} else {
  @{ Bg = '#1C1A19'; Border = '#34302D'; Divider = '#2C2926'; Text = '#EBE7E2'; Muted = '#8D8680'; Warn = '#E8953F'; Error = '#E5584F'; Ok = '#5BBF86'; Track = '#35302C'; Hover = '#2A2725'; Card = '#242120'; CardBorder = '#2E2A27' }
}
$Accents = @{ claude = '#D97757'; codex = $(if ($light) { '#0F8A6C' } else { '#3DBE9C' }); cursor = $C.Text; 'opencode-go' = $C.Text }
function Brush([string]$hex) { [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

# ---- window -------------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="OpenUsage" Width="320" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" ShowActivated="False"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="$($C.Text)">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="6,2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Hover)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Margin="8" Background="$($C.Bg)" BorderBrush="$($C.Border)" BorderThickness="1" CornerRadius="12" Padding="14,10,14,10">
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35"/></Border.Effect>
    <StackPanel>
      <DockPanel x:Name="Header" Background="Transparent">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
          <Button x:Name="GearBtn" Style="{StaticResource Btn}" ToolTip="Settings">
            <Grid>
              <TextBlock Text="&#x2699;" FontFamily="Segoe UI Symbol"/>
              <Ellipse x:Name="GearDot" Width="6" Height="6" Fill="$($C.Warn)" HorizontalAlignment="Right" VerticalAlignment="Top"
                       Margin="0,0,-4,0" Visibility="Collapsed"/>
            </Grid>
          </Button>
          <Button x:Name="AddBtn" Style="{StaticResource Btn}" ToolTip="Add account">+</Button>
          <Button x:Name="ModeBtn" Style="{StaticResource Btn}" ToolTip="Used / left">Used</Button>
          <Button x:Name="RefreshBtn" Style="{StaticResource Btn}" ToolTip="Refresh">&#x27F3;</Button>
          <Button x:Name="MinBtn" Style="{StaticResource Btn}" ToolTip="Minimize">&#x2013;</Button>
          <Button x:Name="HideBtn" Style="{StaticResource Btn}" ToolTip="Hide (tray icon brings it back)">&#x2715;</Button>
        </StackPanel>
        <TextBlock VerticalAlignment="Center" FontWeight="SemiBold">
          <Run Foreground="$($C.Muted)">&#x25F7;</Run> OpenUsage
        </TextBlock>
      </DockPanel>
      <StackPanel x:Name="Body">
        <Border Height="1" Background="$($C.Divider)" Margin="0,8,0,8"/>
        <StackPanel x:Name="List"/>
        <Border Height="1" Background="$($C.Divider)" Margin="0,10,0,6"/>
        <DockPanel>
          <TextBlock x:Name="ErrorText" DockPanel.Dock="Right" Foreground="$($C.Error)" FontSize="11.5"/>
          <TextBlock x:Name="Updated" Foreground="$($C.Muted)" FontSize="11.5"/>
        </DockPanel>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
foreach ($n in 'Header', 'GearBtn', 'GearDot', 'AddBtn', 'ModeBtn', 'RefreshBtn', 'MinBtn', 'HideBtn', 'Body', 'List', 'Updated', 'ErrorText') { $ui[$n] = $win.FindName($n) }

$area = [System.Windows.SystemParameters]::WorkArea
$win.Left = if ($null -ne $state.x) { [double]$state.x } else { $area.Right - 330 }
$win.Top = if ($null -ne $state.y) { [double]$state.y } else { $area.Top + 16 }
$win.Topmost = if ($null -ne $state.topmost) { [bool]$state.topmost } else { $true }

# ---- formatting ---------------------------------------------------------------
function Level([double]$pct) { if ($pct -ge 80) { $C.Error } elseif ($pct -ge 50) { $C.Warn } else { $null } }

function Format-Reset($ms) {
  if (-not $ms) { return '' }
  $d = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime
  if ($d.Date -eq (Get-Date).Date) { return $d.ToString('t') }
  return $d.ToString('ddd, dd MMM') + ', ' + $d.ToString('t')
}

# Shorter, for the compact rows: "14:00", "Wed 14:00" within the week, else "14 Oct".
function Format-ResetShort($ms) {
  if (-not $ms) { return '' }
  $d = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime
  if ($d.Date -eq (Get-Date).Date) { return $d.ToString('t') }
  if (($d - (Get-Date)).TotalDays -lt 6) { return $d.ToString('ddd') + ' ' + $d.ToString('t') }
  return $d.ToString('dd MMM')
}

function Format-Ago($ms) {
  if (-not $ms) { return '' }
  $m = [math]::Round(((Get-Date) - [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime).TotalMinutes)
  if ($m -lt 1) { 'updated just now' } elseif ($m -lt 60) { "updated $m min ago" } else { "updated $([math]::Round($m / 60)) h ago" }
}

function New-Text([string]$text, $color, [double]$size = 13, [string]$weight = 'Normal') {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text
  $t.FontSize = $size
  $t.FontWeight = $weight
  if ($color) { $t.Foreground = Brush $color }
  return $t
}

function New-Row($left, $right) {
  $row = New-Object System.Windows.Controls.DockPanel
  $row.Margin = '0,3,0,0'
  [System.Windows.Controls.DockPanel]::SetDock($right, 'Right')
  $row.Children.Add($right) | Out-Null
  $row.Children.Add($left) | Out-Null
  return $row
}

# ---- data ---------------------------------------------------------------------
# The last good result is cached on disk, so a restart (or a rate-limited first fetch) still shows numbers.
$CachePath = Join-Path $StateDir 'data.json'
$script:data = @()
$script:updatedAt = $null
try {
  $cache = Get-Content $CachePath -Raw | ConvertFrom-Json
  $script:data = @($cache.data)
  $script:updatedAt = $cache.updatedAt
} catch {}
$script:lastError = ''
$script:proc = $null

# In compact mode a provider with no account at all (never signed in, no key, nothing to show) gets no card;
# the normal layout keeps it, with the hint on how to sign in.
function Test-Shown($u) {
  if ($script:hiddenProviders -contains $u.id) { return $false }
  if ($script:layout -ne 'compact') { return $true }
  return $u.account -or @($u.windows).Count -or @($u.extras).Count -or -not $u.error
}

function Render {
  $ui.List.Children.Clear()
  $script:shown = @($script:data | Where-Object { Test-Shown $_ })
  if (-not $script:shown.Count) {
    $msg = if ($script:proc) { 'Loading...' } else { 'No data' }
    $ui.List.Children.Add((New-Text $msg $C.Muted)) | Out-Null
  }
  if ($script:layout -eq 'compact') { Render-Compact } else { Render-Normal }
  $ui.ModeBtn.Content = if ($script:display -eq 'used') { 'Used' } else { 'Left' }
  $ui.Updated.Text = if ($script:proc) { 'refreshing...' } else { Format-Ago $script:updatedAt }
  $ui.ErrorText.Text = $script:lastError
  Update-TrayText
}

# One card per account, with every limit as a bar.
function Render-Normal {
  $first = $true
  foreach ($u in $script:shown) {
    # One card per provider so each block reads as a unit.
    $card = New-Object System.Windows.Controls.Border
    $card.Background = Brush $C.Card
    $card.BorderBrush = Brush $C.CardBorder
    $card.BorderThickness = 1
    $card.CornerRadius = 8
    $card.Padding = '11,9,11,10'
    if (-not $first) { $card.Margin = '0,8,0,0' }
    $first = $false
    $section = New-Object System.Windows.Controls.StackPanel
    $card.Child = $section

    $head = New-Object System.Windows.Controls.TextBlock
    $head.FontWeight = 'SemiBold'
    $head.FontSize = 13.5
    $head.Inlines.Add((New-Object System.Windows.Documents.Run ("$($Icons[$u.id])  ") -Property @{ Foreground = (Brush $C.Muted) }))
    $head.Inlines.Add((New-Object System.Windows.Documents.Run $u.name))
    $planBox = New-Object System.Windows.Controls.Border
    if ($u.plan) {
      $planBox.Background = Brush $C.Track
      $planBox.CornerRadius = 4
      $planBox.Padding = '6,1,6,1'
      $planBox.VerticalAlignment = 'Center'
      $planBox.Child = New-Text ([string]$u.plan).ToUpper() $C.Muted 10 'SemiBold'
    }
    $section.Children.Add((New-Row $head $planBox)) | Out-Null
    if ($u.account) {
      $acct = New-Text ([string]$u.account) $C.Muted 11.5
      $acct.Margin = '0,1,0,0'
      $acct.TextTrimming = 'CharacterEllipsis'
      $acct.ToolTip = [string]$u.account
      $section.Children.Add($acct) | Out-Null
    }

    $hasData = ($u.windows.Count + $u.extras.Count) -gt 0
    if ($u.error) {
      $t = if ($hasData) { "stale - $($u.error)" } else { $u.error }
      $errColor = if ($hasData) { $C.Warn } else { $C.Muted }
      $e = New-Text $t $errColor 12
      $e.TextWrapping = 'Wrap'
      $e.Margin = '0,6,0,0'
      $section.Children.Add($e) | Out-Null
    }

    $firstMetric = $true
    foreach ($w in $u.windows) {
      $pct = if ($script:display -eq 'used') { $w.usedPct } else { 100 - $w.usedPct }
      $lv = Level $w.usedPct
      $label = New-Object System.Windows.Controls.TextBlock
      $label.Inlines.Add((New-Object System.Windows.Documents.Run $w.label))
      $reset = Format-Reset $w.resetsAt
      if ($reset) { $label.Inlines.Add((New-Object System.Windows.Documents.Run "  $reset" -Property @{ Foreground = (Brush $C.Muted); FontSize = 12 })) }
      $label.TextTrimming = 'CharacterEllipsis'
      $valueColor = if ($lv) { $lv } else { $C.Text }
      $row = New-Row $label (New-Text ("{0}%" -f [math]::Round($pct)) $valueColor 13 'SemiBold')
      $row.Margin = if ($firstMetric) { '0,9,0,0' } else { '0,8,0,0' }
      $firstMetric = $false
      $section.Children.Add($row) | Out-Null

      $bar = New-Object System.Windows.Controls.ProgressBar
      $bar.Height = 4
      $bar.Margin = '0,5,0,0'
      $bar.Value = [math]::Max(0, [math]::Min(100, $w.usedPct))
      $bar.BorderThickness = 0
      $bar.Background = Brush $C.Track
      $bar.Foreground = Brush $(if ($lv) { $lv } else { $C.Muted })
      $section.Children.Add($bar) | Out-Null
    }
    foreach ($x in $u.extras) {
      $row = New-Row (New-Text $x.label $C.Muted 12.5) (New-Text $x.value $C.Text 12.5)
      $row.Margin = if ($firstMetric) { '0,9,0,0' } else { '0,8,0,0' }
      $firstMetric = $false
      $section.Children.Add($row) | Out-Null
    }
    $ui.List.Children.Add($card) | Out-Null
  }
}

# ---- compact ------------------------------------------------------------------
# One card per provider, one line per account with a ring pair: outer arc = weekly (or the billing cycle), inner = 5 hours.
$script:ringPrev = @{}

function Get-Slots($u) {
  $ws = @($u.windows)
  $short = $ws | Where-Object { $_.label -match 'Hour' } | Select-Object -First 1
  $long = $ws | Where-Object { $_.label -match 'Week|7-Day Limit' } | Select-Object -First 1
  if (-not $long) { $long = $ws | Where-Object { $_ -ne $short -and $_.label -notmatch 'Opus|Sonnet' } | Select-Object -First 1 }
  return @{ short = $short; long = $long }
}

function Get-Shown([double]$used) { if ($script:display -eq 'used') { $used } else { 100 - $used } }

# How much of a ring to fill: the shown value, except that a used-up limit is always a full ring (in red).
function Get-ArcPct([double]$used) { if ($used -ge 100) { 100 } else { Get-Shown $used } }

function Get-SlotName($w) {
  if (-not $w) { return '' }
  switch -Regex ($w.label) { 'Hour' { '5h' } 'Week|7-Day' { 'wk' } 'Month|Billing' { 'mo' } default { $w.label } }
}

# "paulo" for paulo@example.com; without a known account, the profile folder (".claude-2") or nothing.
function Get-ShortAccount($u) {
  if ($u.account) { return ([string]$u.account) -replace '@.*$', '' }
  if ([string]$u.name -match '\((.+)\)$') { return $Matches[1] }
  return ''
}

# A circular arc drawn as the dashed stroke of an ellipse, so the dash offset can be animated from its last value.
function New-Arc([double]$size, [double]$t, [double]$pct, [string]$color, [string]$animKey) {
  $e = New-Object System.Windows.Shapes.Ellipse
  $e.Width = $size; $e.Height = $size
  $e.StrokeThickness = $t
  $e.Stroke = Brush $color
  $e.StrokeDashCap = 'Round'
  $e.RenderTransformOrigin = '0.5,0.5'
  $e.RenderTransform = New-Object System.Windows.Media.RotateTransform -90
  # Dash lengths are in stroke widths: one dash as long as the circle, then an equal gap.
  $len = [math]::PI * ($size - $t) / $t
  $dash = New-Object System.Windows.Media.DoubleCollection
  $dash.Add($len); $dash.Add($len)
  $e.StrokeDashArray = $dash
  $p = [math]::Max(0, [math]::Min(100, $pct)) / 100
  $from = if ($script:ringPrev.ContainsKey($animKey)) { $script:ringPrev[$animKey] } else { 0 }
  $script:ringPrev[$animKey] = $p
  # Under 1% a round-capped dash is just a dot, which reads as noise.
  if ($p -lt 0.01 -and $from -lt 0.01) { $e.Visibility = 'Hidden' }
  $anim = New-Object System.Windows.Media.Animation.DoubleAnimation ($len * (1 - $from)), ($len * (1 - $p)), ([TimeSpan]::FromMilliseconds(550))
  $ease = New-Object System.Windows.Media.Animation.CubicEase
  $ease.EasingMode = 'EaseOut'
  $anim.EasingFunction = $ease
  # Shrinking to under 1%: let it animate down, then drop the leftover dot.
  if ($p -lt 0.01) { $anim.add_Completed({ $e.Visibility = 'Hidden' }.GetNewClosure()) }
  $e.StrokeDashOffset = $len * (1 - $p)
  $e.BeginAnimation([System.Windows.Shapes.Shape]::StrokeDashOffsetProperty, $anim)
  return $e
}

function New-Track([double]$size, [double]$t) {
  $e = New-Object System.Windows.Shapes.Ellipse
  $e.Width = $size; $e.Height = $size
  $e.StrokeThickness = $t
  $e.Stroke = Brush $C.Track
  return $e
}

# Outer arc = weekly (or the billing cycle), inner arc = 5 hours. The numbers sit beside it, not inside.
function New-Ring($u, [double]$size = 42) {
  $t = 4
  $inner = $size - 2 * ($t + 3)
  $slots = Get-Slots $u
  $g = New-Object System.Windows.Controls.Grid
  $g.Width = $size; $g.Height = $size
  $key = if ($u.key) { $u.key } else { $u.id }
  $g.Children.Add((New-Track $size $t)) | Out-Null
  $both = $slots.short -and $slots.long
  if ($both) { $g.Children.Add((New-Track $inner $t)) | Out-Null }
  if ($slots.long) {
    $lv = Level $slots.long.usedPct
    $g.Children.Add((New-Arc $size $t (Get-ArcPct $slots.long.usedPct) $(if ($lv) { $lv } else { $C.Muted }) "$key|long")) | Out-Null
  }
  if ($slots.short) {
    $lv = Level $slots.short.usedPct
    $d = if ($both) { $inner } else { $size }
    $g.Children.Add((New-Arc $d $t (Get-ArcPct $slots.short.usedPct) $(if ($lv) { $lv } else { $C.Text }) "$key|short")) | Out-Null
  }
  if (-not $slots.short -and -not $slots.long) {
    $x = New-Text '!' $C.Warn 13 'SemiBold'
    $x.HorizontalAlignment = 'Center'; $x.VerticalAlignment = 'Center'
    $g.Children.Add($x) | Out-Null
  }
  return $g
}

# Everything the ring leaves out: every limit with its reset, the plan and any error.
function New-Tip($u) {
  $tt = New-Object System.Windows.Controls.ToolTip
  $tt.Background = Brush $C.Card
  $tt.BorderBrush = Brush $C.Border
  $tt.Foreground = Brush $C.Text
  $tt.Padding = '10,8'
  $sp = New-Object System.Windows.Controls.StackPanel
  $title = if ($u.account) { [string]$u.account } else { [string]$u.name }
  if ($u.plan) { $title += "  -  $(([string]$u.plan).ToUpper())" }
  $sp.Children.Add((New-Text $title $C.Text 12 'SemiBold')) | Out-Null
  foreach ($w in $u.windows) {
    $line = "{0}   {1}% {2}" -f $w.label, [math]::Round((Get-Shown $w.usedPct)), $(if ($script:display -eq 'used') { 'used' } else { 'left' })
    $reset = Format-Reset $w.resetsAt
    if ($reset) { $line += "  -  resets $reset" }
    $row = New-Text $line $C.Muted 11.5
    $row.Margin = '0,3,0,0'
    $sp.Children.Add($row) | Out-Null
  }
  foreach ($x in $u.extras) {
    $row = New-Text "$($x.label)   $($x.value)" $C.Muted 11.5
    $row.Margin = '0,3,0,0'
    $sp.Children.Add($row) | Out-Null
  }
  if ($u.error) {
    $row = New-Text ([string]$u.error) $C.Warn 11.5
    $row.Margin = '0,5,0,0'
    $sp.Children.Add($row) | Out-Null
  }
  $tt.Content = $sp
  return $tt
}

function Add-Hover($el) {
  $el.Background = [System.Windows.Media.Brushes]::Transparent
  $el.add_MouseEnter({ param($s) $s.Background = Brush $C.Hover })
  $el.add_MouseLeave({ param($s) $s.Background = [System.Windows.Media.Brushes]::Transparent })
}

# One line per account: ring, name with plan and next reset, then the 5h / weekly numbers on the right.
function New-AccountRow($u) {
  $row = New-Object System.Windows.Controls.Border
  $row.CornerRadius = 8
  $row.Padding = '6,5,8,5'
  $row.Margin = '-6,0,-6,0'
  Add-Hover $row
  $row.ToolTip = New-Tip $u
  $grid = New-Object System.Windows.Controls.Grid
  foreach ($w in 'Auto', '*', 'Auto') {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = $w
    $grid.ColumnDefinitions.Add($cd)
  }
  $grid.Children.Add((New-Ring $u)) | Out-Null

  $slots = Get-Slots $u
  $hasData = $slots.short -or $slots.long
  $plan = if ($u.plan) { ([string]$u.plan).ToUpper() } else { '' }
  # Without a known account (an API key, say) there is no name: the plan, or just the next line, leads.
  $title = Get-ShortAccount $u
  if (-not $title -and $plan) { $title = $plan; $plan = '' }
  $mid = New-Object System.Windows.Controls.StackPanel
  $mid.VerticalAlignment = 'Center'
  $mid.Margin = '12,0,10,0'
  [System.Windows.Controls.Grid]::SetColumn($mid, 1)
  if ($title) {
    $name = New-Text $title $C.Text 13
    $name.TextTrimming = 'CharacterEllipsis'
    $mid.Children.Add($name) | Out-Null
  }
  $main = if ($slots.short) { $slots.short } else { $slots.long }
  $parts = @()
  if ($plan) { $parts += $plan }
  if ($main -and $main.resetsAt) { $parts += "$([char]0x21BB) $(Format-ResetShort $main.resetsAt)" }
  $subText = $parts -join "  $([char]0x00B7)  "
  $subColor = $C.Muted
  if ($u.error) { $subText = if ($hasData) { 'stale' } else { [string]$u.error }; $subColor = if ($hasData) { $C.Warn } else { $C.Muted } }
  if ($subText) {
    $sub = New-Text $subText $subColor $(if ($title) { 11.5 } else { 12 })
    if ($title) {
      $sub.TextTrimming = 'CharacterEllipsis'
      $sub.Margin = '0,1,0,0'
    } else {
      $sub.TextWrapping = 'Wrap'
    }
    $mid.Children.Add($sub) | Out-Null
  }
  $grid.Children.Add($mid) | Out-Null

  # Numbers in a column of their own, labels right-aligned so the percentages line up.
  $nums = New-Object System.Windows.Controls.Grid
  $nums.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($nums, 2)
  foreach ($w in 'Auto', 'Auto') {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = $w
    $nums.ColumnDefinitions.Add($cd)
  }
  $i = 0
  foreach ($w in @($slots.short, $slots.long) | Where-Object { $_ }) {
    $nums.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $lbl = New-Text (Get-SlotName $w) $C.Muted 11.5
    $lbl.HorizontalAlignment = 'Right'; $lbl.VerticalAlignment = 'Center'
    $lbl.Margin = '0,0,8,0'
    [System.Windows.Controls.Grid]::SetRow($lbl, $i)
    $lv = Level $w.usedPct
    $val = New-Text ("{0}%" -f [math]::Round((Get-Shown $w.usedPct))) $(if ($lv) { $lv } else { $C.Text }) 13 'SemiBold'
    $val.HorizontalAlignment = 'Right'
    $val.MinWidth = 34
    $val.TextAlignment = 'Right'
    [System.Windows.Controls.Grid]::SetRow($val, $i)
    [System.Windows.Controls.Grid]::SetColumn($val, 1)
    $nums.Children.Add($lbl) | Out-Null
    $nums.Children.Add($val) | Out-Null
    $i++
  }
  $grid.Children.Add($nums) | Out-Null
  $row.Child = $grid
  return $row
}

function Render-Compact {
  # Group accounts by provider, keeping the order providers arrive in.
  $groups = [ordered]@{}
  foreach ($u in $script:shown) {
    if (-not $groups.Contains($u.id)) { $groups[$u.id] = New-Object System.Collections.ArrayList }
    $null = $groups[$u.id].Add($u)
  }
  $first = $true
  foreach ($id in $groups.Keys) {
    $accounts = @($groups[$id])
    $card = New-Object System.Windows.Controls.Border
    $card.Background = Brush $C.Card
    $card.BorderBrush = Brush $C.CardBorder
    $card.BorderThickness = 1
    $card.CornerRadius = 10
    $card.Padding = '12,10,12,6'
    if (-not $first) { $card.Margin = '0,8,0,0' }
    $first = $false
    $section = New-Object System.Windows.Controls.StackPanel
    $card.Child = $section

    $head = New-Object System.Windows.Controls.TextBlock
    $head.FontWeight = 'SemiBold'
    $head.FontSize = 13.5
    $accent = if ($Accents[$id]) { $Accents[$id] } else { $C.Muted }
    $head.Inlines.Add((New-Object System.Windows.Documents.Run ("$($Icons[$id])  ") -Property @{ Foreground = (Brush $accent) }))
    $head.Inlines.Add((New-Object System.Windows.Documents.Run ([string]($accounts[0].name -replace ' \(.*\)$', ''))))
    $count = New-Text $(if ($accounts.Count -gt 1) { "$($accounts.Count) accounts" } elseif ($accounts[0].plan) { ([string]$accounts[0].plan).ToUpper() } else { '' }) $C.Muted 10.5 'SemiBold'
    $count.VerticalAlignment = 'Center'
    $section.Children.Add((New-Row $head $count)) | Out-Null

    $rows = New-Object System.Windows.Controls.StackPanel
    $rows.Margin = '0,6,0,0'
    foreach ($u in $accounts) { $rows.Children.Add((New-AccountRow $u)) | Out-Null }
    $section.Children.Add($rows) | Out-Null
    $ui.List.Children.Add($card) | Out-Null
  }
}

function Start-Refresh {
  if ($script:proc) { return }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node'
  $ids = @($ProviderNames.Keys | Where-Object { $script:hiddenProviders -notcontains $_ })
  $psi.Arguments = '--experimental-strip-types --no-warnings "' + (Join-Path $Root 'scripts\usage-json.ts') + '" ' + ($ids -join ' ')
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  try {
    $script:proc = [System.Diagnostics.Process]::Start($psi)
    # Read asynchronously so a full pipe never blocks the child.
    $script:outTask = $script:proc.StandardOutput.ReadToEndAsync()
    $script:errTask = $script:proc.StandardError.ReadToEndAsync()
    $script:procStarted = Get-Date
  } catch {
    $script:proc = $null
    $script:lastError = 'node not found'
  }
  Render
}

function Complete-Refresh {
  $p = $script:proc
  if (-not $p) { return }
  if (-not $p.HasExited) {
    if (((Get-Date) - $script:procStarted).TotalSeconds -gt 60) { try { $p.Kill() } catch {} ; $script:lastError = 'timed out' ; $script:proc = $null ; Render }
    return
  }
  $script:proc = $null
  try {
    # Windows PowerShell's ConvertFrom-Json emits a JSON array as one object; ForEach-Object unrolls it.
    $fresh = @($script:outTask.Result | ConvertFrom-Json | ForEach-Object { $_ })
    # A transient provider failure keeps the last good numbers, flagged as stale.
    # Keyed per account (key), falling back to id for caches written before multi-account support.
    $prev = @{}
    foreach ($u in $script:data) { $prev[$(if ($u.key) { $u.key } else { $u.id })] = $u }
    $script:data = @(foreach ($u in $fresh) {
      $k = if ($u.key) { $u.key } else { $u.id }
      if ($u.error -and $prev[$k] -and $prev[$k].windows.Count) {
        # Good results carry no "error" property, so add it rather than assign it.
        $old = $prev[$k].PSObject.Copy(); $old | Add-Member -Force NoteProperty error $u.error; $old
      } else { $u }
    })
    $script:updatedAt = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $script:lastError = ''
    try {
      New-Item -ItemType Directory -Force $StateDir | Out-Null
      @{ updatedAt = $script:updatedAt; data = $script:data } | ConvertTo-Json -Depth 8 -Compress | Set-Content -Encoding UTF8 $CachePath
    } catch {}
  } catch {
    $script:lastError = 'refresh failed'
  }
  Render
  # A login finished while this refresh was running: fetch again so the new account shows up.
  if ($script:refreshPending) { $script:refreshPending = $false; Start-Refresh }
}

# ---- accounts -----------------------------------------------------------------
# Each extra account lives in its own config folder in home (".claude-2", ".codex-work"...), which the
# providers find on their own. Adding one asks for a command name (e.g. "claude2") and opens a terminal that
# creates the folder and a claude2 command for it, then signs in.
$AccountKinds = [ordered]@{
  claude = @{ Name = 'Claude'; Prefix = '.claude'; Command = 'claude' }
  codex = @{ Name = 'Codex'; Prefix = '.codex'; Command = 'codex' }
}
$script:logins = @()
$script:refreshPending = $false

function Show-Message([string]$text) {
  [System.Windows.MessageBox]::Show($text, 'OpenUsage', 'OK', 'Warning') | Out-Null
}

# "claude2" -> ".claude-2", "claude-work" -> ".claude-work", "trabalho" -> ".claude-trabalho".
function Get-AccountDir($k, [string]$name) {
  $suffix = $name
  if ($suffix.StartsWith($k.Command, 'OrdinalIgnoreCase')) { $suffix = $suffix.Substring($k.Command.Length) }
  $suffix = $suffix.TrimStart('-', '_')
  if (-not $suffix) { return $null }
  return Join-Path $HOME "$($k.Prefix)-$suffix"
}

# Why a command name can't be used, or $null when it can.
function Test-AccountName($k, [string]$name) {
  if (-not $name) { return 'Type a name.' }
  if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { return 'Use only letters, digits, - and _.' }
  $dir = Get-AccountDir $k $name
  if (-not $dir) { return "Pick a name other than $($k.Command)." }
  if (Get-Command $name -ErrorAction SilentlyContinue) { return "A command named $name already exists." }
  if (Test-Path $dir) { return "The folder ~\$(Split-Path -Leaf $dir) already exists." }
  return $null
}

# ---- dialogs ------------------------------------------------------------------
# Windows beside the widget, styled like it: rounded card, shadow, draggable title, a close cross.
# $heading is the title's inline XAML; $body goes under it. Styles: Btn / Primary buttons, Seg segmented choices.
function New-DialogXaml([string]$title, [string]$heading, [string]$body, [int]$width = 360) {
  return @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$title" Width="$width" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" Foreground="$($C.Text)">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Text)"/>
      <Setter Property="Background" Value="$($C.Card)"/>
      <Setter Property="BorderBrush" Value="$($C.CardBorder)"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="7" Padding="14,6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="CloseBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="6,2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Hover)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="$($C.Text)"/>
      <Setter Property="Foreground" Value="$($C.Bg)"/>
      <Setter Property="BorderBrush" Value="$($C.Text)"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" Background="Transparent" CornerRadius="6" Padding="12,4" MinWidth="78">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="$($C.Text)"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Text)"/>
                <Setter Property="Foreground" Value="$($C.Bg)"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="34" Height="18" CornerRadius="9" Background="$($C.Track)">
              <Ellipse x:Name="thumb" Width="12" Height="12" Margin="3,0" HorizontalAlignment="Left" Fill="$($C.Muted)"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="$($C.Text)"/>
                <Setter TargetName="thumb" Property="Fill" Value="$($C.Bg)"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="track" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="track" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SegBox" TargetType="Border">
      <Setter Property="Background" Value="$($C.Card)"/>
      <Setter Property="BorderBrush" Value="$($C.CardBorder)"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="3"/>
    </Style>
    <Style x:Key="Caption" TargetType="TextBlock">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="FontSize" Value="10.5"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
  </Window.Resources>
  <Border Margin="12" Background="$($C.Bg)" BorderBrush="$($C.Border)" BorderThickness="1" CornerRadius="12" Padding="18,14,18,16">
    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Opacity="0.4"/></Border.Effect>
    <StackPanel>
      <DockPanel x:Name="Header" Background="Transparent" Margin="0,0,0,12">
        <Button DockPanel.Dock="Right" x:Name="CloseX" Style="{StaticResource CloseBtn}" ToolTip="Close">&#x2715;</Button>
        <TextBlock FontWeight="SemiBold" FontSize="14.5">$heading</TextBlock>
      </DockPanel>
      $body
    </StackPanel>
  </Border>
</Window>
"@
}

# Loads a dialog, places it beside the widget on whichever side has room, and wires dragging and closing.
function New-Dialog([string]$xaml, [string[]]$names) {
  $dlg = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new([xml]$xaml))
  $d = @{ Window = $dlg }
  foreach ($n in @('Header', 'CloseX') + $names) { $d[$n] = $dlg.FindName($n) }
  $w = $dlg.Width
  $area = [System.Windows.SystemParameters]::WorkArea
  $dlg.Left = if ($win.IsVisible) { if ($win.Left - $w + 4 -ge $area.Left) { $win.Left - $w + 4 } else { $win.Left + $win.ActualWidth - 4 } } else { $area.Right - $w - 28 }
  $dlg.Top = if ($win.IsVisible) { $win.Top } else { $area.Top + 16 }
  # The close cross is a Button, which handles its own mouse-down, so the title drag never swallows the click.
  $d.Header.add_MouseLeftButtonDown({ param($s) [System.Windows.Window]::GetWindow($s).DragMove() })
  $d.CloseX.add_Click({ param($s) [System.Windows.Window]::GetWindow($s).DialogResult = $false })
  $dlg.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.DialogResult = $false } })
  return $d
}

# Asks for the new account's command name; $null when cancelled.
function Show-NameDialog([string]$kind, [string]$suggested) {
  $k = $AccountKinds[$kind]
  $body = @"
      <TextBlock Foreground="$($C.Muted)" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8">
        Command that opens this account from any terminal:
      </TextBlock>
      <Border x:Name="Field" Background="$($C.Card)" BorderBrush="$($C.CardBorder)" BorderThickness="1" CornerRadius="7" Padding="8,6">
        <DockPanel>
          <TextBlock DockPanel.Dock="Left" Text="&gt;" Foreground="$($C.Muted)" FontFamily="Cascadia Mono, Consolas" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBox x:Name="NameBox" Background="Transparent" BorderThickness="0" Foreground="$($C.Text)" CaretBrush="$($C.Text)"
                   SelectionBrush="$($C.Muted)" FontFamily="Cascadia Mono, Consolas" FontSize="13.5" VerticalContentAlignment="Center"/>
        </DockPanel>
      </Border>
      <TextBlock x:Name="Info" FontSize="11.5" TextWrapping="Wrap" Margin="2,7,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="CancelBtn" Style="{StaticResource Btn}" IsCancel="True" Margin="0,0,8,0">Cancel</Button>
        <Button x:Name="OkBtn" Style="{StaticResource Primary}" IsDefault="True">Sign in</Button>
      </StackPanel>
"@
  $heading = "<Run Foreground=`"$($C.Muted)`">$($Icons[$kind])</Run>  Add $($k.Name) account"
  $d = New-Dialog (New-DialogXaml "Add $($k.Name) account" $heading $body) @('Field', 'NameBox', 'Info', 'CancelBtn', 'OkBtn')
  $dlg = $d.Window

  # Shows where the account will live, or why the name can't be used.
  $validate = {
    $name = $d.NameBox.Text.Trim()
    $err = Test-AccountName $k $name
    if ($err) {
      $d.Info.Text = $err
      $d.Info.Foreground = Brush $C.Error
      $d.Field.BorderBrush = Brush $(if ($name) { $C.Error } else { $C.CardBorder })
    } else {
      $d.Info.Text = "Saved in ~\$(Split-Path -Leaf (Get-AccountDir $k $name))"
      $d.Info.Foreground = Brush $C.Muted
      $d.Field.BorderBrush = Brush $C.CardBorder
    }
    $d.OkBtn.IsEnabled = -not $err
  }
  $d.NameBox.add_TextChanged($validate)
  $d.OkBtn.add_Click({ $dlg.DialogResult = $true })
  $dlg.add_ContentRendered({ $d.NameBox.Focus() | Out-Null; $d.NameBox.SelectAll() })

  $d.NameBox.Text = $suggested
  & $validate
  if ($dlg.ShowDialog()) { return $d.NameBox.Text.Trim() }
  return $null
}

# The terminal runs scripts\add-account.ts, which creates the folder and command, signs in and undoes both when
# nothing (or the main account again) was signed in. Same script as on macOS and Linux.
function Add-Account([string]$kind) {
  $k = $AccountKinds[$kind]
  if (-not (Get-Command $k.Command -ErrorAction SilentlyContinue)) { Show-Message "$($k.Command) was not found. Install $($k.Name) first."; return }
  $n = 2
  while (Test-AccountName $k "$($k.Command)$n") { $n++ }
  $name = Show-NameDialog $kind "$($k.Command)$n"
  if (-not $name) { return }
  $addScript = (Join-Path $Root 'scripts\add-account.ts') -replace "'", "''"
  # Keep the window open when it fails, so its message can be read.
  $cmd = "node --experimental-strip-types --no-warnings '$addScript' $kind $name; if (`$LASTEXITCODE) { Read-Host 'Press Enter to close' }"
  try {
    $script:logins += Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd -PassThru
  } catch {
    Show-Message 'Could not open a terminal to sign in.'
  }
}

# When a sign-in terminal closes, fetch again so the new account shows up.
function Complete-Logins {
  if (-not @($script:logins | Where-Object { $_.HasExited }).Count) { return }
  $script:logins = @($script:logins | Where-Object { -not $_.HasExited })
  if ($script:proc) { $script:refreshPending = $true } else { Start-Refresh }
}

$addMenu = New-Object System.Windows.Controls.ContextMenu
$addMenu.PlacementTarget = $ui.AddBtn
$addMenu.Placement = 'Bottom'
foreach ($kind in $AccountKinds.Keys) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Header = "$($Icons[$kind])  $($AccountKinds[$kind].Name) account"
  $mi.Tag = $kind
  $mi.add_Click({ param($s) Add-Account $s.Tag })
  $null = $addMenu.Items.Add($mi)
}

# ---- update -------------------------------------------------------------------
# scripts\update.ts reports the version and how many commits the remote is ahead ("check"), or fast-forwards ("apply").
$script:upd = @{ busy = ''; version = ''; commit = ''; behind = 0; error = ''; checkedAt = $null }
$script:updProc = $null

function Start-Update([string]$action) {
  if ($script:updProc) { return }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node'
  $psi.Arguments = '--experimental-strip-types --no-warnings "' + (Join-Path $Root 'scripts\update.ts') + '" ' + $action
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  try {
    $script:updProc = [System.Diagnostics.Process]::Start($psi)
    $script:updOut = $script:updProc.StandardOutput.ReadToEndAsync()
    $script:upd.busy = $action
  } catch {
    $script:upd.error = 'node not found'
  }
}

function Complete-Update {
  $p = $script:updProc
  if (-not $p -or -not $p.HasExited) { return }
  $script:updProc = $null
  $action = $script:upd.busy
  $script:upd.busy = ''
  try {
    $r = $script:updOut.Result | ConvertFrom-Json
    if (-not $r) { throw 'no output' }
    $script:upd.version = [string]$r.version
    $script:upd.commit = [string]$r.commit
    $script:upd.error = [string]$r.error
    if ($null -ne $r.behind) { $script:upd.behind = [int]$r.behind }
    $script:upd.checkedAt = Get-Date
    if ($action -eq 'apply' -and $r.updated -and -not $r.error) { Restart-Widget; return }
  } catch {
    $script:upd.error = 'update check failed'
  }
  $ui.GearDot.Visibility = if ($script:upd.behind -gt 0) { 'Visible' } else { 'Collapsed' }
}

# The new code only runs in a new process: start one after this one has let go of the single-instance mutex.
function Restart-Widget {
  $vbs = Join-Path $PSScriptRoot 'usage-widget.vbs'
  $cmd = "Start-Sleep 2; Start-Process wscript.exe -ArgumentList '`"$vbs`"'"
  Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $cmd
  $script:quitting = $true
  $win.Close()
}

# ---- settings -----------------------------------------------------------------
function Get-SwitchName([string]$id) { 'Prov_' + ($id -replace '\W', '_') }

function Show-Settings {
  $iconUri = (Join-Path $Root 'docs\icon.png') -replace '&', '&amp;'
  $providerRows = foreach ($id in $ProviderNames.Keys) {
    @"
      <DockPanel Margin="0,0,0,8">
        <CheckBox x:Name="$(Get-SwitchName $id)" DockPanel.Dock="Right" Style="{StaticResource Switch}" Tag="$id" AutomationProperties.Name="Show $($ProviderNames[$id])" VerticalAlignment="Center"/>
        <TextBlock VerticalAlignment="Center"><Run Foreground="$($Accents[$id])">$($Icons[$id])</Run>  $($ProviderNames[$id])</TextBlock>
      </DockPanel>
"@
  }
  $body = @"
      <TextBlock Style="{StaticResource Caption}" Text="DISPLAY"/>
      <DockPanel Margin="0,0,0,8">
        <Border DockPanel.Dock="Right" Style="{StaticResource SegBox}">
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="UsedOpt" GroupName="display" Style="{StaticResource Seg}">Used</RadioButton>
            <RadioButton x:Name="LeftOpt" GroupName="display" Style="{StaticResource Seg}">Left</RadioButton>
          </StackPanel>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Numbers"/>
          <TextBlock Text="Default for every limit" Foreground="$($C.Muted)" FontSize="11"/>
        </StackPanel>
      </DockPanel>
      <DockPanel>
        <Border DockPanel.Dock="Right" Style="{StaticResource SegBox}">
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="NormalOpt" GroupName="layout" Style="{StaticResource Seg}">Normal</RadioButton>
            <RadioButton x:Name="CompactOpt" GroupName="layout" Style="{StaticResource Seg}">Compact</RadioButton>
          </StackPanel>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Layout"/>
          <TextBlock Text="Compact: a line per account" Foreground="$($C.Muted)" FontSize="11"/>
        </StackPanel>
      </DockPanel>
      <Border Height="1" Background="$($C.Divider)" Margin="0,16,0,14"/>
      <TextBlock Style="{StaticResource Caption}" Text="PROVIDERS"/>
$($providerRows -join "`n")
      <Border Height="1" Background="$($C.Divider)" Margin="0,8,0,14"/>
      <TextBlock Style="{StaticResource Caption}" Text="ABOUT"/>
      <DockPanel>
        <Image DockPanel.Dock="Left" Source="$iconUri" Width="40" Height="40" Margin="0,0,12,0" RenderOptions.BitmapScalingMode="HighQuality"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="OpenUsage" FontWeight="SemiBold" FontSize="13.5"/>
          <TextBlock x:Name="VersionText" Foreground="$($C.Muted)" FontFamily="Cascadia Mono, Consolas" FontSize="11.5" Margin="0,1,0,0"/>
        </StackPanel>
      </DockPanel>
      <Border Background="$($C.Card)" BorderBrush="$($C.CardBorder)" BorderThickness="1" CornerRadius="8" Padding="10,8" Margin="0,12,0,0">
        <DockPanel>
          <Ellipse x:Name="StatusDot" DockPanel.Dock="Left" Width="8" Height="8" Margin="0,0,9,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusText" TextWrapping="Wrap" FontSize="12.5" VerticalAlignment="Center"/>
        </DockPanel>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Button x:Name="CheckBtn" Style="{StaticResource Btn}">Check for updates</Button>
        <Button x:Name="UpdateBtn" Style="{StaticResource Primary}" Margin="8,0,0,0">Update now</Button>
      </StackPanel>
"@
  $heading = "<Run Foreground=`"$($C.Muted)`" FontFamily=`"Segoe UI Symbol`">&#x2699;</Run>  Settings"
  $d = New-Dialog (New-DialogXaml 'OpenUsage settings' $heading $body 380) @(
    'UsedOpt', 'LeftOpt', 'NormalOpt', 'CompactOpt', 'VersionText', 'StatusDot', 'StatusText', 'CheckBtn', 'UpdateBtn')
  $dlg = $d.Window

  # One switch per provider; the last one left on can't be switched off, so the widget is never empty.
  $switches = @(foreach ($id in $ProviderNames.Keys) { $dlg.FindName((Get-SwitchName $id)) })
  $syncSwitches = { foreach ($sw in $switches) { $sw.IsEnabled = -not $sw.IsChecked -or @($switches | Where-Object { $_.IsChecked }).Count -gt 1 } }
  foreach ($sw in $switches) { $sw.IsChecked = $script:hiddenProviders -notcontains $sw.Tag }
  & $syncSwitches
  $setProvider = {
    param($s)
    $script:hiddenProviders = @($switches | Where-Object { -not $_.IsChecked } | ForEach-Object { [string]$_.Tag })
    Set-State @{ hiddenProviders = $script:hiddenProviders }
    & $syncSwitches
    Render
    # A provider switched back on has nothing cached: fetch it.
    if ($s.IsChecked) { if ($script:proc) { $script:refreshPending = $true } else { Start-Refresh } }
  }
  foreach ($sw in $switches) { $sw.add_Checked($setProvider); $sw.add_Unchecked($setProvider) }

  $d.UsedOpt.IsChecked = $script:display -eq 'used'
  $d.LeftOpt.IsChecked = $script:display -ne 'used'
  $d.NormalOpt.IsChecked = $script:layout -ne 'compact'
  $d.CompactOpt.IsChecked = $script:layout -eq 'compact'
  # Changes apply to the widget right away.
  $setDisplay = { $script:display = if ($d.UsedOpt.IsChecked) { 'used' } else { 'remaining' }; Set-State @{ display = $script:display }; Render }
  $setLayout = { $script:layout = if ($d.CompactOpt.IsChecked) { 'compact' } else { 'normal' }; Set-State @{ layout = $script:layout }; Render }
  $d.UsedOpt.add_Checked($setDisplay); $d.LeftOpt.add_Checked($setDisplay)
  $d.NormalOpt.add_Checked($setLayout); $d.CompactOpt.add_Checked($setLayout)

  # Mirrors the update state while the dialog is open.
  $sync = {
    $u = $script:upd
    $d.VersionText.Text = if ($u.version) { "v$($u.version)" + $(if ($u.commit) { " $([char]0x00B7) $($u.commit)" } else { '' }) } else { '...' }
    $color = $C.Muted
    $d.StatusText.Text = if ($u.busy -eq 'apply') { 'Updating...' }
      elseif ($u.busy -eq 'check') { 'Checking for updates...' }
      elseif ($u.error) { $color = $C.Error; "Can't update: $($u.error)" }
      elseif ($u.behind -gt 0) { $color = $C.Warn; "Update available: $($u.behind) new change$(if ($u.behind -gt 1) { 's' })" }
      elseif ($u.checkedAt) { $color = $C.Ok; 'Up to date' }
      else { 'Not checked yet' }
    $d.StatusDot.Fill = Brush $color
    $d.CheckBtn.IsEnabled = -not $u.busy
    $d.UpdateBtn.Visibility = if ($u.behind -gt 0 -and -not $u.error) { 'Visible' } else { 'Collapsed' }
    $d.UpdateBtn.IsEnabled = -not $u.busy
  }
  $d.CheckBtn.add_Click({ Start-Update 'check'; & $sync })
  $d.UpdateBtn.add_Click({ Start-Update 'apply'; & $sync })
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(300)
  $timer.add_Tick($sync)
  & $sync
  $timer.Start()
  $null = $dlg.ShowDialog()
  $timer.Stop()
}

# ---- tray ---------------------------------------------------------------------
$IconPath = Join-Path $PSScriptRoot 'openusage.ico'
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-Object System.Drawing.Icon $IconPath, ([System.Windows.Forms.SystemInformation]::SmallIconSize)
$tray.Text = 'OpenUsage'
$tray.Visible = $true

function Update-TrayText {
  $parts = foreach ($u in $script:data) {
    if ($u.windows.Count -and $script:hiddenProviders -notcontains $u.id) { "{0} {1}%" -f $u.name, [math]::Round(($u.windows | Measure-Object usedPct -Maximum).Maximum) }
  }
  $text = if ($parts) { 'OpenUsage - ' + ($parts -join ' | ') } else { 'OpenUsage' }
  $tray.Text = $text.Substring(0, [math]::Min(63, $text.Length))
}

# Minimized keeps just the title bar on screen; the same button brings the limits back.
function Set-Minimized([bool]$on) {
  $script:minimized = $on
  $ui.Body.Visibility = if ($on) { 'Collapsed' } else { 'Visible' }
  $ui.MinBtn.Content = if ($on) { [string][char]0x25A1 } else { [string][char]0x2013 }
  $ui.MinBtn.ToolTip = if ($on) { 'Restore' } else { 'Minimize' }
  Set-State @{ minimized = $on }
}

function Toggle-Window {
  if ($win.IsVisible) { $win.Hide(); Set-State @{ hidden = $true } }
  else { $win.Show(); Set-State @{ hidden = $false } }
}

function New-Shortcut([string]$path) {
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
  # Go through the .vbs launcher so no console window flashes.
  $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
  $lnk.Arguments = "`"$(Join-Path $PSScriptRoot 'usage-widget.vbs')`""
  $lnk.IconLocation = $IconPath
  $lnk.Description = 'OpenUsage'
  $lnk.Save()
}

# A menu item that creates or removes a shortcut.
function New-ShortcutItem([string]$text, [string]$path) {
  $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
  $item.Tag = $path
  $item.Checked = Test-Path $path
  $item.add_Click({
    param($s)
    if (Test-Path $s.Tag) { Remove-Item $s.Tag } else { New-Shortcut $s.Tag }
    $s.Checked = Test-Path $s.Tag
  })
  return $item
}

$startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'usage-widget.lnk'
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'OpenUsage.lnk'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$null = $menu.Items.Add('Show / hide', $null, { Toggle-Window })
$null = $menu.Items.Add('Refresh', $null, { Start-Refresh })
$null = $menu.Items.Add('Settings', $null, { Show-Settings })
$addItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Add account'
foreach ($kind in $AccountKinds.Keys) {
  $sub = New-Object System.Windows.Forms.ToolStripMenuItem "$($AccountKinds[$kind].Name) account"
  $sub.Tag = $kind
  $sub.add_Click({ param($s) Add-Account $s.Tag })
  $null = $addItem.DropDownItems.Add($sub)
}
$null = $menu.Items.Add($addItem)
$null = $menu.Items.Add('-')
$topItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Always on top'
$topItem.Checked = $win.Topmost
$topItem.add_Click({ $win.Topmost = -not $win.Topmost; $topItem.Checked = $win.Topmost; Set-State @{ topmost = $win.Topmost } })
$null = $menu.Items.Add($topItem)
$null = $menu.Items.Add((New-ShortcutItem 'Start with Windows' $startupLink))
$null = $menu.Items.Add((New-ShortcutItem 'Desktop shortcut' $desktopLink))
$null = $menu.Items.Add('-')
$null = $menu.Items.Add('Quit', $null, { $script:quitting = $true; $win.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Toggle-Window } })

# ---- events -------------------------------------------------------------------
$ui.Header.add_MouseLeftButtonDown({ $win.DragMove(); Set-State @{ x = $win.Left; y = $win.Top } })
$ui.ModeBtn.add_Click({
  $script:display = if ($script:display -eq 'used') { 'remaining' } else { 'used' }
  Set-State @{ display = $script:display }
  Render
})
$ui.GearBtn.add_Click({ Show-Settings })
$ui.AddBtn.add_Click({ $addMenu.IsOpen = $true })
$ui.RefreshBtn.add_Click({ Start-Refresh })
$ui.MinBtn.add_Click({ Set-Minimized (-not $script:minimized) })
$ui.HideBtn.add_Click({ Toggle-Window })
$win.add_Closing({ param($s, $e) if (-not $script:quitting) { $e.Cancel = $true; Toggle-Window } })
$win.add_Closed({ $tray.Visible = $false; $tray.Dispose(); [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() })

# Poll the child process and schedule refreshes on the UI thread.
$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(400)
$poll.add_Tick({
  if ($showEvent.WaitOne(0) -and -not $win.IsVisible) { Toggle-Window }
  Complete-Refresh
  Complete-Logins
  Complete-Update
})
$poll.Start()
$tick = New-Object System.Windows.Threading.DispatcherTimer
$tick.Interval = [TimeSpan]::FromMinutes($RefreshMinutes)
$tick.add_Tick({ Start-Refresh })
$tick.Start()
# Look for a new version at start and once a day; the gear gets a dot when there is one.
$daily = New-Object System.Windows.Threading.DispatcherTimer
$daily.Interval = [TimeSpan]::FromHours(24)
$daily.add_Tick({ Start-Update 'check' })
$daily.Start()
$ago = New-Object System.Windows.Threading.DispatcherTimer
$ago.Interval = [TimeSpan]::FromSeconds(30)
$ago.add_Tick({ if (-not $script:proc) { $ui.Updated.Text = Format-Ago $script:updatedAt } })
$ago.Start()

# Launching the widget always shows it; "hidden" only lasts for the running session.
Set-Minimized ([bool]$state.minimized)
$win.Show()
Set-State @{ hidden = $false }
Start-Refresh
Start-Update 'check'
[System.Windows.Threading.Dispatcher]::Run()
$mutex.ReleaseMutex()
