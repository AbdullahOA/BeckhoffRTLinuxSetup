; Inno Setup script - builds the customer installer for Beckhoff RT Linux Setup (unofficial)
; Compiled by Build-Release.ps1; needs Inno Setup 6.3 or newer (winget install JRSoftware.InnoSetup)

#define MyAppName      "Beckhoff RT Linux Setup (unofficial)"
#define MyAppVersion   "1.2.0"
#define MyAppPublisher "Abdullah Omar, Beckhoff UAE - personal tool, not a Beckhoff product"
#define MyAppExeName   "BeckhoffRTLinuxSetup.exe"

[Setup]
AppId={{7E2F5C3A-4B61-4D8E-9C2B-5A0F3D1E8B77}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppComments=Unofficial tool. Not supported or endorsed by Beckhoff Automation.
DefaultDirName={autopf}\Beckhoff RT Linux Setup
DefaultGroupName=Beckhoff RT Linux Setup (unofficial)
DisableProgramGroupPage=yes
LicenseFile=DISCLAIMER.txt
OutputDir=dist
OutputBaseFilename=BeckhoffRTLinuxSetup-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=Installer - unofficial tool by Abdullah Omar (Beckhoff UAE)

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "DISCLAIMER.txt";         DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}";           Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Disclaimer";             Filename: "{app}\DISCLAIMER.txt"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";     Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Add the Windows OpenSSH client if it is missing (only possible when installing as admin)
Filename: "powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {{ Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 }"""; \
  StatusMsg: "Checking the Windows OpenSSH client..."; Flags: runhidden waituntilterminated; Check: IsAdminInstallMode
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
// Warn non-admin installs if ssh.exe is missing (we cannot add the Windows feature without elevation)
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and (not IsAdminInstallMode) and
     (not FileExists(ExpandConstant('{sys}\OpenSSH\ssh.exe'))) then
    MsgBox('The Windows "OpenSSH Client" feature is not installed on this PC and this ' +
           'installer is running without administrator rights, so it could not add it.' + #13#10#13#10 +
           'Ask an administrator to enable it: Settings > Apps > Optional features > OpenSSH Client.',
           mbInformation, MB_OK);
end;


