[Setup]
AppId={{9D14829D-5B3D-4208-BFCA-0A1A2B95C7F1}
AppName=Ariyabod
AppVersion=1.4.0
AppPublisher=Ariyabod
DefaultDirName={autopf}\Ariyabod
DefaultGroupName=Ariyabod
DisableProgramGroupPage=yes
OutputDir=dist\installer
OutputBaseFilename=Ariyabod-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Ariyabod.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
; Bundle Flutter Windows Release output; skip WebView2 caches created next to the exe.
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.WebView2\*"

[Icons]
Name: "{autoprograms}\Ariyabod"; Filename: "{app}\Ariyabod.exe"
Name: "{autodesktop}\Ariyabod"; Filename: "{app}\Ariyabod.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Ariyabod.exe"; Description: "Launch Ariyabod"; Flags: nowait postinstall skipifsilent
