# DSP WSL Manager — Handleiding

> DT-RAS Digital Signal Processing • Elektrotechniek • Avans Breda

De DSP WSL Manager automatiseert het opzetten van een complete Linux-ontwikkelomgeving voor de Raspberry Pi Pico, direct vanuit Windows — zonder dat je zelf Linux-commando's hoeft te kennen.

---

## Voorbereiding

Download de volgende bestanden en plaats ze in dezelfde map:

- **`DSP-Manager-Core.ps1`** — het hoofdscript
- **`Start DSP Manager.bat`** — de launcher om de tool te starten

---

## Aan de slag

### Stap 1 — Tool openen

Dubbelklik op **`Start DSP Manager.bat`**. De tool controleert automatisch of je systeem klaar is.

### Stap 2 — WSL installeren (eenmalig)

Als WSL ontbreekt verschijnt er een rode banner. Klik op **WSL Installeren**, accepteer de admin-prompt en **herstart de computer**. De tool detecteert ook of VM Platform of BIOS-virtualisatie nog ingeschakeld moet worden.

### Stap 3 — Nieuwe distro aanmaken (eenmalig)

Klik op **Nieuw** bij het WSL Distributies paneel. Er wordt automatisch een Ubuntu 24.04 omgeving geïnstalleerd met alle benodigde tools (ARM toolchain, Pico SDK, picotool). Dit duurt enkele minuten.

### Stap 4 — DSP project ophalen (eenmalig)

Klik op **DSP Project Ophalen** en kies een map. De Git-repository wordt gekloond. De tool onthoudt de locatie.

### Stap 5 — Pico aansluiten en koppelen

Sluit je Raspberry Pi Pico aan via USB. Klik op **Koppelen** in het Pico-paneel. De tool installeert `usbipd-win` automatisch als dat nodig is en koppelt de Pico aan WSL.

### Stap 6 — Bouwen en flashen

Klik op **Project Builden** om je code te compileren. Klik daarna op **Flashen** om de firmware direct naar de Pico te sturen. De Pico wordt automatisch in de juiste modus gezet.

### Dagelijks gebruik

Na de eerste setup herhaal je alleen stap 5 en 6. De typische cyclus is: code schrijven → builden → flashen → testen.

---

## Uitgebreide beschrijving per onderdeel

### DSP Project Acties

De bovenste sectie bevat de knoppen voor je dagelijks werk.

**DSP Project Ophalen** kloont de DSP Git-repository vanuit GitHub naar een zelfgekozen map. Dit hoef je maar één keer te doen.

**Open Terminal** opent een Linux-terminal (WSL) die direct in je projectmap start. Handig voor handmatige commando's, debugging of git-operaties.

**Project Builden** voert een volledige build uit: git safe directories instellen, submodules ophalen, vorige build opruimen, CMake-configuratie genereren met de ARM-toolchain, en compileren met `make`. Het `.uf2` firmwarebestand verschijnt in de `build` map.

**Flashen** stuurt het `.uf2` bestand naar de Pico. De tool zoekt het bestand automatisch, controleert of de Pico gekoppeld is, herstart naar BOOTSEL-modus indien nodig (via `picotool`), flasht de firmware en herstart de Pico. Bij meerdere gekoppelde Pico's verschijnt een selectiescherm.

### WSL Distributies

Het middelste paneel toont alle geïnstalleerde WSL-distributies met hun status.

| Knop | Functie |
|------|---------|
| **Nieuw** | Installeert een nieuwe Ubuntu 24.04 distro met alle benodigde tools |
| **Start** | Start de geselecteerde distro op de achtergrond |
| **Stop** | Stopt de geselecteerde distro |
| **Wis** | Verwijdert de geselecteerde distro (met bevestiging) |
| **🔄** | Vernieuwt de lijst |

Bij het aanmaken van een nieuwe distro wordt automatisch geïnstalleerd: gebruiker `student` (wachtwoord `student`), build tools (`cmake`, `gcc`, `git`), ARM cross-compiler (`gcc-arm-none-eabi`), Raspberry Pi Pico SDK inclusief TinyUSB, `picotool`, en USB-regels voor directe Pico-toegang.

### Raspberry Pi Pico

Het onderste paneel toont aangesloten Pico's en hun koppelstatus. Klik op **Koppelen** om een Pico via USB aan WSL te verbinden. De tool detecteert zowel RP2040 als RP2350 boards en werkt met zowel oudere als nieuwere versies van `usbipd-win`.

### Logvenster

Onderaan de tool staat een logvenster met real-time feedback. Alle regels worden ook opgeslagen in `WSL-Setup.log` voor troubleshooting.

---

## Problemen oplossen

| Probleem | Oplossing |
|----------|-----------|
| Tool start niet | Gebruik `support scripts\Start DSP Manager.bat` als alternatief |
| "WSL is niet geïnstalleerd" | Klik op "WSL Installeren" en herstart de computer |
| "VM Platform mist" | Klik op de knop, herstart, en controleer of VT-x aan staat in het BIOS |
| BIOS-virtualisatie uit | Herstart → BIOS openen (DEL/F2/F10) → Virtualization Technology inschakelen → opslaan |
| Pico niet gevonden | Controleer de USB-kabel en sluit de Pico opnieuw aan |
| Pico niet zichtbaar in WSL | Start WSL eerst via de Start-knop, koppel dan de Pico |
| Build mislukt | Bekijk het logvenster voor foutmeldingen |
| Flash mislukt | Houd BOOTSEL ingedrukt terwijl je de Pico aansluit, koppel opnieuw |

---

*Crafted by Danny van der Zande*
