# DSP WSL Manager - Core Script (Start via de 'Start DSP Manager.bat' file!)
# Beheert WSL distro's, installeert nieuwe DSP distro (Ubuntu 24.04) met automatische credentials

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

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
            $state.reason = "WSL is niet geinstalleerd."
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
        Title="DSP WSL Manager" Height="800" Width="820"
        WindowStartupLocation="CenterScreen"
        Background="#1e1e2e" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
        <Style TargetType="Button" x:Key="ActionBtn">
            <Setter Property="Background" Value="#89b4fa"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
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
                                <Setter Property="Background" Value="#b4d0fb"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#45475a"/>
                                <Setter Property="Foreground" Value="#6c7086"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button" x:Key="DangerBtn" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#f38ba8"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#f5a3b8"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#45475a"/>
                                <Setter Property="Foreground" Value="#6c7086"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button" x:Key="GreenBtn" BasedOn="{StaticResource ActionBtn}">
            <Setter Property="Background" Value="#a6e3a1"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#b8edb3"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Background" Value="#45475a"/>
                                <Setter Property="Foreground" Value="#6c7086"/>
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
    </Window.Resources>

    <DockPanel LastChildFill="True">
        <TextBlock DockPanel.Dock="Bottom" Text="&#x26A1; Crafted by Danny van der Zande"
                   Foreground="#585b70" FontSize="13" FontStyle="Italic"
                   HorizontalAlignment="Right" Margin="0,4,24,6"/>

        <Grid Margin="20,20,20,0">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,16">
            <TextBlock Text="&#x1F427; DSP WSL Manager" FontSize="24" FontWeight="Bold"
                       Foreground="#cdd6f4" Margin="0,0,0,4"/>
            <TextBlock Text="DT-RAS Digital Signal Processing &#x2022; Elektrotechniek &#x2022; Avans Breda"
                       FontSize="13" Foreground="#6c7086"/>
        </StackPanel>

        <Border Grid.Row="1" Name="pnlWslMissing" Background="#f38ba8" CornerRadius="8"
                Padding="16,12" Margin="0,0,0,8" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
                <TextBlock Name="txtWslError" Text="&#x26A0; WSL is niet beschikbaar."
                           Foreground="#1e1e2e" FontSize="14" FontWeight="SemiBold"
                           VerticalAlignment="Center" Margin="0,0,16,0" TextWrapping="Wrap" MaxWidth="550"/>
                <Button Content="WSL Installeren" Style="{StaticResource ActionBtn}"
                        Name="btnInstallWSL" Padding="20,8" FontSize="14"/>
            </StackPanel>
        </Border>

        <Grid Grid.Row="2" Name="pnlMainContent">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <!-- DSP Project Paneel -->
            <Border Grid.Row="0" Background="#313244" CornerRadius="8" Padding="16,12" Margin="0,0,0,16">
                <StackPanel>
                    <TextBlock Text="&#x1F4C2; DSP Project Acties" Foreground="#cdd6f4" FontWeight="SemiBold" FontSize="14" Margin="0,0,0,12"/>
                    <WrapPanel Orientation="Horizontal">
                        <Button Content="&#x1F4E5; DSP Project Ophalen" Style="{StaticResource ActionBtn}" Name="btnCloneRepo" Margin="0,0,8,0"/>
                        <Button Content="&#x1F4BB; Open Terminal" Style="{StaticResource ActionBtn}" Name="btnTerminal" Margin="0,0,8,0"/>
                        <Button Content="&#x1F528; Project Builden" Style="{StaticResource GreenBtn}" Name="btnBuild" Margin="0,0,8,0"/>
                        <Button Content="&#x26A1; Flashen" Style="{StaticResource GreenBtn}" Name="btnFlash"/>
                    </WrapPanel>
                </StackPanel>
            </Border>

            <!-- WSL Distributies Paneel -->
            <Grid Grid.Row="1" Margin="0,0,0,16">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                
                <Grid Grid.Row="0" Margin="0,0,0,8">
                    <TextBlock Text="&#x1F427; WSL Distributies" Foreground="#cdd6f4" FontWeight="SemiBold" FontSize="14" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Content="&#x2795; Nieuw" Style="{StaticResource SmallGreenBtn}" Name="btnInstall" Margin="0,0,8,0"/>
                        <Button Content="&#x25B6; Start" Style="{StaticResource SmallActionBtn}" Name="btnStart" Margin="0,0,8,0"/>
                        <Button Content="&#x23F9; Stop" Style="{StaticResource SmallActionBtn}" Name="btnStop" Margin="0,0,8,0"/>
                        <Button Content="&#x1F5D1; Wis" Style="{StaticResource SmallDangerBtn}" Name="btnRemove" Margin="0,0,8,0"/>
                        <Button Content="&#x1F504;" Style="{StaticResource SmallActionBtn}" ToolTip="Vernieuwen" Name="btnRefresh"/>
                    </StackPanel>
                </Grid>

                <Border Grid.Row="1" Background="#313244" CornerRadius="8" Padding="2">
                    <DataGrid Name="dgDistros" AutoGenerateColumns="False" Background="Transparent" BorderThickness="0"
                              RowBackground="#313244" AlternatingRowBackground="#363849" Foreground="#cdd6f4" FontSize="13"
                              GridLinesVisibility="None" HeadersVisibility="Column" SelectionMode="Single"
                              CanUserAddRows="False" CanUserDeleteRows="False" IsReadOnly="True">
                        <DataGrid.ColumnHeaderStyle>
                            <Style TargetType="DataGridColumnHeader">
                                <Setter Property="Background" Value="#45475a"/>
                                <Setter Property="Foreground" Value="#89b4fa"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                                <Setter Property="Padding" Value="12,8"/>
                                <Setter Property="BorderThickness" Value="0"/>
                            </Style>
                        </DataGrid.ColumnHeaderStyle>
                        <DataGrid.CellStyle>
                            <Style TargetType="DataGridCell">
                                <Setter Property="Padding" Value="12,6"/>
                                <Setter Property="BorderThickness" Value="0"/>
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="DataGridCell">
                                            <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
                                                <ContentPresenter VerticalAlignment="Center"/>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                                <Style.Triggers>
                                    <Trigger Property="IsSelected" Value="True">
                                        <Setter Property="Background" Value="#45475a"/>
                                        <Setter Property="Foreground" Value="#cdd6f4"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </DataGrid.CellStyle>
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Naam" Binding="{Binding Name}" Width="*"/>
                            <DataGridTextColumn Header="Status" Binding="{Binding State}" Width="100"/>
                            <DataGridTextColumn Header="WSL Versie" Binding="{Binding Version}" Width="90"/>
                            <DataGridTextColumn Header="Default" Binding="{Binding Default}" Width="70"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Border>
            </Grid>

            <!-- Raspberry Pi Pico Paneel -->
            <Grid Grid.Row="2" Margin="0,0,0,8">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                
                <Grid Grid.Row="0" Margin="0,0,0,8">
                    <TextBlock Text="&#x1F50C; Raspberry Pi Pico" Foreground="#cdd6f4" FontWeight="SemiBold" FontSize="14" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Content="&#x1F50C; Koppelen" Style="{StaticResource SmallActionBtn}" Name="btnPico"/>
                    </StackPanel>
                </Grid>

                <Border Grid.Row="1" Background="#313244" CornerRadius="8" Padding="2">
                    <DataGrid Name="dgPicos" AutoGenerateColumns="False" Background="Transparent" BorderThickness="0"
                              RowBackground="#313244" AlternatingRowBackground="#363849" Foreground="#cdd6f4" FontSize="13"
                              GridLinesVisibility="None" HeadersVisibility="Column" SelectionMode="Single"
                              CanUserAddRows="False" CanUserDeleteRows="False" IsReadOnly="True">
                        <DataGrid.ColumnHeaderStyle>
                            <Style TargetType="DataGridColumnHeader">
                                <Setter Property="Background" Value="#45475a"/>
                                <Setter Property="Foreground" Value="#89b4fa"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                                <Setter Property="Padding" Value="12,8"/>
                                <Setter Property="BorderThickness" Value="0"/>
                            </Style>
                        </DataGrid.ColumnHeaderStyle>
                        <DataGrid.CellStyle>
                            <Style TargetType="DataGridCell">
                                <Setter Property="Padding" Value="12,6"/>
                                <Setter Property="BorderThickness" Value="0"/>
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="DataGridCell">
                                            <Border Padding="{TemplateBinding Padding}" Background="{TemplateBinding Background}">
                                                <ContentPresenter VerticalAlignment="Center"/>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </DataGrid.CellStyle>
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Pico ID" Binding="{Binding Id}" Width="150"/>
                            <DataGridTextColumn Header="Omschrijving" Binding="{Binding Desc}" Width="*"/>
                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="150"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Border>
            </Grid>
        </Grid>

        <Border Grid.Row="3" Background="#313244" CornerRadius="6" Padding="12,8" Margin="0,4,0,0">
            <TextBlock Name="txtStatus" Text="Gereed." Foreground="#a6adc8" FontSize="12"/>
        </Border>

        <Border Grid.Row="4" Background="#181825" CornerRadius="6" Padding="8" Margin="0,8,0,0"
                MaxHeight="100">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <TextBlock Name="txtLog" Text="" Foreground="#6c7086" FontSize="11"
                           FontFamily="Consolas" TextWrapping="Wrap"/>
            </ScrollViewer>
        </Border>

    </Grid>
    </DockPanel>
</Window>
"@

# Parse XAML
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# Get controls
$dgDistros = $window.FindName("dgDistros")
$dgPicos = $window.FindName("dgPicos")
$btnRefresh = $window.FindName("btnRefresh")
$btnInstall = $window.FindName("btnInstall")
$btnRemove = $window.FindName("btnRemove")
$btnStart = $window.FindName("btnStart")
$btnStop = $window.FindName("btnStop")
$btnPico = $window.FindName("btnPico")
$btnCloneRepo = $window.FindName("btnCloneRepo")
$btnTerminal = $window.FindName("btnTerminal")
$btnBuild = $window.FindName("btnBuild")
$btnFlash = $window.FindName("btnFlash")
$btnInstallWSL = $window.FindName("btnInstallWSL")
$pnlWslMissing = $window.FindName("pnlWslMissing")
$txtWslError = $window.FindName("txtWslError")
$pnlMainContent = $window.FindName("pnlMainContent")
$picoIcon = [char]::ConvertFromUtf32(0x1F50C)
$txtStatus = $window.FindName("txtStatus")
$txtLog = $window.FindName("txtLog")

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
    } else {
        $pnlWslMissing.Visibility = "Visible"
        $pnlMainContent.Visibility = "Collapsed"
        # Show specific reason in the banner
        $reason = $script:wslState.reason
        $txtWslError.Text = [char]0x26A0 + " $reason"
        $txtStatus.Text = $reason

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
    $projectPath = Get-ProjectPath
    if ($projectPath) {
        $btnTerminal.IsEnabled = $true
        $btnTerminal.ToolTip = "Open terminal in: $projectPath"
        $btnBuild.IsEnabled = $true
        $btnBuild.ToolTip = "Build project in: $projectPath"
        $btnFlash.IsEnabled = $true
        $btnFlash.ToolTip = "Flash firmware naar gekoppelde Pico"
    } else {
        $btnTerminal.IsEnabled = $false
        $btnTerminal.ToolTip = "Haal eerst het DSP project op"
        $btnBuild.IsEnabled = $false
        $btnBuild.ToolTip = "Haal eerst het DSP project op"
        $btnFlash.IsEnabled = $false
        $btnFlash.ToolTip = "Haal eerst het DSP project op"
    }
}

# Log file in same directory as script
$logFile = Join-Path $scriptDir "WSL-Setup.log"

# Helper: run a command as administrator (elevated) and capture output
# Uses a temp script + output file since elevated processes can't pipe back to the caller
function Invoke-Elevated {
    param([string]$Command)
    $outputFile = Join-Path $env:TEMP "wsl-admin-output.txt"
    $scriptFile = Join-Path $env:TEMP "wsl-admin-cmd.ps1"
    Remove-Item $outputFile -ErrorAction SilentlyContinue
    
    # Fix 1: Vervang 'usbipd' door het absolute pad, omdat het Admin account vaak een ander PATH heeft
    $cmdText = $Command
    $usbipdCmd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
    if ($usbipdCmd) {
        $cmdText = $cmdText -replace '\busbipd\b', "& '$($usbipdCmd.Source)'"
    }

    # Write a small script that runs the command and captures all output
    $scriptContent = @"
try {
    `$(
        $cmdText
    ) *>&1 | Out-File -FilePath '$outputFile' -Encoding UTF8 -Append
} catch {
    `$_.Exception.Message | Out-File -FilePath '$outputFile' -Encoding UTF8 -Append
}
"@
    Set-Content -Path $scriptFile -Value $scriptContent -Encoding UTF8
    # Fix 2: -WindowStyle Hidden is verwijderd. Deze vlag blokkeert op veel pc's stilletjes de UAC prompt!
    $proc = Start-Process powershell.exe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`"" `
        -Verb RunAs -Wait -PassThru -ErrorAction SilentlyContinue
    $lines = @()
    if (Test-Path $outputFile) {
        $lines = Get-Content $outputFile -Encoding UTF8 -ErrorAction SilentlyContinue
        Remove-Item $outputFile -ErrorAction SilentlyContinue
    }
    Remove-Item $scriptFile -ErrorAction SilentlyContinue
    return $lines
}

# Helper: log message (GUI + file)
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    # Write to file
    try { Add-Content -Path $logFile -Value $logLine -Encoding UTF8 } catch {}
    # Write to GUI
    $txtLog.Text += "$logLine`n"
    $txtStatus.Text = $Message
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
                Default = if ($isDefault) { "★" } else { "" }
            }
            $dgDistros.Items.Add($item) | Out-Null
        }
    }

    Write-Log "$($dgDistros.Items.Count) distro('s) gevonden."
}

# Button: Refresh
$btnRefresh.Add_Click({
    Refresh-Distros
})

# Helper: disable/enable all buttons during long operations
function Set-ButtonsEnabled {
    param([bool]$Enabled)
    $btnInstall.IsEnabled = $Enabled
    $btnRefresh.IsEnabled = $Enabled
    $btnStart.IsEnabled = $Enabled
    $btnStop.IsEnabled = $Enabled
    $btnPico.IsEnabled = $Enabled
    $btnRemove.IsEnabled = $Enabled
    $btnCloneRepo.IsEnabled = $Enabled
    $btnTerminal.IsEnabled = $Enabled
    $btnBuild.IsEnabled = $Enabled
    $btnFlash.IsEnabled = $Enabled
}

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
        [System.Windows.MessageBox]::Show($window,
            "Virtualisatie (VT-x / AMD-V) moet worden ingeschakeld in het BIOS.`n`nDit kan niet automatisch worden gedaan.`n`n1. Herstart de computer`n2. Ga naar het BIOS (meestal DEL of F2 bij opstarten)`n3. Schakel Virtualization Technology in`n4. Sla op en herstart",
            "BIOS instelling vereist",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    $result = [System.Windows.MessageBox]::Show($window,
        "$actionDesc`n`nDit vereist administratorrechten en waarschijnlijk een herstart.`n`nDoorgaan?",
        $actionDesc,
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $btnInstallWSL.IsEnabled = $false
    $txtStatus.Text = "$actionDesc... (dit kan even duren)"
    Write-Log "$actionDesc via '$action'..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $wslInstallOutput = @()
    try {
        $lines = Invoke-Elevated $action
        foreach ($rawLine in $lines) {
            $line = ($rawLine -replace '\x00', '').Trim()
            if ($line) {
                Write-Log $line
                $wslInstallOutput += $line
            }
        }
    } catch {
        Write-Log "$actionDesc geannuleerd of mislukt: $_"
        $btnInstallWSL.IsEnabled = $true
        $txtStatus.Text = "$actionDesc geannuleerd."
        return
    }

    # After running the elevated command, re-check WSL state
    Start-Sleep -Seconds 2
    Update-WslPresence

    if ($script:wslInstalled) {
        Write-Log "WSL is nu functioneel!"
        Refresh-Distros
        $txtStatus.Text = "WSL is gereed! Je kunt nu een DSP distro installeren."
        [System.Windows.MessageBox]::Show($window,
            "WSL is succesvol geconfigureerd!`n`nJe kunt nu een DSP distro installeren via de groene knop.",
            "WSL Gereed",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    } else {
        Write-Log "WSL nog niet functioneel na $actionDesc. Herstart waarschijnlijk nodig."
        $btnInstallWSL.IsEnabled = $true
        [System.Windows.MessageBox]::Show($window,
            "De wijziging is doorgevoerd maar de computer moet waarschijnlijk opnieuw worden opgestart.`n`nHerstart je computer en start daarna dit programma opnieuw.",
            "Herstart vereist",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
    }
})

# Button: Install new Ubuntu 24.04
$btnInstall.Add_Click({
    $window.Topmost = $true; $window.Topmost = $false

    # Verify WSL is actually functional before attempting distro install
    if (-not $script:wslInstalled) {
        [System.Windows.MessageBox]::Show($window,
            "WSL is nog niet actief.`n`nAls je WSL net hebt geinstalleerd, herstart dan eerst je computer.",
            "WSL niet actief",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    $result = [System.Windows.MessageBox]::Show($window,
        "Wil je een nieuwe DSP distro (Ubuntu 24.04) installeren?`n`nGebruiker: student`nWachtwoord: student`n`nDit kan enkele minuten duren.`nDe interface reageert niet tijdens de installatie.",
        "Nieuwe DSP Distro Installeren",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
        Write-Log "Installatie geannuleerd."
        return
    }

    # Check if any Ubuntu distro already exists
    $existing = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
    $existingUbuntu = $existing -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -match "^Ubuntu" -and $_ -notmatch "^docker-desktop" }

    if ($existingUbuntu.Count -gt 0) {
        $foundList = ($existingUbuntu | Select-Object -Unique) -join " en "

        $overwrite = [System.Windows.MessageBox]::Show($window,
            "$foundList bestaat al!`n`nWil je deze VERWIJDEREN en opnieuw installeren?`nAlle data in deze distro('s) gaat verloren!",
            "Distro bestaat al",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($overwrite -ne [System.Windows.MessageBoxResult]::Yes) {
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

    # Quick network check before downloading
    $netOk = $false
    try { $netOk = (Test-Connection -ComputerName raw.githubusercontent.com -Count 1 -Quiet -ErrorAction SilentlyContinue) } catch {}
    if (-not $netOk) {
        Write-Log "Geen internetverbinding gedetecteerd."
        Stop-InstallTimer
        $window.Title = "DSP WSL Manager"
        Set-ButtonsEnabled $true
        [System.Windows.MessageBox]::Show($window,
            "Geen internetverbinding gevonden.`n`nDe installatie heeft internet nodig om Ubuntu te downloaden.`nControleer je verbinding en probeer het opnieuw.",
            "Geen internet",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    # Determine correct Ubuntu distro name from available online list
    Write-Log "Beschikbare distributies ophalen..."
    $onlineList = (& wsl --list --online 2>&1 | Out-String) -replace '\x00', ''
    Write-Log "Online lijst: $onlineList"
    # Try Ubuntu-24.04 first, then Ubuntu24.04, then just Ubuntu
    $distroName = $null
    foreach ($candidate in @("Ubuntu-24.04", "Ubuntu24.04", "Ubuntu-24.04-LTS")) {
        if ($onlineList -match [regex]::Escape($candidate)) {
            $distroName = $candidate
            break
        }
    }
    if (-not $distroName) {
        # Fallback: pick any Ubuntu line from the online list
        $ubuntuLine = ($onlineList -split "`r?`n" | Where-Object { $_ -match "^\s*Ubuntu" } | Select-Object -First 1)
        if ($ubuntuLine -and $ubuntuLine -match "^\s*(\S+)") {
            $distroName = $Matches[1]
        } else {
            $distroName = "Ubuntu"
        }
    }
    Write-Log "Geselecteerde distributie: $distroName"

    # Install the distro with --no-launch so we can configure it
    Write-Log "wsl --install -d $distroName --no-launch"
    $installOutput = @()
    try {
        # Distro install does not require admin — WSL is already installed at this point
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        $lines = (& wsl --install -d $distroName --no-launch 2>&1) | ForEach-Object { ($_ | Out-String) -replace '\x00', '' }
        foreach ($rawLine in $lines) {
            $line = ($rawLine -replace '\x00', '').Trim()
            $line = $line -replace 'ge´nstalleerd', 'geinstalleerd'
            if ($line) {
                Write-Log $line
                $installOutput += $line
            }
        }
    } catch {
        Write-Log "Distro installatie geannuleerd of mislukt: $_"
        Stop-InstallTimer
        $window.Title = "DSP WSL Manager"
        Set-ButtonsEnabled $true
        $txtStatus.Text = "Installatie geannuleerd."
        return
    }

    # Don't trust text output for success/failure — WSL often mixes informational reboot
    # messages with successful installs. Instead, verify the distro actually exists.
    # Retry several times because WSL install can take time to register the distro.
    Write-Log "Wachten tot distro beschikbaar is..."
    $script:installBaseText = "Wachten op distro registratie..."
    $hasUbuntu = $null
    for ($i = 0; $i -lt 12; $i++) {
        # Flush UI so timer keeps ticking during sleep
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        # Sleep in small steps to allow timer updates
        for ($s = 0; $s -lt 5; $s++) {
            Start-Sleep -Seconds 1
            $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
        }
        $postInstall = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
        $installedDistros = $postInstall -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" -and $_ -notmatch "^docker-desktop" }
        $hasUbuntu = $installedDistros | Where-Object { $_ -match "Ubuntu" }
        if ($hasUbuntu) {
            Write-Log "Distro gevonden na $((($i+1)*5)) seconden."
            break
        }
        Write-Log "Poging $(($i+1))/12: distro nog niet gevonden..."
    }

    if (-not $hasUbuntu) {
        Write-Log "Distro niet gevonden na 60 seconden. Installatie output: $($installOutput -join ' | ')"
        Stop-InstallTimer
        $window.Title = "DSP WSL Manager"
        Set-ButtonsEnabled $true
        [System.Windows.MessageBox]::Show($window,
            "De distro is niet gevonden na installatie.`n`nMogelijk moet de computer opnieuw worden opgestart,`nof is er onvoldoende rechten/netwerkverbinding.`n`nControleer het logbestand voor details.",
            "Distro niet gevonden",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }
    $actualDistroName = $hasUbuntu | Select-Object -First 1
    Write-Log "Geinstalleerde distro naam: $actualDistroName"
    # Update the script-level distro name for all subsequent operations
    $script:dspDistro = $actualDistroName

    # Clean up generic "Ubuntu" distro if wsl --install created it as a side effect (only if we also have a versioned one)
    if ($script:dspDistro -ne "Ubuntu") {
        $postClean = (& wsl --list --quiet 2>&1 | Out-String) -replace '\x00', ''
        if (($postClean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "^Ubuntu$" }).Count -gt 0) {
            Write-Log "Extra 'Ubuntu' distro gevonden, verwijderen..."
            & wsl --unregister Ubuntu 2>&1 | Out-Null
        }
    }

    # Configure default user via /etc/wsl.conf and create user
    Write-Log "Gebruiker aanmaken, packages updaten en tools installeren..."
    $script:installBaseText = "Tools en SDK installeren..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Launch the distro to set up the user
    $setupScript = @"
#!/bin/bash
set -e

echo ">>> Creating user student..."
useradd -m -s /bin/bash -G sudo,plugdev student 2>/dev/null || echo "User student already exists"
echo 'student:student' | chpasswd
STUDENT_UID=`$(id -u student)
echo ">>> student UID = `$STUDENT_UID"

# Set as default user in wsl.conf
echo ">>> Writing /etc/wsl.conf..."
cat > /etc/wsl.conf << 'WSLCONF'
[boot]
systemd=true

[user]
default=student
WSLCONF

# Disable Ubuntu OOBE first-run wizard
echo ">>> Disabling OOBE via /etc/wsl-distribution.conf..."
cat > /etc/wsl-distribution.conf << DISTCONF
[oobe]
command = /bin/true
defaultUid = `$STUDENT_UID
DISTCONF

# Also disable any cloud-init based first-run
if [ -d /etc/cloud ]; then
    echo ">>> Disabling cloud-init..."
    touch /etc/cloud/cloud-init.disabled
fi

# Set up udev rules for all Raspberry Pi Pico modes
echo ">>> Writing udev rules for Pico..."
cat > /etc/udev/rules.d/99-pico.rules << 'UDEV'
# Raspberry Pi Pico - all device modes
# RP2040 BOOTSEL mode
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0003", MODE="0666", GROUP="plugdev"
# RP2040 CDC serial (MicroPython/CircuitPython REPL)
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0005", MODE="0666", GROUP="plugdev"
# RP2040 vendor-specific (picotool/custom firmware)
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="000a", MODE="0666", GROUP="plugdev"
# RP2350 BOOTSEL mode (Pico 2)
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="000f", MODE="0666", GROUP="plugdev"
# RP2350 CDC serial (Pico 2)
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", ATTR{idProduct}=="0009", MODE="0666", GROUP="plugdev"
# Catch-all for any Raspberry Pi device
SUBSYSTEM=="usb", ATTR{idVendor}=="2e8a", MODE="0666", GROUP="plugdev"
UDEV

# Update package index
export DEBIAN_FRONTEND=noninteractive
echo ">>> apt update..."
apt-get update -y
echo ">>> apt upgrade..."
apt-get upgrade -y

# Install build dependencies and libusb
echo ">>> Installing build tools and libusb..."
apt-get install -y build-essential cmake pkg-config git \
    libusb-1.0-0 libusb-1.0-0-dev python3 usbutils

# ARM toolchain for Pico firmware development
echo ">>> Installing ARM toolchain..."
apt-get install -y gcc-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib

# Install Pico SDK (shallow clone, no heavy submodules)
echo ">>> Cloning Pico SDK (shallow)..."
PICO_SDK_PATH="/opt/pico-sdk"
if [ -d "`$PICO_SDK_PATH" ]; then
    echo "Pico SDK already exists, skipping clone."
else
    git clone --depth 1 https://github.com/raspberrypi/pico-sdk.git "`$PICO_SDK_PATH"
    cd "`$PICO_SDK_PATH"
    echo ">>> Pico SDK submodules initialiseren (tinyusb etc.)..."
    git submodule update --init --depth 1
    cd /
fi

# Set PICO_SDK_PATH globally
echo ">>> Setting PICO_SDK_PATH environment variable..."
echo "export PICO_SDK_PATH=`$PICO_SDK_PATH" > /etc/profile.d/pico-sdk.sh
chmod +x /etc/profile.d/pico-sdk.sh

# Build and install picotool from source
echo ">>> Cloning and building picotool (shallow)..."
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

    Write-Log "Setup script starten in WSL..."
    # Write setup script to temp file with Unix line endings
    $setupScript = $setupScript -replace "`r`n", "`n"
    $tempFile = Join-Path $env:TEMP "wsl-setup.sh"
    [System.IO.File]::WriteAllText($tempFile, $setupScript, [System.Text.UTF8Encoding]::new($false))
    # Convert Windows path to WSL /mnt/ path directly (no wslpath call needed)
    $drive = $tempFile.Substring(0,1).ToLower()
    $wslTempPath = "/mnt/$drive" + ($tempFile.Substring(2) -replace '\\', '/')
    Write-Log "Script pad: $wslTempPath"
    & wsl -d $script:dspDistro -u root -- bash "$wslTempPath" 2>&1 | ForEach-Object {
        Write-Log $_
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    # Also try to set default user via the Ubuntu launcher exe (belt-and-suspenders)
    # Only use versioned exe (ubuntu2404.exe) — generic ubuntu.exe can hang
    Write-Log "Default user instellen via Ubuntu launcher..."
    $launcherFound = $false
    foreach ($exeName in @("ubuntu2404.exe", "ubuntu24.04.exe")) {
        $exe = Get-Command $exeName -ErrorAction SilentlyContinue
        if ($exe) {
            Write-Log "Gevonden: $exeName"
            $proc = Start-Process -FilePath $exe.Source -ArgumentList "config","--default-user","student" -NoNewWindow -Wait -PassThru -ErrorAction SilentlyContinue
            Write-Log "  Exit code: $($proc.ExitCode)"
            $launcherFound = $true
            break
        }
    }
    if (-not $launcherFound) {
        Write-Log "Geen versioned Ubuntu launcher gevonden - wsl.conf + wsl-distribution.conf worden gebruikt."
    }

    # Terminate and restart so wsl.conf takes effect
    Write-Log "WSL herstarten om configuratie toe te passen..."
    & wsl --terminate $script:dspDistro 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # Set as default WSL distro
    Write-Log "$($script:dspDistro) instellen als standaard WSL distro..."
    & wsl --set-default $script:dspDistro 2>&1 | Out-Null

    # Auto-start the distro so it's immediately ready
    Write-Log "WSL distro starten..."
    & wsl -d $script:dspDistro -- echo "WSL is gestart" 2>&1 | ForEach-Object {
        Write-Log $_
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }

    Write-Log "Ubuntu 24.04 is geinstalleerd en gestart! (user: student / ww: student)"

    # Re-enable buttons and restore title
    Stop-InstallTimer
    $window.Title = "DSP WSL Manager"
    Set-ButtonsEnabled $true
    Refresh-Distros

    $window.Topmost = $true; $window.Topmost = $false
    [System.Windows.MessageBox]::Show($window,
        "DSP distro is succesvol geinstalleerd en gestart!`n`nGebruiker: student`nWachtwoord: student`nSystemd: ingeschakeld`nPico udev rule: ingesteld`nStandaard distro: ja`n`nGeinstalleerde tools:`n- Pico SDK (/opt/pico-sdk)`n- picotool (from source)`n- libusb-1.0`n- gcc-arm-none-eabi`n- cmake, build-essential",
        "Installatie Voltooid",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    )
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
    $txtStatus.Text = "'$distroName' stoppen..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    & wsl --terminate $distroName 2>&1 | Out-Null
    Write-Log "'$distroName' is gestopt."
    Refresh-Distros
})

# Button: Open interactive WSL terminal in project folder
$btnTerminal.Add_Click({
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        [System.Windows.MessageBox]::Show($window,
            "Haal eerst het DSP project op via 'DSP Project Ophalen'.",
            "Project niet gevonden",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
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
        $installResult = [System.Windows.MessageBox]::Show($window,
            "usbipd-win is niet geinstalleerd.`nDit is nodig om USB-apparaten aan WSL te koppelen.`n`nWil je usbipd-win nu installeren via winget?",
            "usbipd-win niet gevonden",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($installResult -eq [System.Windows.MessageBoxResult]::Yes) {
            Write-Log "usbipd-win installeren via winget..."
            & winget install --id dorssel.usbipd-win --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object {
                Write-Log $_
                $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
            }
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            $usbipd = Get-Command usbipd.exe -ErrorAction SilentlyContinue
            if (-not $usbipd) {
                Write-Log "usbipd-win installatie mislukt of herstart nodig."
                [System.Windows.MessageBox]::Show($window,
                    "usbipd-win kon niet gevonden worden na installatie.`nHerstart de PC en probeer het opnieuw.",
                    "Herstart nodig",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
                return
            }
        } else {
            return
        }
    }

    Write-Log "usbipd gevonden, USB-apparaten scannen..."

    # Step 2: Detect Pico via usbipd list
    $usbipdOutput = & usbipd list 2>&1 | Out-String
    Write-Log $usbipdOutput

    # Negeer opgeslagen spookapparaten, focus alleen op fysiek aangesloten poorten
    $connectedPart = $usbipdOutput
    $persistedIdx = $usbipdOutput.IndexOf("Persisted:")
    if ($persistedIdx -ge 0) { $connectedPart = $usbipdOutput.Substring(0, $persistedIdx) }

    $picoLines = $connectedPart -split "`r?`n" | Where-Object { $_ -match "2e8a|RP2040|RP2350|Raspberry Pi|Pico" }

    if ($picoLines.Count -eq 0) {
        [System.Windows.MessageBox]::Show($window,
            "Geen Raspberry Pi Pico gevonden.`n`nZorg dat de Pico via USB is aangesloten.`nHoud BOOTSEL ingedrukt bij het aansluiten voor programmeer-modus.",
            "Pico niet gevonden",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
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
        foreach ($line in $lines) { Write-Log $line }

        [System.Windows.MessageBox]::Show($window,
                "De Pico had een verbindingsfout (wel gereserveerd, maar niet verbonden).`n`nHet apparaat is nu volledig ontkoppeld en gereset.`n`nKlik nogmaals op de knop om de Pico schoon te koppelen.",
                "Pico Hersteld",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        Update-PicoButton
        return
    }

    # LOGICA 2: Geheel Gekoppeld
    elseif ($devStatus -eq "Attached") {
        $detachResult = [System.Windows.MessageBox]::Show($window,
            "Pico is momenteel GEHEEL GEKOPPELD aan WSL.`n`nID: $devId`n$picoDesc`n`nWil je de Pico ontkoppelen?",
            "Pico Ontkoppelen",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($detachResult -eq [System.Windows.MessageBoxResult]::Yes) {
            Write-Log "Pico ontkoppelen en vrijgeven (admin rechten nodig)..."
            $lines = Invoke-Elevated "usbipd unbind $idFlag $devId"
            foreach ($line in $lines) { Write-Log $line }
            Write-Log "Pico is ontkoppeld."
            $btnPico.Content = "$picoIcon Pico koppelen"
            [System.Windows.MessageBox]::Show($window,
                "Pico is ontkoppeld van WSL.`nHet apparaat is weer beschikbaar voor Windows.",
                "Pico Ontkoppeld",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        }
        Update-PicoButton
        return
    }

    # LOGICA 3: Totaal Ontkoppeld
    elseif ($devStatus -eq "Not shared") {
        $attachResult = [System.Windows.MessageBox]::Show($window,
            "Pico gevonden (TOTAAL ONTKOPPELD).`n`nID: $devId`n$picoDesc`n`nWil je dit apparaat koppelen aan WSL?",
            "Pico Koppelen",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )

        if ($attachResult -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-Log "Koppelen geannuleerd."
            return
        }

        # Bind (met force) en Attach (met wsl flag)
        Write-Log "Pico binden (admin rechten nodig): $idFlag $devId..."
        $lines = Invoke-Elevated "usbipd bind $idFlag $devId --force"
        foreach ($line in $lines) { Write-Log $line }
        Start-Sleep -Seconds 1
        Write-Log "Pico auto-koppelen aan WSL (background proces)..."
        Start-Process -FilePath "usbipd.exe" -ArgumentList "attach --wsl $idFlag $devId --auto-attach" -WindowStyle Hidden

        # Verificatie in WSL
        Start-Sleep -Seconds 2
        $lsusbOutput = & wsl -d $script:dspDistro -- lsusb 2>&1 | Out-String
        Write-Log "lsusb output: $lsusbOutput"
        $picoFound = $lsusbOutput -match "2e8a|RP2040|RP2350"

        if ($picoFound) {
            Write-Log "Pico zichtbaar in WSL (lsusb bevestigd)."
            $btnPico.Content = "$picoIcon Pico ontkoppelen"
            [System.Windows.MessageBox]::Show($window,
                "Pico is succesvol gekoppeld aan WSL!`n`nHet apparaat is nu beschikbaar in de WSL-omgeving.",
                "Pico Gekoppeld",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        } else {
            Write-Log "Pico niet zichtbaar in WSL na attach."
            [System.Windows.MessageBox]::Show($window,
                "Pico is gekoppeld maar niet zichtbaar in WSL.`n`nMogelijk moet de WSL distro herstarten of ligt het aan de rechten.",
                "Verificatie mislukt",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            )
        }
        Update-PicoButton
    }
})

# Button: Clone DSP project repo
$btnCloneRepo.Add_Click({
    Write-Log "DSP Project ophalen..."

    # Check if WSL distro is running
    $wslCheck = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
    if (-not ($wslCheck -match "$([regex]::Escape($script:dspDistro))\s+Running")) {
        [System.Windows.MessageBox]::Show($window,
            "WSL is niet actief.`nStart eerst de WSL via de 'Start WSL' knop.",
            "WSL niet actief",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    # Open folder picker dialog
    Add-Type -AssemblyName System.Windows.Forms
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Kies een map om het DSP project in op te slaan"
    $folderDialog.ShowNewFolderButton = $true

    if ($folderDialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Log "Map selectie geannuleerd."
        return
    }

    $targetFolder = $folderDialog.SelectedPath
    $projectFolder = Join-Path $targetFolder "avd-dsp-project"

    # Check if folder already exists
    if (Test-Path $projectFolder) {
        $overwrite = [System.Windows.MessageBox]::Show($window,
            "De map 'avd-dsp-project' bestaat al in:`n$targetFolder`n`nWil je de bestaande map verwijderen en opnieuw ophalen?",
            "Map bestaat al",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($overwrite -ne [System.Windows.MessageBoxResult]::Yes) {
            Write-Log "Clone geannuleerd."
            return
        }
        Write-Log "Bestaande map verwijderen..."
        Remove-Item -Path $projectFolder -Recurse -Force
    }

    # Convert Windows path to WSL /mnt/ path
    $drive = $targetFolder.Substring(0,1).ToLower()
    $wslTargetPath = "/mnt/$drive" + ($targetFolder.Substring(2) -replace '\\', '/')

    Write-Log "Clonen naar: $projectFolder"
    Write-Log "WSL pad: $wslTargetPath"
    $txtStatus.Text = "DSP project ophalen..."
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Clone via WSL git with progress (no git needed on Windows)
    & wsl -d $script:dspDistro -- git clone --progress https://github.com/dkroeske/avd-dsp-project.git "$wslTargetPath/avd-dsp-project" 2>&1 | ForEach-Object {
        $line = "$_"
        # Extract percentage from git progress lines (e.g. "Receiving objects:  45% (123/456)")
        if ($line -match "(\d+)%") {
            $txtStatus.Text = "DSP project ophalen... $($Matches[1])%"
        }
        Write-Log $line
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
    $txtStatus.Text = "Gereed."

    if (Test-Path $projectFolder) {
        Save-ProjectPath $projectFolder
        Update-TerminalButton
        Write-Log "DSP project succesvol opgehaald naar: $projectFolder"
        [System.Windows.MessageBox]::Show($window,
            "DSP project is opgehaald!`n`nLocatie: $projectFolder`n`nDe 'Open Terminal' knop opent nu in deze map.",
            "Project Opgehaald",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    } else {
        Write-Log "Clone lijkt mislukt - map niet gevonden."
        [System.Windows.MessageBox]::Show($window,
            "Het ophalen van het project is mislukt.`nControleer het logbestand voor details.",
            "Clone Mislukt",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
})

# Helper: Flash the built .uf2 image to the Pico
function Flash-Pico {
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        [System.Windows.MessageBox]::Show($window,
            "Haal eerst het DSP project op via 'DSP Project Ophalen'.",
            "Project niet gevonden",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    $buildDir = Join-Path $projectPath "build"
    $uf2File = $null
    if (Test-Path $buildDir) {
        $uf2File = Get-ChildItem -Path $buildDir -Filter "*.uf2" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if (-not $uf2File) {
        [System.Windows.MessageBox]::Show($window,
            "Geen .uf2 bestand gevonden in de build directory.`nBuild eerst het project.",
            "Geen firmware",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    # Check if Pico is connected and coupled to WSL
    $usbipdExe = Get-Command usbipd.exe -ErrorAction SilentlyContinue
    if (-not $usbipdExe) {
        [System.Windows.MessageBox]::Show($window,
            "usbipd is niet gevonden. Kan de Pico niet bereiken.",
            "Fout",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
        return
    }

    $usbipdOut = & usbipd list 2>&1 | Out-String
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
        [System.Windows.MessageBox]::Show($window,
            "Geen Pico gevonden die momenteel gekoppeld is aan WSL.`n`nKlik eerst op 'Pico koppelen' om de Pico met WSL te verbinden.",
            "Pico niet gekoppeld",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
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
    $txtStatus.Text = "Pico flashen..."
    Set-ButtonsEnabled $false
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    $uf2WinPath = $uf2File.FullName
    $uf2Drive = $uf2WinPath.Substring(0,1).ToLower()
    $uf2WslPath = "/mnt/$uf2Drive" + ($uf2WinPath.Substring(2) -replace '\\', '/')

    $devId = $targetPico.Id
    $idFlag = if ($devId -match "-" -and $devId.Length -gt 10) { "--guid" } else { "--busid" }

    if ($targetPico.Desc -notmatch "Boot") {
        Write-Log "Pico is in applicatie-modus. Herstarten naar BOOTSEL..."
        & wsl -d $script:dspDistro -u root -- bash -c "export PICO_SDK_PATH=/opt/pico-sdk; picotool reboot -f -u" 2>&1 | Out-Null
        
        Write-Log "Wachten op USB reconnect van de Pico (BOOTSEL modus)..."
        Start-Sleep -Seconds 3
        
        Write-Log "Pico opnieuw binden en koppelen (admin rechten nodig)..."
        $lines = Invoke-Elevated "usbipd bind $idFlag $devId --force"
        Start-Sleep -Seconds 1
        Start-Process -FilePath "usbipd.exe" -ArgumentList "attach --wsl $idFlag $devId --auto-attach" -WindowStyle Hidden
        Start-Sleep -Seconds 2
    }

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

    $flashSuccess = $false
    & wsl -d $script:dspDistro -u root -- bash "$wslFlashPath" 2>&1 | ForEach-Object {
        Write-Log $_
        if ($_ -match "FLASH_COMPLETE") { $flashSuccess = $true }
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
    Remove-Item $tempFlash -ErrorAction SilentlyContinue

    if ($detachedOthers.Count -gt 0) {
        Write-Log "Andere Pico's weer aankoppelen..."
        $bindCmds = @()
        foreach ($dev in $detachedOthers) {
            $bindCmds += "usbipd bind $($dev.Flag) $($dev.Id) --force"
        }
        Invoke-Elevated ($bindCmds -join "; ") | Out-Null
        Start-Sleep -Seconds 1
        foreach ($dev in $detachedOthers) {
            Start-Process -FilePath "usbipd.exe" -ArgumentList "attach --wsl $($dev.Flag) $($dev.Id) --auto-attach" -WindowStyle Hidden
        }
        Update-PicoButton
    }

    Set-ButtonsEnabled $true
    Write-Log "=== FLASH AFGEROND ==="

    if ($flashSuccess) {
        Write-Log "Wachten op herstart van de Pico naar applicatie-modus..."
        Start-Sleep -Seconds 3
        Write-Log "Pico opnieuw binden en koppelen (applicatie-modus)..."
        $lines = Invoke-Elevated "usbipd bind $idFlag $devId --force"
        Start-Process -FilePath "usbipd.exe" -ArgumentList "attach --wsl $idFlag $devId --auto-attach" -WindowStyle Hidden
        Update-PicoButton
    }

    if ($flashSuccess) {
        $window.Topmost = $true; $window.Topmost = $false
        [System.Windows.MessageBox]::Show($window,
            "Firmware is succesvol geflasht naar de Pico!`n`nDe Pico is automatisch herstart.",
            "Flash Voltooid",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    } else {
        $window.Topmost = $true; $window.Topmost = $false
        [System.Windows.MessageBox]::Show($window,
            "Flash is mislukt.`n`nMogelijke oplossingen:`n- Houd BOOTSEL ingedrukt en sluit de Pico opnieuw aan`n- Controleer of de Pico gekoppeld is aan WSL`n- Bekijk het logvenster voor details",
            "Flash Mislukt",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
}

# Button: Build DSP project
$btnBuild.Add_Click({
    $projectPath = Get-ProjectPath
    if (-not $projectPath) {
        [System.Windows.MessageBox]::Show($window,
            "Haal eerst het DSP project op via 'DSP Project Ophalen'.",
            "Project niet gevonden",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
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

    $result = [System.Windows.MessageBox]::Show($window,
        "DSP project builden?`n`nProject: $wslProjectPath`n`nDit voert de volgende stappen uit:`n- Git safe directory instellen`n- Submodules ophalen`n- CMake configuratie genereren`n- Project compileren (make -j8)`n`nDe interface reageert niet tijdens het builden.",
        "Project Builden",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($result -ne [System.Windows.MessageBoxResult]::Yes) {
        Write-Log "Build geannuleerd."
        return
    }

    Set-ButtonsEnabled $false
    $window.Title = "DSP WSL Manager - BEZIG MET BUILDEN..."
    Write-Log "=== BUILD GESTART ==="
    $txtStatus.Text = "Project builden... (interface reageert niet)"
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Write build script to temp file
    $buildScript = @"
#!/bin/bash
set -e

# Load PICO_SDK_PATH (set during WSL install in /etc/profile.d/)
export PICO_SDK_PATH=/opt/pico-sdk
echo ">>> PICO_SDK_PATH=`$PICO_SDK_PATH"

cd "$wslProjectPath"
echo ">>> Working directory: `$(pwd)"

echo ">>> Git safe directory instellen..."
git config --global --add safe.directory "$wslProjectPath"
git config --global --add safe.directory "`$PICO_SDK_PATH"

echo ">>> Submodules ophalen..."
git submodule update --init --recursive

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
    $buildSuccess = $false
    & wsl -d $script:dspDistro -u root -- bash "$wslTempPath" 2>&1 | ForEach-Object {
        Write-Log $_
        if ($_ -match "BUILD VOLTOOID") { $buildSuccess = $true }
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
    Remove-Item $tempFile -ErrorAction SilentlyContinue

    $window.Title = "DSP WSL Manager"
    Set-ButtonsEnabled $true
    Update-TerminalButton
    Write-Log "=== BUILD AFGEROND ==="

    if ($buildSuccess) {
        # Find the .uf2 file in the build directory
        $uf2File = $null
        $buildDir = Join-Path $projectPath "build"
        if (Test-Path $buildDir) {
            $uf2File = Get-ChildItem -Path $buildDir -Filter "*.uf2" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        }

        if ($uf2File) {
            Write-Log "UF2 gevonden: $($uf2File.FullName)"
            $flashResult = [System.Windows.MessageBox]::Show($window,
                "Project is succesvol gebuild!`n`nUF2 bestand: $($uf2File.Name)`n`nWil je de firmware nu naar de Pico flashen?",
                "Build Voltooid - Flashen?",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question
            )

            if ($flashResult -eq [System.Windows.MessageBoxResult]::Yes) {
                Flash-Pico
            }
        } else {
            $window.Topmost = $true; $window.Topmost = $false
            [System.Windows.MessageBox]::Show($window,
                "Project is succesvol gebuild!`n`nGeen .uf2 bestand gevonden in de build directory.`nBuild bestanden staan in:`n$projectPath\build",
                "Build Voltooid",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        }
    } else {
        $window.Topmost = $true; $window.Topmost = $false
        [System.Windows.MessageBox]::Show($window,
            "Build is mislukt.`nControleer het logvenster of het logbestand voor details.",
            "Build Mislukt",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
})

# Button: Remove selected distro
$btnRemove.Add_Click({
    $selected = $dgDistros.SelectedItem
    if (-not $selected) {
        [System.Windows.MessageBox]::Show($window,
            "Selecteer eerst een distro in de lijst.",
            "Geen selectie",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    $distroName = $selected.Name

    # Prevent removing docker distros
    if ($distroName -match "docker") {
        [System.Windows.MessageBox]::Show($window,
            "Docker distro's kunnen niet via deze tool verwijderd worden.",
            "Niet toegestaan",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    $result = [System.Windows.MessageBox]::Show($window,
        "Weet je zeker dat je '$distroName' wilt verwijderen?`n`nALLE DATA IN DEZE DISTRO GAAT VERLOREN!`nDit kan niet ongedaan gemaakt worden!",
        "Distro Verwijderen",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )

    if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
        Write-Log "'$distroName' verwijderen..."
        & wsl --unregister $distroName 2>&1 | ForEach-Object { Write-Log $_ }
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

# Helper: check WSL running state and Pico attach status
function Update-PicoButton {
    try {
        if (-not $script:wslInstalled) {
            $btnPico.IsEnabled = $false
            $btnPico.Content = "$picoIcon Pico (WSL uit)"
            $dgPicos.Items.Clear()
            return
        }
        # Check if Ubuntu distro is running
        $wslOutput = (& wsl --list --verbose 2>&1 | Out-String) -replace '\x00', ''
        $isRunning = $wslOutput -match "$([regex]::Escape($script:dspDistro))\s+Running"

        if (-not $isRunning) {
            $btnPico.IsEnabled = $false
            $btnPico.Content = "$picoIcon Pico (WSL uit)"
            $dgPicos.Items.Clear()
            return
        }

        $btnPico.IsEnabled = $true

        # Check if usbipd is available and Pico is attached
        $usbipdExe = Get-Command usbipd.exe -ErrorAction SilentlyContinue
        if ($usbipdExe) {
            $usbipdOut = & usbipd list 2>&1 | Out-String
            
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
            $dgPicos.Items.Clear()
        }
    } catch {
        # Silently ignore timer errors
    }
}

# Periodic timer: check WSL and Pico status every 5 seconds
$statusTimer = New-Object System.Windows.Threading.DispatcherTimer
$statusTimer.Interval = [TimeSpan]::FromSeconds(5)
$statusTimer.Add_Tick({ Update-PicoButton })
$statusTimer.Start()

# Initial load — clear previous session logs
Set-Content -Path $logFile -Value "========== DSP WSL Manager gestart: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==========" -Encoding UTF8
$txtLog.Text = ""
Write-Log "Logbestand: $logFile"

# Show window immediately with loading state, then run checks
Set-ButtonsEnabled $false
$txtStatus.Text = "Systeem controleren..."

# Use Loaded event to run checks after window is visible
$window.Add_ContentRendered({
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

    # Now run the slow checks (systeminfo etc.)
    Write-Log "WSL status controleren..."
    $script:wslState = Test-WslState
    $script:wslInstalled = $script:wslState.ok

    $script:dspDistro = Find-UbuntuDistro
    if (-not $script:dspDistro) { $script:dspDistro = "Ubuntu-24.04" }

    Update-WslPresence
    if ($script:wslInstalled) {
        Write-Log "WSL gedetecteerd. Distro: $($script:dspDistro)"
        $savedProject = Get-ProjectPath
        if ($savedProject) {
            Write-Log "DSP project gevonden: $savedProject"
        } else {
            Write-Log "Geen DSP project geconfigureerd."
        }
        Refresh-Distros
        Update-PicoButton
        Update-TerminalButton
    } else {
        Write-Log "WSL is niet actief (niet geinstalleerd of herstart nodig)."
    }
    Set-ButtonsEnabled $true
    if (-not $script:wslInstalled) {
        $txtStatus.Text = $script:wslState.reason
    } else {
        $txtStatus.Text = "Gereed."
    }
})

# Show window
$window.ShowDialog() | Out-Null

# Cleanup: stop timer when window closes
$statusTimer.Stop()