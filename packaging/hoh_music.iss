#define AppName "HoH music"
#define AppVersion "0.1.0-beta.1"
#define AppPublisher "HoH music"
#define AppExeName "hoh_music.exe"

[Setup]
AppId={{C8601BD7-6FE4-46C4-B64C-48BA53C33259}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\HoH music
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
LicenseFile=..\LICENSE
OutputDir=..\dist\windows
OutputBaseFilename=HoH-music-Setup-{#AppVersion}-Windows-x64
SetupIconFile=..\windows\runner\resources\app_icon.ico
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
Uninstallable=yes
UninstallDisplayName={#AppName}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Windows installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion=0.1.0.1
VersionInfoVersion=0.1.0.1

[Tasks]
; The desktop shortcut is enabled by default, while remaining removable in the
; installer's task selection page.
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："

[Files]
; Install the entire Flutter Release bundle so plugin DLLs, assets and media backends stay together.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\开源项目与协议清单.md"; DestDir: "{app}\licenses"; DestName: "THIRD-PARTY-LICENSES.md"; Flags: ignoreversion
Source: "..\music音源\*.js"; DestDir: "{app}\music音源"; Flags: ignoreversion
Source: "..\music音源\README.md"; DestDir: "{app}\music音源"; Flags: ignoreversion
; Official Microsoft x64 MSVC runtime bootstrapper. It is installed only when the runtime is absent.
Source: "..\build\packaging\vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装 Microsoft Visual C++ 运行库…"; Flags: waituntilterminated; Check: not IsVCRuntimeInstalled
Filename: "{app}\{#AppExeName}"; Description: "启动 HoH music"; WorkingDir: "{app}"; Flags: postinstall nowait skipifsilent

[Code]
function IsVCRuntimeInstalled: Boolean;
var
  Installed: Cardinal;
begin
  Result := IsWin64 and
    RegQueryDWordValue(HKLM64,
      'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
      'Installed', Installed) and (Installed = 1);
end;
