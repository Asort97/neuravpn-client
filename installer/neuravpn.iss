; -------------------------------------------------------
; neuravpn — Inno Setup Installer Script
; -------------------------------------------------------
; Requires Inno Setup 6+  (https://jrsoftware.org/isinfo.php)
;
; Usage (from repo root):
;   iscc /DAppVersion=1.0.5 installer\neuravpn.iss
;
; The script expects the Flutter build output in:
;   build\windows\x64\runner\Release\
; and the compiled updater in:
;   tool\updater\build\updater.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName      "neuravpn"
#define AppExeName   "neuravpn.exe"
#define AppPublisher "neuravpn"
#define AppURL       "https://github.com/Asort97/neuravpn-client"

[Setup]
AppId={{B8A3F0E2-7C4D-4A1B-9E6F-5D2C8B0A1E3F}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputBaseFilename=neuravpn-setup-v{#AppVersion}
OutputDir=..\build
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
; Allow user to choose whether to create a desktop icon
AllowNoIcons=yes
; Min Windows 10
MinVersion=10.0

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Main application files from Flutter build output
Source: "..\build\windows\x64\runner\Release\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

; Updater utility
Source: "..\tool\updater\build\updater.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Store install path so the app (and updater) can find it
Root: HKLM; Subkey: "Software\{#AppName}"; ValueType: string; ValueName: "InstallPath"; ValueData: "{app}"; Flags: uninsdeletekey

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent shellexec runascurrentuser; Verb: runas

[UninstallRun]
Filename: "taskkill"; Parameters: "/F /IM {#AppExeName}"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""neuravpn"" /F"; Flags: runhidden; RunOnceId: "DeleteAutoStartTask"
Filename: "{sys}\reg.exe"; Parameters: "delete ""HKCU\Software\Microsoft\Windows\CurrentVersion\Run"" /v ""neuravpn"" /f"; Flags: runhidden; RunOnceId: "DeleteLegacyAutoStart"

[Code]
// Kill running instance before installing/updating
function InitializeSetup(): Boolean;
var
  ResultCode: Integer;
begin
  Exec('taskkill', '/F /IM {#AppExeName}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := True;
end;
