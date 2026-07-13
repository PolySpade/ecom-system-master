; Ecom Video Tracker - Inno Setup installer (PKG-01/PKG-02)
;
; Design notes:
; - The app stores its data (database.db, videos\, logs\, settings.json)
;   BESIDE the executable (ecom-py parity, config BASE_DIR = exe dir), so it
;   installs per-user to {localappdata}\Programs where writes never need
;   admin rights. PrivilegesRequired=lowest keeps kiosk deployment
;   admin-free.
; - FFmpeg is bundled under ffmpeg\bin\ (first location FfmpegLocator
;   searches); watermarking + compression work out of the box.
; - Uninstall leaves recorded videos/database/settings in place (operator
;   data is never deleted silently).
;
; Build: ISCC.exe setup.iss   (expects a fresh `flutter build windows
; --release` and ffmpeg.exe/ffprobe.exe in Source paths below)

#define MyAppName "Ecom Video Tracker"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Ecom"
#define MyAppExeName "ecom_flutter.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{7CFB33C5-0492-45D8-9B68-61237DFB9D25}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=EcomVideoTrackerSetup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; App binaries + Flutter runtime, EXCLUDING any runtime data that may sit in
; the Release folder from developer test runs.
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; \
  Excludes: "database.db,database.db-shm,database.db-wal,settings.json,videos\*,logs\*"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; nothing - never touch operator data on uninstall
