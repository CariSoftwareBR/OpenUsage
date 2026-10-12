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
$ProviderNames = [ordered]@{
  claude = 'Claude'; codex = 'Codex'; copilot = 'Copilot'; cursor = 'Cursor'; devin = 'Devin'; grok = 'Grok'; kilo = 'Kilo'
  ollama = 'Ollama'; 'opencode-go' = 'OpenCode Go'; openrouter = 'OpenRouter'; zai = 'Z.ai'
}
$Icons = @{
  claude = [string][char]0x273B; codex = [string][char]0x25CE; copilot = [string][char]0x25C8; cursor = [string][char]0x2B21
  devin = [string][char]0x25C7; grok = [string][char]0x2726; kilo = [string][char]0x25C6; ollama = [string][char]0x25C9
  'opencode-go' = [string][char]0x25A3; openrouter = [string][char]0x21C4; zai = [string][char]0x25B2
}
# The providers' own marks (assets/providers/*.svg, one path each); the glyphs above stand in for any without one.
$Logos = @{}; $LogoData = @{}
foreach ($f in @(Get-ChildItem (Join-Path $Root 'assets\providers') -Filter *.svg -ErrorAction SilentlyContinue)) {
  try {
    $d = ([regex]::Matches((Get-Content $f.FullName -Raw), '\sd="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) -join ' '
    if ($d) { $Logos[$f.BaseName] = [System.Windows.Media.Geometry]::Parse("F1 $d"); $Logos[$f.BaseName].Freeze(); $LogoData[$f.BaseName] = "F1 $d" }
  } catch {}
}
if ($Logos.opencode) { $Logos['opencode-go'] = $Logos.opencode; $LogoData['opencode-go'] = $LogoData.opencode }

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
$script:layout = if (@('compact', 'bar') -contains $state.layout) { [string]$state.layout } elseif ($state.layout -eq 'bars') { 'bar' } else { 'normal' }
# How compact and strip draw a limit: 'ring' or 'bar' (a slim meter).
$script:gauge = if ($state.gauge -eq 'bar' -or $state.layout -eq 'bars') { 'bar' } else { 'ring' }
# Providers switched off: not fetched and not shown. At the first start only the ones set up on this PC are on;
# "seen" remembers which were found, so one installed later turns on by itself and one switched off stays off.
$script:hiddenProviders = @($state.hiddenProviders | Where-Object { $_ })
$script:seenProviders = if ($null -ne $state.seenProviders) { @($state.seenProviders | Where-Object { $_ }) } else { $null }
# Providers this widget offered at the last detection: one added by an update starts off unless it is found here.
$script:knownProviders = if ($null -ne $state.knownProviders) { @($state.knownProviders | Where-Object { $_ }) } else { @($script:seenProviders) + @($script:hiddenProviders) }

# ---- theme (follows Windows light/dark) ---------------------------------------
$light = $false
try { $light = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme) -eq 1 } catch {}
$C = if ($light) {
  @{ Bg = '#FBFAF8'; Border = '#E2DDD7'; Divider = '#ECE8E3'; Text = '#1F1C1A'; Muted = '#857D76'; Warn = '#C46D12'; Error = '#C9362D'; Ok = '#2E8B57'; Track = '#E4DED7'; Hover = '#F1EDE8'; Card = '#F3F0EB'; CardBorder = '#E8E3DD' }
} else {
  @{ Bg = '#1C1A19'; Border = '#34302D'; Divider = '#2C2926'; Text = '#EBE7E2'; Muted = '#8D8680'; Warn = '#E8953F'; Error = '#E5584F'; Ok = '#5BBF86'; Track = '#35302C'; Hover = '#2A2725'; Card = '#242120'; CardBorder = '#2E2A27' }
}
$Accents = @{
  claude = '#D97757'; codex = $(if ($light) { '#0F8A6C' } else { '#3DBE9C' }); copilot = $(if ($light) { '#8250DF' } else { '#A371F7' }); cursor = $C.Text
  devin = $(if ($light) { '#2563EB' } else { '#60A5FA' }); grok = $C.Text; kilo = $(if ($light) { '#A68A00' } else { '#F2D33C' }); ollama = $C.Text
  'opencode-go' = $C.Text; openrouter = $(if ($light) { '#4F46E5' } else { '#818CF8' }); zai = $(if ($light) { '#0E7490' } else { '#22D3EE' })
}
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
  <Grid>
  <Border x:Name="Frame" Margin="8" Background="$($C.Bg)" BorderBrush="$($C.Border)" BorderThickness="1" CornerRadius="12" Padding="14,10,14,10">
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35"/></Border.Effect>
    <Grid>
    <Border x:Name="FrameShimmer" Margin="-14,-10,-14,-10" CornerRadius="11" IsHitTestVisible="False" Opacity="0"/>
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
          <Button x:Name="RefreshBtn" Style="{StaticResource Btn}" ToolTip="Refresh" RenderTransformOrigin="0.5,0.5">
            <Button.RenderTransform><RotateTransform/></Button.RenderTransform>&#x27F3;</Button>
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
    </Grid>
  </Border>
  <!-- Bar layout: one slim pill, a chip per account. -->
  <Border x:Name="BarFrame" Margin="8" Visibility="Collapsed" Background="$($C.Bg)" BorderBrush="$($C.Border)" BorderThickness="1"
          CornerRadius="23" Padding="5,4,5,4">
    <Border.Effect><DropShadowEffect BlurRadius="16" ShadowDepth="2" Opacity="0.35"/></Border.Effect>
    <Grid>
      <Border x:Name="Shimmer" CornerRadius="19" IsHitTestVisible="False" Opacity="0"/>
      <StackPanel Orientation="Horizontal" Background="Transparent">
        <Grid x:Name="BarGrip" Width="26" Height="38" Background="Transparent" Cursor="SizeAll">
          <TextBlock Text="&#x25F7;" Foreground="$($C.Muted)" FontSize="14" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>
        <StackPanel x:Name="BarChips" Orientation="Horizontal" VerticalAlignment="Center"/>
        <StackPanel x:Name="BarTools" Orientation="Horizontal" VerticalAlignment="Center" Margin="2,0,0,0" Opacity="0.35">
          <Button x:Name="BarRefresh" Style="{StaticResource Btn}" ToolTip="Refresh" RenderTransformOrigin="0.5,0.5">
            <Button.RenderTransform><RotateTransform/></Button.RenderTransform>&#x27F3;</Button>
          <Button x:Name="BarGear" Style="{StaticResource Btn}" ToolTip="Settings">
            <TextBlock Text="&#x2699;" FontFamily="Segoe UI Symbol"/>
          </Button>
        </StackPanel>
      </StackPanel>
    </Grid>
  </Border>
  </Grid>
</Window>
"@
$win = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($xaml))
$ui = @{}
foreach ($n in 'Frame', 'FrameShimmer', 'Header', 'GearBtn', 'GearDot', 'AddBtn', 'ModeBtn', 'RefreshBtn', 'MinBtn', 'HideBtn', 'Body', 'List', 'Updated', 'ErrorText',
  'BarFrame', 'Shimmer', 'BarGrip', 'BarChips', 'BarTools', 'BarRefresh', 'BarGear') { $ui[$n] = $win.FindName($n) }

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

# A provider's mark, fitted to a $size box; its glyph when there is no mark.
function New-Logo([string]$id, $color, [double]$size = 13) {
  if (-not $Logos[$id]) {
    $t = New-Text $Icons[$id] $color $size
    $t.VerticalAlignment = 'Center'
    return $t
  }
  $p = New-Object System.Windows.Shapes.Path
  $p.Data = $Logos[$id]
  $p.Stretch = 'Uniform'
  $p.Width = $size; $p.Height = $size
  $p.Fill = Brush $color
  $p.VerticalAlignment = 'Center'
  return $p
}

# The mark inside a line of text.
function New-LogoInline([string]$id, $color, [double]$size = 13) {
  $c = New-Object System.Windows.Documents.InlineUIContainer (New-Logo $id $color $size)
  $c.BaselineAlignment = 'Center'
  return $c
}

# The same for XAML written as text (dialog titles, settings rows).
function Get-LogoXaml([string]$id, [string]$color, [double]$size = 13) {
  if (-not $Logos[$id]) { return "<Run Foreground=`"$color`">$($Icons[$id])</Run>" }
  return "<InlineUIContainer BaselineAlignment=`"Center`"><Path Width=`"$size`" Height=`"$size`" Stretch=`"Uniform`" Fill=`"$color`" Data=`"$($LogoData[$id])`"/></InlineUIContainer>"
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
  # Windows PowerShell reads an empty JSON array as one $null.
  $script:data = @($cache.data | Where-Object { $_ })
  $script:updatedAt = $cache.updatedAt
} catch {}
$script:lastError = ''
$script:proc = $null

# In compact and bar modes a provider with no account at all (never signed in, no key, nothing to show) is left
# out; the normal layout keeps it, with the hint on how to sign in.
function Test-Shown($u) {
  if ($script:hiddenProviders -contains $u.id) { return $false }
  if ($script:layout -eq 'normal') { return $true }
  return $u.account -or @($u.windows).Count -or @($u.extras).Count -or -not $u.error
}

function Render {
  $ui.List.Children.Clear()
  $script:shown = @($script:data | Where-Object { Test-Shown $_ })
  if (-not $script:shown.Count) {
    $msg = if ($script:proc -or $script:detectProc) { 'Loading...' }
      elseif (-not @($ProviderNames.Keys | Where-Object { $script:hiddenProviders -notcontains $_ }).Count) { "No AI tool found on this PC. Turn one on in settings ($([char]0x2699))." }
      else { 'No data' }
    $ui.List.Children.Add((New-Text $msg $C.Muted)) | Out-Null
  }
  if (Test-Strip) { Render-Bar } elseif ($script:layout -eq 'compact') { Render-Compact } else { Render-Normal }
  $ui.ModeBtn.Content = if ($script:display -eq 'used') { 'Used' } else { 'Left' }
  $ui.Updated.Text = if ($script:proc) { 'refreshing...' } else { Format-Ago $script:updatedAt }
  $ui.ErrorText.Text = $script:lastError
  Update-TrayText
  Set-Shimmer ([bool]$script:proc)
  $script:barIntro = $false
}

# One card per account, with every limit as a bar.
function Render-Normal {
  $first = $true
  $index = 0
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
    $head.Inlines.Add((New-LogoInline $u.id $(if ($Accents[$u.id]) { $Accents[$u.id] } else { $C.Muted }) 14))
    $head.Inlines.Add((New-Object System.Windows.Documents.Run '  '))
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

      $bar = New-Fill $w.usedPct $(if ($lv) { $lv } else { $C.Muted }) $index
      $bar.Margin = '0,5,0,0'
      $section.Children.Add($bar) | Out-Null
    }
    foreach ($x in $u.extras) {
      $row = New-Row (New-Text $x.label $C.Muted 12.5) (New-Text $x.value $C.Text 12.5)
      $row.Margin = if ($firstMetric) { '0,9,0,0' } else { '0,8,0,0' }
      $firstMetric = $false
      $section.Children.Add($row) | Out-Null
    }
    Add-Lift $card
    Add-Intro $card $index
    $index++
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
    # Only a balance (credits, say) and nothing wrong: a "$" rather than the warning mark.
    $x = if (@($u.extras).Count -and -not $u.error) { New-Text '$' $C.Muted 13 'SemiBold' } else { New-Text '!' $C.Warn 13 'SemiBold' }
    $x.HorizontalAlignment = 'Center'; $x.VerticalAlignment = 'Center'
    $g.Children.Add($x) | Out-Null
  }
  if (@($slots.short, $slots.long) | Where-Object { $_ -and $_.usedPct -ge 80 }) { Add-Glow $g $C.Error }
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

# Compact with bars: one short line per account, its name and a meter per limit.
function New-AccountMeterRow($u, [int]$index, [string]$accent) {
  $row = New-Object System.Windows.Controls.Border
  $row.CornerRadius = 6
  $row.Padding = '6,3,6,3'
  $row.Margin = '-6,0,-6,0'
  Add-Hover $row
  $row.ToolTip = New-Tip $u
  $grid = New-Object System.Windows.Controls.Grid
  foreach ($w in '*', 'Auto') {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = $w
    $grid.ColumnDefinitions.Add($cd)
  }
  $slots = Get-Slots $u
  $meters = @(@($slots.short, $slots.long) | Where-Object { $_ })
  $title = Get-ShortAccount $u
  # No account to name (an API key): the balance, if any, says more than the plan already in the header.
  if (-not $title) {
    $bal = @($u.extras | Where-Object { $_.label -match 'Balance' })
    $title = if ($bal.Count -and $meters.Count) { "$($bal[0].value) balance" } else { [string]($u.name -replace ' \(.*\)$', '') }
  }
  $name = New-Text $title $(if ($u.error -and -not $meters.Count) { $C.Muted } else { $C.Text }) 12
  $name.TextTrimming = 'CharacterEllipsis'
  $name.VerticalAlignment = 'Center'
  $name.Margin = '0,0,8,0'
  $grid.Children.Add($name) | Out-Null
  $right = New-Object System.Windows.Controls.StackPanel
  $right.Orientation = 'Horizontal'
  $right.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($right, 1)
  if ($meters.Count) {
    # One limit gets the room of two.
    $len = if ($meters.Count -eq 1) { 112 } else { 36 }
    foreach ($w in $meters) {
      $m = New-Meter $w $accent $index $len
      if ($right.Children.Count) { $m.Margin = '6,0,0,0' }
      $right.Children.Add($m) | Out-Null
    }
    if ($u.error) { $right.Opacity = 0.55 }
  } elseif (@($u.extras).Count) {
    $x = @($u.extras)[0]
    $right.Children.Add((New-Text "$(([string]$x.label).ToLower())  " $C.Muted 11)) | Out-Null
    $right.Children.Add((New-Text ([string]$x.value) $C.Text 12 'SemiBold')) | Out-Null
  } else {
    $err = New-Text $(if ($u.error) { [string]$u.error } else { 'no data' }) $C.Muted 11
    $err.TextTrimming = 'CharacterEllipsis'
    $err.MaxWidth = 190
    $right.Children.Add($err) | Out-Null
  }
  $grid.Children.Add($right) | Out-Null
  $row.Child = $grid
  return $row
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
  if (-not $title -and @($u.extras | Where-Object { $_.label -match 'Balance' })) { $title = "$((@($u.extras | Where-Object { $_.label -match 'Balance' }))[0].value) balance" }
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
  # No limit to show: the first extra (a credit balance) takes the numbers' place.
  if (-not $i -and @($u.extras).Count) {
    $x = @($u.extras)[0]
    $lbl = New-Text ([string]$x.label).ToLower() $C.Muted 11.5
    $lbl.VerticalAlignment = 'Center'
    $lbl.Margin = '0,0,8,0'
    $val = New-Text ([string]$x.value) $C.Text 13 'SemiBold'
    [System.Windows.Controls.Grid]::SetColumn($val, 1)
    $nums.Children.Add($lbl) | Out-Null
    $nums.Children.Add($val) | Out-Null
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
  $index = 0
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
    $head.Inlines.Add((New-LogoInline $id $accent 14))
    $head.Inlines.Add((New-Object System.Windows.Documents.Run '  '))
    $head.Inlines.Add((New-Object System.Windows.Documents.Run ([string]($accounts[0].name -replace ' \(.*\)$', ''))))
    $count = New-Text $(if ($accounts.Count -gt 1) { "$($accounts.Count) accounts" } elseif ($accounts[0].plan) { ([string]$accounts[0].plan).ToUpper() } else { '' }) $C.Muted 10.5 'SemiBold'
    $count.VerticalAlignment = 'Center'
    $section.Children.Add((New-Row $head $count)) | Out-Null

    $rows = New-Object System.Windows.Controls.StackPanel
    $rows.Margin = '0,6,0,0'
    if ($script:gauge -eq 'bar') {
      $card.Padding = '12,8,12,6'
      $rows.Margin = '0,4,0,0'
      foreach ($u in $accounts) { $rows.Children.Add((New-AccountMeterRow $u $index $accent)) | Out-Null }
    } else {
      foreach ($u in $accounts) { $rows.Children.Add((New-AccountRow $u)) | Out-Null }
    }
    $section.Children.Add($rows) | Out-Null
    Add-Lift $card
    Add-Intro $card $index
    $index++
    $ui.List.Children.Add($card) | Out-Null
  }
}

# ---- bar ----------------------------------------------------------------------
# The slimmest layout: one pill with a chip per account. A chip is a small ring pair around the provider's mark,
# with the main number beside it and the other one under it. Hovering a chip lifts it and shows every limit.
$script:barIntro = $true
$script:shimmerOn = $false

function Test-Strip { $script:layout -eq 'bar' }

function New-Ease([string]$kind = 'Cubic', [string]$mode = 'EaseOut') {
  $e = New-Object "System.Windows.Media.Animation.${kind}Ease"
  $e.EasingMode = $mode
  return $e
}

function New-Anim([double]$from, [double]$to, [int]$ms, $ease) {
  $a = New-Object System.Windows.Media.Animation.DoubleAnimation $from, $to, ([TimeSpan]::FromMilliseconds($ms))
  if ($ease) { $a.EasingFunction = $ease }
  return $a
}

# Ring pair around the provider's mark: outer = weekly (or the billing cycle), inner = 5 hours.
function New-BarRing($u) {
  $size = 32; $t = 3
  $inner = $size - 2 * ($t + 2)
  $slots = Get-Slots $u
  $g = New-Object System.Windows.Controls.Grid
  $g.Width = $size; $g.Height = $size
  $key = 'bar|' + $(if ($u.key) { $u.key } else { $u.id })
  $both = $slots.short -and $slots.long
  $g.Children.Add((New-Track $size $t)) | Out-Null
  if ($both) { $g.Children.Add((New-Track $inner $t)) | Out-Null }
  if ($slots.long) {
    $lv = Level $slots.long.usedPct
    $g.Children.Add((New-Arc $size $t (Get-ArcPct $slots.long.usedPct) $(if ($lv) { $lv } else { $C.Muted }) "$key|long")) | Out-Null
  }
  if ($slots.short) {
    $lv = Level $slots.short.usedPct
    $g.Children.Add((New-Arc $(if ($both) { $inner } else { $size }) $t (Get-ArcPct $slots.short.usedPct) $(if ($lv) { $lv } else { $C.Text }) "$key|short")) | Out-Null
  }
  $accent = if ($Accents[$u.id]) { $Accents[$u.id] } else { $C.Muted }
  $mark = if (-not $slots.short -and -not $slots.long -and $u.error -and -not @($u.extras).Count) { New-Text '!' $C.Warn 11 'SemiBold' } else { New-Logo $u.id $accent 13 }
  $mark.HorizontalAlignment = 'Center'; $mark.VerticalAlignment = 'Center'
  $g.Children.Add($mark) | Out-Null
  $hot = @($slots.short, $slots.long) | Where-Object { $_ -and $_.usedPct -ge 80 } | Select-Object -First 1
  if ($hot) { Add-Glow $g $C.Error }
  return $g
}

# A limit at 80% or more breathes a soft glow in its warning color.
function Add-Glow($el, [string]$color, [double]$blur = 12) {
  $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
  $glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($color)
  $glow.ShadowDepth = 0
  $glow.BlurRadius = $blur
  $pulse = New-Anim 0.15 0.9 1100 (New-Ease 'Sine' 'EaseInOut')
  $pulse.AutoReverse = $true
  $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
  $glow.BeginAnimation([System.Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $pulse)
  $el.Effect = $glow
}

# A rounded track whose fill grows in from the left on first show, in a gradient of its color. Stretches unless given a Width.
function New-Fill([double]$used, [string]$color, [int]$index, [double]$height = 4) {
  $track = New-Object System.Windows.Controls.Grid
  $track.Height = $height
  $track.ClipToBounds = $false
  foreach ($w in 0, 1) { $track.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition)) }
  $pct = [math]::Max(0, [math]::Min(100, (Get-ArcPct $used)))
  $track.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength $pct, 'Star'
  $track.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength (100 - $pct), 'Star'
  $bg = New-Object System.Windows.Controls.Border
  $bg.CornerRadius = $height / 2
  $bg.Background = Brush $C.Track
  [System.Windows.Controls.Grid]::SetColumnSpan($bg, 2)
  $track.Children.Add($bg) | Out-Null
  if ($pct -le 0) { return $track }
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($color)
  $fade = [System.Windows.Media.Color]::FromArgb(140, $c.R, $c.G, $c.B)
  $fill = New-Object System.Windows.Controls.Border
  $fill.CornerRadius = $height / 2
  $fill.MinWidth = $height
  $fill.Background = New-Object System.Windows.Media.LinearGradientBrush $fade, $c, 0
  $fill.RenderTransformOrigin = '0,0.5'
  $grow = New-Object System.Windows.Media.ScaleTransform 1, 1
  $fill.RenderTransform = $grow
  # The fill spans its column; MinWidth keeps a sliver visible for tiny values.
  $fill.HorizontalAlignment = 'Stretch'
  $track.Children.Add($fill) | Out-Null
  if ($used -ge 80) { Add-Glow $fill $color 9 }
  if ($script:barIntro) {
    $g = New-Anim 0 1 750 (New-Ease 'Quartic' 'EaseOut')
    $g.BeginTime = [TimeSpan]::FromMilliseconds(120 + 70 * $index)
    $grow.ScaleX = 0
    $grow.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $g)
  }
  return $track
}

# First show of a layout: blocks fade in and rise one after the other.
function Add-Intro($el, [int]$index, [int]$step = 70, [switch]$Force) {
  if (-not $script:barIntro -and -not $Force) { return }
  $shift = New-Object System.Windows.Media.TranslateTransform 0, 10
  if ($el.RenderTransform -is [System.Windows.Media.TransformGroup]) { $el.RenderTransform.Children.Add($shift) } else { $el.RenderTransform = $shift }
  $delay = [TimeSpan]::FromMilliseconds($step * $index)
  $fade = New-Anim 0 $el.Opacity 380 (New-Ease)
  $fade.BeginTime = $delay
  $el.Opacity = 0
  $rise = New-Anim 10 0 460 (New-Ease 'Back' 'EaseOut')
  $rise.BeginTime = $delay
  $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
  $shift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $rise)
}

# Cards: the border lights up and the card lifts a little under the mouse.
function Add-Lift($card) {
  $card.RenderTransform = New-Object System.Windows.Media.TransformGroup
  $card.RenderTransform.Children.Add((New-Object System.Windows.Media.TranslateTransform 0, 0))
  $card.add_MouseEnter({
    param($s)
    $s.BorderBrush = Brush $C.Border
    $t = $s.RenderTransform.Children[0]
    $t.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-Anim $t.Y -2 180 (New-Ease 'Back' 'EaseOut')))
  })
  $card.add_MouseLeave({
    param($s)
    $s.BorderBrush = Brush $C.CardBorder
    $t = $s.RenderTransform.Children[0]
    $t.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (New-Anim $t.Y 0 260 (New-Ease)))
  })
}

# One limit as a slim meter: "5h ▬▬▬▬▬▭▭ 72%". The fill grows in from the left and glows when it runs hot.
function New-Meter($w, [string]$accent, [int]$index, [double]$len = 46) {
  $used = [double]$w.usedPct
  $lv = Level $used
  $color = if ($lv) { $lv } else { $accent }
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  # Kept to a few letters so the meters line up: "Credits" -> "cr", "Daily" -> "day".
  $label = switch -Regex (Get-SlotName $w) { '^Credit' { 'cr'; break } '^Daily' { 'day'; break } '^.{4,}' { $_.Substring(0, 3).ToLower(); break } default { $_ } }
  $name = New-Text $label $C.Muted 10
  $name.MinWidth = 16
  $name.VerticalAlignment = 'Center'
  $row.Children.Add($name) | Out-Null
  $track = New-Fill $used $color $index 5
  $track.Width = $len
  $track.VerticalAlignment = 'Center'
  $track.Margin = '3,0,5,0'
  $row.Children.Add($track) | Out-Null
  $num = New-Text ("{0}%" -f [math]::Round((Get-Shown $used))) $(if ($lv) { $lv } else { $C.Text }) 11 'SemiBold'
  $num.MinWidth = 27
  $num.VerticalAlignment = 'Center'
  $row.Children.Add($num) | Out-Null
  return $row
}

# Bars layout: the provider's mark, then a meter per limit (or the balance when that is all there is).
function New-MeterBlock($u, [int]$index) {
  $slots = Get-Slots $u
  $accent = if ($Accents[$u.id]) { $Accents[$u.id] } else { $C.Text }
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $badge = New-Object System.Windows.Controls.Border
  $badge.Width = 26; $badge.Height = 26
  $badge.CornerRadius = 13
  $badge.Background = Brush $C.Card
  $badge.VerticalAlignment = 'Center'
  $mark = New-Logo $u.id $accent 14
  $mark.HorizontalAlignment = 'Center'; $mark.VerticalAlignment = 'Center'
  $badge.Child = $mark
  $row.Children.Add($badge) | Out-Null
  $col = New-Object System.Windows.Controls.StackPanel
  $col.VerticalAlignment = 'Center'
  $col.Margin = '7,0,0,0'
  $meters = @(@($slots.short, $slots.long) | Where-Object { $_ })
  if ($meters.Count) {
    foreach ($w in $meters) { $col.Children.Add((New-Meter $w $accent $index)) | Out-Null }
    # A single limit leaves room for who it belongs to.
    if ($meters.Count -eq 1) {
      $who = Get-ShortAccount $u
      if (-not $who -and @($u.extras).Count) { $who = "$(@($u.extras)[0].value) $(([string]@($u.extras)[0].label).ToLower())" }
      if ($who) { $col.Children.Add((New-Text $who $C.Muted 10)) | Out-Null }
    }
  } elseif (@($u.extras).Count) {
    $x = @($u.extras)[0]
    $col.Children.Add((New-Text ([string]$x.value) $C.Text 12.5 'SemiBold')) | Out-Null
    $col.Children.Add((New-Text ([string]$x.label).ToLower() $C.Muted 10)) | Out-Null
  } else {
    $col.Children.Add((New-Text ([string]($u.name -replace ' \(.*\)$', '')) $C.Text 12 'SemiBold')) | Out-Null
    $col.Children.Add((New-Text $(if ($u.error) { 'error' } else { 'no data' }) $(if ($u.error) { $C.Warn } else { $C.Muted }) 10)) | Out-Null
  }
  $row.Children.Add($col) | Out-Null
  return $row
}

function New-BarChip($u, [int]$index) {
  $slots = Get-Slots $u
  $chip = New-Object System.Windows.Controls.Border
  $chip.CornerRadius = 17
  $chip.Padding = '3,3,10,3'
  $chip.Background = [System.Windows.Media.Brushes]::Transparent
  $chip.ToolTip = New-Tip $u
  [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($chip, 250)
  $chip.RenderTransformOrigin = '0.5,0.5'
  $tg = New-Object System.Windows.Media.TransformGroup
  $tg.Children.Add((New-Object System.Windows.Media.ScaleTransform 1, 1))
  $chip.RenderTransform = $tg

  if ($script:gauge -eq 'bar') {
    $chip.Padding = '3,3,6,3'
    $chip.Child = New-MeterBlock $u $index
    if ($u.error -and ($slots.short -or $slots.long)) { $chip.Opacity = 0.55 }
  } else {
  $row = New-Object System.Windows.Controls.StackPanel
  $row.Orientation = 'Horizontal'
  $row.Children.Add((New-BarRing $u)) | Out-Null
  $text = New-Object System.Windows.Controls.StackPanel
  $text.VerticalAlignment = 'Center'
  $text.Margin = '7,0,0,0'
  $main = if ($slots.short) { $slots.short } else { $slots.long }
  $other = if ($slots.short -and $slots.long) { $slots.long } else { $null }
  if ($main) {
    $lv = Level $main.usedPct
    $top = New-Object System.Windows.Controls.TextBlock
    $top.Inlines.Add((New-Object System.Windows.Documents.Run ("{0}%" -f [math]::Round((Get-Shown $main.usedPct))) -Property @{ Foreground = (Brush $(if ($lv) { $lv } else { $C.Text })); FontWeight = 'SemiBold'; FontSize = 13 }))
    $top.Inlines.Add((New-Object System.Windows.Documents.Run (' ' + (Get-SlotName $main)) -Property @{ Foreground = (Brush $C.Muted); FontSize = 10 }))
    $text.Children.Add($top) | Out-Null
    $sub = if ($other) { "$(Get-SlotName $other) $([math]::Round((Get-Shown $other.usedPct)))%" } else { Get-ShortAccount $u }
  } elseif (@($u.extras).Count) {
    # Only a balance to show (credits, say): the amount leads.
    $x = @($u.extras)[0]
    $text.Children.Add((New-Text ([string]$x.value) $C.Text 13 'SemiBold')) | Out-Null
    $sub = ([string]$x.label).ToLower()
  } else {
    $text.Children.Add((New-Text ([string]($u.name -replace ' \(.*\)$', '')) $C.Text 12 'SemiBold')) | Out-Null
    $sub = 'no data'
  }
  if ($sub) {
    $lv = if ($other) { Level $other.usedPct } else { $null }
    $s2 = New-Text $sub $(if ($lv) { $lv } else { $C.Muted }) 10
    $s2.Margin = '0,-1,0,0'
    $text.Children.Add($s2) | Out-Null
  }
  $row.Children.Add($text) | Out-Null
  $chip.Child = $row
  # Numbers kept from a failed refresh fade back a little.
  if ($u.error -and ($slots.short -or $slots.long)) { $chip.Opacity = 0.55 }
  }

  # Hover: the chip lifts a bit and lights up.
  $chip.add_MouseEnter({
    param($s)
    $s.Background = Brush $C.Hover
    $sc = $s.RenderTransform.Children[0]
    foreach ($p in [System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty) {
      $sc.BeginAnimation($p, (New-Anim $sc.ScaleX 1.06 160 (New-Ease 'Back' 'EaseOut')))
    }
  })
  $chip.add_MouseLeave({
    param($s)
    $s.Background = [System.Windows.Media.Brushes]::Transparent
    $sc = $s.RenderTransform.Children[0]
    foreach ($p in [System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty) {
      $sc.BeginAnimation($p, (New-Anim $sc.ScaleX 1 200 (New-Ease)))
    }
  })
  # First show: the chips rise in one after the other.
  Add-Intro $chip $index
  return $chip
}

function Render-Bar {
  $ui.BarChips.Children.Clear()
  $i = 0
  $prev = $null
  foreach ($u in $script:shown) {
    # A hairline between providers; accounts of the same provider sit together.
    if ($null -ne $prev -and $prev -ne $u.id) {
      $sep = New-Object System.Windows.Controls.Border
      $sep.Width = 1; $sep.Height = 20
      $sep.Margin = '3,0,3,0'
      $sep.Background = Brush $C.Divider
      $ui.BarChips.Children.Add($sep) | Out-Null
    }
    $ui.BarChips.Children.Add((New-BarChip $u $i)) | Out-Null
    $prev = $u.id
    $i++
  }
  if (-not $i) {
    $msg = if ($script:proc -or $script:detectProc) { 'Loading...' } else { 'No data' }
    $t = New-Text $msg $C.Muted 12
    $t.Margin = '4,0,8,0'
    $ui.BarChips.Children.Add($t) | Out-Null
  }
  $ui.BarGrip.ToolTip = if ($script:lastError) { "OpenUsage - $($script:lastError)" } elseif ($script:updatedAt) { "OpenUsage - $(Format-Ago $script:updatedAt)" } else { 'OpenUsage' }
}

# While a refresh runs, a soft light sweeps across the widget and the refresh arrows turn.
function Set-Shimmer([bool]$on) {
  if ($on -eq $script:shimmerOn) { return }
  $script:shimmerOn = $on
  $layers = $ui.Shimmer, $ui.FrameShimmer
  $spins = $ui.BarRefresh.RenderTransform, $ui.RefreshBtn.RenderTransform
  if (-not $on) {
    foreach ($l in $layers) { $l.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim $l.Opacity 0 300 (New-Ease))) }
    foreach ($sp in $spins) { $sp.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null); $sp.Angle = 0 }
    return
  }
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($C.Text)
  $clear = [System.Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B)
  $glow = [System.Windows.Media.Color]::FromArgb($(if ($light) { 22 } else { 30 }), $c.R, $c.G, $c.B)
  foreach ($l in $layers) {
    $brush = New-Object System.Windows.Media.LinearGradientBrush
    # The tall panel gets a diagonal sweep, the strip a horizontal one.
    $brush.StartPoint = if ($l -eq $ui.FrameShimmer) { '0,0' } else { '0,0.5' }
    $brush.EndPoint = if ($l -eq $ui.FrameShimmer) { '1,1' } else { '1,0.5' }
    foreach ($stop in @(@($clear, 0.35), @($glow, 0.5), @($clear, 0.65))) {
      $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop $stop[0], $stop[1]))
    }
    $move = New-Object System.Windows.Media.TranslateTransform
    $brush.RelativeTransform = $move
    $l.Background = $brush
    $sweep = New-Anim -0.7 0.7 1300 (New-Ease 'Sine' 'EaseInOut')
    $sweep.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $move.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $sweep)
    $move.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $(if ($l -eq $ui.FrameShimmer) { $sweep } else { $null }))
    $l.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim 0 1 250 $null))
  }
  foreach ($sp in $spins) {
    $turn = New-Anim 0 360 900 $null
    $turn.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $sp.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $turn)
  }
}

# Bar: the window follows its content's width. Others: the usual 320-wide panel.
function Set-LayoutFrame {
  $bar = Test-Strip
  $ui.BarFrame.Visibility = if ($bar) { 'Visible' } else { 'Collapsed' }
  $ui.Frame.Visibility = if ($bar) { 'Collapsed' } else { 'Visible' }
  $script:barIntro = $true
  if ($bar) {
    $win.SizeToContent = 'WidthAndHeight'
  } else {
    $win.SizeToContent = 'Height'
    $win.Width = 320
  }
}

function Start-Refresh {
  # While the providers are being detected the switches aren't settled yet; detection refreshes when done.
  if ($script:proc -or $script:detectProc) { return }
  $ids = @($ProviderNames.Keys | Where-Object { $script:hiddenProviders -notcontains $_ })
  # Nothing switched on: no ids would mean "whatever is set up" to the script, so don't ask at all.
  if (-not $ids.Count) { $script:data = @(); Render; return }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node'
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

# Asks which providers are set up on this PC (local files only, no network), then refreshes.
function Start-Detect {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node'
  $psi.Arguments = '--experimental-strip-types --no-warnings "' + (Join-Path $Root 'scripts\usage-json.ts') + '" --detect'
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  try {
    $script:detectProc = [System.Diagnostics.Process]::Start($psi)
    $script:detectOut = $script:detectProc.StandardOutput.ReadToEndAsync()
  } catch {
    $script:detectProc = $null
    Start-Refresh
  }
}

function Complete-Detect {
  $p = $script:detectProc
  if (-not $p -or -not $p.HasExited) { return }
  $script:detectProc = $null
  try {
    # A run that failed (or printed nothing) found nothing out: leave the switches as they are.
    if ($p.ExitCode -ne 0 -or -not $script:detectOut.Result.Trim()) { throw 'detect failed' }
    $found = @($script:detectOut.Result | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ })
    $all = @($ProviderNames.Keys)
    if ($null -eq $script:seenProviders) {
      $script:hiddenProviders = @($all | Where-Object { $found -notcontains $_ })
      $script:seenProviders = $found
    } else {
      $new = @($found | Where-Object { $script:seenProviders -notcontains $_ })
      $unknown = @($all | Where-Object { $script:knownProviders -notcontains $_ -and $found -notcontains $_ })
      $script:hiddenProviders = @(@($script:hiddenProviders | Where-Object { $new -notcontains $_ }) + $unknown | Select-Object -Unique)
      $script:seenProviders = @($script:seenProviders) + $new
    }
    $script:knownProviders = $all
    Set-State @{ hiddenProviders = $script:hiddenProviders; seenProviders = $script:seenProviders; knownProviders = $script:knownProviders }
  } catch {}
  if ($script:proc) { $script:refreshPending = $true } else { Start-Refresh }
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
    # No output or a failed run (a script that doesn't load, say) is a failed refresh, not "no providers":
    # keep the numbers on screen and in the cache.
    if ($p.ExitCode -ne 0 -or -not $script:outTask.Result.Trim()) { throw 'usage script failed' }
    $fresh = @($script:outTask.Result | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ })
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
      <Setter Property="MinWidth" Value="78"/>
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="6" Padding="{TemplateBinding Padding}" MinWidth="{TemplateBinding MinWidth}">
              <Border.Background><SolidColorBrush Color="$($C.Text)" Opacity="0"/></Border.Background>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="$($C.Text)"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Opacity)" To="1" Duration="0:0:0.22"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="b" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Opacity)" To="0" Duration="0:0:0.18"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
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
            <Border x:Name="track" Width="34" Height="18" CornerRadius="9">
              <Border.Background><SolidColorBrush Color="$($C.Track)"/></Border.Background>
              <Ellipse x:Name="thumb" Width="12" Height="12" Margin="3,0" HorizontalAlignment="Left">
                <Ellipse.Fill><SolidColorBrush Color="$($C.Muted)"/></Ellipse.Fill>
                <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
              </Ellipse>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="thumb" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="16" Duration="0:0:0.28">
                    <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.4"/></DoubleAnimation.EasingFunction>
                  </DoubleAnimation>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="$($C.Text)" Duration="0:0:0.22"/>
                  <ColorAnimation Storyboard.TargetName="thumb" Storyboard.TargetProperty="(Shape.Fill).(SolidColorBrush.Color)" To="$($C.Bg)" Duration="0:0:0.22"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="thumb" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="0:0:0.28">
                    <DoubleAnimation.EasingFunction><BackEase EasingMode="EaseOut" Amplitude="0.4"/></DoubleAnimation.EasingFunction>
                  </DoubleAnimation>
                  <ColorAnimation Storyboard.TargetName="track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="$($C.Track)" Duration="0:0:0.22"/>
                  <ColorAnimation Storyboard.TargetName="thumb" Storyboard.TargetProperty="(Shape.Fill).(SolidColorBrush.Color)" To="$($C.Muted)" Duration="0:0:0.22"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
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
  <Border x:Name="Root" Margin="12" Background="$($C.Bg)" BorderBrush="$($C.Border)" BorderThickness="1" CornerRadius="12" Padding="18,14,18,16"
          RenderTransformOrigin="0.5,0.3">
    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Opacity="0.4"/></Border.Effect>
    <StackPanel x:Name="Content">
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
  foreach ($n in @('Header', 'CloseX', 'Root', 'Content') + $names) { $d[$n] = $dlg.FindName($n) }
  # Opening: the dialog pops in, then its rows arrive one after the other.
  $d.Root.RenderTransform = New-Object System.Windows.Media.ScaleTransform 0.94, 0.94
  $d.Root.Opacity = 0
  $dlg.add_Loaded({
    param($s)
    $root = $s.FindName('Root')
    $root.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim 0 1 200 (New-Ease)))
    foreach ($p in [System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty) {
      $root.RenderTransform.BeginAnimation($p, (New-Anim 0.94 1 320 (New-Ease 'Back' 'EaseOut')))
    }
    $i = 0
    foreach ($el in @($s.FindName('Content').Children)) {
      if ($i) { Add-Intro $el ([math]::Min($i, 16)) 22 -Force }
      $i++
    }
  })
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
  $heading = "$(Get-LogoXaml $kind $Accents[$kind] 15)  Add $($k.Name) account"
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
  $mi.Header = "$($AccountKinds[$kind].Name) account"
  $mi.Icon = New-Logo $kind $Accents[$kind] 14
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

# ---- API keys -----------------------------------------------------------------
# OpenRouter and Z.ai have no CLI login: scripts\keys.ts finds the key the other tools on this PC already use, or
# keeps one pasted in Settings once the service has accepted it. The key reaches node in an environment variable,
# never on a command line. Same script as on macOS and Linux.
$KeyedProviders = @('openrouter', 'zai')
$script:keys = @{}
$script:keysProc = $null

# Runs scripts\keys.ts; $onDone gets the error text ('' when none) once it is back. $false only when one is still running.
function Start-Keys([string[]]$arguments, [string]$key, [scriptblock]$onDone) {
  if ($script:keysProc) { return $false }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'node'
  $psi.Arguments = '--experimental-strip-types --no-warnings "' + (Join-Path $Root 'scripts\keys.ts') + '" ' + ($arguments -join ' ')
  $psi.WorkingDirectory = $Root
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  if ($key) { $psi.EnvironmentVariables['OPENUSAGE_KEY'] = $key }
  try {
    $script:keysProc = [System.Diagnostics.Process]::Start($psi)
    $script:keysOut = $script:keysProc.StandardOutput.ReadToEndAsync()
    $script:keysDone = $onDone
    return $true
  } catch {
    if ($onDone) { & $onDone 'node not found' }
    return $true
  }
}

function Complete-Keys {
  $p = $script:keysProc
  if (-not $p -or -not $p.HasExited) { return }
  $script:keysProc = $null
  $err = ''
  try {
    $r = $script:keysOut.Result | ConvertFrom-Json
    foreach ($k in @($r.keys)) { $script:keys[[string]$k.id] = $k }
    $err = [string]$r.error
  } catch {
    $err = "couldn't read the keys"
  }
  # The callback belongs to a dialog; one closed meanwhile has cleared it. Never let it take the widget down.
  $done = $script:keysDone
  $script:keysDone = $null
  if ($done) { try { & $done $err } catch {} }
}

# "No key yet", "Saved here", "Found in OpenCode", "From OPENROUTER_API_KEY".
function Get-KeyStatus([string]$id) {
  $k = $script:keys[$id]
  if (-not $k) { return 'Looking for a key...' }
  if (-not $k.source) { return 'No key yet' }
  if ($k.saved) { return 'Saved here' }
  if ($k.source -match '^[A-Z0-9_]+$' -or $k.source -match '[\\/]') { return "From $($k.source)" }
  return "Found in $($k.source)"
}

# Asks for the key, checks it with the service and keeps it; $true once saved.
# Its handlers run while the settings dialog is open, which names its own $d / $dlg: hence $kd / $kdlg here.
function Show-KeyDialog([string]$id) {
  $name = $ProviderNames[$id]
  $url = if ($script:keys[$id]) { [string]$script:keys[$id].url } else { '' }
  $site = $url -replace '^https?://', '' -replace '/$', ''
  $body = @"
      <TextBlock Foreground="$($C.Muted)" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,8">
        $name has no app sign-in to read, so it needs an API key.$(if ($site) { " Create one at <Hyperlink x:Name=`"KeyLink`" Foreground=`"$($C.Text)`">$site</Hyperlink>." })
      </TextBlock>
      <Border x:Name="Field" Background="$($C.Card)" BorderBrush="$($C.CardBorder)" BorderThickness="1" CornerRadius="7" Padding="8,6">
        <PasswordBox x:Name="KeyBox" Background="Transparent" BorderThickness="0" Foreground="$($C.Text)" CaretBrush="$($C.Text)"
                     SelectionBrush="$($C.Muted)" FontFamily="Cascadia Mono, Consolas" FontSize="13.5" VerticalContentAlignment="Center"/>
      </Border>
      <TextBlock x:Name="Info" FontSize="11.5" TextWrapping="Wrap" Margin="2,7,0,0" Foreground="$($C.Muted)">Kept on this PC only, and sent to $name alone.</TextBlock>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="CancelBtn" Style="{StaticResource Btn}" IsCancel="True" Margin="0,0,8,0">Cancel</Button>
        <Button x:Name="OkBtn" Style="{StaticResource Primary}" IsDefault="True" IsEnabled="False">Save</Button>
      </StackPanel>
"@
  $heading = "$(Get-LogoXaml $id $Accents[$id] 15)  $name API key"
  $kd = New-Dialog (New-DialogXaml "$name API key" $heading $body) @('Field', 'KeyBox', 'Info', 'CancelBtn', 'OkBtn', 'KeyLink')
  $kdlg = $kd.Window
  if ($kd.KeyLink) { $kd.KeyLink.add_Click({ Start-Process $url }) }
  $kd.KeyBox.add_PasswordChanged({ $kd.OkBtn.IsEnabled = [bool]$kd.KeyBox.Password.Trim() -and -not $script:keysProc })
  $kd.OkBtn.add_Click({
    $kd.OkBtn.IsEnabled = $false
    $kd.KeyBox.IsEnabled = $false
    $kd.Info.Text = "Checking the key with $name..."
    $kd.Info.Foreground = Brush $C.Muted
    $done = {
      param($err)
      if (-not $err) { $kdlg.DialogResult = $true; return }
      $kd.Info.Text = $err
      $kd.Info.Foreground = Brush $C.Error
      $kd.Field.BorderBrush = Brush $C.Error
      $kd.KeyBox.IsEnabled = $true
      $kd.OkBtn.IsEnabled = $true
      $kd.KeyBox.Focus() | Out-Null
    }
    if (-not (Start-Keys @('set', $id) $kd.KeyBox.Password.Trim() $done)) { & $done 'Busy, try again in a moment.' }
  })
  $kdlg.add_ContentRendered({ $kd.KeyBox.Focus() | Out-Null })
  $saved = [bool]$kdlg.ShowDialog()
  # Closed while the key was being checked: the answer has no dialog left to go to.
  $script:keysDone = $null
  return $saved
}

# ---- settings -----------------------------------------------------------------
function Get-SwitchName([string]$id) { 'Prov_' + ($id -replace '\W', '_') }

function Show-Settings {
  $iconUri = (Join-Path $Root 'docs\icon.png') -replace '&', '&amp;'
  # Two columns, so the list stays short with every provider in it.
  $col = 0
  $providerRows = foreach ($id in $ProviderNames.Keys) {
    $margin = if ($col++ % 2) { '10,0,0,8' } else { '0,0,10,8' }
    @"
      <DockPanel Margin="$margin">
        <CheckBox x:Name="$(Get-SwitchName $id)" DockPanel.Dock="Right" Style="{StaticResource Switch}" Tag="$id" AutomationProperties.Name="Show $($ProviderNames[$id])" VerticalAlignment="Center"/>
        <TextBlock VerticalAlignment="Center">$(Get-LogoXaml $id $Accents[$id] 14)  $($ProviderNames[$id])</TextBlock>
      </DockPanel>
"@
  }
  $keyRows = foreach ($id in $KeyedProviders) {
    @"
      <DockPanel Margin="0,0,0,10">
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="KeyDel_$id" Style="{StaticResource Btn}" Margin="0,0,6,0" Visibility="Collapsed">Remove</Button>
          <Button x:Name="KeyBtn_$id" Style="{StaticResource Btn}" MinWidth="86">Add key</Button>
        </StackPanel>
        <StackPanel VerticalAlignment="Center">
          <TextBlock>$(Get-LogoXaml $id $Accents[$id] 14)  $($ProviderNames[$id])</TextBlock>
          <TextBlock x:Name="KeyInfo_$id" Foreground="$($C.Muted)" FontSize="11"/>
        </StackPanel>
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
      <DockPanel Margin="0,0,0,6">
        <TextBlock x:Name="LayoutNote" DockPanel.Dock="Right" VerticalAlignment="Bottom" Foreground="$($C.Muted)" FontSize="11"/>
        <TextBlock Text="Layout"/>
      </DockPanel>
      <Border Style="{StaticResource SegBox}" Margin="0,0,0,10">
        <UniformGrid Rows="1">
          <RadioButton x:Name="NormalOpt" GroupName="layout" Style="{StaticResource Seg}" MinWidth="0" Padding="6,4">Normal</RadioButton>
          <RadioButton x:Name="CompactOpt" GroupName="layout" Style="{StaticResource Seg}" MinWidth="0" Padding="6,4">Compact</RadioButton>
          <RadioButton x:Name="BarOpt" GroupName="layout" Style="{StaticResource Seg}" MinWidth="0" Padding="6,4">Strip</RadioButton>
        </UniformGrid>
      </Border>
      <DockPanel>
        <Border DockPanel.Dock="Right" Style="{StaticResource SegBox}">
          <StackPanel Orientation="Horizontal">
            <RadioButton x:Name="RingOpt" GroupName="gauge" Style="{StaticResource Seg}">Rings</RadioButton>
            <RadioButton x:Name="MeterOpt" GroupName="gauge" Style="{StaticResource Seg}">Bars</RadioButton>
          </StackPanel>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="Gauges"/>
          <TextBlock x:Name="GaugeNote" Foreground="$($C.Muted)" FontSize="11"/>
        </StackPanel>
      </DockPanel>
      <Border Height="1" Background="$($C.Divider)" Margin="0,16,0,14"/>
      <TextBlock Style="{StaticResource Caption}" Text="PROVIDERS"/>
      <UniformGrid Columns="2">
$($providerRows -join "`n")
      </UniformGrid>
      <Border Height="1" Background="$($C.Divider)" Margin="0,8,0,14"/>
      <TextBlock Style="{StaticResource Caption}" Text="API KEYS"/>
      <TextBlock Foreground="$($C.Muted)" FontSize="11.5" TextWrapping="Wrap" Margin="0,0,0,10">Found by itself when OpenCode, Kilo, Crush or Claude Code already use one; otherwise add it here.</TextBlock>
$($keyRows -join "`n")
      <Border Height="1" Background="$($C.Divider)" Margin="0,4,0,14"/>
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
    'UsedOpt', 'LeftOpt', 'NormalOpt', 'CompactOpt', 'BarOpt', 'RingOpt', 'MeterOpt', 'GaugeNote', 'LayoutNote', 'VersionText', 'StatusDot', 'StatusText', 'CheckBtn', 'UpdateBtn')
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

  # API keys: what was found, and buttons to add, change or remove the one pasted here.
  $syncKeys = {
    foreach ($id in $KeyedProviders) {
      $k = $script:keys[$id]
      $dlg.FindName("KeyInfo_$id").Text = Get-KeyStatus $id
      $dlg.FindName("KeyBtn_$id").Content = if ($k -and $k.source) { 'Change' } else { 'Add key' }
      $dlg.FindName("KeyBtn_$id").IsEnabled = [bool]$k
      $dlg.FindName("KeyDel_$id").Visibility = if ($k -and $k.saved) { 'Visible' } else { 'Collapsed' }
    }
  }
  # A key saved or removed turns its provider on or off, and fetches again.
  $setShown = {
    param([string]$id, [bool]$on)
    $sw = $dlg.FindName((Get-SwitchName $id))
    if ($on -and $script:seenProviders -notcontains $id) { $script:seenProviders = @($script:seenProviders) + $id; Set-State @{ seenProviders = $script:seenProviders } }
    if ($sw.IsChecked -ne $on) { $sw.IsChecked = $on } elseif ($script:proc) { $script:refreshPending = $true } else { Start-Refresh }
  }
  $askKey = {
    param([string]$id)
    if (Show-KeyDialog $id) { & $syncKeys; & $setShown $id $true }
  }
  foreach ($id in $KeyedProviders) {
    $dlg.FindName("KeyBtn_$id").Tag = $id
    $dlg.FindName("KeyBtn_$id").add_Click({ param($s) & $askKey ([string]$s.Tag) })
    $dlg.FindName("KeyDel_$id").Tag = $id
    $dlg.FindName("KeyDel_$id").add_Click({
      param($s)
      $script:keyRemoving = [string]$s.Tag
      $null = Start-Keys @('remove', $script:keyRemoving) '' {
        param($err)
        & $syncKeys
        # No other key on the PC: nothing left to show.
        if (-not $script:keys[$script:keyRemoving].source) { & $setShown $script:keyRemoving $false }
      }
    })
  }
  # Switching on a provider that needs a key it doesn't have asks for one.
  foreach ($id in $KeyedProviders) {
    $dlg.FindName((Get-SwitchName $id)).add_Checked({
      param($s)
      $k = $script:keys[[string]$s.Tag]
      if ($k -and -not $k.source) {
        & $askKey ([string]$s.Tag)
        # Cancelled: without a key it would only show an error.
        if (-not $script:keys[[string]$s.Tag].source) { $s.IsChecked = $false }
      }
    })
  }
  & $syncKeys
  $null = Start-Keys @() '' { param($err) & $syncKeys }

  $d.UsedOpt.IsChecked = $script:display -eq 'used'
  $d.LeftOpt.IsChecked = $script:display -ne 'used'
  $d.NormalOpt.IsChecked = $script:layout -eq 'normal'
  $d.CompactOpt.IsChecked = $script:layout -eq 'compact'
  $d.BarOpt.IsChecked = $script:layout -eq 'bar'
  $d.RingOpt.IsChecked = $script:gauge -ne 'bar'
  $d.MeterOpt.IsChecked = $script:gauge -eq 'bar'
  # Changes apply to the widget right away.
  $setDisplay = { $script:display = if ($d.UsedOpt.IsChecked) { 'used' } else { 'remaining' }; Set-State @{ display = $script:display }; Render }
  $notes = @{ normal = 'A card per account'; compact = 'A line per account'; bar = 'One slim strip' }
  $d.LayoutNote.Text = $notes[$script:layout]
  $setLayout = {
    $script:layout = if ($d.BarOpt.IsChecked) { 'bar' } elseif ($d.CompactOpt.IsChecked) { 'compact' } else { 'normal' }
    $d.LayoutNote.Text = $notes[$script:layout]
    Set-State @{ layout = $script:layout }
    Set-LayoutFrame
    & $syncGauge
    Render
  }
  # The full layout keeps its rings and bars; the choice is for the compact ones.
  $syncGauge = {
    $d.GaugeNote.Text = if ($script:layout -eq 'normal') { 'For Compact and Strip' } elseif ($script:gauge -eq 'bar') { 'Slim meters' } else { 'Rings around the numbers' }
  }
  & $syncGauge
  $setGauge = {
    $script:gauge = if ($d.MeterOpt.IsChecked) { 'bar' } else { 'ring' }
    Set-State @{ gauge = $script:gauge }
    $script:barIntro = $true
    & $syncGauge
    Render
  }
  $d.RingOpt.add_Checked($setGauge); $d.MeterOpt.add_Checked($setGauge)
  $d.UsedOpt.add_Checked($setDisplay); $d.LeftOpt.add_Checked($setDisplay)
  $d.NormalOpt.add_Checked($setLayout); $d.CompactOpt.add_Checked($setLayout); $d.BarOpt.add_Checked($setLayout)

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
  $script:keysDone = $null
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
# Minimizing folds the body up under the header (and restoring unfolds it) instead of snapping.
function Set-Minimized([bool]$on, [switch]$Instant) {
  $script:minimized = $on
  $ui.MinBtn.Content = if ($on) { [string][char]0x25A1 } else { [string][char]0x2013 }
  $ui.MinBtn.ToolTip = if ($on) { 'Restore' } else { 'Minimize' }
  Set-State @{ minimized = $on }
  $body = $ui.Body
  $hp = [System.Windows.FrameworkElement]::HeightProperty
  $op = [System.Windows.UIElement]::OpacityProperty
  if ($Instant -or -not $win.IsVisible) {
    $body.BeginAnimation($hp, $null); $body.BeginAnimation($op, $null)
    $body.Height = [double]::NaN; $body.Opacity = 1
    $body.Visibility = if ($on) { 'Collapsed' } else { 'Visible' }
    return
  }
  if ($on) {
    $fold = New-Anim $body.ActualHeight 0 260 (New-Ease 'Cubic' 'EaseInOut')
    $fold.add_Completed({
      if ($script:minimized) {
        $ui.Body.Visibility = 'Collapsed'
        $ui.Body.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
        $ui.Body.Height = [double]::NaN
      }
    })
    $body.BeginAnimation($op, (New-Anim $body.Opacity 0 180 (New-Ease)))
    $body.BeginAnimation($hp, $fold)
  } else {
    # The height it will need: measured at the panel's width, then unfolded up to it.
    $from = if ($body.Visibility -eq 'Visible') { $body.ActualHeight } else { 0 }
    $body.BeginAnimation($hp, $null)
    $body.Height = [double]::NaN
    $body.Visibility = 'Visible'
    $body.Measure((New-Object System.Windows.Size $ui.Header.ActualWidth, ([double]::PositiveInfinity)))
    $unfold = New-Anim $from $body.DesiredSize.Height 340 (New-Ease 'Back' 'EaseOut')
    $unfold.EasingFunction.Amplitude = 0.25
    $unfold.add_Completed({
      if (-not $script:minimized) {
        $ui.Body.BeginAnimation([System.Windows.FrameworkElement]::HeightProperty, $null)
        $ui.Body.Height = [double]::NaN
      }
    })
    $body.BeginAnimation($hp, $unfold)
    $fade = New-Anim 0 1 260 (New-Ease)
    $fade.BeginTime = [TimeSpan]::FromMilliseconds(80)
    $body.Opacity = 0
    $body.BeginAnimation($op, $fade)
  }
}

# Opening: the widget fades in and settles from a little smaller. Closing: it shrinks a touch as it fades out.
$win.Content.RenderTransformOrigin = '0.5,0.2'
$win.Content.RenderTransform = New-Object System.Windows.Media.ScaleTransform 1, 1
function Show-Widget {
  $script:hiding = $false
  $sc = $win.Content.RenderTransform
  $win.Opacity = 0
  $win.Show()
  $win.BeginAnimation([System.Windows.Window]::OpacityProperty, (New-Anim 0 1 220 (New-Ease)))
  foreach ($p in [System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty) {
    $sc.BeginAnimation($p, (New-Anim 0.92 1 380 (New-Ease 'Back' 'EaseOut')))
  }
}
function Hide-Widget {
  if ($script:hiding) { return }
  $script:hiding = $true
  $sc = $win.Content.RenderTransform
  $out = New-Anim $win.Opacity 0 170 (New-Ease 'Cubic' 'EaseIn')
  $out.add_Completed({
    if ($script:hiding) {
      $script:hiding = $false
      $win.Hide()
      $win.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
      $win.Opacity = 1
    }
  })
  foreach ($p in [System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty) {
    $sc.BeginAnimation($p, (New-Anim 1 0.94 170 (New-Ease 'Cubic' 'EaseIn')))
  }
  $win.BeginAnimation([System.Windows.Window]::OpacityProperty, $out)
}
function Toggle-Window {
  if ($win.IsVisible -and -not $script:hiding) { Hide-Widget; Set-State @{ hidden = $true } }
  else { Show-Widget; Set-State @{ hidden = $false } }
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
$ui.Header.add_MouseLeftButtonDown({ $win.DragMove(); Save-Position })
# The bar drags from anywhere but its buttons, and its menu is the tray's.
$ui.BarFrame.add_MouseLeftButtonDown({ $win.DragMove(); Save-Position })
$ui.BarFrame.add_MouseRightButtonUp({ $menu.Show([System.Windows.Forms.Cursor]::Position) })
$ui.BarRefresh.add_Click({ Start-Refresh })
$ui.BarGear.add_Click({ Show-Settings })
$ui.BarFrame.add_MouseEnter({ $ui.BarTools.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim $ui.BarTools.Opacity 1 180 (New-Ease))) })
$ui.BarFrame.add_MouseLeave({ $ui.BarTools.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim $ui.BarTools.Opacity 0.35 400 (New-Ease))) })
# When the bar grows or shrinks, the edge nearer the screen's side stays put, so a bar docked right grows leftwards.
# Whether a window this wide, at the current Left, sits on the right half of its monitor.
function Test-RightHalf([double]$width) {
  $scr = [System.Windows.Forms.Screen]::FromHandle((New-Object System.Windows.Interop.WindowInteropHelper $win).Handle).WorkingArea
  $toPx = [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11
  return ($win.Left + $width / 2) * $toPx -gt $scr.Left + $scr.Width / 2
}
# On the right half of the screen the widget keeps its right edge where it was put: the strip grows leftward as
# accounts arrive, and switching layouts doesn't push it off the screen. Elsewhere it keeps its left edge.
$script:anchorRight = if ($null -ne $state.right) { [double]$state.right } else { $null }
function Save-Position {
  $script:anchorRight = if (Test-RightHalf $win.ActualWidth) { $win.Left + $win.ActualWidth } else { $null }
  Set-State @{ x = $win.Left; y = $win.Top; right = $script:anchorRight }
}
$win.add_SizeChanged({
  param($s, $e)
  if (-not $e.WidthChanged -or $null -eq $script:anchorRight) { return }
  $win.Left = $script:anchorRight - $e.NewSize.Width
  Set-State @{ x = $win.Left }
})
# Saved by an older version without the right edge: work it out once shown.
if ($null -eq $state.right -and $null -ne $state.x) { $win.add_ContentRendered({ if ($null -eq $script:anchorRight) { Save-Position } }) }
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
  Complete-Detect
  Complete-Refresh
  Complete-Logins
  Complete-Update
  Complete-Keys
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
Set-Minimized ([bool]$state.minimized) -Instant
Set-LayoutFrame
Show-Widget
Set-State @{ hidden = $false }
# Every start looks again for tools installed since; the refresh follows.
Start-Detect
Render
Start-Update 'check'
[System.Windows.Threading.Dispatcher]::Run()
$mutex.ReleaseMutex()
