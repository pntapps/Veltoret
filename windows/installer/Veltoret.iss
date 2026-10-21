; Veltoret for Windows — installer (Inno Setup 6.7+). Build with installer\build.ps1, which publishes the app
; first and passes the version. Dark wizard with the app's palette; per-user install by default (no admin
; prompt), with the option to install for all users.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppName "Veltoret"
#define AppExe "Veltoret.exe"
#define Publisher "PNT Apps"
#define PublisherUrl "https://www.pntapps.com"
#define Publish "..\artifacts\publish"
#define Art "art\"
#define Scales(Prefix) Art + Prefix + "-100.png," + Art + Prefix + "-125.png," + Art + Prefix + "-150.png," + \
  Art + Prefix + "-175.png," + Art + Prefix + "-200.png," + Art + Prefix + "-225.png," + Art + Prefix + "-250.png"

[Setup]
AppId={{6F1C2E4B-7A39-4C8E-9B52-3D0E8A71C4F5}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#Publisher}
AppPublisherURL={#PublisherUrl}
AppSupportURL={#PublisherUrl}
AppUpdatesURL={#PublisherUrl}
AppCopyright=© {#Publisher}. Free software under the GNU GPL v3.
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}

DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
DisableReadyPage=no
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041

; One Veltoret per user: close it before replacing files (it also lives in the notification area).
; (/DPreview skips the check, for screenshots of the wizard while Veltoret is open.)
#ifndef Preview
AppMutex=Veltoret.SingleInstance
#endif
CloseApplications=force
RestartApplications=no

OutputDir=..\artifacts\installer
OutputBaseFilename=Veltoret-Setup-{#AppVersion}-x64
SetupIconFile=..\src\Veltoret.App\Assets\Veltoret.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
LicenseFile=..\LICENSE

; Look: always dark like the app, Windows 11 style controls, no bevel lines, Veltoret's background color.
WizardStyle=modern dark windows11 hidebevels
WizardBackColor=#0B0B0D
WizardSizePercent=110
WizardImageFile={#Scales("wizard")}
WizardSmallImageFile={#Scales("header")}
WizardImageAlphaFormat=defined

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupWindowTitle=Install %1
WelcomeLabel1=Welcome to Veltoret
WelcomeLabel2=Your movies and shows, as a private cinema.%n%nVeltoret turns the videos in your Google Drive, on this PC and on your network shares into a beautiful Movies and TV Shows library, and plays them with a full-featured player.%n%nSetup will install Veltoret {#AppVersion} on your computer.
LicenseLabel3=Veltoret is free software under the GNU General Public License v3. Please read the summary below.
FinishedHeadingLabel=Veltoret is ready
FinishedLabel=Veltoret has been installed. Open it to choose your library folders — posters, cast and episode guides are added automatically.
FinishedLabelNoIcons=Veltoret has been installed.
ClickFinish=Click Finish to close Setup.

[CustomMessages]
OpenVeltoret=Open Veltoret now
DesktopIcon=Add a shortcut on the desktop
RemoveData=Also remove your Veltoret library on this PC?%n%nThis deletes watch progress, the Watchlist, reminders, settings, saved network servers and Google sign-ins. Your video files are never touched.%n%nChoose No to keep them for a future install.

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"

[Files]
Source: "{#Publish}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\third_party\fonts\OFL.txt"; DestDir: "{app}\licenses"; DestName: "Fonts-OFL.txt"; Flags: ignoreversion

[InstallDelete]
; Remove files left by an older version's layout (LibVLC plugins are re-copied whole).
Type: filesandordirs; Name: "{app}\libvlc"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; Comment: "Your movies and shows, as a private cinema"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon; Comment: "Your movies and shows, as a private cinema"

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:OpenVeltoret}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Veltoret keeps running in the notification area; stop it so its files can be removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM {#AppExe}"; Flags: runhidden; RunOnceId: "StopVeltoret"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\libvlc"

[Registry]
; "Start with Windows" (set from Veltoret's Settings) must not outlive the app.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Veltoret"; Flags: uninsdeletevalue dontcreatekey

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DataDir := ExpandConstant('{localappdata}\Veltoret');
    if DirExists(DataDir) and not UninstallSilent then
      if SuppressibleMsgBox(CustomMessage('RemoveData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES then
        DelTree(DataDir, True, True, True);
  end;
end;
