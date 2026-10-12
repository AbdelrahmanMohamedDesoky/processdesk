#ifndef AppName
  #error Missing AppName
#endif
[Setup]
AppId={{4B51CCB7-65C8-4799-B8E7-EF326B6682DA}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#Publisher}
AppPublisherURL={#RepositoryURL}
AppSupportURL={#RepositoryURL}/issues
AppUpdatesURL={#RepositoryURL}/releases
DefaultDirName={autopf}\{#AppIdName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#AppIdName}.exe
SetupIconFile={#Payload}\Resources\app.ico
LicenseFile={#Payload}\LICENSE.txt
OutputDir={#Output}
OutputBaseFilename={#AppIdName}-{#AppVersion}-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
VersionInfoCompany={#Publisher}
VersionInfoVersion={#AppVersion}

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppIdName}.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppIdName}.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppIdName}.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser
