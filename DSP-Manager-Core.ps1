#! DSP WSL Manager - Core Script (Start via de 'Start DSP Manager.bat' file!)
# Beheert WSL distro's, installeert nieuwe DSP distro (Ubuntu 24.04) met automatische credentials

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Versie
$script:appVersion = "2.0.1"

# Determine script directory early (needed for log and config files)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path } else { (Get-Location).Path }

# Check WSL state: not just installed but actually functional
# Returns a hashtable with 'ok' (bool) and 'reason' (string) for UI messages
function Test-WslState {
    $state = @{ ok = $false; reason = "unknown"; needsVMPlatform = $false; needsBIOS = $false; needsInstall = $false }
    try {
        # Check hardware virtualization support via systeminfo (more reliable than WMI)
        # WMI VirtualizationFirmwareEnabled returns false when a hypervisor (Hyper-V/VMware) is active
        $vtEnabled = $true  # assume true, only set false if systeminfo explicitly says no
        try {
            $sysInfo = systeminfo 2>&1 | Out-String
            # Look for "Virtualization Enabled In Firmware: No" (EN) or "Virtualisatie ingeschakeld in firmware: Nee" (NL)
            if ($sysInfo -match "Virtuali[sz]ati.*firmware.*:\s*(No|Nee)\b") {
                $vtEnabled = $false
            }
            # If Hyper-V is running, virtualization is definitely available
            if ($sysInfo -match "hypervisor.*detected|Er is een hypervisor gedetecteerd") {
                $vtEnabled = $true
            }
        } catch {}

        # First check if wsl.exe is the full version (not just the stub)
        $helpOut = (& wsl --help 2>&1 | Out-String) -replace '\x00', ''
        if ($helpOut.Trim().Length -lt 1500 -or $helpOut -notmatch "--export|--import|--set-default") {
            $state.reason = "WSL is niet geïnstalleerd."
            $state.needsInstall = $true
            if (-not $vtEnabled) {
                $state.reason += "`n`nLET OP: Virtualisatie (VT-x/AMD-V) staat UIT in het BIOS.`nDit moet eerst worden ingeschakeld voordat WSL kan werken."
                $state.needsBIOS = $true
            }
            return $state
        }

        # WSL exe exists and is full version — check status for deeper issues
        $statusOut = (& wsl --status 2>&1 | Out-String) -replace '\x00', ''

        # Check BIOS virtualization first — this is the most fundamental requirement
        if (-not $vtEnabled) {
            $state.reason = "Virtualisatie (VT-x/AMD-V) staat UIT in het BIOS.`n`nDit moet worden ingeschakeld voordat WSL kan werken:`n1. Herstart de computer en ga naar het BIOS (DEL/F2/F10)`n2. Schakel Virtualization Technology in`n3. Sla op en herstart"
            $state.needsBIOS = $true
            return $state
        }

        # Check for Virtual Machine Platform issue (BIOS is OK but Windows feature not enabled)
        if ($statusOut -match "Virtual Machine Platform") {
            $state.reason = "Virtual Machine Platform is niet ingeschakeld.`nDit wordt automatisch geactiveerd — herstart daarna de computer."
            $state.needsVMPlatform = $true
            return $state
        }

        # Check for specific virtualization error messages in status (not just any mention of the word)
        if ($statusOut -match "enable virtualization|schakel virtualisatie in|virtualization.*not enabled|virtualisatie.*niet ingeschakeld") {
            $state.reason = "Virtualisatie-ondersteuning ontbreekt.`nControleer BIOS-instellingen en Windows-onderdelen."
            $state.needsVMPlatform = $true
            return $state
        }

        # All checks passed — WSL is functional
        $state.ok = $true
        $state.reason = ""
        return $state
    } catch {
        $state.reason = "Fout bij het controleren van WSL: $_"
        return $state
    }
}

# Initialize state — will be populated after window is shown
$script:wslState = @{ ok = $false; reason = "Laden..."; needsVMPlatform = $false; needsBIOS = $false; needsInstall = $false }
$script:wslInstalled = $false
$script:wslIsRunning = $false

# Detect installed Ubuntu distro name (may vary per system: Ubuntu-24.04, Ubuntu24.04, Ubuntu, etc.)
function Find-UbuntuDistro {
    if (-not $script:wslInstalled) { return $null }
    $list = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
    $distros = $list -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch "^docker-desktop" }
    # Prefer versioned Ubuntu, fallback to generic Ubuntu
    $found = $distros | Where-Object { $_ -match "^Ubuntu-?\d" } | Select-Object -First 1
    if (-not $found) { $found = $distros | Where-Object { $_ -match "^Ubuntu$" } | Select-Object -First 1 }
    return $found
}
$script:dspDistro = "Ubuntu-24.04"

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSP WSL Manager" Height="750" Width="1050"
        WindowStartupLocation="CenterScreen"
        Background="#181825" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <Style TargetType="Button" x:Key="ActionBtn">
            <Setter Property="Background" Value="#394264"/>
            <Setter Property="Foreground" Value="#b4c6ef"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#475480"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button" x:Key="DangerBtn" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#4a2535"/>
            <Setter Property="Foreground" Value="#e08a9e"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#5c2f42"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button" x:Key="GreenBtn" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#2d4a35"/>
            <Setter Property="Foreground" Value="#a6d9a0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#3a5c43"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button" x:Key="SmallActionBtn" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Padding" Value="12,4"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="Button" x:Key="SmallGreenBtn" BasedOn="{StaticResource GreenBtn}">
            <Setter Property="Padding" Value="12,4"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <Style TargetType="Button" x:Key="SmallDangerBtn" BasedOn="{StaticResource DangerBtn}">
            <Setter Property="Padding" Value="12,4"/>
            <Setter Property="FontSize" Value="12"/>
        </Style>
        <!-- Big action button styles -->
        <Style TargetType="Button" x:Key="BigGreenBtn" BasedOn="{StaticResource GreenBtn}">
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Padding" Value="24,14"/>
        </Style>
        <Style TargetType="Button" x:Key="BigActionBtn" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="Padding" Value="24,14"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="280"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- ========== LOADING OVERLAY (spans both columns) ========== -->
        <Border Grid.ColumnSpan="2" Name="pnlLoading" Background="#1e1e2e" Visibility="Visible" Panel.ZIndex="10">
            <Canvas HorizontalAlignment="Center" VerticalAlignment="Center" Width="500" Height="340">
                <TextBlock Text="&#x1F427; DSP WSL Manager" FontSize="24" FontWeight="Bold" Foreground="#cdd6f4" Canvas.Left="0" Canvas.Top="0"/>
                <TextBlock Text="DT-RAS Digital Signal Processing &#x2022; Elektrotechniek &#x2022; Avans Breda" FontSize="12" Foreground="#6c7086" Canvas.Left="0" Canvas.Top="32"/>
                <TextBlock Text="&#x23F3; Systeem controleren..." Foreground="#cdd6f4" FontSize="16" FontWeight="SemiBold" Canvas.Left="0" Canvas.Top="72"/>
                <TextBlock Name="chkVirtualization" Text="&#x2B1C; Virtualisatie controleren..." Foreground="#6c7086" FontSize="13" Canvas.Left="0" Canvas.Top="104"/>
                <TextBlock Name="chkWsl" Text="&#x2B1C; WSL status controleren..." Foreground="#6c7086" FontSize="13" Canvas.Left="0" Canvas.Top="128"/>
                <TextBlock Name="chkDistro" Text="&#x2B1C; Distro detecteren..." Foreground="#6c7086" FontSize="13" Canvas.Left="0" Canvas.Top="152"/>
                <TextBlock Name="chkProject" Text="&#x2B1C; DSP project zoeken..." Foreground="#6c7086" FontSize="13" Canvas.Left="0" Canvas.Top="176"/>
                <TextBlock Name="chkUsbipd" Text="&#x2B1C; USB-IPD controleren..." Foreground="#6c7086" FontSize="13" Canvas.Left="0" Canvas.Top="200"/>
                <TextBlock Name="chkInit" Text="&#x2B1C; Interface voorbereiden..." Foreground="#6c7086" FontSize="13" Canvas.Left="0" Canvas.Top="224"/>
                <TextBlock Name="txtLoadingHint" Text="" Foreground="#585b70" FontSize="16" FontWeight="SemiBold" Canvas.Left="80" Canvas.Top="268"/>
                <TextBlock FontSize="16" FontStyle="Italic" FontWeight="SemiBold" Canvas.Left="80" Canvas.Top="316">
                    <Run Text="Crafted by Danny van der Zande" Foreground="#89b4fa"/>
                    <Run Text=" - " Foreground="#585b70"/>
                    <Run Text="v2.0.0" Foreground="#585b70"/>
                </TextBlock>
            </Canvas>
        </Border>

        <!-- ========== SIDEBAR (left) ========== -->
        <Border Grid.Column="0" Background="#1e1e2e" BorderBrush="#313244" BorderThickness="0,0,1,0">
            <DockPanel Margin="16,16,16,8">
                <!-- Footer -->
                <StackPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
                    <Button Name="btnDevRestart" Style="{StaticResource SmallActionBtn}" Content="&#x1F504; Restart app"
                            FontSize="9" Padding="8,4" HorizontalAlignment="Center" Margin="0,0,0,4" Visibility="Collapsed"/>
                    <Button Name="btnCheckUpdate" Style="{StaticResource SmallActionBtn}" ToolTip="Check for updates"
                            FontSize="9" Padding="8,4" HorizontalAlignment="Center" Margin="0,0,0,6">
                        <Grid>
                            <StackPanel Orientation="Horizontal">
                                <Path Data="M12,4 C7.58,4 4,7.58 4,12 S7.58,20 12,20 S20,16.42 20,12 H18 C18,15.31 15.31,18 12,18 S6,15.31 6,12 S8.69,6 12,6 C13.66,6 15.14,6.69 16.22,7.78 L13,11 H20 V4 L17.65,6.35 C16.2,4.9 14.21,4 12,4 Z"
                                      Fill="#a6e3a1" Stretch="Uniform" Width="11" Height="11" Margin="0,1,5,0"/>
                                <TextBlock Text="Check for updates" Foreground="#bac2de" FontSize="9" VerticalAlignment="Center"/>
                            </StackPanel>
                            <Ellipse Name="dotUpdate" Width="7" Height="7" Fill="#f38ba8"
                                     HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-4,-4,0" Visibility="Collapsed"/>
                        </Grid>
                    </Button>
                    <TextBlock FontSize="11" FontStyle="Italic" HorizontalAlignment="Center">
                        <Run Text="Crafted by Danny van der Zande" Foreground="#7f849c"/>
                        <Run Text=" - " Foreground="#6c7086"/>
                        <Run Text="v2.0.0" Foreground="#6c7086"/>
                    </TextBlock>
                </StackPanel>

                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                <StackPanel>
                    <TextBlock Text="&#x1F427; DSP WSL Manager" FontSize="18" FontWeight="Bold" Foreground="#cdd6f4" Margin="0,0,0,2"/>
                    <TextBlock Text="DT-RAS Elektrotechniek &#x2022; Avans Breda" FontSize="9" Foreground="#6c7086" Margin="0,0,0,2"/>
                    <TextBlock Text="Manager tool for setting up and using dev environment for DSP study assignment" FontSize="8" Foreground="#585b70" TextWrapping="Wrap" Margin="0,0,0,16"/>

                    <!-- WSL OMGEVING header + knoppen -->
                    <Grid Margin="0,0,0,8">
                        <TextBlock Text="WSL OMGEVING" Foreground="#89b4fa" FontSize="10" FontWeight="Bold" VerticalAlignment="Center"/>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button Name="btnInstall" Style="{StaticResource SmallActionBtn}" ToolTip="Nieuwe distro"
                                    Width="24" Height="20" Padding="0" Margin="0,0,4,0">
                                <TextBlock Text="+" Foreground="#b4c6ef" FontSize="14" FontWeight="Bold" Margin="0,-2,0,0"/>
                            </Button>
                            <Button Name="btnRefresh" Style="{StaticResource SmallActionBtn}" ToolTip="Vernieuwen"
                                    Width="24" Height="20" Padding="0">
                                <Path Data="M17.65,6.35 C16.2,4.9 14.21,4 12,4 C7.58,4 4.01,7.58 4.01,12 S7.58,20 12,20 C15.73,20 18.84,17.45 19.73,14 L17.65,14 C16.83,16.33 14.61,18 12,18 C8.69,18 6,15.31 6,12 S8.69,6 12,6 C13.66,6 15.14,6.69 16.22,7.78 L13,11 L20,11 V4 L17.65,6.35 Z"
                                      Fill="#b4c6ef" Stretch="Uniform" Width="12" Height="12"/>
                            </Button>
                        </StackPanel>
                    </Grid>

                    <!-- Distro lijst: klikbare kaarten -->
                    <ListBox Name="dgDistros" Background="Transparent" BorderThickness="0" SelectionMode="Single"
                             MaxHeight="180" MinHeight="40"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                        <ListBox.ItemContainerStyle>
                            <Style TargetType="ListBoxItem">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ListBoxItem">
                                            <Grid Margin="0,0,0,4">
                                                <Border Name="cardBg" Background="Transparent" CornerRadius="6" Padding="10,8">
                                                    <ContentPresenter/>
                                                </Border>
                                                <!-- Selection indicator bar -->
                                                <Border Name="selBar" Width="4" CornerRadius="2" HorizontalAlignment="Right"
                                                        VerticalAlignment="Center" Height="20" Background="Transparent" Margin="0,0,-2,0"/>
                                            </Grid>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="cardBg" Property="Background" Value="#313244"/>
                                                </Trigger>
                                                <Trigger Property="IsSelected" Value="True">
                                                    <Setter TargetName="cardBg" Property="Background" Value="#45475a"/>
                                                    <Setter TargetName="cardBg" Property="Opacity" Value="0.6"/>
                                                    <Setter TargetName="selBar" Property="Background" Value="#89b4fa"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Cursor" Value="Hand"/>
                            </Style>
                        </ListBox.ItemContainerStyle>
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <StackPanel Orientation="Horizontal">
                                    <!-- Status dot -->
                                    <Ellipse Name="statusDot" Width="8" Height="8" Fill="#6c7086" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                    <StackPanel>
                                        <TextBlock Text="{Binding Name}" Foreground="#cdd6f4" FontSize="11" FontWeight="SemiBold"/>
                                        <TextBlock Foreground="#9399b2" FontSize="8">
                                            <TextBlock.Text>
                                                <MultiBinding StringFormat="{}{0} &#x2022; WSL {1}{2}">
                                                    <Binding Path="State"/>
                                                    <Binding Path="Version"/>
                                                    <Binding Path="Default"/>
                                                </MultiBinding>
                                            </TextBlock.Text>
                                        </TextBlock>
                                    </StackPanel>
                                </StackPanel>
                                <DataTemplate.Triggers>
                                    <DataTrigger Binding="{Binding State}" Value="Running">
                                        <Setter TargetName="statusDot" Property="Fill" Value="#a6e3a1"/>
                                    </DataTrigger>
                                </DataTemplate.Triggers>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>

                    <!-- PROJECT header -->
                    <TextBlock Text="PROJECT" Foreground="#89b4fa" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>

                    <Border Background="#313244" CornerRadius="6" Padding="12,8" Margin="0,0,0,6">
                        <Grid>
                            <StackPanel>
                                <TextBlock Name="txtProjectName" Text="Geen project" Foreground="#cdd6f4" FontSize="12" FontWeight="SemiBold" Margin="0,0,20,0"/>
                                <TextBlock Name="txtProjectAuthor" Visibility="Collapsed" FontSize="9" Margin="0,4,0,2">
                                    <Hyperlink Name="linkProjectAuthor" NavigateUri="https://github.com/dkroeske/avd-dsp-project" Foreground="#6c7086">
                                        <Run Text="Git project by Diederich Kroeske"/>
                                    </Hyperlink>
                                </TextBlock>
                                <StackPanel Orientation="Horizontal" Margin="0,2,0,4">
                                    <Button Name="btnOpenFolder" Style="{StaticResource SmallActionBtn}" ToolTip="Map openen" Width="18" Height="16" Padding="0" Margin="0,0,5,0" VerticalAlignment="Center" Visibility="Collapsed">
                                        <Path Data="M10,4 H4 C2.9,4 2,4.9 2,6 V18 C2,19.1 2.9,20 4,20 H20 C21.1,20 22,19.1 22,18 V8 C22,6.9 21.1,6 20,6 H12 L10,4 Z"
                                              Fill="#b4c6ef" Stretch="Uniform" Width="11" Height="10"/>
                                    </Button>
                                    <TextBlock Name="txtProjectPath" Text="Klik 'Koppelen' om te starten" Foreground="#6c7086" FontSize="9" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" MaxWidth="160"/>
                                </StackPanel>
                                <TextBlock Name="txtProjectStatus" Text="Niet geconfigureerd" Foreground="#f38ba8" FontSize="9" FontWeight="SemiBold"/>
                            </StackPanel>
                            <!-- X knop rechtsboven: ontkoppelen -->
                            <Button Name="btnUnlinkProject" Style="{StaticResource SmallDangerBtn}" ToolTip="Ontkoppelen" Width="20" Height="18" Padding="0"
                                    HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-2,-4,0" Visibility="Collapsed">
                                <Path Data="M19,6.41 L17.59,5 L12,10.59 L6.41,5 L5,6.41 L10.59,12 L5,17.59 L6.41,19 L12,13.41 L17.59,19 L19,17.59 L13.41,12 Z"
                                      Fill="#e08a9e" Stretch="Uniform" Width="8" Height="8"/>
                            </Button>
                        </Grid>
                    </Border>
                    <!-- Koppelen knop: alleen zichtbaar als er geen project is -->
                    <Button Content="&#x1F4E5; Koppelen" Style="{StaticResource SmallActionBtn}" Name="btnCloneRepo" Padding="8,5" FontSize="10" Margin="0,0,0,8" HorizontalAlignment="Left"/>

                    <!-- RASPBERRY PI PICO -->
                    <TextBlock Text="RASPBERRY PI PICO" Foreground="#89b4fa" FontSize="10" FontWeight="Bold" Margin="0,0,0,8"/>

                    <ListBox Name="dgPicos" Background="Transparent" BorderThickness="0" SelectionMode="Single"
                             MaxHeight="120" MinHeight="30" Margin="0,0,0,6"
                             ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                        <ListBox.ItemContainerStyle>
                            <Style TargetType="ListBoxItem">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ListBoxItem">
                                            <Grid>
                                                <Border Name="picoBg" Background="Transparent" CornerRadius="6" Padding="10,6" Margin="0,1"/>
                                                <ContentPresenter Margin="10,6"/>
                                                <Border Name="picoBar" Width="4" CornerRadius="2" HorizontalAlignment="Right"
                                                        VerticalAlignment="Center" Height="20" Background="Transparent" Margin="0,0,-2,0"/>
                                            </Grid>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="picoBg" Property="Background" Value="#313244"/>
                                                </Trigger>
                                                <Trigger Property="IsSelected" Value="True">
                                                    <Setter TargetName="picoBg" Property="Background" Value="#45475a"/>
                                                    <Setter TargetName="picoBg" Property="Opacity" Value="0.6"/>
                                                    <Setter TargetName="picoBar" Property="Background" Value="#89b4fa"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Cursor" Value="Hand"/>
                            </Style>
                        </ListBox.ItemContainerStyle>
                        <ListBox.ItemTemplate>
                            <DataTemplate>
                                <StackPanel Orientation="Horizontal">
                                    <Ellipse Name="picoDot" Width="8" Height="8" Fill="#6c7086" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                    <StackPanel>
                                        <TextBlock Text="{Binding Desc}" Foreground="#cdd6f4" FontSize="11" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="160"/>
                                        <TextBlock Foreground="#9399b2" FontSize="8">
                                            <TextBlock.Text>
                                                <MultiBinding StringFormat="{}{0} &#x2022; {1}">
                                                    <Binding Path="Id"/>
                                                    <Binding Path="Status"/>
                                                </MultiBinding>
                                            </TextBlock.Text>
                                        </TextBlock>
                                    </StackPanel>
                                </StackPanel>
                                <DataTemplate.Triggers>
                                    <DataTrigger Binding="{Binding Status}" Value="Gekoppeld aan WSL">
                                        <Setter TargetName="picoDot" Property="Fill" Value="#a6e3a1"/>
                                    </DataTrigger>
                                </DataTemplate.Triggers>
                            </DataTemplate>
                        </ListBox.ItemTemplate>
                    </ListBox>

                    <Button Content="&#x1F50C; Pico Koppelen" Style="{StaticResource SmallActionBtn}" Name="btnPico" HorizontalAlignment="Stretch" Padding="8,5" FontSize="11"/>

                </StackPanel>
                </ScrollViewer>
            </DockPanel>
        </Border>

        <!-- ========== MAIN AREA (right) ========== -->
        <Grid Grid.Column="1" Margin="16,16,16,8">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- WSL Missing banner -->
            <Border Grid.Row="0" Name="pnlWslMissing" Background="#f38ba8" CornerRadius="8"
                    Padding="16,12" Margin="0,0,0,12" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal">
                    <TextBlock Name="txtWslError" Text="&#x26A0; WSL is niet beschikbaar."
                               Foreground="#1e1e2e" FontSize="14" FontWeight="SemiBold"
                               VerticalAlignment="Center" Margin="0,0,16,0" TextWrapping="Wrap" MaxWidth="500"/>
                    <Button Content="WSL Installeren" Style="{StaticResource ActionBtn}"
                            Name="btnInstallWSL" Padding="20,8" FontSize="14"/>
                </StackPanel>
            </Border>

            <!-- Main content wrapper (hidden during loading) -->
            <Border Grid.Row="1" Grid.RowSpan="6" Name="pnlMainContent" Visibility="Collapsed">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="150"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <!-- Selected distro title -->
                    <TextBlock Grid.Row="0" Name="txtSelectedDistro" Text=""
                               Foreground="#cdd6f4" FontSize="18" FontWeight="Bold" Margin="0,0,0,8"/>

                    <!-- 3-column status panel -->
                    <Border Grid.Row="1" Background="#1e1e2e" CornerRadius="10" BorderBrush="#313244" BorderThickness="1" Padding="16,10" Margin="0,0,0,10">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Kolom 1: WSL status -->
                            <StackPanel Grid.Column="0">
                                <TextBlock Text="WSL" Foreground="#89b4fa" FontSize="9" FontWeight="Bold" Margin="0,0,0,4"/>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
                                    <Ellipse Width="8" Height="8" Name="dotWslStatus" Fill="#a6e3a1" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Name="txtWslRunState" Text="Running" Foreground="#a6e3a1" FontSize="11" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock Name="txtWslUptime" Text="" Foreground="#6c7086" FontSize="9"/>
                                <TextBlock Name="txtWslVersion" Text="WSL 2" Foreground="#6c7086" FontSize="9"/>
                            </StackPanel>

                            <!-- WSL action buttons (kleine knoppen verticaal) -->
                            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="8,0,12,0">
                                <Button Name="btnStartMain" Style="{StaticResource SmallGreenBtn}" ToolTip="Start" Width="24" Height="22" Padding="0" Margin="0,0,0,3">
                                    <Path Data="M8,5 V19 L19,12 Z" Fill="#a6d9a0" Stretch="Uniform" Width="10" Height="10"/>
                                </Button>
                                <Button Name="btnStopMain" Style="{StaticResource SmallActionBtn}" ToolTip="Stop" Width="24" Height="22" Padding="0" Margin="0,0,0,3">
                                    <Path Data="M6,6 H18 V18 H6 Z" Fill="#b4c6ef" Stretch="Uniform" Width="9" Height="9"/>
                                </Button>
                                <Button Name="btnRemoveMain" Style="{StaticResource SmallDangerBtn}" ToolTip="Wis" Width="24" Height="22" Padding="0">
                                    <Path Data="M19,6.41 L17.59,5 L12,10.59 L6.41,5 L5,6.41 L10.59,12 L5,17.59 L6.41,19 L12,13.41 L17.59,19 L19,17.59 L13.41,12 Z"
                                          Fill="#e08a9e" Stretch="Uniform" Width="9" Height="9"/>
                                </Button>
                            </StackPanel>

                            <!-- Separator 1 -->
                            <Border Grid.Column="2" Width="1" Background="#45475a" Opacity="0.4" Margin="0,2"/>

                            <!-- Kolom 2: Details -->
                            <StackPanel Grid.Column="3" Margin="16,0,0,0">
                                <TextBlock Text="DETAILS" Foreground="#89b4fa" FontSize="9" FontWeight="Bold" Margin="0,0,0,4"/>
                                <TextBlock Name="txtDetailMem" Text="Memory: --" Foreground="#cdd6f4" FontSize="10" Margin="0,0,0,2"/>
                                <TextBlock Name="txtDetailDisk" Text="Disk: --" Foreground="#cdd6f4" FontSize="10" Margin="0,0,0,2"/>
                                <TextBlock Name="txtDetailHome" Text="" Foreground="#6c7086" FontSize="9"/>
                            </StackPanel>

                            <!-- Separator 2 -->
                            <Border Grid.Column="4" Width="1" Background="#45475a" Opacity="0.4" Margin="16,2,0,2"/>

                            <!-- Kolom 3: Pico status -->
                            <StackPanel Grid.Column="5" Margin="16,0,0,0">
                                <TextBlock Text="PICO" Foreground="#89b4fa" FontSize="9" FontWeight="Bold" Margin="0,0,0,4"/>
                                <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
                                    <Ellipse Width="8" Height="8" Name="dotPicoStatusMain" Fill="#6c7086" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                    <TextBlock Name="txtPicoStatusMain" Text="Geen Pico" Foreground="#6c7086" FontSize="10" FontWeight="SemiBold"/>
                                </StackPanel>
                                <TextBlock Name="txtPicoDescMain" Text="" Foreground="#cdd6f4" FontSize="9" Margin="0,0,0,1"/>
                                <TextBlock Name="txtPicoIdMain" Text="" Foreground="#6c7086" FontSize="9" TextTrimming="CharacterEllipsis" MaxWidth="200"/>
                            </StackPanel>
                        </Grid>
                    </Border>

                    <!-- Big action buttons + smaller buttons -->
                    <Grid Grid.Row="2" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="8"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="8"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Button Grid.Column="0" Content="&#x1F528; Build Project" Style="{StaticResource BigGreenBtn}" Name="btnBuild"/>
                        <Button Grid.Column="2" Content="&#x26A1; Pico Flashen" Style="{StaticResource BigActionBtn}" Name="btnFlash"/>
                        <StackPanel Grid.Column="4" VerticalAlignment="Stretch" Width="88">
                            <Button Content="&#x1F4BB; Terminal" Style="{StaticResource SmallActionBtn}" Name="btnTerminal" HorizontalAlignment="Stretch" Padding="8,6" FontSize="10"/>
                        </StackPanel>
                    </Grid>

                    <!-- Status bar -->
                    <Border Grid.Row="3" Background="#1e1e2e" CornerRadius="6" Padding="12,6" Margin="0,0,0,8">
                        <Grid>
                            <TextBlock Name="txtStatus" Text="Gereed." Foreground="#a6adc8" FontSize="11"/>
                            <TextBlock Name="txtStatusTime" Text="" Foreground="#585b70" FontSize="9" HorizontalAlignment="Right"/>
                        </Grid>
                    </Border>

                    <!-- Status Log (compact) -->
                    <Border Grid.Row="4" Background="#11111b" CornerRadius="8" BorderBrush="#313244" BorderThickness="1" Margin="0,0,0,6">
                        <Grid>
                            <DockPanel>
                                <Border DockPanel.Dock="Top" Background="#313244" CornerRadius="8,8,0,0" Padding="10,4">
                                    <TextBlock Text="STATUS LOG" Foreground="#585b70" FontSize="9" FontWeight="Bold"/>
                                </Border>
                                <ScrollViewer Name="svLog" VerticalScrollBarVisibility="Hidden" Padding="4">
                                    <TextBlock Name="txtLog" Text="" Foreground="#6c7086" FontSize="10"
                                               FontFamily="Consolas" TextWrapping="Wrap" Margin="4,2"/>
                                </ScrollViewer>
                            </DockPanel>
                            <Button Name="btnScrollLog" Visibility="Collapsed"
                                    HorizontalAlignment="Right" VerticalAlignment="Bottom"
                                    Margin="0,0,8,8" Width="24" Height="24"
                                    Background="#394264" BorderBrush="#585b70" BorderThickness="1"
                                    Cursor="Hand" ToolTip="Scroll naar beneden">
                                <Path Data="M7,10 L12,15 L17,10" Stroke="#b4c6ef" StrokeThickness="2" Fill="Transparent" Stretch="Uniform" Width="10" Height="8"/>
                            </Button>
                        </Grid>
                    </Border>

                    <!-- Console Output (groot) -->
                    <Border Grid.Row="5" Background="#11111b" CornerRadius="8" BorderBrush="#313244" BorderThickness="1">
                        <Grid>
                            <DockPanel>
                                <Border DockPanel.Dock="Top" Background="#313244" CornerRadius="8,8,0,0" Padding="10,4">
                                    <TextBlock Text="CONSOLE" Foreground="#585b70" FontSize="9" FontWeight="Bold"/>
                                </Border>
                                <ScrollViewer Name="svConsole" VerticalScrollBarVisibility="Hidden" Padding="4">
                                    <TextBlock Name="txtConsole" Text="" Foreground="#585b70" FontSize="9"
                                               FontFamily="Consolas" TextWrapping="Wrap" Margin="4,2"/>
                                </ScrollViewer>
                            </DockPanel>
                            <Button Name="btnScrollConsole" Visibility="Collapsed"
                                    HorizontalAlignment="Right" VerticalAlignment="Bottom"
                                    Margin="0,0,8,8" Width="24" Height="24"
                                    Background="#394264" BorderBrush="#585b70" BorderThickness="1"
                                    Cursor="Hand" ToolTip="Scroll naar beneden">
                                <Path Data="M7,10 L12,15 L17,10" Stroke="#b4c6ef" StrokeThickness="2" Fill="Transparent" Stretch="Uniform" Width="10" Height="8"/>
                            </Button>
                        </Grid>
                    </Border>
                </Grid>
            </Border>
        </Grid>
        <!-- ========== CUSTOM DIALOG OVERLAY ========== -->
        <Border Name="dialogOverlay" Grid.ColumnSpan="2" Background="#CC11111b" Visibility="Collapsed"
                HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
            <Border Name="dialogCard" Background="#1e1e2e" CornerRadius="12" Padding="28,24"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    MinWidth="380" MaxWidth="520"
                    BorderBrush="#45475a" BorderThickness="1">
                <Border.Effect>
                    <DropShadowEffect Color="#11111b" BlurRadius="30" ShadowDepth="4" Opacity="0.6"/>
                </Border.Effect>
                <StackPanel>
                    <!-- Icon + Title -->
                    <StackPanel Orientation="Horizontal" Margin="0,0,0,12">
                        <TextBlock Name="dialogIcon" FontSize="22" VerticalAlignment="Center" Margin="0,0,10,0"/>
                        <TextBlock Name="dialogTitle" FontSize="16" FontWeight="Bold" Foreground="#cdd6f4" VerticalAlignment="Center"/>
                    </StackPanel>
                    <!-- Message -->
                    <TextBlock Name="dialogMessage" Foreground="#bac2de" FontSize="13" TextWrapping="Wrap" Margin="0,0,0,20" LineHeight="20"/>
                    <!-- Buttons -->
                    <StackPanel Name="dialogButtons" Orientation="Horizontal" HorizontalAlignment="Right"/>
                </StackPanel>
            </Border>
        </Border>
    </Grid>
</Window>
"@

# Parse XAML
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Get controls
$dgDistros = $window.FindName("dgDistros")
$dgPicos = $window.FindName("dgPicos")
$btnInstall = $window.FindName("btnInstall")
$btnPico = $window.FindName("btnPico")
$btnCloneRepo = $window.FindName("btnCloneRepo")
$btnUnlinkProject = $window.FindName("btnUnlinkProject")
$btnTerminal = $window.FindName("btnTerminal")
$btnBuild = $window.FindName("btnBuild")
$btnFlash = $window.FindName("btnFlash")
$btnInstallWSL = $window.FindName("btnInstallWSL")
$pnlWslMissing = $window.FindName("pnlWslMissing")
$txtWslError = $window.FindName("txtWslError")
$pnlMainContent = $window.FindName("pnlMainContent")
$pnlLoading = $window.FindName("pnlLoading")
$chkVirtualization = $window.FindName("chkVirtualization")
$chkWsl = $window.FindName("chkWsl")
$chkDistro = $window.FindName("chkDistro")
$chkProject = $window.FindName("chkProject")
$chkUsbipd = $window.FindName("chkUsbipd")
$chkInit = $window.FindName("chkInit")
$txtLoadingHint = $window.FindName("txtLoadingHint")
$picoIcon = [char]::ConvertFromUtf32(0x1F50C)
$txtStatus = $window.FindName("txtStatus")
$txtStatusTime = $window.FindName("txtStatusTime")
$txtLog = $window.FindName("txtLog")
$txtConsole = $window.FindName("txtConsole")
$svLog = $window.FindName("svLog")
$svConsole = $window.FindName("svConsole")
$btnScrollLog = $window.FindName("btnScrollLog")
$btnScrollConsole = $window.FindName("btnScrollConsole")
# Sidebar controls
$txtProjectName = $window.FindName("txtProjectName")
$txtProjectPath = $window.FindName("txtProjectPath")
$txtProjectStatus = $window.FindName("txtProjectStatus")
# Main status panel controls
$txtSelectedDistro = $window.FindName("txtSelectedDistro")
$dotWslStatus = $window.FindName("dotWslStatus")
$txtWslRunState = $window.FindName("txtWslRunState")
$txtWslUptime = $window.FindName("txtWslUptime")
$txtWslVersion = $window.FindName("txtWslVersion")
$txtDetailMem = $window.FindName("txtDetailMem")
$txtDetailDisk = $window.FindName("txtDetailDisk")
$txtDetailHome = $window.FindName("txtDetailHome")
$dotPicoStatusMain = $window.FindName("dotPicoStatusMain")
$txtPicoStatusMain = $window.FindName("txtPicoStatusMain")
$txtPicoDescMain = $window.FindName("txtPicoDescMain")
$txtPicoIdMain = $window.FindName("txtPicoIdMain")
$btnOpenFolder = $window.FindName("btnOpenFolder")
$txtProjectAuthor = $window.FindName("txtProjectAuthor")
$linkProjectAuthor = $window.FindName("linkProjectAuthor")
$linkProjectAuthor.Add_RequestNavigate({
    param($s, $e)
    Start-Process $e.Uri.AbsoluteUri
    $e.Handled = $true
})
$dotUpdate = $window.FindName("dotUpdate")
# Dialog overlay controls
$dialogOverlay = $window.FindName("dialogOverlay")
$dialogCard = $window.FindName("dialogCard")
$dialogIcon = $window.FindName("dialogIcon")
$dialogTitle = $window.FindName("dialogTitle")
$dialogMessage = $window.FindName("dialogMessage")
$dialogButtons = $window.FindName("dialogButtons")
$btnStartMain = $window.FindName("btnStartMain")
$btnStopMain = $window.FindName("btnStopMain")
$btnRemoveMain = $window.FindName("btnRemoveMain")
# Aliases for compatibility
$btnStart = $btnStartMain
$btnStop = $btnStopMain
$btnRemove = $btnRemoveMain
$btnRefresh = $window.FindName("btnRefresh")

# ========== CUSTOM DIALOG SYSTEM ==========
# Vervangt alle standaard MessageBox-aanroepen met een gestylede overlay

function Show-CustomDialog {
    param(
        [string]$Message,
        [string]$Title = "Melding",
        [ValidateSet("OK","YesNo","YesNoCancel")]
        [string]$Buttons = "OK",
        [ValidateSet("Info","Warning","Question","Error","Success")]
        [string]$Type = "Info"
    )

    # Icon en kleur per type
    $iconMap = @{
        "Info"     = @{ Icon = [char]0x2139;  Color = "#89b4fa" }
        "Warning"  = @{ Icon = [char]0x26A0;  Color = "#f9e2af" }
        "Question" = @{ Icon = "?";           Color = "#cba6f7" }
        "Error"    = @{ Icon = [char]0x274C;  Color = "#f38ba8" }
        "Success"  = @{ Icon = [char]0x2705;  Color = "#a6e3a1" }
    }
    $iconInfo = $iconMap[$Type]
    $dialogIcon.Text = $iconInfo.Icon
    $dialogIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($iconInfo.Color)
    $dialogTitle.Text = $Title
    $dialogTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($iconInfo.Color)

    # Bericht met newline-support
    $dialogMessage.Text = $Message -replace '`n', "`n"

    # Knoppen opbouwen
    $dialogButtons.Children.Clear()
    $script:dialogResult = $null

    # Knop-stijl helper
    $makeBtn = {
        param($Text, $Result, $BgColor, $FgColor, $IsPrimary)
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $Text
        $btn.MinWidth = 90
        $btn.Padding = "16,8"
        $btn.Margin = "6,0,0,0"
        $btn.FontSize = 12
        $btn.FontWeight = if ($IsPrimary) { "SemiBold" } else { "Normal" }
        $btn.Cursor = [System.Windows.Input.Cursors]::Hand
        $btn.BorderThickness = [System.Windows.Thickness]::new(0)

        # Custom template met rounded corners
        $template = [System.Windows.Markup.XamlReader]::Parse(@"
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button">
    <Border Name="bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
            <Setter TargetName="bd" Property="Opacity" Value="0.85"/>
        </Trigger>
    </ControlTemplate.Triggers>
</ControlTemplate>
"@)
        $btn.Template = $template
        $btn.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom($BgColor)
        $btn.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($FgColor)

        $btn.Tag = $Result
        $btn.Add_Click({
            $script:dialogResult = $this.Tag
            # Fade-out
            $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
            $fadeOut.From = 1.0
            $fadeOut.To = 0.0
            $fadeOut.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150))
            $fadeOut.Add_Completed({ $dialogOverlay.Visibility = "Collapsed"; $dialogOverlay.Opacity = 1.0 })
            $dialogOverlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeOut)
        })
        return $btn
    }

    switch ($Buttons) {
        "OK" {
            $dialogButtons.Children.Add((& $makeBtn "OK" "OK" "#89b4fa" "#1e1e2e" $true)) | Out-Null
        }
        "YesNo" {
            $dialogButtons.Children.Add((& $makeBtn "Nee" "No" "#45475a" "#cdd6f4" $false)) | Out-Null
            $dialogButtons.Children.Add((& $makeBtn "Ja" "Yes" "#89b4fa" "#1e1e2e" $true)) | Out-Null
        }
        "YesNoCancel" {
            $dialogButtons.Children.Add((& $makeBtn "Annuleren" "Cancel" "#45475a" "#cdd6f4" $false)) | Out-Null
            $dialogButtons.Children.Add((& $makeBtn "Nee" "No" "#585b70" "#cdd6f4" $false)) | Out-Null
            $dialogButtons.Children.Add((& $makeBtn "Ja" "Yes" "#89b4fa" "#1e1e2e" $true)) | Out-Null
        }
    }

    # Fade-in
    $dialogOverlay.Opacity = 0
    $dialogOverlay.Visibility = "Visible"
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0.0
    $fadeIn.To = 1.0
    $fadeIn.Duration = [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200))
    $dialogOverlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)

    # Blokkeer tot gebruiker klikt (WPF dispatcher loop)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $checkTimer = New-Object System.Windows.Threading.DispatcherTimer
    $checkTimer.Interval = [TimeSpan]::FromMilliseconds(50)
    $checkTimer.Add_Tick({
        if ($null -ne $script:dialogResult) {
            $checkTimer.Stop()
            $frame.Continue = $false
        }
    })
    $checkTimer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)

    return $script:dialogResult
}

# Update distro buttons when selection changes
$dgDistros.Add_SelectionChanged({ Update-DistroButtons; Update-StatusPanel })

# Refresh button: refresh distro list
$btnRefresh.Add_Click({ Refresh-Distros; Update-StatusPanel })

# Open project folder in Windows Explorer
$btnOpenFolder.Add_Click({
    $projectPath = Get-ProjectPath
    if ($projectPath -and (Test-Path $projectPath)) {
        Start-Process explorer.exe -ArgumentList $projectPath
    }
})

# Wire main panel WSL buttons to same handlers as sidebar buttons
$btnStartMain.Add_Click({
    $selected = $dgDistros.SelectedItem
    if (-not $selected) { return }
    $distroName = $selected.Name
    Write-Log "Distro starten: $distroName..."
    & wsl -d $distroName -- echo "WSL gestart" 2>&1 | Out-Null
    Write-Log "Distro $distroName is gestart."
    Refresh-Distros
    Update-StatusPanel
})

$btnStopMain.Add_Click({
    $selected = $dgDistros.SelectedItem
    if (-not $selected) { return }
    $distroName = $selected.Name
    Write-Log "Distro stoppen: $distroName..."
    & wsl --terminate $distroName 2>&1 | Out-Null
    Write-Log "Distro $distroName is gestopt."
    Refresh-Distros
    Update-StatusPanel
})

# Function to toggle UI between WSL-missing and normal mode
function Update-WslPresence {
    # Re-check WSL state
    $script:wslState = Test-WslState
    $script:wslInstalled = $script:wslState.ok

    if ($script:wslInstalled) {
        $pnlWslMissing.Visibility = "Collapsed"
        $pnlMainContent.Visibility = "Visible"
        # Re-detect distro name
        $script:dspDistro = Find-UbuntuDistro
        if (-not $script:dspDistro) { $script:dspDistro = "Ubuntu-24.04" }
        # Update sidebar info
        Update-ProjectInfo
        Update-WorkflowContext
    } else {
        $pnlWslMissing.Visibility = "Visible"
        $pnlMainContent.Visibility = "Collapsed"
        # Show specific reason in the banner
        $reason = $script:wslState.reason
        $txtWslError.Text = [char]0x26A0 + " $reason"
        Write-Log $reason

        # Adjust button text based on what's needed
        if ($script:wslState.needsVMPlatform) {
            $btnInstallWSL.Content = "VM Platform Inschakelen"
        } elseif ($script:wslState.needsInstall) {
            $btnInstallWSL.Content = "WSL Installeren"
        } else {
            $btnInstallWSL.Content = "WSL Repareren"
        }
    }
}

# Config file for persistent settings (same folder as script)
$configFile = Join-Path $scriptDir "WSL-Manager.conf"

function Save-ProjectPath {
    param([string]$Path)
    Set-Content -Path $configFile -Value "ProjectPath=$Path" -Encoding UTF8
}

function Get-ProjectPath {
    if (Test-Path $configFile) {
        $content = Get-Content $configFile -ErrorAction SilentlyContinue
        foreach ($line in $content) {
            if ($line -match "^ProjectPath=(.+)$") {
                $savedPath = $Matches[1]
                if (Test-Path $savedPath) {
                    return $savedPath
                }
            }
        }
    }
    return $null
}

function Update-TerminalButton {
    # Niet aanraken als er een build/flash bezig is
    if ($script:buildInProgress) { return }

    $projectPath = Get-ProjectPath
    # Gebruik de WSL running-status uit Update-StatusPanel
    $wslRunning = $script:wslIsRunning -eq $true

    if (-not $projectPath) {
        $btnTerminal.IsEnabled = $false
        $btnTerminal.ToolTip = "Haal eerst het DSP project op"
        $btnBuild.IsEnabled = $false
        $btnBuild.ToolTip = "Haal eerst het DSP project op"
        $btnFlash.IsEnabled = $false
        $btnFlash.ToolTip = "Haal eerst het DSP project op"
    } elseif (-not $wslRunning) {
        $btnTerminal.IsEnabled = $false
        $btnTerminal.ToolTip = "Start eerst de WSL distro"
        $btnBuild.IsEnabled = $false
        $btnBuild.ToolTip = "Start eerst de WSL distro"
        $btnFlash.IsEnabled = $false
        $btnFlash.ToolTip = "Start eerst de WSL distro"
    } else {
        $btnTerminal.IsEnabled = $true
        $btnTerminal.ToolTip = "Open terminal in: $projectPath"
        $btnBuild.IsEnabled = $true
        $btnBuild.ToolTip = "Build project in: $projectPath"
        # Flash wordt apart beheerd door Update-PicoButton (alleen aan als Pico gekoppeld)
    }
}

# Update the sidebar project info card
function Update-ProjectInfo {
    # Gebruik de WSL running-status uit Update-StatusPanel
    $wslRunning = $script:wslIsRunning -eq $true

    $projectPath = Get-ProjectPath
    if ($projectPath) {
        $folderName = Split-Path $projectPath -Leaf
        $txtProjectName.Text = $folderName
        $txtProjectPath.Text = $projectPath
        $txtProjectStatus.Text = "Gekoppeld"
        $txtProjectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#a6e3a1")
        $btnUnlinkProject.Visibility = "Visible"
        $btnOpenFolder.Visibility = "Visible"
        $txtProjectAuthor.Visibility = "Visible"
        $btnCloneRepo.Visibility = "Collapsed"
    } else {
        $txtProjectName.Text = "Geen project"
        if ($wslRunning) {
            $txtProjectPath.Text = "Klik 'Koppelen' om te starten"
            $btnCloneRepo.IsEnabled = $true
        } else {
            $txtProjectPath.Text = "Start WSL om een project te koppelen"
            $btnCloneRepo.IsEnabled = $false
        }
        $txtProjectStatus.Text = "Niet geconfigureerd"
        $txtProjectStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f38ba8")
        $btnUnlinkProject.Visibility = "Collapsed"
        $txtProjectAuthor.Visibility = "Collapsed"
        $btnOpenFolder.Visibility = "Collapsed"
        $btnCloneRepo.Visibility = "Visible"
    }
}

# Update the main status panel (3-column: WSL, Details, Project)
function Update-StatusPanel {
    # Selected distro title
    $selected = $dgDistros.SelectedItem
    if ($selected) {
        $txtSelectedDistro.Text = $selected.Name
    } elseif ($script:dspDistro) {
        $txtSelectedDistro.Text = $script:dspDistro
    } else {
        $txtSelectedDistro.Text = "Geen distro"
    }

    # WSL status column
    $wslRunning = $false
    if ($script:wslInstalled -and $selected) {
        $wslOut = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
        $distroName = $selected.Name
        if ($wslOut -match "$([regex]::Escape($distroName))\s+Running") {
            $wslRunning = $true
        }
    }

    # Keep-alive: als WSL eerder draaide maar nu gestopt is, herstart automatisch
    if (-not $wslRunning -and $script:wslIsRunning -and $script:wslInstalled -and $selected) {
        Write-Log "WSL distro '$($selected.Name)' is gestopt — wordt automatisch herstart..."
        try {
            & wsl -d $selected.Name -- echo "keepalive" 2>&1 | Out-Null
            $wslRunning = $true
            Write-Log "WSL distro '$($selected.Name)' succesvol herstart."
        } catch {
            Write-Log "WSL herstart mislukt: $_"
        }
    }

    $script:wslIsRunning = $wslRunning
    $greenBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#a6e3a1")
    $grayBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#6c7086")
    $redBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f38ba8")

    if ($wslRunning) {
        $dotWslStatus.Fill = $greenBrush
        $txtWslRunState.Text = "Running"
        $txtWslRunState.Foreground = $greenBrush

        # Uptime ophalen via /proc/uptime
        try {
            $uptimeRaw = (& wsl -d $selected.Name -- cat /proc/uptime 2>&1 | Out-String).Trim()
            if ($uptimeRaw -match '^([\d\.]+)') {
                $uptimeSec = [int][double]$Matches[1]
                $days = [math]::Floor($uptimeSec / 86400)
                $hours = [math]::Floor(($uptimeSec % 86400) / 3600)
                $mins = [math]::Floor(($uptimeSec % 3600) / 60)
                if ($days -gt 0) {
                    $txtWslUptime.Text = "Uptime: ${days}d ${hours}u ${mins}m"
                } elseif ($hours -gt 0) {
                    $txtWslUptime.Text = "Uptime: ${hours}u ${mins}m"
                } else {
                    $txtWslUptime.Text = "Uptime: ${mins}m"
                }
            } else {
                $txtWslUptime.Text = ""
            }
        } catch {
            $txtWslUptime.Text = ""
        }

        # Memory info ophalen via /proc/meminfo (WSL gebruikt)
        try {
            $memRaw = (& wsl -d $selected.Name -- cat /proc/meminfo 2>&1 | Out-String)
            $memTotal = 0; $memAvail = 0
            if ($memRaw -match 'MemTotal:\s+(\d+)') { $memTotal = [long]$Matches[1] }
            if ($memRaw -match 'MemAvailable:\s+(\d+)') { $memAvail = [long]$Matches[1] }
            if ($memTotal -gt 0) {
                $memUsedGB = [math]::Round(($memTotal - $memAvail) / 1048576, 1)
                $txtDetailMem.Text = "Memory: ${memUsedGB} GB in gebruik"
            } else {
                $txtDetailMem.Text = "Memory: --"
            }
        } catch {
            $txtDetailMem.Text = "Memory: --"
        }

        # Disk info ophalen via df
        try {
            $dfRaw = (& wsl -d $selected.Name -- df -BG / 2>&1 | Out-String) -replace '\x00', ''
            $dfLines = $dfRaw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch '^Filesystem' }
            $matched = $false
            foreach ($dfLine in $dfLines) {
                if ($dfLine -match '(\d+)G\s+(\d+)G\s+(\d+)G\s+(\d+)%') {
                    $diskUsed = $Matches[2]
                    $txtDetailDisk.Text = "Disk: ${diskUsed} GB in gebruik"
                    $matched = $true
                    break
                }
            }
            if (-not $matched) { $txtDetailDisk.Text = "Disk: --" }
        } catch {
            $txtDetailDisk.Text = "Disk: --"
        }

        # Home directory
        try {
            $homePath = (& wsl -d $selected.Name -- bash -c 'echo $HOME' 2>&1 | Out-String).Trim()
            if ($homePath) {
                $txtDetailHome.Text = $homePath
            } else {
                $txtDetailHome.Text = "/home/student"
            }
        } catch {
            $txtDetailHome.Text = "/home/student"
        }

    } else {
        $dotWslStatus.Fill = $grayBrush
        $txtWslRunState.Text = "Stopped"
        $txtWslRunState.Foreground = $grayBrush
        $txtWslUptime.Text = ""
        $txtDetailMem.Text = "Memory: --"
        $txtDetailDisk.Text = "Disk: --"
        $txtDetailHome.Text = ""
    }

    if ($selected) {
        $txtWslVersion.Text = "WSL $($selected.Version)"
    }

    # Pico column — show selected or first attached Pico
    $yellowBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f9e2af")
    $selectedPico = $dgPicos.SelectedItem
    if (-not $selectedPico -and $dgPicos.Items.Count -gt 0) {
        $selectedPico = $dgPicos.Items[0]
    }
    if ($selectedPico) {
        $txtPicoDescMain.Text = $selectedPico.Desc
        $txtPicoIdMain.Text = $selectedPico.Id
        if ($selectedPico.Status -eq "Gekoppeld aan WSL") {
            $dotPicoStatusMain.Fill = $greenBrush
            $txtPicoStatusMain.Text = "Gekoppeld"
            $txtPicoStatusMain.Foreground = $greenBrush
        } elseif ($selectedPico.Status -eq "Alleen Windows") {
            $dotPicoStatusMain.Fill = $yellowBrush
            $txtPicoStatusMain.Text = "Alleen Windows"
            $txtPicoStatusMain.Foreground = $yellowBrush
        } else {
            $dotPicoStatusMain.Fill = $grayBrush
            $txtPicoStatusMain.Text = $selectedPico.Status
            $txtPicoStatusMain.Foreground = $grayBrush
        }
    } else {
        $dotPicoStatusMain.Fill = $grayBrush
        $txtPicoStatusMain.Text = "Geen Pico"
        $txtPicoStatusMain.Foreground = $grayBrush
        $txtPicoDescMain.Text = ""
        $txtPicoIdMain.Text = ""
    }
}

# Compatibility wrapper — old code calls Update-WorkflowContext
function Update-WorkflowContext {
    Update-StatusPanel
}

# Distro management buttons: only active when a distro is selected
function Update-DistroButtons {
    $selected = $dgDistros.SelectedItem
    $hasSelection = $null -ne $selected
    $btnStart.IsEnabled = $hasSelection
    $btnStop.IsEnabled = $hasSelection
    $btnRemove.IsEnabled = $hasSelection
}

# Log file in same directory as script
$logFile = Join-Path $scriptDir "WSL-Setup.log"

# Helper: check if current session is elevated (admin)
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# Script-level variabele waarop callers de laatste elevated exit code kunnen nalezen.
# 0 = success, 1 = exception in elevated script, -2 = UAC geweigerd / elevatie-fout,
# -3 = Start-Process gaf geen process terug, anders = raw exit code van powershell.
$script:lastElevatedExitCode = 0

# Helper: ruim orphaned usbipd.exe --auto-attach watchers op die zijn achtergebleven
# uit eerdere (of gecrashte) sessies van deze app. De watchers blijven doordraaien
# omdat ze als onafhankelijke background processes gestart worden.
# $Silent=$true onderdrukt Write-Log calls (bv. tijdens startup-fase voor Write-Log bestaat).
# $NoElevation=$true slaat de UAC-fallback voor admin-owned processes over (voor close-handler).
function Stop-OrphanedAutoAttach {
    param(
        [bool]$Silent = $false,
        [bool]$NoElevation = $false
    )
    try {
        $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name='usbipd.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -and $_.CommandLine -match '--auto-attach' }
        if (-not $procs) { return 0 }

        $procIds = @($procs | ForEach-Object { $_.ProcessId })
        $killedLocal = @()
        $needElevated = @()

        foreach ($procId in $procIds) {
            try {
                Stop-Process -Id $procId -Force -ErrorAction Stop
                $killedLocal += $procId
            } catch {
                # Meestal admin-owned (gestart via elevated shell) — escaleren nodig.
                $needElevated += $procId
            }
        }

        if ($needElevated.Count -gt 0 -and -not $NoElevation) {
            # Één enkele elevated taskkill batch — voorkomt meerdere UAC prompts.
            $idArgs = ($needElevated | ForEach-Object { "/PID $_" }) -join ' '
            try {
                Start-Process -FilePath "taskkill.exe" `
                    -ArgumentList "/F $idArgs" `
                    -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction Stop | Out-Null
                $killedLocal += $needElevated
            } catch {
                if (-not $Silent -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
                    Write-Log "[Cleanup] Kon $($needElevated.Count) admin-owned usbipd-watcher(s) niet killen — UAC geweigerd?"
                }
            }
        }

        if (-not $Silent -and $killedLocal.Count -gt 0 -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            Write-Log "[Cleanup] $($killedLocal.Count) orphaned usbipd --auto-attach process(en) opgeruimd."
        }
        return $killedLocal.Count
    } catch {
        return 0
    }
}

# Helper: run a command as administrator (elevated) and capture output
# Uses a temp script + output file since elevated processes can't pipe back to the caller
function Invoke-Elevated {
    param([string]$Command)
    $script:lastElevatedExitCode = -1
    $outputFile = Join-Path $env:TEMP "wsl-admin-output.txt"
    $scriptFile = Join-Path $env:TEMP "wsl-admin-cmd.ps1"
    Remove-Item $outputFile -ErrorAction SilentlyContinue
    Remove-Item $scriptFile -ErrorAction SilentlyContinue

    # Fix 1: Vervang kale 'usbipd' door het absolute pad, omdat het Admin account vaak
    # een ander PATH heeft. Negative lookahead (?!\.exe) voorkomt dat we 'usbipd.exe'
    # binnen b.v. 'Start-Process usbipd.exe ...' ook vervangen (wat brak script opleverde).
    $cmdText = $Command
    $usbipdCmd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
    if ($usbipdCmd) {
        $cmdText = $cmdText -replace '\busbipd(?!\.exe)\b', "& '$($usbipdCmd.Source)'"
    }

    # Fix 3: Als de app al elevated draait, hoeven we geen UAC prompt te tonen —
    # run in-process via Invoke-Expression. Scheelt de dubbele UAC prompt en maakt
    # ook duidelijk dat 'app als admin starten' een geldige fallback is.
    if (Test-IsAdmin) {
        $lines = @()
        try {
            $out = Invoke-Expression $cmdText 2>&1
            $lines = @($out | ForEach-Object { "$_" })
            $script:lastElevatedExitCode = 0
        } catch {
            $lines = @("[Fout] $($_.Exception.Message)")
            $script:lastElevatedExitCode = 1
        }
        return $lines
    }

    # Write a small script that runs the command and captures all output.
    # $ErrorActionPreference = 'SilentlyContinue' voorkomt dat PowerShell de stderr
    # output van native tools (zoals de info-berichten van usbipd) als NativeCommandError
    # wrapt en naar het outputfile schrijft. We vangen echte errors via try/catch.
    $scriptContent = @"
`$ErrorActionPreference = 'SilentlyContinue'
try {
    `$(
        $cmdText
    ) *>&1 | Out-File -FilePath '$outputFile' -Encoding UTF8 -Append
    exit 0
} catch {
    `$_.Exception.Message | Out-File -FilePath '$outputFile' -Encoding UTF8 -Append
    exit 1
}
"@
    Set-Content -Path $scriptFile -Value $scriptContent -Encoding UTF8

    # Fix 2: -WindowStyle Hidden is verwijderd. Deze vlag blokkeert op veel pc's stilletjes de UAC prompt!
    # Fix 4: -ErrorAction Stop i.p.v. SilentlyContinue zodat we UAC-weigering kunnen detecteren.
    $proc = $null
    try {
        $proc = Start-Process powershell.exe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`"" `
            -Verb RunAs -Wait -PassThru -ErrorAction Stop
    } catch {
        $script:lastElevatedExitCode = -2
        Remove-Item $scriptFile -ErrorAction SilentlyContinue
        return @("[Elevatie mislukt of geweigerd] $($_.Exception.Message)")
    }

    $lines = @()
    if (Test-Path $outputFile) {
        $lines = Get-Content $outputFile -Encoding UTF8 -ErrorAction SilentlyContinue
        Remove-Item $outputFile -ErrorAction SilentlyContinue
    }
    Remove-Item $scriptFile -ErrorAction SilentlyContinue

    if ($proc) { $script:lastElevatedExitCode = $proc.ExitCode } else { $script:lastElevatedExitCode = -3 }
    return $lines
}

# Helper: check if ScrollViewer is at the bottom
function Test-ScrollAtBottom {
    param($sv)
    if ($sv.ExtentHeight -le $sv.ViewportHeight) { return $true }
    return ($sv.VerticalOffset + $sv.ViewportHeight) -ge ($sv.ExtentHeight - 5)
}

# Helper: log message (GUI Status Log + status bar + file)
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    try { Add-Content -Path $logFile -Value $logLine -Encoding UTF8 } catch {}
    $wasAtBottom = Test-ScrollAtBottom $svLog
    $txtLog.Text += "$logLine`n"
    if ($wasAtBottom) { $svLog.UpdateLayout(); $svLog.ScrollToEnd() }
    $txtStatus.Text = $Message
    $txtStatusTime.Text = (Get-Date -Format "HH:mm:ss")
}

# Helper: verbose console output (GUI Console panel + file)
function Write-Console {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    try { Add-Content -Path $logFile -Value $logLine -Encoding UTF8 } catch {}
    $wasAtBottom = Test-ScrollAtBottom $svConsole
    $txtConsole.Text += "$logLine`n"
    if ($wasAtBottom) { $svConsole.UpdateLayout(); $svConsole.ScrollToEnd() }
}

# Scroll-down button visibility: show when not at bottom
$svLog.Add_ScrollChanged({
    if (Test-ScrollAtBottom $svLog) {
        $btnScrollLog.Visibility = "Collapsed"
    } else {
        $btnScrollLog.Visibility = "Visible"
    }
})

$svConsole.Add_ScrollChanged({
    if (Test-ScrollAtBottom $svConsole) {
        $btnScrollConsole.Visibility = "Collapsed"
    } else {
        $btnScrollConsole.Visibility = "Visible"
    }
})

# Scroll-down button click handlers
$btnScrollLog.Add_Click({ $svLog.ScrollToEnd() })
$btnScrollConsole.Add_Click({ $svConsole.ScrollToEnd() })

# Helper: status bar tekst direct zetten + in status log opnemen
function Set-Status {
    param([string]$Message)
    Write-Log $Message
}

# Install progress timer — shows elapsed time so user knows the system isn't frozen
$script:installStartTime = $null
$script:installBaseText = ""
$installTimer = New-Object System.Windows.Threading.DispatcherTimer
$installTimer.Interval = [TimeSpan]::FromSeconds(2)
$installTimer.Add_Tick({
    if ($script:installStartTime) {
        $elapsed = [int]((Get-Date) - $script:installStartTime).TotalSeconds
        $min = [math]::Floor($elapsed / 60)
        $sec = $elapsed % 60
        $timeStr = if ($min -gt 0) { "{0}m {1:D2}s" -f $min, $sec } else { "${sec}s" }
        $txtStatus.Text = "$($script:installBaseText) ($timeStr verstreken)"
    }
})

function Start-InstallTimer {
    param([string]$BaseText = "Bezig met installeren...")
    $script:installStartTime = Get-Date
    $script:installBaseText = $BaseText
    $txtStatus.Text = "$BaseText (0s verstreken)"
    $installTimer.Start()
}

function Stop-InstallTimer {
    $installTimer.Stop()
    $script:installStartTime = $null
}

# ===== BACKGROUND TASK INFRASTRUCTURE =====
# Runs long operations in a background runspace so the WPF UI stays responsive.
# Uses a synchronized hashtable + ConcurrentQueues for thread-safe message passing.
# A DispatcherTimer on the UI thread polls for messages and completion.

$script:bgRunspace = $null
$script:bgPowerShell = $null
$script:bgSync = $null
$script:bgOnComplete = $null

$bgPollTimer = New-Object System.Windows.Threading.DispatcherTimer
$bgPollTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$bgPollTimer.Add_Tick({
    if (-not $script:bgSync) { return }
    # Drain console messages
    $msg = $null
    while ($script:bgSync.ConsoleQueue.TryDequeue([ref]$msg)) {
        Write-Console $msg
    }
    # Drain status messages
    while ($script:bgSync.StatusQueue.TryDequeue([ref]$msg)) {
        Write-Log $msg
    }
    # Drain status-bar-only messages (no log, e.g. percentage ticks)
    while ($script:bgSync.StatusBarQueue.TryDequeue([ref]$msg)) {
        $txtStatus.Text = $msg
    }
    # Check completion
    if ($script:bgSync.Done) {
        $bgPollTimer.Stop()
        $callback = $script:bgOnComplete
        $success = $script:bgSync.Success
        $errorMsg = $script:bgSync.Error
        $resultData = $script:bgSync.ResultData
        # Cleanup runspace
        try {
            if ($script:bgPowerShell) { $script:bgPowerShell.Dispose() }
            if ($script:bgRunspace) { $script:bgRunspace.Dispose() }
        } catch {}
        $script:bgPowerShell = $null
        $script:bgRunspace = $null
        $script:bgSync = $null
        $script:bgOnComplete = $null
        # Invoke completion callback on UI thread
        if ($callback) { & $callback $success $errorMsg $resultData }
    }
})

function Start-BackgroundTask {
    param(
        [scriptblock]$Work,           # Scriptblock to run in background. Receives $sync hashtable.
        [scriptblock]$OnComplete,     # Callback(bool $success, string $error, object $resultData) on UI thread
        [hashtable]$Parameters = @{}  # Extra parameters to pass to the runspace
    )

    # Create synchronized hashtable for communication
    $script:bgSync = [hashtable]::Synchronized(@{
        ConsoleQueue  = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        StatusQueue   = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        StatusBarQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        Done          = $false
        Success       = $false
        Error         = ""
        ResultData    = $null
    })
    $script:bgOnComplete = $OnComplete

    # Create runspace
    $script:bgRunspace = [runspacefactory]::CreateRunspace()
    $script:bgRunspace.ApartmentState = "STA"
    $script:bgRunspace.Open()

    # Create PowerShell instance
    $script:bgPowerShell = [powershell]::Create()
    $script:bgPowerShell.Runspace = $script:bgRunspace

    # The background script wraps the user work in a try/catch
    $wrapperScript = {
        param($sync, $work, $extraParams)
        try {
            # Define helper functions accessible in the runspace
            function BG-Console { param([string]$Message); $sync.ConsoleQueue.Enqueue($Message) }
            function BG-Status { param([string]$Message); $sync.StatusQueue.Enqueue($Message) }
            function BG-StatusBar { param([string]$Message); $sync.StatusBarQueue.Enqueue($Message) }

            # Execute the actual work
            $sb = [scriptblock]::Create($work)
            & $sb $sync $extraParams
            if (-not $sync.Done) {
                $sync.Success = $true
                $sync.Done = $true
            }
        } catch {
            $sync.Error = "$_"
            $sync.Success = $false
            $sync.Done = $true
        }
    }

    $script:bgPowerShell.AddScript($wrapperScript).
        AddArgument($script:bgSync).
        AddArgument($Work.ToString()).
        AddArgument($Parameters) | Out-Null

    # Start background work + polling timer
    $script:bgPowerShell.BeginInvoke() | Out-Null
    $bgPollTimer.Start()
}

# Helper: refresh distro list
function Refresh-Distros {
    $dgDistros.Items.Clear()
    if (-not $script:wslInstalled) {
        Write-Log "WSL niet beschikbaar — distro lijst overgeslagen."
        return
    }
    Write-Log "Distro's ophalen..."

    $output = & wsl --list --verbose 2>&1 | Out-String
    # Clean up UTF-16LE encoding issues (wsl outputs null bytes)
    $output = $output -replace '\x00', ''
    $lines = $output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    $headerSkipped = $false
    foreach ($line in $lines) {
        if (-not $headerSkipped) {
            # Support both English (NAME STATE VERSION) and Dutch (NAAM STATUS VERSIE) headers
            if ($line -match "^\s*(NAME|NAAM)\s+(STATE|STATUS)\s+(VERSION|VERSIE)") {
                $headerSkipped = $true
            }
            continue
        }

        $isDefault = $false
        $cleanLine = $line
        if ($cleanLine.StartsWith("*")) {
            $isDefault = $true
            $cleanLine = $cleanLine.Substring(1).TrimStart()
        }

        # Parse columns
        if ($cleanLine -match "^(\S+(?:\s\S+)*?)\s{2,}(\S+)\s{2,}(\d+)") {
            $distroName = $Matches[1]

            # Hide docker-desktop distros to avoid confusion
            if ($distroName -match "^docker-desktop") {
                continue
            }

            $item = [PSCustomObject]@{
                Name    = $distroName
                State   = $Matches[2]
                Version = $Matches[3]
                Default = if ($isDefault) { " • Default" } else { "" }
            }
            $dgDistros.Items.Add($item) | Out-Null
        }
    }

    Write-Log "$($dgDistros.Items.Count) distro('s) gevonden."

    # Auto-selecteer Ubuntu distro (of eerste beschikbare)
    if ($dgDistros.Items.Count -gt 0 -and $dgDistros.SelectedIndex -lt 0) {
        $ubuntuIdx = -1
        for ($i = 0; $i -lt $dgDistros.Items.Count; $i++) {
            if ($dgDistros.Items[$i].Name -match "Ubuntu") {
                $ubuntuIdx = $i
                break
            }
        }
        if ($ubuntuIdx -ge 0) {
            $dgDistros.SelectedIndex = $ubuntuIdx
        } else {
            $dgDistros.SelectedIndex = 0
        }
    }

    Update-DistroButtons
}

# Refresh is now triggered by distro selection change (no separate button)

# Helper: disable/enable all buttons during long operations
function Set-ButtonsEnabled {
    param([bool]$Enabled)
    $btnInstall.IsEnabled = $Enabled
    if ($btnRefresh) { $btnRefresh.IsEnabled = $Enabled }
    $btnStart.IsEnabled = $Enabled
    $btnStop.IsEnabled = $Enabled
    $btnPico.IsEnabled = $Enabled
    $btnRemove.IsEnabled = $Enabled
    $btnCloneRepo.IsEnabled = $Enabled
    $btnUnlinkProject.IsEnabled = $Enabled
    $btnTerminal.IsEnabled = $Enabled
    $btnBuild.IsEnabled = $Enabled
    # btnFlash wordt NIET hier beheerd — alleen Update-PicoButton mag deze aan/uitzetten
    # (voorkomt dat Flash bereikbaar is zonder usbipd of gekoppelde Pico)
    if ($btnStartMain) { $btnStartMain.IsEnabled = $Enabled }
    if ($btnStopMain) { $btnStopMain.IsEnabled = $Enabled }
    if ($btnRemoveMain) { $btnRemoveMain.IsEnabled = $Enabled }
    if ($btnOpenFolder) { $btnOpenFolder.IsEnabled = $Enabled }

    # When re-enabling, reapply smart states so buttons respect prerequisites
    if ($Enabled) {
        Update-TerminalButton      # disables Terminal/Build/Flash if no project
        Update-PicoButton          # disables Pico/Flash if WSL not running or no Pico attached
        Update-DistroButtons       # disables Start/Stop/Wis if no distro selected
        Update-ProjectInfo         # updates sidebar project card
        Update-WorkflowContext     # updates workflow context line
    }
}

# ============================================================
# UPDATE FUNCTIE — vergelijk lokale bestanden met GitHub
# ============================================================
$script:updateGitHubRepo = "dannyvanderzande/DSP-WSL-Manager"
$script:updateBranch = "main"
$script:updateAvailable = $false
$script:updateFiles = @()

# Bestanden die we bijhouden voor updates (relatieve paden in de repo)
# Links: repo-pad → rechts: lokaal pad relatief aan $scriptDir
$script:updateFileMap = @{
    "DSP-Manager-Core.ps1"                  = "DSP-Manager-Core.ps1"
    "Start DSP Manager.bat"                 = "Start DSP Manager.bat"
}

function Get-GitBlobSha {
    param([string]$FilePath)
    # Git blob SHA-1 = SHA1("blob <size>\0<content>")
    # Git normaliseert CRLF naar LF — we doen hetzelfde voor correcte vergelijking
    if (-not (Test-Path $FilePath)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    # Normaliseer CRLF naar LF (zoals git intern doet bij core.autocrlf)
    # BOM wordt NIET gestript — git bewaart BOM in de blob
    $normalized = [System.Collections.Generic.List[byte]]::new($bytes.Length)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 0x0D -and ($i + 1) -lt $bytes.Length -and $bytes[$i + 1] -eq 0x0A) {
            continue  # Skip CR van CRLF
        }
        $normalized.Add($bytes[$i])
    }
    $cleanBytes = $normalized.ToArray()
    $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($cleanBytes.Length)`0")
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $sha.TransformBlock($header, 0, $header.Length, $null, 0) | Out-Null
    $sha.TransformFinalBlock($cleanBytes, 0, $cleanBytes.Length) | Out-Null
    return ($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Check-ForUpdates {
    param([switch]$Manual)

    # Bypass: als update-bypass bestand bestaat, sla automatische check over
    $bypassFile = Join-Path $scriptDir "update-bypass"
    if (-not $Manual -and (Test-Path $bypassFile)) {
        Write-Log "Update check overgeslagen (update-bypass bestand gevonden)"
        return
    }

    Write-Log "Updates controleren..."
    $script:updateAvailable = $false
    $script:updateFiles = @()

    try {
        # Haal bestandslijst op van GitHub (root)
        $rootUrl = "https://api.github.com/repos/$($script:updateGitHubRepo)/contents/?ref=$($script:updateBranch)"
        $rootJson = (Invoke-WebRequest -Uri $rootUrl -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json

        # Haal ook support scripts op
        $supportUrl = "https://api.github.com/repos/$($script:updateGitHubRepo)/contents/support%20scripts?ref=$($script:updateBranch)"
        $supportJson = @()
        try { $supportJson = (Invoke-WebRequest -Uri $supportUrl -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json } catch {}

        $allFiles = @{}
        foreach ($f in $rootJson) { if ($f.type -eq "file") { $allFiles[$f.name] = $f.sha } }
        foreach ($f in $supportJson) { if ($f.type -eq "file") { $allFiles["support scripts/$($f.name)"] = $f.sha } }

        foreach ($repoPath in $script:updateFileMap.Keys) {
            $localRelPath = $script:updateFileMap[$repoPath]
            $localFullPath = Join-Path $scriptDir $localRelPath

            if ($allFiles.ContainsKey($repoPath)) {
                $remoteSha = $allFiles[$repoPath]
                $localSha = Get-GitBlobSha $localFullPath

                if ($localSha -ne $remoteSha) {
                    $script:updateFiles += @{
                        RepoPath  = $repoPath
                        LocalPath = $localFullPath
                        RemoteSha = $remoteSha
                        LocalSha  = if ($localSha) { $localSha } else { "(nieuw)" }
                    }
                }
            }
        }

        if ($script:updateFiles.Count -gt 0) {
            $script:updateAvailable = $true
            $dotUpdate.Visibility = "Visible"
            Write-Log "$($script:updateFiles.Count) update(s) beschikbaar."
        } else {
            $dotUpdate.Visibility = "Collapsed"
            Write-Log "Geen updates gevonden — alles is up-to-date."
        }
    } catch {
        Write-Log "Update check mislukt: $_"
    }
}

function Restart-App {
    param([string]$UpdateTempDir = "")
    $scriptPath = Join-Path $scriptDir "DSP-Manager-Core.ps1"
    $restartBat = Join-Path $env:TEMP "dsp-restart.bat"

    $batLines = @()
    $batLines += "@echo off"
    $batLines += "taskkill /F /PID $PID >nul 2>&1"
    $batLines += "timeout /t 2 /nobreak >nul"

    # Als er een temp update-map is, kopieer bestanden naar de doelmap
    if ($UpdateTempDir -and (Test-Path $UpdateTempDir)) {
        $batLines += "echo Updating files..."
        Get-ChildItem -Path $UpdateTempDir -File | ForEach-Object {
            $src = $_.FullName
            $dst = Join-Path $scriptDir $_.Name
            $batLines += "copy /y `"$src`" `"$dst`""
        }
        $batLines += "rmdir /s /q `"$UpdateTempDir`""
    }

    $batLines += "start `"`" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $batLines += "del `"%~f0`""

    $batContent = $batLines -join "`r`n"
    [System.IO.File]::WriteAllText($restartBat, $batContent, [System.Text.Encoding]::ASCII)
    Write-Log "Restart bat geschreven: $restartBat"
    Start-Process cmd.exe -ArgumentList "/c `"$restartBat`"" -WindowStyle Hidden
    # Bat file doet de kill via taskkill — hier alleen wachten
    Start-Sleep -Seconds 5
}

function Install-Updates {
    if ($script:updateFiles.Count -eq 0) {
        Write-Log "Geen updates om te installeren."
        return
    }

    $fileList = ($script:updateFiles | ForEach-Object { Split-Path $_.LocalPath -Leaf }) -join "`n- "

    $choice = Show-CustomDialog -Message "Er zijn $($script:updateFiles.Count) update(s) beschikbaar:`n`n- $fileList`n`nWil je deze bestanden bijwerken? De huidige versies worden overschreven." -Title "Updates Beschikbaar" -Buttons "YesNo" -Type "Question"
    if ($choice -ne "Yes") { return }

    $updatedCount = 0
    $errors = @()

    foreach ($file in $script:updateFiles) {
        $repoPath = $file.RepoPath
        $fileName = Split-Path $file.LocalPath -Leaf
        $targetPath = $file.LocalPath

        try {
            $rawUrl = "https://raw.githubusercontent.com/$($script:updateGitHubRepo)/$($script:updateBranch)/$($repoPath -replace ' ', '%20')"
            Write-Log "Bijwerken: $fileName..."
            Invoke-WebRequest -Uri $rawUrl -OutFile $targetPath -UseBasicParsing -TimeoutSec 30
            Write-Log "Bijgewerkt: $fileName"
            $updatedCount++
        } catch {
            Write-Log "Fout bij bijwerken van ${fileName}: $_"
            $errors += $fileName
        }
    }

    $script:updateAvailable = $false
    $dotUpdate.Visibility = "Collapsed"

    if ($errors.Count -eq 0) {
        Write-Log "Alle $updatedCount bestand(en) bijgewerkt."
        Show-CustomDialog -Message "Update succesvol!`n`n$updatedCount bestand(en) bijgewerkt.`nHerstart de applicatie om de update te activeren." -Title "Update Voltooid" -Buttons "OK" -Type "Success"
        $statusTimer.Stop()
        $window.Close()
    } else {
        $errList = $errors -join ", "
        Show-CustomDialog -Message "$updatedCount bestand(en) bijgewerkt, maar er waren fouten bij: $errList`n`nBekijk het logvenster voor details." -Title "Update Gedeeltelijk" -Buttons "OK" -Type "Warning"
    }
}

# Update knop: klik = installeer updates of check handmatig
$btnCheckUpdate = $window.FindName("btnCheckUpdate")

# Gedeelde update-actie voor beide knoppen
$script:doUpdateCheck = {
    if ($script:updateAvailable) {
        Install-Updates
    } else {
        Check-ForUpdates -Manual
        if (-not $script:updateAvailable) {
            Show-CustomDialog -Message "Alles is up-to-date!" -Title "Geen Updates" -Buttons "OK" -Type "Success"
        } else {
            Install-Updates
        }
    }
}

$btnCheckUpdate.Add_Click({ & $script:doUpdateCheck })

# Dev restart knop: alleen zichtbaar als update-bypass bestaat
$btnDevRestart = $window.FindName("btnDevRestart")
$bypassFile = Join-Path $scriptDir "update-bypass"
if (Test-Path $bypassFile) {
    $btnDevRestart.Visibility = "Visible"
}
$btnDevRestart.Add_Click({
    Write-Log "Handmatige herstart..."
    Restart-App
})

# Button: Install WSL (shown when WSL is not present on the system)
$btnInstallWSL.Add_Click({
    $window.Topmost = $true; $window.Topmost = $false

    # Determine what action to take based on the current WSL state
    $action = "wsl --install --no-distribution"
    $actionDesc = "WSL installeren"
    if ($script:wslState.needsVMPlatform) {
        $action = "wsl --install --no-distribution"
        $actionDesc = "Virtual Machine Platform inschakelen"
    } elseif ($script:wslState.needsBIOS) {
        Show-CustomDialog -Message "Virtualisatie (VT-x / AMD-V) moet worden ingeschakeld in het BIOS.`n`nDit kan niet automatisch worden gedaan.`n`n1. Herstart de computer`n2. Ga naar het BIOS (meestal DEL of F2 bij opstarten)`n3. Schakel Virtualization Technology in`n4. Sla op en herstart" -Title "BIOS instelling vereist" -Buttons "OK" -Type "Info"
        return
    }

    $result = Show-CustomDialog -Message "$actionDesc`n`nDit vereist administratorrechten en waarschijnlijk een herstart.`n`nDoorgaan?" -Title "Melding" -Buttons "YesNo" -Type "Question"

    if ($result -ne "Yes") { return }

    $btnInstallWSL.IsEnabled = $false
    Write-Log "$actionDesc... (dit kan even duren)"
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $wslInstallOutput = @()
    try {
        $lines = Invoke-Elevated $action
        foreach ($rawLine in $lines) {
            $line = ($rawLine -replace '\x00', '').Trim()
            if ($line) {
                Write-Console $line
                $wslInstallOutput += $line
            }
        }
    } catch {
        $errMsg = "$_"
        if ($errMsg -match "canceled|geannuleerd|user") {
            Write-Log "$actionDesc geannuleerd door gebruiker."
            Write-Log "$actionDesc geannuleerd."
        } else {
            Write-Log "$actionDesc mislukt: $errMsg"
            Write-Console "FOUT: $errMsg"
            Write-Log "$actionDesc mislukt."
        }
        $btnInstallWSL.IsEnabled = $true
        return
    }

    # After running the elevated command, re-check WSL state
    Start-Sleep -Seconds 2
    Update-WslPresence

    if ($script:wslInstalled) {
        Write-Log "WSL is nu functioneel!"
        Refresh-Distros
        Write-Log "WSL is gereed! Je kunt nu een DSP distro installeren."
        Show-CustomDialog -Message "WSL is succesvol geconfigureerd!`n`nJe kunt nu een DSP distro installeren via de groene knop." -Title "WSL Gereed" -Buttons "OK" -Type "Info"
    } else {
        Write-Log "WSL nog niet functioneel na $actionDesc. Herstart waarschijnlijk nodig."
        $btnInstallWSL.IsEnabled = $true
        Show-CustomDialog -Message "De wijziging is doorgevoerd maar de computer moet waarschijnlijk opnieuw worden opgestart.`n`nHerstart je computer en start daarna dit programma opnieuw." -Title "Herstart vereist" -Buttons "OK" -Type "Warning"
    }
})

# Button: Install new Ubuntu 24.04
$btnInstall.Add_Click({
    $window.Topmost = $true; $window.Topmost = $false

    # Verify WSL is actually functional before attempting distro install
    if (-not $script:wslInstalled) {
        Show-CustomDialog -Message "WSL is nog niet actief.`n`nAls je WSL net hebt geïnstalleerd, herstart dan eerst je computer." -Title "WSL niet actief" -Buttons "OK" -Type "Warning"
        return
    }

    $result = Show-CustomDialog -Message "Wil je een nieuwe DSP distro (Ubuntu 24.04) installeren?`n`nGebruiker: student`nWachtwoord: student`n`nDit kan enkele minuten duren.`nDe interface reageert niet tijdens de installatie." -Title "Nieuwe DSP Distro Installeren" -Buttons "YesNo" -Type "Question"

    if ($result -ne "Yes") {
        Write-Log "Installatie geannuleerd."
        return
    }

    # Check if any Ubuntu distro already exists
    $existing = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
    $existingUbuntu = $existing -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -match "^Ubuntu" -and $_ -notmatch "^docker-desktop" }

    if ($existingUbuntu.Count -gt 0) {
        $foundList = ($existingUbuntu | Select-Object -Unique) -join " en "

        $overwrite = Show-CustomDialog -Message "$foundList bestaat al!`n`nWil je deze VERWIJDEREN en opnieuw installeren?`nAlle data in deze distro('s) gaat verloren!" -Title "Distro bestaat al" -Buttons "YesNo" -Type "Warning"
        if ($overwrite -ne "Yes") {
            Write-Log "Installatie geannuleerd."
            return
        }
        foreach ($d in $existingUbuntu) {
            Write-Log "Bestaande $d verwijderen..."
            & wsl --unregister $d 2>&1 | Out-Null
        }
        Write-Log "Verwijderd."
        # Refresh distro list so removed distro disappears from UI
        Refresh-Distros
    }

    # Disable buttons and show busy status
    Set-ButtonsEnabled $false
    $window.Title = "DSP WSL Manager - BEZIG MET INSTALLEREN..."
    Write-Log "Ubuntu 24.04 installeren... (dit kan even duren)"
    Start-InstallTimer "Bezig met installeren..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Run the entire installation in a background runspace
    Start-BackgroundTask -Parameters @{ dspDistro = $script:dspDistro } -Work {
        param($sync, $params)
        $dspDistro = $params.dspDistro

        # Network check
        $netOk = $false
        try { $netOk = (Test-Connection -ComputerName raw.githubusercontent.com -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch {}
        if (-not $netOk) {
            BG-Status "Geen internetverbinding gedetecteerd."
            $sync.Error = "NO_NETWORK"
            $sync.Success = $false
            $sync.Done = $true
            return
        }

        # Determine correct Ubuntu distro name
        BG-Status "Beschikbare distributies ophalen..."
        $onlineList = (& wsl --list --online 2>&1 | Out-String) -replace '\x00', ''
        BG-Console "Online lijst: $onlineList"
        $distroName = $null
        foreach ($candidate in @("Ubuntu-24.04", "Ubuntu24.04", "Ubuntu-24.04-LTS")) {
            if ($onlineList -match [regex]::Escape($candidate)) {
                $distroName = $candidate
                break
            }
        }
        if (-not $distroName) {
            $ubuntuLine = ($onlineList -split "`r?`n" | Where-Object { $_ -match "^\s*Ubuntu" } | Select-Object -First 1)
            if ($ubuntuLine -and $ubuntuLine -match "^\s*(\S+)") {
                $distroName = $Matches[1]
            } else {
                $distroName = "Ubuntu"
            }
        }
        BG-Status "Geselecteerde distributie: $distroName"

        # Install distro
        BG-Status "wsl --install -d $distroName --no-launch"
        $installOutput = @()
        try {
            $lines = (& wsl --install -d $distroName --no-launch 2>&1) | ForEach-Object { ($_ | Out-String) -replace '\x00', '' }
            foreach ($rawLine in $lines) {
                $line = ($rawLine -replace '\x00', '').Trim()
                if ($line) {
                    BG-Console $line
                    $installOutput += $line
                }
            }
        } catch {
            BG-Status "Distro installatie mislukt: $_"
            BG-Console "FOUT: $_"
            $sync.Error = "INSTALL_FAILED"
            $sync.Success = $false
            $sync.Done = $true
            return
        }

        # Wait for distro registration
        BG-Status "Wachten tot distro beschikbaar is..."
        BG-StatusBar "Wachten op distro registratie..."
        $hasUbuntu = $null
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Seconds 5
            $postInstall = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
            $installedDistros = $postInstall -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch "^docker-desktop" }
            $hasUbuntu = $installedDistros | Where-Object { $_ -match "Ubuntu" }
            if ($hasUbuntu) {
                BG-Status "Distro gevonden na $((($i+1)*5)) seconden."
                break
            }
            BG-Status "Poging $(($i+1))/12: distro nog niet gevonden..."
        }

        if (-not $hasUbuntu) {
            BG-Status "Distro niet gevonden na 60 seconden."
            $sync.Error = "DISTRO_NOT_FOUND"
            $sync.ResultData = ($installOutput -join ' | ')
            $sync.Success = $false
            $sync.Done = $true
            return
        }
        $actualDistroName = ($hasUbuntu | Select-Object -First 1).Trim()
        BG-Status "Geïnstalleerde distro naam: $actualDistroName"
        $dspDistro = $actualDistroName

        # Clean up generic "Ubuntu" if versioned one also exists
        if ($dspDistro -ne "Ubuntu") {
            $postClean = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
            if (($postClean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^Ubuntu$" }).Count -gt 0) {
                BG-Status "Extra 'Ubuntu' distro gevonden, verwijderen..."
                & wsl --unregister Ubuntu 2>&1 | Out-Null
            }
        }

        # Setup script
        BG-Status "Gebruiker aanmaken, packages updaten en tools installeren..."
        BG-StatusBar "Tools en SDK installeren..."

        $setupScript = @"
#!/bin/bash
set -e

echo ">>> Gebruiker 'student' aanmaken..."
useradd -m -s /bin/bash -G sudo,plugdev student 2>/dev/null || echo "User student already exists"
echo 'student:student' | chpasswd
STUDENT_UID=`$(id -u student)
echo ">>> student UID = `$STUDENT_UID"

echo ">>> WSL configuratie schrijven..."
cat > /etc/wsl.conf << 'WSLCONF'
[boot]
systemd=true

[user]
default=student
WSLCONF

echo ">>> OOBE wizard uitschakelen..."
cat > /etc/wsl-distribution.conf << DISTCONF
[oobe]
command = /bin/true
defaultUid = `$STUDENT_UID
DISTCONF

if [ -d /etc/cloud ]; then
    echo ">>> Cloud-init uitschakelen..."
    touch /etc/cloud/cloud-init.disabled
fi

echo ">>> Pico udev regels instellen..."
cat > /etc/udev/rules.d/99-pico.rules << 'UDEV'
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0003", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0005", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="000a", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="000f", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0009", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", MODE="0666", GROUP="plugdev"
UDEV

export DEBIAN_FRONTEND=noninteractive
echo ">>> Pakketlijst ophalen..."
apt-get update -y
echo ">>> Systeem upgraden..."
apt-get upgrade -y

echo ">>> Build tools installeren (cmake, gcc, libusb)..."
apt-get install -y build-essential cmake pkg-config git \
    libusb-1.0-0 libusb-1.0-0-dev python3 usbutils

echo ">>> ARM toolchain installeren (gcc-arm-none-eabi)..."
apt-get install -y gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib

echo ">>> Pico SDK downloaden..."
PICO_SDK_PATH="/opt/pico-sdk"
if [ -d "`$PICO_SDK_PATH" ]; then
    echo "Pico SDK already exists, skipping clone."
else
    git clone --depth 1 https://github.com/raspberrypi/pico-sdk.git "`$PICO_SDK_PATH"
    cd "`$PICO_SDK_PATH"
    echo ">>> Pico SDK submodules ophalen (tinyusb)..."
    git submodule update --init --depth 1
    cd /
fi

echo ">>> PICO_SDK_PATH instellen..."
echo "export PICO_SDK_PATH=`$PICO_SDK_PATH" > /etc/profile.d/pico-sdk.sh
chmod +x /etc/profile.d/pico-sdk.sh

echo ">>> Picotool bouwen en installeren..."
PICOTOOL_SRC="/tmp/picotool-build"
rm -rf "`$PICOTOOL_SRC"
git clone --depth 1 https://github.com/raspberrypi/picotool.git "`$PICOTOOL_SRC"
cd "`$PICOTOOL_SRC"
mkdir build && cd build
cmake .. -DPICO_SDK_PATH="`$PICO_SDK_PATH" -DCMAKE_INSTALL_PREFIX=/usr/local
make -j`$(nproc)
make install
echo ">>> picotool installed at: `$(which picotool)"
picotool version || echo "picotool version check skipped"
rm -rf "`$PICOTOOL_SRC"

echo "SETUP_COMPLETE"
exit 0
"@

        BG-Status "Setup script starten in WSL..."
        $setupScript = $setupScript -replace "`r`n", "`n"
        $tempFile = Join-Path $env:TEMP "wsl-setup.sh"
        [System.IO.File]::WriteAllText($tempFile, $setupScript, [System.Text.UTF8Encoding]::new($false))
        $drive = $tempFile.Substring(0,1).ToLower()
        $wslTempPath = "/mnt/$drive" + ($tempFile.Substring(2) -replace '\\', '/')
        BG-Status "Script pad: $wslTempPath"

        & wsl -d $dspDistro -u root -- bash "$wslTempPath" 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match '>>>\s*(.+)') {
                BG-Status ($Matches[1].Trim())
            }
            BG-Console $line
        }
        Remove-Item $tempFile -ErrorAction SilentlyContinue

        # Try to set default user via Ubuntu launcher
        BG-Status "Default user instellen via Ubuntu launcher..."
        $launcherFound = $false
        foreach ($exeName in @("ubuntu2404.exe", "ubuntu24.04.exe")) {
            $exe = Get-Command $exeName -ErrorAction SilentlyContinue
            if ($exe) {
                BG-Status "Gevonden: $exeName"
                $proc = Start-Process -FilePath $exe.Source -ArgumentList "config","--default-user","student" -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
                BG-Status "  Exit code: $($proc.ExitCode)"
                $launcherFound = $true
                break
            }
        }
        if (-not $launcherFound) {
            BG-Status "Geen versioned Ubuntu launcher gevonden - wsl.conf + wsl-distribution.conf worden gebruikt."
        }

        # Terminate and restart
        BG-Status "WSL herstarten om configuratie toe te passen..."
        & wsl --terminate $dspDistro 2>&1 | Out-Null
        Start-Sleep -Seconds 2

        BG-Status "$dspDistro instellen als standaard WSL distro..."
        & wsl --set-default $dspDistro 2>&1 | Out-Null

        BG-Status "WSL distro starten..."
        & wsl -d $dspDistro -- echo "WSL is gestart" 2>&1 | ForEach-Object {
            BG-Console "$_"
        }

        BG-Status "Ubuntu 24.04 is geïnstalleerd en gestart! (user: student / ww: student)"
        $sync.ResultData = $dspDistro
        $sync.Success = $true
        $sync.Done = $true

    } -OnComplete {
        param($success, $errorMsg, $resultData)
        Stop-InstallTimer
        $window.Title = "DSP WSL Manager"
        Set-ButtonsEnabled $true
        Update-PicoButton

        if ($success) {
            $script:dspDistro = $resultData
            Refresh-Distros
            $window.Topmost = $true; $window.Topmost = $false
            Show-CustomDialog -Message "DSP distro is succesvol geïnstalleerd en gestart!`n`nGebruiker: student`nWachtwoord: student`nSystemd: ingeschakeld`nPico udev rule: ingesteld`nStandaard distro: ja`n`nGeïnstalleerde tools:`n- Pico SDK (/opt/pico-sdk)`n- picotool (from source)`n- libusb-1.0`n- gcc-arm-none-eabi`n- cmake, build-essential" -Title "Installatie Voltooid" -Buttons "OK" -Type "Info"
        } elseif ($errorMsg -eq "NO_NETWORK") {
            Show-CustomDialog -Message "Geen internetverbinding gevonden.`n`nDe installatie heeft internet nodig om Ubuntu te downloaden.`nControleer je verbinding en probeer het opnieuw." -Title "Geen internet" -Buttons "OK" -Type "Warning"
        } elseif ($errorMsg -eq "DISTRO_NOT_FOUND") {
            Show-CustomDialog -Message "De distro is niet gevonden na installatie.`n`nMogelijk moet de computer opnieuw worden opgestart,`nof is er onvoldoende rechten/netwerkverbinding.`n`nControleer het logbestand voor details." -Title "Distro niet gevonden" -Buttons "OK" -Type "Warning"
        } else {
            Write-Log "Installatie mislukt: $errorMsg"
        }
    }
})

# Button: Start WSL (background, no terminal window)
$btnStart.Add_Click({
    $selected = $dgDistros.SelectedItem
    if ($selected) {
        $distroName = $selected.Name
    } else {
        $distroName = $script:dspDistro
    }

    Write-Log "'$distroName' starten en instellen als standaard..."
    & wsl --set-default $distroName 2>&1 | Out-Null

    # Start the distro in the background (just boot, no interactive shell)
    & wsl -d $distroName -- echo "WSL gestart" 2>&1 | Out-Null
    Write-Log "'$distroName' is gestart als standaard distro."
    Start-Sleep -Seconds 1
    Refresh-Distros
})

# Button: Stop WSL (terminate)
$btnStop.Add_Click({
    $selected = $dgDistros.SelectedItem
    if ($selected) {
        $distroName = $selected.Name
    } else {
        $distroName = $script:dspDistro
    }

    Write-Log "'$distroName' stoppen..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    & wsl --terminate $distroName 2>&1 | Out-Null
    Write-Log "'$distroName' is gestopt."
    Refresh-Distros
})

# Button: Open interactive WSL terminal in project folder
$btnTerminal.Add_Click({
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        Show-CustomDialog -Message "Haal eerst het DSP project op via 'DSP Project Ophalen'." -Title "Project niet gevonden" -Buttons "OK" -Type "Warning"
        return
    }

    $distroName = $script:dspDistro

    # Check if distro is running, start if needed
    $wslCheck = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
    if (-not ($wslCheck -match "$([regex]::Escape($distroName))\s+Running")) {
        Write-Log "'$distroName' starten..."
        & wsl --set-default $distroName 2>&1 | Out-Null
        & wsl -d $distroName -- echo "WSL gestart" 2>&1 | Out-Null
        Start-Sleep -Seconds 1
    }

    # Convert project path to WSL /mnt/ path
    $drive = $projectPath.Substring(0,1).ToLower()
    $wslProjectPath = "/mnt/$drive" + ($projectPath.Substring(2) -replace '\\', '/')

    Write-Log "Terminal openen in: $wslProjectPath"

    # Try Windows Terminal first, fallback to plain wsl.exe
    $wtExe = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wtExe) {
        Start-Process -FilePath "wt.exe" -ArgumentList "wsl.exe", "-d", $distroName, "--cd", $wslProjectPath
    } else {
        Start-Process -FilePath "wsl.exe" -ArgumentList "-d", $distroName, "--cd", $wslProjectPath
    }
    Refresh-Distros
})

# Button: Detect and attach/detach Pico to WSL via usbipd
$btnPico.Add_Click({
    Write-Log "Pico detecteren..."

    # Step 1: Check if usbipd is installed
    $usbipd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
    if (-not $usbipd) {
        $installResult = Show-CustomDialog -Message "usbipd-win is niet geïnstalleerd.`nDit is nodig om USB-apparaten aan WSL te koppelen.`n`nWil je usbipd-win nu installeren via winget?" -Title "usbipd-win niet gevonden" -Buttons "YesNo" -Type "Question"
        if ($installResult -eq "Yes") {
            Write-Log "usbipd-win installeren via winget..."
            & winget install --id dorssel.usbipd-win --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object {
                Write-Console $_
                $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
            }
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            $usbipd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
            if (-not $usbipd) {
                Write-Log "usbipd-win installatie mislukt of herstart nodig."
                Show-CustomDialog -Message "usbipd-win kon niet gevonden worden na installatie.`nHerstart de PC en probeer het opnieuw." -Title "Herstart nodig" -Buttons "OK" -Type "Warning"
                return
            }
        } else {
            return
        }
    }

    Write-Log "usbipd gevonden, USB-apparaten scannen..."

    # Step 2: Detect Pico via usbipd list
    # Subshell + SilentlyContinue voorkomt dat usbipd's native stderr warnings
    # (bijv. 'Unknown USB filter edevmon / USBPcap') als rode NativeCommandError
    # in het log opgenoemd worden — de warning text blijft wel in de output
    # string staan via 2>&1.
    $usbipdOutput = & {
        $ErrorActionPreference = 'SilentlyContinue'
        (& usbipd list 2>&1) | Out-String
    }
    Write-Log $usbipdOutput

    # Negeer opgeslagen spookapparaten, focus alleen op fysiek aangesloten poorten
    $connectedPart = $usbipdOutput
    $persistedIdx = $usbipdOutput.IndexOf("Persisted:")
    if ($persistedIdx -ge 0) { $connectedPart = $usbipdOutput.Substring(0, $persistedIdx) }

    $picoLines = $connectedPart -split "`r?`n" | Where-Object { $_ -match "2e8a|RP2040|RP2350|Raspberry Pi|Pico" }

    if ($picoLines.Count -eq 0) {
        Show-CustomDialog -Message "Geen Raspberry Pi Pico gevonden.`n`nZorg dat de Pico via USB is aangesloten.`nHoud BOOTSEL ingedrukt bij het aansluiten voor programmeer-modus." -Title "Pico niet gevonden" -Buttons "OK" -Type "Warning"
        Write-Log "Geen Pico gevonden."
        return
    }

    $picoDevices = @()
    foreach ($line in $picoLines) {
        $devId = $null
        $devDesc = ""
        $status = "Not shared"
        $isGuid = $false

        # Bepaal de status exact zoals gevraagd
        if ($line -match "Attached") { $status = "Attached" }
        elseif ($line -match "Not shared") { $status = "Not shared" }
        elseif ($line -match "Shared") { $status = "Shared" }

        if ($line -match "^\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+(.+)$") {
            $devId = $Matches[1]
            $devDesc = ($Matches[2] -replace "(?i)\s+(Not shared|Shared|Attached.*)$", "").Trim()
            $isGuid = $true
        } elseif ($line -match "^\s*(\d+-\d+)\s+(.+)$") {
            $devId = $Matches[1]
            $devDesc = ($Matches[2] -replace "(?i)\s+(Not shared|Shared|Attached.*)$", "").Trim()
            $isGuid = $false
        }

        if ($devId) {
            $picoDevices += @{
                Id = $devId
                Desc = $devDesc
                Status = $status
                UseGuid = $isGuid
            }
        }
    }

    if ($picoDevices.Count -eq 0) {
        Write-Log "Kon device-ID niet bepalen uit usbipd output."
        return
    }

    $selectedPico = $null
    if ($picoDevices.Count -gt 1) {
        # Build selection dialog
        $picoWindow = New-Object System.Windows.Window
        $picoWindow.Title = "Pico Selecteren"
        $picoWindow.Width = 520
        $picoWindow.SizeToContent = "Height"
        $picoWindow.WindowStartupLocation = "CenterOwner"
        $picoWindow.Owner = $window
        $picoWindow.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1e1e2e")
        $picoWindow.ResizeMode = "NoResize"

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Margin = [System.Windows.Thickness]::new(20)

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = "Meerdere Pico's gevonden. Selecteer welke je wilt beheren:"
        $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $label.FontSize = 14
        $label.Margin = [System.Windows.Thickness]::new(0,0,0,12)
        $label.TextWrapping = "Wrap"
        $stack.Children.Add($label) | Out-Null

        $listBox = New-Object System.Windows.Controls.ListBox
        $listBox.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#313244")
        $listBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $listBox.BorderThickness = [System.Windows.Thickness]::new(0)
        $listBox.FontSize = 13
        $listBox.Padding = [System.Windows.Thickness]::new(4)
        
        foreach ($dev in $picoDevices) {
            $statusText = ""
            if ($dev.Status -eq "Attached") { $statusText = " [GEHEEL GEKOPPELD]" }
            elseif ($dev.Status -eq "Shared") { $statusText = " [TUSSENSTAND]" }
            $listBox.Items.Add("$($dev.Id) - $($dev.Desc)$statusText") | Out-Null
        }
        $listBox.SelectedIndex = 0
        $stack.Children.Add($listBox) | Out-Null

        $btnPanel = New-Object System.Windows.Controls.StackPanel
        $btnPanel.Orientation = "Horizontal"
        $btnPanel.HorizontalAlignment = "Right"
        $btnPanel.Margin = [System.Windows.Thickness]::new(0,12,0,0)

        $btnOk = New-Object System.Windows.Controls.Button
        $btnOk.Content = "Selecteren"
        $btnOk.Padding = [System.Windows.Thickness]::new(20,8,20,8)
        $btnOk.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#89b4fa")
        $btnOk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1e1e2e")
        $btnOk.FontWeight = "SemiBold"
        $btnOk.BorderThickness = [System.Windows.Thickness]::new(0)
        $btnOk.Add_Click({ $picoWindow.DialogResult = $true; $picoWindow.Close() })
        $btnPanel.Children.Add($btnOk) | Out-Null

        $btnCancel = New-Object System.Windows.Controls.Button
        $btnCancel.Content = "Annuleren"
        $btnCancel.Padding = [System.Windows.Thickness]::new(20,8,20,8)
        $btnCancel.Margin = [System.Windows.Thickness]::new(8,0,0,0)
        $btnCancel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#45475a")
        $btnCancel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $btnCancel.BorderThickness = [System.Windows.Thickness]::new(0)
        $btnCancel.Add_Click({ $picoWindow.DialogResult = $false; $picoWindow.Close() })
        $btnPanel.Children.Add($btnCancel) | Out-Null

        $stack.Children.Add($btnPanel) | Out-Null
        $picoWindow.Content = $stack

        $dialogResult = $picoWindow.ShowDialog()
        if (-not $dialogResult) {
            Write-Log "Pico selectie geannuleerd."
            return
        }
        $selectedPico = $picoDevices[$listBox.SelectedIndex]
    } else {
        $selectedPico = $picoDevices[0]
    }

    $devId = $selectedPico.Id
    $picoDesc = $selectedPico.Desc
    $devStatus = $selectedPico.Status
    $idFlag = if ($selectedPico.UseGuid) { "--guid" } else { "--busid" }

    Write-Log "Geselecteerde Pico: $devId - $picoDesc (Status: $devStatus)"

    # LOGICA 1: Tussenstand (Wel gebonden, niet attached)
    if ($devStatus -eq "Shared") {
        Write-Log "Tussenstand gedetecteerd (Shared). Forceer unbind (admin rechten nodig)..."
        $lines = Invoke-Elevated "usbipd unbind $idFlag $devId"
        foreach ($line in $lines) { Write-Console $line }

        Show-CustomDialog -Message "De Pico had een verbindingsfout (wel gereserveerd, maar niet verbonden).`n`nHet apparaat is nu volledig ontkoppeld en gereset.`n`nKlik nogmaals op de knop om de Pico schoon te koppelen." -Title "Pico Hersteld" -Buttons "OK" -Type "Info"
        Update-PicoButton
        return
    }

    # LOGICA 2: Geheel Gekoppeld
    elseif ($devStatus -eq "Attached") {
        $detachResult = Show-CustomDialog -Message "Pico is momenteel GEHEEL GEKOPPELD aan WSL.`n`nID: $devId`n$picoDesc`n`nWil je de Pico ontkoppelen?" -Title "Pico Ontkoppelen" -Buttons "YesNo" -Type "Question"
        if ($detachResult -eq "Yes") {
            Write-Log "Pico ontkoppelen en vrijgeven (admin rechten nodig)..."
            $lines = Invoke-Elevated "usbipd unbind $idFlag $devId"
            foreach ($line in $lines) { Write-Console $line }
            Write-Log "Pico is ontkoppeld."
            $btnPico.Content = "$picoIcon Pico koppelen"
            Show-CustomDialog -Message "Pico is ontkoppeld van WSL.`nHet apparaat is weer beschikbaar voor Windows." -Title "Pico Ontkoppeld" -Buttons "OK" -Type "Info"
        }
        Update-PicoButton
        return
    }

    # LOGICA 3: Totaal Ontkoppeld
    elseif ($devStatus -eq "Not shared") {
        $attachResult = Show-CustomDialog -Message "Pico gevonden (TOTAAL ONTKOPPELD).`n`nID: $devId`n$picoDesc`n`nWil je dit apparaat koppelen aan WSL?" -Title "Pico Koppelen" -Buttons "YesNo" -Type "Question"

        if ($attachResult -ne "Yes") {
            Write-Log "Koppelen geannuleerd."
            return
        }

        # Bind + Attach in EEN elevated call, zodat de attach-stap ook admin rechten heeft.
        # Anders vereist 'usbipd attach' lidmaatschap van de lokale 'usbipd' groep, wat pas
        # na uit-/inloggen actief wordt en op verse installs stille failures geeft.
        # NB: Geen --auto-attach hier (synchrone attach, elevated PS kan direct afsluiten).
        # Auto-attach is alleen nodig in de flash-flow voor BOOTSEL-reconnect.
        Write-Log "Pico binden + koppelen (admin rechten nodig): $idFlag $devId..."
        $bindAndAttach = "usbipd bind $idFlag $devId --force; usbipd attach --wsl $idFlag $devId"
        $lines = Invoke-Elevated $bindAndAttach
        foreach ($line in $lines) { Write-Console $line }

        if ($script:lastElevatedExitCode -ne 0) {
            Write-Log "Elevatie mislukt of geweigerd (exitcode: $($script:lastElevatedExitCode))."
            Show-CustomDialog -Message "Admin rechten zijn niet toegekend.`n`nDe Pico kan niet worden gekoppeld zonder admin rechten voor 'usbipd bind'.`n`nProbeer opnieuw en klik 'Ja' op de UAC-prompt." -Title "Admin rechten nodig" -Buttons "OK" -Type "Warning"
            Update-PicoButton
            return
        }

        # Verificatie: usbipd list moet "Attached" tonen voor dit device.
        # We pompen de UI dispatcher tussen de retries zodat de app niet bevriest.
        # lsusb-verificatie is verwijderd — die blokkeerde UI en de usbipd-status is
        # autoritatief genoeg voor de gebruiker.
        $txtStatus.Text = "Pico-verbinding verifiëren..."
        $statusOk = $false

        # UI pump helper (WPF equivalent van Application.DoEvents)
        $pumpUI = {
            param($ms)
            $deadline = (Get-Date).AddMilliseconds($ms)
            while ((Get-Date) -lt $deadline) {
                $frame = New-Object System.Windows.Threading.DispatcherFrame
                $null = [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
                    [System.Windows.Threading.DispatcherPriority]::Background,
                    [Action]{ $frame.Continue = $false }
                )
                [System.Windows.Threading.Dispatcher]::PushFrame($frame)
                Start-Sleep -Milliseconds 50
            }
        }

        for ($i = 1; $i -le 3; $i++) {
            & $pumpUI 600
            $usbipdStatus = ""
            try {
                $usbipdStatus = & {
                    $ErrorActionPreference = 'SilentlyContinue'
                    (& usbipd list 2>&1) | Out-String
                }
            } catch { $usbipdStatus = "" }
            foreach ($ln in ($usbipdStatus -split "`r?`n")) {
                if ($ln -match [regex]::Escape($devId) -and $ln -match "Attached") { $statusOk = $true; break }
            }
            if ($statusOk) { break }
        }
        Write-Log ("usbipd status na attach: " + $(if ($statusOk) { 'Attached' } else { 'NIET Attached' }))
        $txtStatus.Text = ""

        if ($statusOk) {
            Write-Log "Pico gekoppeld (usbipd: Attached)."
            $btnPico.Content = "$picoIcon Pico ontkoppelen"
            Show-CustomDialog -Message "Pico is succesvol gekoppeld aan WSL!`n`nHet apparaat is nu beschikbaar in de WSL-omgeving." -Title "Pico Gekoppeld" -Buttons "OK" -Type "Info"
        } else {
            Write-Log "Pico niet attached in usbipd — koppelen mislukt."
            Show-CustomDialog -Message "Koppelen is mislukt.`n`nMogelijke oorzaken:`n- Na een verse 'usbipd-win' installatie moet je uit- en opnieuw inloggen zodat de 'usbipd' groep actief wordt`n- De USBPcap of edevmon filter driver blokkeert toegang tot de Pico`n- De Pico is ontkoppeld tussen bind en attach`n`nTip: check met 'whoami /groups | findstr usbipd' in PowerShell of je lid bent." -Title "Koppelen mislukt" -Buttons "OK" -Type "Warning"
        }
        Update-PicoButton
    }
})

# Button: Clone DSP project repo
# Button: Unlink project (ontkoppelen)
$btnUnlinkProject.Add_Click({
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        Show-CustomDialog -Message "Er is momenteel geen project gekoppeld." -Title "Niets te ontkoppelen" -Buttons "OK" -Type "Info"
        return
    }

    $result = Show-CustomDialog -Message "Wil je het project ontkoppelen?`n`nHuidige map: $projectPath`n`nDe bestanden worden niet verwijderd, alleen de koppeling wordt opgeheven." -Title "Project Ontkoppelen" -Buttons "YesNo" -Type "Question"

    if ($result -eq "Yes") {
        Remove-Item $configFile -ErrorAction SilentlyContinue
        Write-Log "Project ontkoppeld: $projectPath"
        Update-TerminalButton
        Update-ProjectInfo
        Update-WorkflowContext
    }
})

# Button: Link/clone project (koppelen)
$btnCloneRepo.Add_Click({
    Write-Log "DSP Project koppelen..."

    # WSL moet draaien om te koppelen
    $wslCheck = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
    if (-not ($wslCheck -match "$([regex]::Escape($script:dspDistro))\s+Running")) {
        Show-CustomDialog -Message "WSL is niet actief.`nStart eerst de WSL via de 'Start WSL' knop voordat je een project koppelt." -Title "WSL niet actief" -Buttons "OK" -Type "Warning"
        return
    }

    # Open folder picker dialog
    Add-Type -AssemblyName System.Windows.Forms
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Kies een map met (of voor) het DSP project"
    $folderDialog.ShowNewFolderButton = $true

    if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log "Map selectie geannuleerd."
        return
    }

    $targetFolder = $folderDialog.SelectedPath

    # Detecteer of de geselecteerde map zelf al het project is
    $selectedName = Split-Path $targetFolder -Leaf
    if ($selectedName -eq "avd-dsp-project") {
        $projectFolder = $targetFolder
        $targetFolder = Split-Path $targetFolder -Parent
    } else {
        $projectFolder = Join-Path $targetFolder "avd-dsp-project"
    }

    # Check if folder already has project data
    if (Test-Path $projectFolder) {
        $choice = Show-CustomDialog -Message "De map 'avd-dsp-project' bestaat al in:`n$targetFolder`n`nWil je de bestaande data gebruiken?`n`n- Ja: Bestaande project koppelen (geen download)`n- Nee: Alles overschrijven met een verse kopie van GitHub" -Title "Project gevonden" -Buttons "YesNo" -Type "Question"

        if ($choice -eq "Cancel") {
            Write-Log "Koppelen geannuleerd."
            return
        }

        if ($choice -eq "Yes") {
            # Bestaande data gebruiken
            Save-ProjectPath $projectFolder
            Update-TerminalButton
            Update-ProjectInfo
            Update-WorkflowContext
            Write-Log "Bestaand project gekoppeld: $projectFolder"
            Show-CustomDialog -Message "Project gekoppeld!`n`nLocatie: $projectFolder" -Title "Project Gekoppeld" -Buttons "OK" -Type "Info"
            return
        }

        # Nee gekozen — overschrijven met verse clone
        Write-Log "Bestaande map verwijderen..."
        Remove-Item -Path $projectFolder -Recurse -Force
    }

    # Convert Windows path to WSL /mnt/ path
    $drive = $targetFolder.Substring(0,1).ToLower()
    $wslTargetPath = "/mnt/$drive" + ($targetFolder.Substring(2) -replace '\\', '/')

    Write-Log "Clonen naar: $projectFolder"
    Write-Log "WSL pad: $wslTargetPath"
    Write-Log "DSP project ophalen van GitHub..."
    Set-ButtonsEnabled $false

    # Sla projectFolder op in script-scope zodat OnComplete het kan vinden
    $script:pendingProjectFolder = $projectFolder

    Start-BackgroundTask -Parameters @{ dspDistro = $script:dspDistro; wslTargetPath = $wslTargetPath } -Work {
        param($sync, $params)
        & wsl -d $params.dspDistro -- git clone --progress https://github.com/dkroeske/avd-dsp-project.git "$($params.wslTargetPath)/avd-dsp-project" 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match "(\d+)%") {
                BG-StatusBar "DSP project ophalen... $($Matches[1])%"
            }
            BG-Console $line
        }
        BG-Status "DSP project ophalen voltooid."
        $sync.Success = $true
        $sync.Done = $true
    } -OnComplete {
        param($success, $errorMsg, $resultData)
        Set-ButtonsEnabled $true
        Update-PicoButton
        $pf = $script:pendingProjectFolder
        if ($pf -and (Test-Path $pf)) {
            Save-ProjectPath $pf
            Update-TerminalButton
            Update-ProjectInfo
            Update-WorkflowContext
            Write-Log "DSP project succesvol opgehaald naar: $pf"
            Show-CustomDialog -Message "DSP project is opgehaald en gekoppeld!`n`nLocatie: $pf" -Title "Project Opgehaald" -Buttons "OK" -Type "Info"
        } else {
            Write-Log "Clone lijkt mislukt - map niet gevonden: $pf"
            Show-CustomDialog -Message "Het ophalen van het project is mislukt.`nControleer het logbestand voor details." -Title "Clone Mislukt" -Buttons "OK" -Type "Error"
        }
        $script:pendingProjectFolder = $null
    }
})

# Helper: Flash the built .uf2 image to the Pico
function Flash-Pico {
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        Show-CustomDialog -Message "Haal eerst het DSP project op via 'DSP Project Ophalen'." -Title "Project niet gevonden" -Buttons "OK" -Type "Warning"
        return
    }

    $buildDir = Join-Path $projectPath "build"
    $uf2File = $null
    if (Test-Path $buildDir) {
        $uf2File = Get-ChildItem -Path $buildDir -Filter "*.uf2" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $uf2File) {
        Show-CustomDialog -Message "Geen .uf2 bestand gevonden in de build directory.`nBuild eerst het project." -Title "Geen firmware" -Buttons "OK" -Type "Warning"
        return
    }

    # Check if Pico is connected and coupled to WSL
    $usbipdExe = Get-Command usbipd.exe -ErrorAction SilentlyContinue
    if (-not $usbipdExe) {
        Show-CustomDialog -Message "usbipd is niet gevonden. Kan de Pico niet bereiken." -Title "Fout" -Buttons "OK" -Type "Error"
        return
    }

    $usbipdOut = & {
        $ErrorActionPreference = 'SilentlyContinue'
        (& usbipd list 2>&1) | Out-String
    }
    $connectedPart = $usbipdOut
    $persistedIdx = $usbipdOut.IndexOf("Persisted:")
    if ($persistedIdx -ge 0) { $connectedPart = $usbipdOut.Substring(0, $persistedIdx) }

    $picoLinesAll = $connectedPart -split "`r?`n" | Where-Object { $_ -match "2e8a|RP2040|RP2350|Raspberry Pi|Pico" }

    $attachedPicos = @()
    foreach ($line in $picoLinesAll) {
        if ($line -match "Attached") {
            $devId = $null
            $devDesc = ""
            if ($line -match "^\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+(.+)$") {
                $devId = $Matches[1]
                $devDesc = ($Matches[2] -replace "(?i)\s+(Not shared|Shared|Attached.*)$", "").Trim()
            } elseif ($line -match "^\s*(\d+-\d+)\s+(.+)$") {
                $devId = $Matches[1]
                $devDesc = ($Matches[2] -replace "(?i)\s+(Not shared|Shared|Attached.*)$", "").Trim()
            }
            if ($devId) {
                $attachedPicos += @{ Id = $devId; Desc = $devDesc }
            }
        }
    }

    if ($attachedPicos.Count -eq 0) {
        Show-CustomDialog -Message "Geen Pico gevonden die momenteel gekoppeld is aan WSL.`n`nKlik eerst op 'Pico koppelen' om de Pico met WSL te verbinden." -Title "Pico niet gekoppeld" -Buttons "OK" -Type "Warning"
        return
    }

    $targetPico = $null
    if ($attachedPicos.Count -eq 1) {
        $targetPico = $attachedPicos[0]
    } else {
        # Show selection dialog
        $picoWindow = New-Object System.Windows.Window
        $picoWindow.Title = "Pico Selecteren voor Flash"
        $picoWindow.Width = 520
        $picoWindow.SizeToContent = "Height"
        $picoWindow.WindowStartupLocation = "CenterOwner"
        $picoWindow.Owner = $window
        $picoWindow.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1e1e2e")
        $picoWindow.ResizeMode = "NoResize"

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Margin = [System.Windows.Thickness]::new(20)

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = "Er zijn meerdere gekoppelde Pico's. Selecteer welke je wilt flashen:"
        $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $label.FontSize = 14
        $label.Margin = [System.Windows.Thickness]::new(0,0,0,12)
        $label.TextWrapping = "Wrap"
        $stack.Children.Add($label) | Out-Null

        $listBox = New-Object System.Windows.Controls.ListBox
        $listBox.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#313244")
        $listBox.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $listBox.BorderThickness = [System.Windows.Thickness]::new(0)
        $listBox.FontSize = 13
        $listBox.Padding = [System.Windows.Thickness]::new(4)

        foreach ($dev in $attachedPicos) {
            $listBox.Items.Add("$($dev.Id) - $($dev.Desc)") | Out-Null
        }
        $listBox.SelectedIndex = 0
        $stack.Children.Add($listBox) | Out-Null

        $btnPanel = New-Object System.Windows.Controls.StackPanel
        $btnPanel.Orientation = "Horizontal"
        $btnPanel.HorizontalAlignment = "Right"
        $btnPanel.Margin = [System.Windows.Thickness]::new(0,12,0,0)

        $btnOk = New-Object System.Windows.Controls.Button
        $btnOk.Content = "Flashen"
        $btnOk.Padding = [System.Windows.Thickness]::new(20,8,20,8)
        $btnOk.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#a6e3a1")
        $btnOk.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#1e1e2e")
        $btnOk.FontWeight = "SemiBold"
        $btnOk.BorderThickness = [System.Windows.Thickness]::new(0)
        $btnOk.Add_Click({ $picoWindow.DialogResult = $true; $picoWindow.Close() })
        $btnPanel.Children.Add($btnOk) | Out-Null

        $btnCancel = New-Object System.Windows.Controls.Button
        $btnCancel.Content = "Annuleren"
        $btnCancel.Padding = [System.Windows.Thickness]::new(20,8,20,8)
        $btnCancel.Margin = [System.Windows.Thickness]::new(8,0,0,0)
        $btnCancel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#45475a")
        $btnCancel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $btnCancel.BorderThickness = [System.Windows.Thickness]::new(0)
        $btnCancel.Add_Click({ $picoWindow.DialogResult = $false; $picoWindow.Close() })
        $btnPanel.Children.Add($btnCancel) | Out-Null

        $stack.Children.Add($btnPanel) | Out-Null
        $picoWindow.Content = $stack

        $dialogResult = $picoWindow.ShowDialog()
        if (-not $dialogResult) {
            Write-Log "Flash geannuleerd door gebruiker."
            return
        }
        $targetPico = $attachedPicos[$listBox.SelectedIndex]
    }

    # Bevestiging vragen voordat we flashen
    $confirmResult = Show-CustomDialog `
        -Message "Weet je zeker dat je wilt flashen?`n`nPico: $($targetPico.Desc)`nID: $($targetPico.Id)`nFirmware: $($uf2File.Name)`n`nDe Pico wordt overschreven met de nieuwe firmware." `
        -Title "Pico Flashen" -Buttons "YesNo" -Type "Warning"
    if ($confirmResult -ne "Yes") {
        Write-Log "Flash geannuleerd door gebruiker."
        return
    }

    # Temporarily detach other picos to avoid picotool confusion
    $detachedOthers = @()
    if ($attachedPicos.Count -gt 1) {
        Write-Log "Tijdelijk andere Pico's ontkoppelen om conflicten te voorkomen..."
        $unbindCmds = @()
        foreach ($dev in $attachedPicos) {
            if ($dev.Id -ne $targetPico.Id) {
                $isGuid = $dev.Id -match "-" -and $dev.Id.Length -gt 10
                $idFlag = if ($isGuid) { "--guid" } else { "--busid" }
                $unbindCmds += "usbipd unbind $idFlag $($dev.Id)"
                $detachedOthers += @{ Id = $dev.Id; Flag = $idFlag }
            }
        }
        if ($unbindCmds.Count -gt 0) {
            Invoke-Elevated ($unbindCmds -join "; ") | Out-Null
            Start-Sleep -Seconds 1
        }
    }

    Write-Log "=== FLASH GESTART voor Pico $($targetPico.Id) ==="
    Write-Log "Pico flashen..."
    Set-ButtonsEnabled $false

    $uf2WinPath = $uf2File.FullName
    $uf2Drive = $uf2WinPath.Substring(0,1).ToLower()
    $uf2WslPath = "/mnt/$uf2Drive" + ($uf2WinPath.Substring(2) -replace '\\', '/')

    $devId = $targetPico.Id
    $idFlag = if ($devId -match "-" -and $devId.Length -gt 10) { "--guid" } else { "--busid" }
    $needBootsel = ($targetPico.Desc -notmatch "Boot")

    # Write flash script to temp file before starting background task
    $flashScript = @"
#!/bin/bash
export PICO_SDK_PATH=/opt/pico-sdk

echo ">>> Firmware flashen: $uf2WslPath"
picotool load "$uf2WslPath" -f 2>&1
LOAD_RESULT=`$?

if [ `$LOAD_RESULT -eq 0 ]; then
    echo ">>> Firmware geladen! Pico herstarten..."
    picotool reboot 2>&1 || true
    echo "FLASH_COMPLETE"
else
    echo ">>> FOUT bij laden van firmware (exit code: `$LOAD_RESULT)"
    echo "FLASH_FAILED"
fi
"@

    $flashScript = $flashScript -replace "`r`n", "`n"
    $tempFlash = Join-Path $env:TEMP "wsl-flash.sh"
    [System.IO.File]::WriteAllText($tempFlash, $flashScript, [System.Text.UTF8Encoding]::new($false))
    $flashDrive = $tempFlash.Substring(0,1).ToLower()
    $wslFlashPath = "/mnt/$flashDrive" + ($tempFlash.Substring(2) -replace '\\', '/')

    # Serialize detachedOthers for passing to runspace
    $detachedSerialized = @()
    foreach ($dev in $detachedOthers) {
        $detachedSerialized += @{ Id = $dev.Id; Flag = $dev.Flag }
    }

    Start-BackgroundTask -Parameters @{
        dspDistro = $script:dspDistro
        wslFlashPath = $wslFlashPath
        tempFlash = $tempFlash
        devId = $devId
        idFlag = $idFlag
        needBootsel = $needBootsel
        detachedOthers = $detachedSerialized
    } -Work {
        param($sync, $params)

        # Helper: run elevated command (inline version for runspace)
        function BG-Elevated {
            param([string]$Command)
            $outputFile = Join-Path $env:TEMP "wsl-admin-output-bg.txt"
            $scriptFile = Join-Path $env:TEMP "wsl-admin-cmd-bg.ps1"
            Remove-Item $outputFile -ErrorAction SilentlyContinue
            $usbipdCmd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
            $cmdText = $Command
            # Fix: negative lookahead voorkomt dat 'usbipd.exe' (binnen Start-Process calls) ook
            # ten onrechte vervangen wordt tot een broken script.
            if ($usbipdCmd) { $cmdText = $cmdText -replace '\busbipd(?!\.exe)\b', "& '$($usbipdCmd.Source)'" }

            # Als de app al elevated draait, skip UAC en run direct
            $isAdmin = $false
            try {
                $idn = [Security.Principal.WindowsIdentity]::GetCurrent()
                $pr = New-Object Security.Principal.WindowsPrincipal($idn)
                $isAdmin = $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            } catch {}
            if ($isAdmin) {
                try { return (Invoke-Expression $cmdText 2>&1 | Out-String) } catch { return $_.Exception.Message }
            }

            # $ErrorActionPreference='SilentlyContinue' voorkomt dat PowerShell stderr-output
            # van native tools (usbipd info-berichten e.d.) als NativeCommandError naar de log wrapt.
            $scriptContent = "`$ErrorActionPreference='SilentlyContinue'; try { `$output = $cmdText 2>&1 | Out-String; Set-Content -Path '$outputFile' -Value `$output -Encoding UTF8 ; exit 0 } catch { Set-Content -Path '$outputFile' -Value `$_.Exception.Message -Encoding UTF8 ; exit 1 }"
            Set-Content -Path $scriptFile -Value $scriptContent -Encoding UTF8
            # -WindowStyle Hidden verwijderd: kan op sommige machines stilletjes UAC blokkeren.
            $proc = $null
            try {
                $proc = Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptFile`"" -Verb RunAs -Wait -PassThru -ErrorAction Stop
            } catch {
                Remove-Item $scriptFile -ErrorAction SilentlyContinue
                return "[Elevatie mislukt of geweigerd] $($_.Exception.Message)"
            }
            $result = ""; if (Test-Path $outputFile) { $result = Get-Content $outputFile -Raw -ErrorAction SilentlyContinue }
            Remove-Item $scriptFile, $outputFile -ErrorAction SilentlyContinue
            return $result
        }

        if ($params.needBootsel) {
            BG-Status "Pico is in applicatie-modus. Herstarten naar BOOTSEL..."
            & wsl -d $params.dspDistro -u root -- bash -c "export PICO_SDK_PATH=/opt/pico-sdk; picotool reboot -f -u" 2>&1 | Out-Null

            BG-Status "Wachten op USB reconnect van de Pico (BOOTSEL modus)..."
            Start-Sleep -Seconds 3

            BG-Status "Pico opnieuw binden en koppelen (admin rechten nodig)..."
            # Combineer bind + attach in EEN elevated call zodat attach ook admin rechten heeft.
            BG-Elevated "usbipd bind $($params.idFlag) $($params.devId) --force; Start-Sleep -Milliseconds 500; Start-Process -FilePath usbipd.exe -ArgumentList 'attach --wsl $($params.idFlag) $($params.devId) --auto-attach' -WindowStyle Hidden" | Out-Null
            Start-Sleep -Seconds 2
        }

        $flashSuccess = $false
        & wsl -d $params.dspDistro -u root -- bash $params.wslFlashPath 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match '>>>\s*(.+)') { BG-Status ($Matches[1].Trim()) }
            BG-Console $line
            if ($line -match "FLASH_COMPLETE") { $flashSuccess = $true }
        }
        Remove-Item $params.tempFlash -ErrorAction SilentlyContinue

        if ($params.detachedOthers.Count -gt 0) {
            BG-Status "Andere Pico's weer aankoppelen..."
            # Bind EN attach voor elk device in EEN elevated call (1 UAC prompt, attach erft admin)
            $bindAttachCmds = @()
            foreach ($dev in $params.detachedOthers) {
                $bindAttachCmds += "usbipd bind $($dev.Flag) $($dev.Id) --force"
                $bindAttachCmds += "Start-Sleep -Milliseconds 300"
                $bindAttachCmds += "Start-Process -FilePath usbipd.exe -ArgumentList 'attach --wsl $($dev.Flag) $($dev.Id) --auto-attach' -WindowStyle Hidden"
            }
            BG-Elevated ($bindAttachCmds -join "; ") | Out-Null
        }

        if ($flashSuccess) {
            BG-Status "Wachten op herstart van de Pico naar applicatie-modus..."
            Start-Sleep -Seconds 3
            BG-Status "Pico opnieuw binden en koppelen (applicatie-modus)..."
            # Combineer bind + attach in EEN elevated call
            BG-Elevated "usbipd bind $($params.idFlag) $($params.devId) --force; Start-Sleep -Milliseconds 500; Start-Process -FilePath usbipd.exe -ArgumentList 'attach --wsl $($params.idFlag) $($params.devId) --auto-attach' -WindowStyle Hidden" | Out-Null
        }

        $sync.ResultData = $flashSuccess
        $sync.Success = $flashSuccess
        $sync.Done = $true
    } -OnComplete {
        param($success, $errorMsg, $resultData)
        Set-ButtonsEnabled $true
        Update-PicoButton
        Write-Log "=== FLASH AFGEROND ==="

        if ($resultData) {
            $window.Topmost = $true; $window.Topmost = $false
            Show-CustomDialog -Message "Firmware is succesvol geflasht naar de Pico!`n`nDe Pico is automatisch herstart." -Title "Flash Voltooid" -Buttons "OK" -Type "Info"
        } else {
            $window.Topmost = $true; $window.Topmost = $false
            Show-CustomDialog -Message "Flash is mislukt.`n`nMogelijke oplossingen:`n- Houd BOOTSEL ingedrukt en sluit de Pico opnieuw aan`n- Controleer of de Pico gekoppeld is aan WSL`n- Bekijk het logvenster voor details" -Title "Flash Mislukt" -Buttons "OK" -Type "Error"
        }
    }
}

# Button: Build DSP project
$btnBuild.Add_Click({
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        Show-CustomDialog -Message "Haal eerst het DSP project op via 'DSP Project Ophalen'." -Title "Project niet gevonden" -Buttons "OK" -Type "Warning"
        return
    }

    # Check WSL is running
    $wslCheck = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
    if (-not ($wslCheck -match "$([regex]::Escape($script:dspDistro))\s+Running")) {
        Write-Log "WSL starten voor build..."
        & wsl --set-default $script:dspDistro 2>&1 | Out-Null
        & wsl -d $script:dspDistro -- echo "WSL gestart" 2>&1 | Out-Null
        Start-Sleep -Seconds 1
    }

    # Convert project path to WSL /mnt/ path
    $drive = $projectPath.Substring(0,1).ToLower()
    $wslProjectPath = "/mnt/$drive" + ($projectPath.Substring(2) -replace '\\', '/')

    $result = Show-CustomDialog -Message "DSP project build starten?`n`nProject: $wslProjectPath`n`nDit voert de volgende stappen uit:`n- Git safe directory instellen`n- Submodules ophalen`n- CMake configuratie genereren`n- Project compileren (make -j8)" -Title "Build Project" -Buttons "YesNo" -Type "Question"

    if ($result -ne "Yes") {
        Write-Log "Build geannuleerd."
        return
    }

    $script:buildInProgress = $true
    $btnBuild.IsEnabled = $false
    $btnFlash.IsEnabled = $false
    $script:buildStartTime = [DateTime]::Now
    $script:buildEmoji = [char]::ConvertFromUtf32(0x1F528)
    $btnBuild.Content = "$($script:buildEmoji) Building... 0:00"
    $btnBuild.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#f9e2af")
    $window.Title = "DSP WSL Manager - BEZIG MET BUILDEN..."

    # Timer: update knoptekst elke seconde met verstreken tijd
    $script:buildTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:buildTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:buildTimer.Add_Tick({
        $elapsed = [DateTime]::Now - $script:buildStartTime
        $mins = [int][math]::Floor($elapsed.TotalMinutes)
        $secs = [int]($elapsed.Seconds)
        $btnBuild.Content = "$($script:buildEmoji) Building... ${mins}:$($secs.ToString('D2'))"
    })
    $script:buildTimer.Start()

    Write-Log "=== BUILD GESTART ==="
    Write-Log "Build starten..."

    # Write build script to temp file
    $buildScript = @"
#!/bin/bash
set -e

export PICO_SDK_PATH=/opt/pico-sdk
echo ">>> PICO_SDK_PATH=`$PICO_SDK_PATH"

cd "$wslProjectPath"
echo ">>> Working directory: `$(pwd)"

echo ">>> Git safe directory instellen..."
git config --global --add safe.directory "$wslProjectPath"
git config --global --add safe.directory "`$PICO_SDK_PATH"

echo ">>> Submodules ophalen (dit kan even duren)..."
git submodule update --init --recursive --progress

echo ">>> Build directory opschonen en aanmaken..."
rm -rf build
mkdir -p build
cd build

echo ">>> CMake configuratie genereren..."
cmake .. -DPICO_SDK_PATH="`$PICO_SDK_PATH"

echo ">>> Compileren (make -j8)..."
make -j8

echo ">>> BUILD VOLTOOID"
"@

    $buildScript = $buildScript -replace "`r`n", "`n"
    $tempFile = Join-Path $env:TEMP "wsl-build.sh"
    [System.IO.File]::WriteAllText($tempFile, $buildScript, [System.Text.UTF8Encoding]::new($false))
    $driveTmp = $tempFile.Substring(0,1).ToLower()
    $wslTempPath = "/mnt/$driveTmp" + ($tempFile.Substring(2) -replace '\\', '/')

    Write-Log "Build script: $wslTempPath"

    Start-BackgroundTask -Parameters @{ dspDistro = $script:dspDistro; wslTempPath = $wslTempPath; tempFile = $tempFile } -Work {
        param($sync, $params)
        $buildSuccess = $false
        & wsl -d $params.dspDistro -u root -- bash $params.wslTempPath 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -match '>>>\s*(.+)') { BG-Status ($Matches[1].Trim()) }
            BG-Console $line
            if ($line -match "BUILD VOLTOOID") { $buildSuccess = $true }
        }
        Remove-Item $params.tempFile -ErrorAction SilentlyContinue
        $sync.ResultData = $buildSuccess
        $sync.Success = $buildSuccess
        $sync.Done = $true
    } -OnComplete {
        param($success, $errorMsg, $resultData)
        $script:buildInProgress = $false
        if ($script:buildTimer) { $script:buildTimer.Stop() }
        $elapsed = [DateTime]::Now - $script:buildStartTime
        $mins = [int][math]::Floor($elapsed.TotalMinutes)
        $secs = [int]($elapsed.Seconds)
        Write-Log "Build duur: ${mins}:$($secs.ToString('D2'))"
        $btnBuild.Content = "$($script:buildEmoji) Build Project"
        $btnBuild.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#cdd6f4")
        $window.Title = "DSP WSL Manager"
        Update-TerminalButton
        Update-PicoButton
        Write-Log "=== BUILD AFGEROND ==="

        if ($resultData) {
            $window.Topmost = $true; $window.Topmost = $false
            Show-CustomDialog -Message "Project is succesvol gebuild!`n`nBuild bestanden staan in:`n$projectPath\build" -Title "Build Voltooid" -Buttons "OK" -Type "Info"
        } else {
            $window.Topmost = $true; $window.Topmost = $false
            Show-CustomDialog -Message "Build is mislukt.`nControleer het logvenster of het logbestand voor details." -Title "Build Mislukt" -Buttons "OK" -Type "Error"
        }
    }
})

# Button: Remove selected distro
$btnRemove.Add_Click({
    $selected = $dgDistros.SelectedItem
    if (-not $selected) {
        Show-CustomDialog -Message "Selecteer eerst een distro in de lijst." -Title "Geen selectie" -Buttons "OK" -Type "Warning"
        return
    }

    $distroName = $selected.Name

    # Prevent removing docker distros
    if ($distroName -match "docker") {
        Show-CustomDialog -Message "Docker distro's kunnen niet via deze tool verwijderd worden." -Title "Niet toegestaan" -Buttons "OK" -Type "Warning"
        return
    }

    $result = Show-CustomDialog -Message "Weet je zeker dat je '$distroName' wilt verwijderen?`n`nALLE DATA IN DEZE DISTRO GAAT VERLOREN!`nDit kan niet ongedaan gemaakt worden!" -Title "Distro Verwijderen" -Buttons "YesNo" -Type "Warning"

    if ($result -eq "Yes") {
        Write-Log "'$distroName' verwijderen..."
        & wsl --unregister $distroName 2>&1 | ForEach-Object { Write-Console $_ }
        Write-Log "'$distroName' is verwijderd."
        Refresh-Distros
    }
})

# Button: Flash UF2 immediately
$btnFlash.Add_Click({
    Flash-Pico
})

# Houd bij welke Pico's in deze sessie verbonden zijn (geweest)
$script:activePicos = @()
$script:buildInProgress = $false

# Helper: check WSL running state and Pico attach status
function Update-PicoButton {
    try {
        # Niet aanraken als er een build/flash bezig is
        if ($script:buildInProgress) { return }

        if (-not $script:wslInstalled) {
            $btnPico.IsEnabled = $false
            $btnFlash.IsEnabled = $false
            $btnPico.Content = "$picoIcon Pico (WSL uit)"
            $dgPicos.Items.Clear()
            return
        }
        # Check if Ubuntu distro is running
        $wslOutput = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
        $isRunning = $wslOutput -match "$([regex]::Escape($script:dspDistro))\s+Running"

        if (-not $isRunning) {
            $btnPico.IsEnabled = $false
            $btnFlash.IsEnabled = $false
            $btnPico.Content = "$picoIcon Pico (WSL uit)"
            $dgPicos.Items.Clear()
            return
        }

        $btnPico.IsEnabled = $true

        # Check if usbipd is available and Pico is attached
        $usbipdExe = Get-Command usbipd.exe -ErrorAction SilentlyContinue
        if ($usbipdExe) {
            $usbipdOut = & {
                $ErrorActionPreference = 'SilentlyContinue'
                (& usbipd list 2>&1) | Out-String
            }

            $connectedPart = $usbipdOut
            $persistedIdx = $usbipdOut.IndexOf("Persisted:")
            if ($persistedIdx -ge 0) { $connectedPart = $usbipdOut.Substring(0, $persistedIdx) }

            # Update Pico DataGrid List
            $dgPicos.Items.Clear()
            $picoLinesAll = $connectedPart -split "`r?`n" | Where-Object { $_ -match "2e8a|RP2040|RP2350|Raspberry Pi|Pico" }
            foreach ($line in $picoLinesAll) {
                $devId = $null
                $devDesc = ""
                $status = "Niet verbonden"

                if ($line -match "Attached") { $status = "Gekoppeld aan WSL" }
                elseif ($line -match "Not shared") { $status = "Alleen Windows" }
                elseif ($line -match "Shared") { $status = "Verbindingsfout (Shared)" }

                if ($line -match "^\s*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+(.+)$") {
                    $devId = $Matches[1]
                    $devDesc = ($Matches[2] -replace "(?i)\s+(Not shared|Shared|Attached.*)$", "").Trim()
                } elseif ($line -match "^\s*(\d+-\d+)\s+(.+)$") {
                    $devId = $Matches[1]
                    $devDesc = ($Matches[2] -replace "(?i)\s+(Not shared|Shared|Attached.*)$", "").Trim()
                }

                if ($devId) {
                    # Registreer de Pico als we hem in een gekoppelde of shared status zien
                    if ($status -ne "Alleen Windows" -and $script:activePicos -notcontains $devId) {
                        $script:activePicos += $devId
                    }

                    # Toon hem alleen in de lijst als hij actief is of ooit actief is geweest deze sessie
                    if ($script:activePicos -contains $devId) {
                        $dgPicos.Items.Add([PSCustomObject]@{ Id = $devId; Desc = $devDesc; Status = $status }) | Out-Null
                    }
                }
            }

            $picoLine = $picoLinesAll | Select-Object -First 1
            $hasAttachedPico = $picoLinesAll | Where-Object { $_ -match "Attached" }
            $btnFlash.IsEnabled = [bool]$hasAttachedPico

            # Dynamic button text based on status
            if ($picoLine -and $picoLine -match "Attached") {
                $btnPico.Content = "$picoIcon Pico ontkoppelen"
            } elseif ($picoLine -and $picoLine -match "Not shared") {
                $btnPico.Content = "$picoIcon Pico koppelen"
            } elseif ($picoLine -and $picoLine -match "Shared") {
                $btnPico.Content = "$picoIcon Pico herstellen"
            } else {
                $btnPico.Content = "$picoIcon Pico koppelen"
            }
        } else {
            $btnPico.Content = "$picoIcon Pico koppelen"
            $btnFlash.IsEnabled = $false
            $dgPicos.Items.Clear()
        }
    } catch {
        # Silently ignore timer errors
    }
}

# Periodic timer: check WSL and Pico status every 5 seconds
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(5)
$statusTimer.Add_Tick({ Update-PicoButton; Update-WorkflowContext; Update-ProjectInfo; Update-TerminalButton })
$statusTimer.Start()

# Initial load — clear previous session logs
Set-Content -Path $logFile -Value "========== DSP WSL Manager gestart: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==========" -Encoding UTF8
$txtLog.Text = ""
Write-Log "Logbestand: $logFile"

# Laag 1 — Startup cleanup: ruim orphaned usbipd.exe --auto-attach watchers op
# uit eerdere sessies. Dit is de belangrijkste laag: dekt normale close, crash,
# taskkill, BSOD, stroomuitval — elke vorm van vorige-sessie-einde.
$orphansKilled = Stop-OrphanedAutoAttach -Silent:$false
if ($orphansKilled -gt 0) {
    Write-Log "Startup-cleanup voltooid: $orphansKilled orphaned process(en) verwijderd."
}

# Laag 3 — AppDomain.ProcessExit fallback: vangt exits via Environment.Exit(),
# unhandled exceptions in de CLR, en de meeste 'nette' crash scenarios.
# Werkt NIET bij: taskkill /F, StackOverflowException, OS-level process termination.
# Voor die gevallen is Laag 1 (startup cleanup) de vangnet.
try {
    [System.AppDomain]::CurrentDomain.add_ProcessExit({
        # NoElevation:$true — tijdens ProcessExit kunnen we geen UAC prompt meer
        # tonen. Orphans die admin rechten vereisen worden volgende startup opgeruimd.
        try { Stop-OrphanedAutoAttach -Silent:$true -NoElevation:$true | Out-Null } catch {}
    })
} catch {
    Write-Log "[Warning] Kon AppDomain.ProcessExit handler niet registreren: $($_.Exception.Message)"
}

# Show window immediately with loading state, then run checks
Set-ButtonsEnabled $false
$txtStatus.Text = "Systeem controleren..."

# Helper: update a checklist item with checkmark or cross
function Set-CheckItem {
    param($Control, [string]$Text, [bool]$Ok, [string]$Detail = "")
    $icon = if ($Ok) { [char]0x2705 } else { [char]0x274C }
    $suffix = if ($Detail) { " - $Detail" } else { "" }
    $Control.Text = "$icon $Text$suffix"
    $Control.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom($(if ($Ok) { "#a6e3a1" } else { "#f38ba8" }))
}

# Loading checks run as a stepped state machine via DispatcherTimer
# Each tick = one check step, so the UI renders between steps
$script:loadStep = 0
$script:loadSavedProject = $null
$script:loadDistroFound = $false

# PreviewKeyDown handler for dismissing loading screen (defined at script scope so self-reference works)
$script:loadHintShownAt = [DateTime]::MinValue
$script:loadDismissHandler = [System.Windows.Input.KeyEventHandler]{
    # Only accept keypress if hint has been visible for at least 500ms (ignore stale events)
    if ($script:loadStep -eq 7 -and ($_.Key -eq "Return" -or $_.Key -eq "Space") -and
        ([DateTime]::Now - $script:loadHintShownAt).TotalMilliseconds -gt 500) {
        $_.Handled = $true
        $script:loadStep = 8  # prevent double-fire
        $window.Remove_PreviewKeyDown($script:loadDismissHandler)

        # Swap panels — main UI is already initialized, so instant
        $pnlLoading.Visibility = "Collapsed"
        $pnlMainContent.Visibility = "Visible"

        # Check for updates na korte vertraging zodat UI volledig geladen is
        $updateTimer = New-Object System.Windows.Threading.DispatcherTimer
        $updateTimer.Interval = [TimeSpan]::FromSeconds(1)
        $updateTimer.Add_Tick({
            $this.Stop()
            try {
                Check-ForUpdates
                if ($script:updateAvailable) { Install-Updates }
            } catch { Write-Log "Update check overgeslagen: $_" }
        })
        $updateTimer.Start()
    }
}
$window.Add_PreviewKeyDown($script:loadDismissHandler)

$loadTimer = New-Object System.Windows.Threading.DispatcherTimer
$loadTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$loadTimer.Add_Tick({
    switch ($script:loadStep) {
        0 {
            # Step 1: Virtualization check
            $vtOk = $true
            try {
                $sysInfo = systeminfo 2>&1 | Out-String
                if ($sysInfo -match "Virtuali[sz]ati.*firmware.*:\s*(No|Nee)\b") { $vtOk = $false }
                if ($sysInfo -match "hypervisor.*detected|Er is een hypervisor gedetecteerd") { $vtOk = $true }
            } catch {}
            Set-CheckItem $chkVirtualization "Virtualisatie controleren" $vtOk $(if ($vtOk) { "OK" } else { "VT-x/AMD-V staat uit in BIOS" })
            $script:loadStep = 1
        }
        1 {
            # Step 2: WSL status
            $script:wslState = Test-WslState
            $script:wslInstalled = $script:wslState.ok
            $wslDetail = if ($script:wslInstalled) { "OK" } else { $script:wslState.reason -replace "`n.*", "" }
            Set-CheckItem $chkWsl "WSL status controleren" $script:wslInstalled $wslDetail
            $script:loadStep = 2
        }
        2 {
            # Step 3: Distro detection
            $script:dspDistro = Find-UbuntuDistro
            if (-not $script:dspDistro) { $script:dspDistro = "Ubuntu-24.04" }
            $script:loadDistroFound = $script:wslInstalled -and (Find-UbuntuDistro)
            Set-CheckItem $chkDistro "Distro detecteren" $script:loadDistroFound $(if ($script:loadDistroFound) { $script:dspDistro } else { "Geen Ubuntu distro gevonden" })
            $script:loadStep = 3
        }
        3 {
            # Step 4: Project check
            $script:loadSavedProject = Get-ProjectPath
            $projectOk = $null -ne $script:loadSavedProject
            Set-CheckItem $chkProject "DSP project zoeken" $projectOk $(if ($projectOk) { $script:loadSavedProject } else { "Niet geconfigureerd" })
            $script:loadStep = 4
        }
        4 {
            # Step 5: USB-IPD check
            $usbipdOk = $false
            $usbipdDetail = "Niet geïnstalleerd"
            try {
                $usbipdExe = Get-Command usbipd.exe -ErrorAction SilentlyContinue
                if ($usbipdExe) {
                    $usbipdOk = $true
                    $usbipdVer = (& usbipd --version 2>&1 | Out-String).Trim()
                    if ($usbipdVer -match '[\d+\.[\d]+\.[\d]+[\-\.\d]*') {
                        $usbipdVer = $Matches[0]
                    }
                    $usbipdDetail = if ($usbipdVer) { "v$usbipdVer" } else { "OK" }
                }
            } catch {}
            Set-CheckItem $chkUsbipd "USB-IPD controleren" $usbipdOk $usbipdDetail
            $script:loadStep = 5
        }
        5 {
            # Step 6: Initialize main UI
            Update-WslPresence
            if ($script:wslInstalled) {
                Write-Log "WSL gedetecteerd. Distro: $($script:dspDistro)"
                if ($script:loadSavedProject) {
                    Write-Log "DSP project gevonden: $($script:loadSavedProject)"
                } else {
                    Write-Log "Geen DSP project geconfigureerd."
                }
                Refresh-Distros
                Update-PicoButton
                Update-TerminalButton
                Update-ProjectInfo
                Update-WorkflowContext
            } else {
                Write-Log "WSL is niet actief (niet geïnstalleerd of niet draaiend)."
            }
            Set-ButtonsEnabled $true
            Update-PicoButton
            if (-not $script:wslInstalled) {
                Write-Log $script:wslState.reason
            } else {
                Write-Log "Gereed."
            }
            $pnlLoading.Visibility = "Collapsed"
            $pnlMainContent.Visibility = "Visible"
            Set-CheckItem $chkInit "Interface voorbereiden" $true "OK"

            # Auto-update check na korte vertraging
            $script:updateCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:updateCheckTimer.Interval = [TimeSpan]::FromSeconds(2)
            $script:updateCheckTimer.Add_Tick({
                $script:updateCheckTimer.Stop()
                try {
                    Check-ForUpdates
                    if ($script:updateAvailable) { Install-Updates }
                } catch { Write-Log "Auto-update check fout: $_" }
            })
            $script:updateCheckTimer.Start()

            $script:loadStep = 6
        }
        6 {
            $loadTimer.Stop()
            $txtLoadingHint.Text = "Druk op Enter of Spatie om door te gaan"
            $window.Activate()
            [System.Windows.Input.Keyboard]::Focus($window)
            $script:loadHintShownAt = [DateTime]::Now
            $script:loadStep = 7
        }
    }
})

# Start loading on ContentRendered
$window.Add_ContentRendered({
    $pnlLoading.Visibility = "Visible"
    $pnlMainContent.Visibility = "Collapsed"
    $txtStatus.Text = "Systeem controleren..."
    $script:loadStep = 0
    $loadTimer.Start()
})

# Laag 2 — Window.Closing handler: nette cleanup bij normaal afsluiten
# (X-knop, Alt+F4, programmatic Close). NoElevation:$true voorkomt een UAC
# prompt op het moment dat de user juist net gesloten heeft — admin-owned
# watchers worden bij de volgende startup opgeruimd (Laag 1).
$window.Add_Closing({
    try {
        $n = Stop-OrphanedAutoAttach -Silent:$true -NoElevation:$true
        if ($n -gt 0) { Write-Log "Afsluiten: $n usbipd --auto-attach process(en) opgeruimd." }
    } catch {}
})

# Show window
$window.ShowDialog() | Out-Null

# Cleanup: stop timers when window closes
$statusTimer.Stop()