# Instellingen
$IconFile   = "C:\Users\danny\Downloads\DSP GUI\assets\RPI_Pico_WSL_DSP.ico"
$OutputDir  = "C:\Users\danny\Downloads\DSP GUI"
$ExeName    = "Start DSP Manager.exe"

$OutputPath = Join-Path $OutputDir $ExeName

# ==============================================================================
# VUL HIER HET PAD IN NAAR HET POWERSHELL SCRIPT (.ps1) DAT GESTART MOET WORDEN.
# Dit is relatief ten opzichte van waar de EXE komt te staan.
# ==============================================================================
$TargetPS1  = "DSP-Manager-Core.ps1"
# ==============================================================================


Write-Host "Bezig met bouwen van de PowerShell Launcher EXE..." -ForegroundColor Cyan

# C# Code voor de EXE
$CsharpCode = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

public class Program {
    public static void Main() {
        try {
            // Bepaal de map waar de EXE op dit moment staat
            string currentDir = AppDomain.CurrentDomain.BaseDirectory;
            string scriptPath = Path.Combine(currentDir, @"$TargetPS1");

            // Controleer of het .ps1 script bestaat
            if (!File.Exists(scriptPath)) {
                MessageBox.Show("Kan het PowerShell script niet vinden!\n\nVerwacht pad:\n" + scriptPath, "Bestand niet gevonden", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Start powershell.exe met de Bypass command en het script
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            
            // Geef de bypass mee, zorg dat hij afsluit na afloop, en voer het bestand uit
            psi.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File \"" + scriptPath + "\"";
            
            // Zorg dat het script wordt uitgevoerd in de map waar het script staat
            psi.WorkingDirectory = Path.GetDirectoryName(scriptPath);
            
            // Dit zorgt ervoor dat er ABSOLUUT GEEN zwart of blauw venster oppopt
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            
            Process.Start(psi);
            
        } catch (Exception ex) {
            MessageBox.Show("Fout bij starten van PowerShell:\n" + ex.Message, "Systeem Fout", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
"@

# Compiler pad (standaard in Windows)
$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

# Compileren met referentie naar Windows Forms voor eventuele fout-popups
& $csc /target:winexe /out:"$OutputPath" /win32icon:"$IconFile" /reference:System.Windows.Forms.dll /reference:System.dll ([System.IO.Path]::GetTempFileName() | %{ 
    Set-Content $_ $CsharpCode; $_ 
})

if (Test-Path $OutputPath) {
    Write-Host "Klaar! De EXE is succesvol gegenereerd." -ForegroundColor Green
    Write-Host "Je kunt de .bat file nu veilig weggooien." -ForegroundColor Green
} else {
    Write-Host "De compiler kon de EXE niet maken. Controleer je paden." -ForegroundColor Red
}