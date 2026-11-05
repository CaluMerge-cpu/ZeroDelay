# ZeroDelay redesign, stage 1: design tokens and the three core components (Primary button, TweakCard, MetricTile).
# For review. Once approved, this moves into ZeroDelay.ps1 as-is (here-strings + functions, no external files).
# Pure XAML + PowerShell 5.1, no dependencies. Everything uses DynamicResource, so theme and accent change live.

# ---------------------------------------------------------------------------------------------------------- tokens ---
# Same keys in both themes. Values checked for 4.5:1 text contrast (see design\DESIGN.md).
$ZdThemeDark = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                    xmlns:sys="clr-namespace:System;assembly=mscorlib">
  <SolidColorBrush x:Key="Bg.Base"        Color="#07080A"/>
  <SolidColorBrush x:Key="Bg.Surface"     Color="#0E1013"/>
  <SolidColorBrush x:Key="Bg.Raised"      Color="#15181D"/>
  <SolidColorBrush x:Key="Border.Subtle"  Color="#1F242B"/>
  <SolidColorBrush x:Key="Border.Strong"  Color="#2B323B"/>
  <SolidColorBrush x:Key="Text.Primary"   Color="#F2F4F7"/>
  <SolidColorBrush x:Key="Text.Secondary" Color="#9AA3AF"/>
  <SolidColorBrush x:Key="Text.Muted"     Color="#7A8390"/>
  <SolidColorBrush x:Key="Good"           Color="#3DDC84"/>
  <SolidColorBrush x:Key="Warn"           Color="#F5B83D"/>
  <SolidColorBrush x:Key="Bad"            Color="#FF5C5C"/>
  <SolidColorBrush x:Key="Info"           Color="#6CA8FF"/>
  <SolidColorBrush x:Key="Good.Soft"      Color="#1F3DDC84"/>
  <SolidColorBrush x:Key="Warn.Soft"      Color="#1FF5B83D"/>
  <SolidColorBrush x:Key="Bad.Soft"       Color="#1FFF5C5C"/>
  <SolidColorBrush x:Key="Info.Soft"      Color="#1F6CA8FF"/>
  <SolidColorBrush x:Key="State.Hover"    Color="#1AFFFFFF"/>
  <SolidColorBrush x:Key="State.Press"    Color="#26000000"/>
  <SolidColorBrush x:Key="Switch.Knob"    Color="#F2F4F7"/>
</ResourceDictionary>
'@
$ZdThemeLight = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                    xmlns:sys="clr-namespace:System;assembly=mscorlib">
  <SolidColorBrush x:Key="Bg.Base"        Color="#F6F7F9"/>
  <SolidColorBrush x:Key="Bg.Surface"     Color="#FFFFFF"/>
  <SolidColorBrush x:Key="Bg.Raised"      Color="#F0F2F5"/>
  <SolidColorBrush x:Key="Border.Subtle"  Color="#E3E6EA"/>
  <SolidColorBrush x:Key="Border.Strong"  Color="#CDD2D9"/>
  <SolidColorBrush x:Key="Text.Primary"   Color="#0B0D10"/>
  <SolidColorBrush x:Key="Text.Secondary" Color="#5A6472"/>
  <SolidColorBrush x:Key="Text.Muted"     Color="#626B77"/>
  <SolidColorBrush x:Key="Good"           Color="#157A43"/>
  <SolidColorBrush x:Key="Warn"           Color="#8A5E06"/>
  <SolidColorBrush x:Key="Bad"            Color="#C81E1E"/>
  <SolidColorBrush x:Key="Info"           Color="#1D63D6"/>
  <SolidColorBrush x:Key="Good.Soft"      Color="#1A157A43"/>
  <SolidColorBrush x:Key="Warn.Soft"      Color="#1A8A5E06"/>
  <SolidColorBrush x:Key="Bad.Soft"       Color="#1AC81E1E"/>
  <SolidColorBrush x:Key="Info.Soft"      Color="#1A1D63D6"/>
  <SolidColorBrush x:Key="State.Hover"    Color="#1AFFFFFF"/>
  <SolidColorBrush x:Key="State.Press"    Color="#1F000000"/>
  <SolidColorBrush x:Key="Switch.Knob"    Color="#FFFFFF"/>
</ResourceDictionary>
'@
# Theme-independent: type, spacing, radii. {MotionFast} is replaced at load (0 when Windows animations are off).
$ZdTokensShared = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                    xmlns:sys="clr-namespace:System;assembly=mscorlib">
  <FontFamily x:Key="Font.UI">Segoe UI Variable Text, Segoe UI</FontFamily>
  <FontFamily x:Key="Font.Display">Segoe UI Variable Display, Segoe UI</FontFamily>
  <FontFamily x:Key="Font.Mono">Cascadia Mono, Consolas</FontFamily>
  <FontFamily x:Key="Font.Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
  <sys:Double x:Key="Type.Display">32</sys:Double>
  <sys:Double x:Key="Type.Title">22</sys:Double>
  <sys:Double x:Key="Type.Subtitle">16</sys:Double>
  <sys:Double x:Key="Type.Body">14</sys:Double>
  <sys:Double x:Key="Type.Caption">12</sys:Double>
  <sys:Double x:Key="Type.Metric">32</sys:Double>
  <CornerRadius x:Key="Radius.Control">8</CornerRadius>
  <CornerRadius x:Key="Radius.Card">12</CornerRadius>
  <CornerRadius x:Key="Radius.Hero">16</CornerRadius>
  <Thickness x:Key="Pad.Card">16</Thickness>
  <Thickness x:Key="Pad.Hero">24</Thickness>
</ResourceDictionary>
'@

# Accent presets: dark value, light value, and the text colour that goes on an accent button in each theme.
# White text fails 4.5:1 on every dark-mode accent, so dark-mode buttons use near-black text.
$ZdAccents = [ordered]@{
    cyan    = @{ Name = 'Cyan';            Dark = '#2EE6D6'; Light = '#0E7469' }
    blue    = @{ Name = 'Electric blue';   Dark = '#3D8BFF'; Light = '#2459E0' }
    volt    = @{ Name = 'Volt green';      Dark = '#B6F23D'; Light = '#4D7007' }
    orange  = @{ Name = 'Orange';          Dark = '#FF8A3D'; Light = '#B34700' }
    magenta = @{ Name = 'Magenta';         Dark = '#FF4FD8'; Light = '#BF0A98' }
    purple  = @{ Name = 'Fortnite purple'; Dark = '#9D5CFF'; Light = '#7B33EC' }
}
# accent values saved by 1.19 and earlier ('accent' setting key unchanged)
$ZdAccentMigration = @{ teal = 'cyan'; pink = 'magenta'; indigo = 'blue'; graphite = 'cyan' }

# ------------------------------------------------------------------------------------------------------ components ---
$ZdComponents = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">

  <!-- Keyboard focus ring: 2 px accent, 3 px outside the control. Mouse clicks do not show it. -->
  <Style x:Key="Zd.FocusRing">
    <Setter Property="Control.Template">
      <Setter.Value>
        <ControlTemplate>
          <Border Margin="-3" CornerRadius="11" BorderThickness="2" BorderBrush="{DynamicResource Accent}"/>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- PRIMARY BUTTON: accent fill, on-accent text, 36 px tall (hit target >= 32), no glow. -->
  <Style x:Key="Zd.Button.Primary" TargetType="Button">
    <Setter Property="Background" Value="{DynamicResource Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource Accent.OnAccent}"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="14"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="MinHeight" Value="36"/>
    <Setter Property="MinWidth" Value="36"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Zd.FocusRing}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid x:Name="Root">
            <Border x:Name="Bg" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
            <Border x:Name="Hover" CornerRadius="8" Background="{DynamicResource State.Hover}" Opacity="0"/>
            <Border x:Name="Press" CornerRadius="8" Background="{DynamicResource State.Press}" Opacity="0"/>
            <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Trigger.EnterActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="1" Duration="{MotionFast}"/>
              </Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="Hover" Storyboard.TargetProperty="Opacity" To="0" Duration="{MotionFast}"/>
              </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Press" Property="Opacity" Value="1"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Root" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <!-- Secondary (outline) and ghost variants reuse the primary template. -->
  <Style x:Key="Zd.Button.Secondary" TargetType="Button" BasedOn="{StaticResource Zd.Button.Primary}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource Text.Primary}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border.Strong}"/>
    <Setter Property="BorderThickness" Value="1"/>
  </Style>
  <Style x:Key="Zd.Button.Ghost" TargetType="Button" BasedOn="{StaticResource Zd.Button.Primary}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource Text.Secondary}"/>
    <Setter Property="FontWeight" Value="Medium"/>
    <Setter Property="Padding" Value="10,0"/>
    <Setter Property="MinHeight" Value="32"/>
  </Style>

  <!-- SWITCH (used by TweakCard): accent track when on. Same x:Name 'Toggle' contract as today's Switch. -->
  <Style x:Key="Zd.Switch" TargetType="ToggleButton">
    <Setter Property="Width" Value="40"/>
    <Setter Property="Height" Value="22"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Zd.FocusRing}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Grid x:Name="Root" Background="Transparent">
            <Border x:Name="Track" CornerRadius="11" Background="{DynamicResource Border.Strong}"/>
            <Border x:Name="OnTrack" CornerRadius="11" Background="{DynamicResource Accent}" Opacity="0"/>
            <Ellipse x:Name="Knob" Width="16" Height="16" Margin="3,0" HorizontalAlignment="Left" Fill="{DynamicResource Switch.Knob}">
              <Ellipse.RenderTransform><TranslateTransform/></Ellipse.RenderTransform>
            </Ellipse>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Knob" Property="Fill" Value="{DynamicResource Accent.OnAccent}"/>
              <Trigger.EnterActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="18" Duration="{MotionFast}">
                  <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                </DoubleAnimation>
                <DoubleAnimation Storyboard.TargetName="OnTrack" Storyboard.TargetProperty="Opacity" To="1" Duration="{MotionFast}"/>
              </Storyboard></BeginStoryboard></Trigger.EnterActions>
              <Trigger.ExitActions><BeginStoryboard><Storyboard>
                <DoubleAnimation Storyboard.TargetName="Knob" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)" To="0" Duration="{MotionFast}">
                  <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                </DoubleAnimation>
                <DoubleAnimation Storyboard.TargetName="OnTrack" Storyboard.TargetProperty="Opacity" To="0" Duration="{MotionFast}"/>
              </Storyboard></BeginStoryboard></Trigger.ExitActions>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Track" Property="Opacity" Value="0.8"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Root" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- Card surface: tone + 1 px border, no shadow. Hover only brightens the border. -->
  <Style x:Key="Zd.Card" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Bg.Surface}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource Border.Subtle}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Padding" Value="16"/>
    <Setter Property="SnapsToDevicePixels" Value="True"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource Border.Strong}"/></Trigger>
    </Style.Triggers>
  </Style>

  <!-- Tag chip on cards -->
  <Style x:Key="Zd.Chip" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource Bg.Raised}"/>
    <Setter Property="CornerRadius" Value="6"/>
    <Setter Property="Padding" Value="7,2,8,3"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
    <Setter Property="TextElement.FontSize" Value="12"/>
    <Setter Property="TextElement.Foreground" Value="{DynamicResource Text.Secondary}"/>
  </Style>

  <!-- Chevron that opens a card's details -->
  <Style x:Key="Zd.Chevron" TargetType="ToggleButton">
    <Setter Property="Width" Value="32"/>
    <Setter Property="Height" Value="32"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Foreground" Value="{DynamicResource Text.Muted}"/>
    <Setter Property="FocusVisualStyle" Value="{StaticResource Zd.FocusRing}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="Bg" CornerRadius="8" Background="Transparent">
            <TextBlock x:Name="Glyph" Text="&#xE70D;" FontFamily="{DynamicResource Font.Icons}" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"
                       Foreground="{TemplateBinding Foreground}" RenderTransformOrigin="0.5,0.5">
              <TextBlock.RenderTransform><RotateTransform/></TextBlock.RenderTransform>
            </TextBlock>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="{DynamicResource Bg.Raised}"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Glyph" Property="RenderTransform"><Setter.Value><RotateTransform Angle="180"/></Setter.Value></Setter></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

# ---------------------------------------------------------------------------------------------------- theme loader ---
# Applies theme + accent to a window (or [Windows.Application]::Current). Safe to call again to switch live.
function Set-ZdTheme($Target, [ValidateSet('dark', 'light')][string]$Mode = 'dark', [string]$Accent = 'cyan') {
    if ($ZdAccentMigration.ContainsKey($Accent)) { $Accent = $ZdAccentMigration[$Accent] }
    if (-not $ZdAccents.Contains($Accent)) { $Accent = 'cyan' }
    $motion = if ([Windows.SystemParameters]::ClientAreaAnimation) { '0:0:0.14' } else { '0:0:0' }
    $md = $Target.Resources.MergedDictionaries
    $md.Clear()
    foreach ($x in $ZdTokensShared, $(if ($Mode -eq 'light') { $ZdThemeLight } else { $ZdThemeDark })) { $md.Add([Windows.Markup.XamlReader]::Parse($x)) }
    # accent brushes go in before the components, which look them up
    $acc = New-Object Windows.ResourceDictionary
    $hex = if ($Mode -eq 'light') { $ZdAccents[$Accent].Light } else { $ZdAccents[$Accent].Dark }
    $c = [Windows.Media.ColorConverter]::ConvertFromString($hex)
    $acc['Accent'] = New-Object Windows.Media.SolidColorBrush $c
    $acc['Accent.OnAccent'] = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($(if ($Mode -eq 'light') { '#FFFFFF' } else { '#07080A' })))
    $acc['Accent.Soft'] = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(0x24, $c.R, $c.G, $c.B))
    foreach ($k in @($acc.Keys)) { $acc[$k].Freeze() }
    $md.Add($acc)
    $md.Add([Windows.Markup.XamlReader]::Parse($ZdComponents.Replace('{MotionFast}', $motion)))
    $script:ZdTheme = @{ Mode = $Mode; Accent = $Accent }
}

# ------------------------------------------------------------------------------------------------------- TweakCard ---
# Builds the card for one tweak. Keeps today's names so Switch-Tweak and friends keep working:
# Toggle (switch), ActionBtn (action tweaks), Extra (custom controls), Warn (the "don't use if" line).
# New names: Busy (applying spinner), FailBox/FailText/Retry, RestartChip, Lock/LockText, NoEffect, More/Details,
# Change, SourceLink, OnSince, Undo.
function New-ZdTweakCardXaml($t, [int]$Width = 360) {
    $glyph = if ($t.Icon) { '&#x{0:X};' -f [int][char]$t.Icon } else { '&#xE713;' }
    $chips = New-Object Collections.Generic.List[string]
    if ($t.Lat)    { $chips.Add("<Border Style='{DynamicResource Zd.Chip}' ToolTip='Affects input delay, frame time or ping'><StackPanel Orientation='Horizontal'><Ellipse Width='6' Height='6' Fill='{DynamicResource Good}' VerticalAlignment='Center' Margin='0,1,6,0'/><TextBlock Text='Input delay'/></StackPanel></Border>") }
    if ($t.Rec)    { $chips.Add("<Border Style='{DynamicResource Zd.Chip}' ToolTip='Included when you press Boost now'><StackPanel Orientation='Horizontal'><TextBlock Text='&#xE73E;' FontFamily='{DynamicResource Font.Icons}' FontSize='10' Foreground='{DynamicResource Accent}' VerticalAlignment='Center' Margin='0,1,5,0'/><TextBlock Text='Recommended'/></StackPanel></Border>") }
    if ($t.New)    { $chips.Add("<Border Style='{DynamicResource Zd.Chip}' Background='{DynamicResource Info.Soft}'><TextBlock Text='New' Foreground='{DynamicResource Info}'/></Border>") }
    $src = if ($t.Source) { "$($t.Source)" } elseif ($t.Url) { "$($t.Url)" } else { '' }
    if ($src -match '^https?://') { $chips.Add("<Border x:Name='SourceChip' Style='{DynamicResource Zd.Chip}' Cursor='Hand' ToolTip='$(Esc $src)'><TextBlock Text='Source &#x2197;'/></Border>") }
    $restartVis = if ($t.Restart) { 'Visible' } else { 'Collapsed' }

    # the control on the right: switch, action button, or "Show me how" for guided cards
    $control = if ($t.Guided) {
        "<Button x:Name='ActionBtn' Content='Show me how' Style='{DynamicResource Zd.Button.Secondary}' MinHeight='32' FontSize='13' Foreground='{DynamicResource Info}' BorderBrush='{DynamicResource Info}'/>"
    } elseif ($t.Action) {
        "<Button x:Name='ActionBtn' Content='$(Esc $t.Action)' Style='{DynamicResource Zd.Button.Secondary}' MinHeight='32' FontSize='13'/>"
    } else {
        "<ToggleButton x:Name='Toggle' Style='{DynamicResource Zd.Switch}' AutomationProperties.Name='$(Esc $t.Title)'/>"
    }
    $warn = if ($t.Warn) { @"
    <Grid x:Name='Warn' Grid.Row='2' Margin='0,8,0,0'>
      <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/></Grid.ColumnDefinitions>
      <TextBlock Text='&#xE946;' FontFamily='{DynamicResource Font.Icons}' FontSize='12' Foreground='{DynamicResource Text.Muted}' Margin='0,2,6,0'/>
      <TextBlock Grid.Column='1' TextWrapping='Wrap' FontSize='12' LineHeight='17' LineStackingStrategy='BlockLineHeight' Foreground='{DynamicResource Text.Muted}'>
        <Run Text="Don't use if:" FontWeight='SemiBold'/> <Run Text='$(Esc $t.Warn)'/>
      </TextBlock>
    </Grid>
"@ } else { '' }

    @"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        Style='{DynamicResource Zd.Card}' Width='$Width' Margin='0,0,16,16' VerticalAlignment='Top'
        AutomationProperties.Name='$(Esc $t.Title)'>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/>
      <RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/>
    </Grid.RowDefinitions>
    <!-- 0: icon, title, switch -->
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <Border Width='32' Height='32' CornerRadius='8' Background='{DynamicResource Bg.Raised}' VerticalAlignment='Top'>
        <TextBlock Text='$glyph' FontFamily='{DynamicResource Font.Icons}' FontSize='16' Foreground='{DynamicResource Text.Secondary}' HorizontalAlignment='Center' VerticalAlignment='Center'/>
      </Border>
      <TextBlock Grid.Column='1' Text='$(Esc $t.Title)' FontFamily='{DynamicResource Font.UI}' FontSize='16' FontWeight='SemiBold' Foreground='{DynamicResource Text.Primary}'
                 TextWrapping='Wrap' VerticalAlignment='Center' Margin='12,0,12,0'/>
      <Grid Grid.Column='2' VerticalAlignment='Center'>
        $control
        <Grid x:Name='Busy' Visibility='Collapsed' Background='{DynamicResource Bg.Surface}' ToolTip='Applying...'>
          <Ellipse Width='18' Height='18' Stroke='{DynamicResource Border.Strong}' StrokeThickness='2'/>
          <Path Width='18' Height='18' Stroke='{DynamicResource Accent}' StrokeThickness='2' StrokeStartLineCap='Round' StrokeEndLineCap='Round'
                Data='M9,1 A8,8 0 0 1 17,9' RenderTransformOrigin='0.5,0.5'>
            <Path.RenderTransform><RotateTransform x:Name='Spin'/></Path.RenderTransform>
          </Path>
        </Grid>
        <StackPanel x:Name='Lock' Orientation='Horizontal' Visibility='Collapsed' Background='{DynamicResource Bg.Surface}'>
          <TextBlock Text='&#xE72E;' FontFamily='{DynamicResource Font.Icons}' FontSize='13' Foreground='{DynamicResource Text.Muted}' VerticalAlignment='Center'/>
          <TextBlock x:Name='LockText' FontSize='12' Foreground='{DynamicResource Text.Muted}' VerticalAlignment='Center' Margin='6,0,0,0'/>
        </StackPanel>
      </Grid>
    </Grid>
    <!-- 1: what it does -->
    <TextBlock Grid.Row='1' Text='$(Esc $t.Desc)' FontFamily='{DynamicResource Font.UI}' FontSize='14' LineHeight='20' LineStackingStrategy='BlockLineHeight'
               Foreground='{DynamicResource Text.Secondary}' TextWrapping='Wrap' Margin='44,4,0,0'/>
    <!-- 2: when NOT to use it (always visible) -->
    $(if ($warn) { $warn -replace "Margin='0,8,0,0'", "Margin='44,8,0,0'" })
    <!-- 3: custom controls (FPS box, pickers) -->
    <ContentControl x:Name='Extra' Grid.Row='3' Margin='44,12,0,0'/>
    <!-- 4: failed / no effect messages -->
    <Border x:Name='FailBox' Grid.Row='4' Visibility='Collapsed' Background='{DynamicResource Bad.Soft}' CornerRadius='8' Padding='10,8' Margin='44,12,0,0'>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width='Auto'/><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
        <TextBlock Text='&#xEA39;' FontFamily='{DynamicResource Font.Icons}' FontSize='13' Foreground='{DynamicResource Bad}' Margin='0,2,8,0'/>
        <TextBlock x:Name='FailText' Grid.Column='1' TextWrapping='Wrap' FontSize='12' Foreground='{DynamicResource Text.Primary}' VerticalAlignment='Center'/>
        <Button x:Name='Retry' Grid.Column='2' Content='Retry' Style='{DynamicResource Zd.Button.Ghost}' Foreground='{DynamicResource Bad}' Margin='8,-6,-6,-6'/>
      </Grid>
    </Border>
    <StackPanel x:Name='NoEffect' Grid.Row='4' Orientation='Horizontal' Visibility='Collapsed' Margin='44,12,0,0'>
      <TextBlock Text='&#xE9D9;' FontFamily='{DynamicResource Font.Icons}' FontSize='12' Foreground='{DynamicResource Text.Muted}' VerticalAlignment='Center'/>
      <TextBlock Text='Tests show no effect' FontSize='12' Foreground='{DynamicResource Text.Muted}' Margin='6,0,0,0'/>
    </StackPanel>
    <!-- 5: tags + details chevron -->
    <Grid Grid.Row='5' Margin='44,12,0,0'>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <WrapPanel VerticalAlignment='Center'>
        $($chips -join "`n        ")
        <Border x:Name='RestartChip' Style='{DynamicResource Zd.Chip}' Background='{DynamicResource Warn.Soft}' Visibility='$restartVis'><TextBlock Text='Needs restart' Foreground='{DynamicResource Warn}'/></Border>
      </WrapPanel>
      <ToggleButton x:Name='More' Grid.Column='1' Style='{DynamicResource Zd.Chevron}' Margin='0,-6,-8,-8' AutomationProperties.Name='Details' ToolTip='Details'/>
    </Grid>
    <!-- 6: details (exact change, source, when, undo) -->
    <Border x:Name='Details' Grid.Row='6' Visibility='Collapsed' BorderBrush='{DynamicResource Border.Subtle}' BorderThickness='0,1,0,0' Margin='44,12,0,0' Padding='0,12,0,0'>
      <StackPanel>
        <TextBlock Text='EXACT CHANGE' FontSize='11' FontWeight='SemiBold' Foreground='{DynamicResource Text.Muted}'/>
        <TextBlock x:Name='Change' FontFamily='{DynamicResource Font.Mono}' FontSize='12' Foreground='{DynamicResource Text.Secondary}' TextWrapping='Wrap' Margin='0,4,0,0'/>
        <TextBlock x:Name='OnSince' FontSize='12' Foreground='{DynamicResource Text.Muted}' Margin='0,8,0,0'/>
        <StackPanel Orientation='Horizontal' Margin='0,8,0,0'>
          <Button x:Name='Undo' Content='Undo' Style='{DynamicResource Zd.Button.Secondary}' MinHeight='32' FontSize='13'/>
          <Button x:Name='SourceLink' Content='Open source &#x2197;' Style='{DynamicResource Zd.Button.Ghost}' Margin='8,0,0,0' Visibility='$(if ($src -match '^https?://') { 'Visible' } else { 'Collapsed' })'/>
        </StackPanel>
      </StackPanel>
    </Border>
  </Grid>
</Border>
"@
}

# States: off, on, applying, failed, restart, guided (built in), noeffect, managed.
function Set-ZdCardState($Card, [string]$State, [string]$Info) {
    $f = { param($n) $Card.FindName($n) }
    $toggle = & $f 'Toggle'; $busy = & $f 'Busy'; $fail = & $f 'FailBox'; $lock = & $f 'Lock'
    $busy.Visibility = 'Collapsed'; $fail.Visibility = 'Collapsed'; $lock.Visibility = 'Collapsed'
    $Card.Opacity = 1
    $Card.ClearValue([Windows.Controls.Border]::BorderBrushProperty)   # back to the style's border
    if ($toggle) { $toggle.IsEnabled = $true }
    switch ($State) {
        'on'       { if ($toggle) { $toggle.IsChecked = $true } }
        'off'      { if ($toggle) { $toggle.IsChecked = $false } }
        'applying' {
            $busy.Visibility = 'Visible'; if ($toggle) { $toggle.IsEnabled = $false }
            # spins only while applying; stops by itself when the state changes (the element is hidden)
            if ([Windows.SystemParameters]::ClientAreaAnimation) {
                $a = [Windows.Media.Animation.DoubleAnimation]::new(0, 360, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(800)))
                $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
                (& $f 'Spin').BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $a)
            }
        }
        'failed'   {
            $fail.Visibility = 'Visible'; (& $f 'FailText').Text = $(if ($Info) { $Info } else { 'This could not be changed.' })
            $Card.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Bad')
        }
        'restart'  { (& $f 'RestartChip').Visibility = 'Visible' }
        'noeffect' { $Card.Opacity = 0.6; (& $f 'NoEffect').Visibility = 'Visible' }
        'managed'  { $lock.Visibility = 'Visible'; (& $f 'LockText').Text = $(if ($Info) { "Managed by $Info" } else { 'Managed by another app' }) }
    }
    if ($State -ne 'applying') { (& $f 'Spin').BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $null) }
}

# ------------------------------------------------------------------------------------------------------ MetricTile ---
# Live tile: label, status (dot + word, never colour alone), big mono value + unit, 60-s sparkline, caption.
function New-ZdMetricTileXaml([string]$Key, [string]$Label, [string]$Icon = '&#xE9D9;', [string]$Unit = '') {
    @"
<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'
        x:Name='Tile_$Key' Style='{DynamicResource Zd.Card}' MinWidth='200' Margin='0,0,16,16' AutomationProperties.Name='$(Esc $Label)'>
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height='Auto'/><RowDefinition Height='Auto'/><RowDefinition Height='40'/><RowDefinition Height='Auto'/></Grid.RowDefinitions>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width='*'/><ColumnDefinition Width='Auto'/></Grid.ColumnDefinitions>
      <StackPanel Orientation='Horizontal'>
        <TextBlock Text='$Icon' FontFamily='{DynamicResource Font.Icons}' FontSize='13' Foreground='{DynamicResource Text.Muted}' VerticalAlignment='Center'/>
        <TextBlock Text='$(Esc $Label)' FontSize='12' FontWeight='SemiBold' Foreground='{DynamicResource Text.Secondary}' VerticalAlignment='Center' Margin='8,0,0,0'/>
      </StackPanel>
      <StackPanel Grid.Column='1' Orientation='Horizontal'>
        <Ellipse x:Name='StatusDot' Width='7' Height='7' Fill='{DynamicResource Text.Muted}' VerticalAlignment='Center'/>
        <TextBlock x:Name='StatusText' FontSize='12' Foreground='{DynamicResource Text.Muted}' VerticalAlignment='Center' Margin='6,0,0,0'/>
      </StackPanel>
    </Grid>
    <StackPanel Grid.Row='1' Orientation='Horizontal' Margin='0,10,0,6'>
      <TextBlock x:Name='Value' Text='--' FontFamily='{DynamicResource Font.Mono}' FontSize='32' Foreground='{DynamicResource Text.Primary}' Typography.NumeralAlignment='Tabular'/>
      <TextBlock x:Name='Unit' Text='$(Esc $Unit)' FontSize='12' Foreground='{DynamicResource Text.Muted}' VerticalAlignment='Bottom' Margin='6,0,0,7'/>
    </StackPanel>
    <Canvas x:Name='Spark' Grid.Row='2' ClipToBounds='True'>
      <Polygon x:Name='SparkFill' Opacity='0.14' Fill='{DynamicResource Text.Muted}'/>
      <Polyline x:Name='SparkLine' StrokeThickness='1.5' Stroke='{DynamicResource Text.Muted}' StrokeLineJoin='Round'/>
    </Canvas>
    <TextBlock x:Name='Sub' Grid.Row='3' FontSize='12' Foreground='{DynamicResource Text.Muted}' TextTrimming='CharacterEllipsis' Margin='0,8,0,0'/>
  </Grid>
</Border>
"@
}

# Updates a tile. Status is good / warn / bad / idle; the word shown next to the dot defaults per status.
# History is up to 60 samples (one per second); Max fixes the scale (e.g. 100 for %), $null = scale to the data.
function Update-ZdMetricTile($Tile, [string]$Value, [string]$Status = 'idle', [string]$StatusText, [double[]]$History, $Max = $null, [string]$Sub) {
    $f = { param($n) $Tile.FindName($n) }
    (& $f 'Value').Text = $Value
    if ($PSBoundParameters.ContainsKey('Sub')) { (& $f 'Sub').Text = $Sub }
    $key  = @{ good = 'Good'; warn = 'Warn'; bad = 'Bad' }[$Status]; if (-not $key) { $key = 'Text.Muted' }
    $word = if ($StatusText) { $StatusText } else { @{ good = 'Good'; warn = 'Check'; bad = 'High'; idle = '' }[$Status] }
    (& $f 'StatusDot').SetResourceReference([Windows.Shapes.Shape]::FillProperty, $key)
    (& $f 'StatusText').Text = $word
    (& $f 'StatusText').SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $key)
    (& $f 'SparkLine').SetResourceReference([Windows.Shapes.Shape]::StrokeProperty, $key)
    (& $f 'SparkFill').SetResourceReference([Windows.Shapes.Shape]::FillProperty, $key)
    if ($History) { Update-ZdSparkline (& $f 'Spark') $History $Max }
}
function Update-ZdSparkline($Canvas, [double[]]$Values, $Max = $null) {
    $w = $Canvas.ActualWidth; $h = $Canvas.ActualHeight
    if ($w -le 0 -or $h -le 0 -or $Values.Count -lt 2) { return }
    $top = if ($null -ne $Max) { [double]$Max } else { ($Values | Measure-Object -Maximum).Maximum * 1.15 }
    if ($top -le 0) { $top = 1 }
    $step = $w / 59   # always a 60-second window: the line grows in from the right
    $x0 = $w - $step * ($Values.Count - 1)
    $line = New-Object Windows.Media.PointCollection
    for ($i = 0; $i -lt $Values.Count; $i++) {
        $y = $h - 1 - [Math]::Min(1, [Math]::Max(0, $Values[$i] / $top)) * ($h - 2)
        $line.Add((New-Object Windows.Point(($x0 + $i * $step), $y)))
    }
    $fill = [Windows.Media.PointCollection]::new($line)   # ::new, so PowerShell does not unroll $line into arguments
    $fill.Add((New-Object Windows.Point($w, $h))); $fill.Add((New-Object Windows.Point($x0, $h)))
    $line.Freeze(); $fill.Freeze()
    $Canvas.Children[0].Points = $fill
    $Canvas.Children[1].Points = $line
}
