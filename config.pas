{
This file is part of OvoM3U
Copyright (C) 2020 Marco Caselli

OvoM3U is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

}
{$I codegen.inc}
unit Config;

interface

uses
  Classes, SysUtils, Graphics, JsonTools, typinfo, sqlite3dyn, sqlite3conn, sqldb, Generics.collections;

type
  { TEnum }

  TEnum<T> = class(TObject)
  public
    class function ToString(const aEnumValue: T): string; reintroduce;
    class function FromString(const aEnumString: string; const aDefault: T): T;
  end;

  { TConfig }
  TConfig = class;

  { TConfigParam }
  TConfigParam = class(TObject)
  private
    FDirty: boolean;
    fOwner: TConfig;
    procedure SetDirty(AValue: boolean);
  protected
    procedure InternalSave; virtual; abstract;
  public
    property Dirty: boolean read FDirty write SetDirty;
    property Owner: TConfig read fOwner;
    constructor Create(aOwner: TConfig); virtual;
    destructor Destroy; override;
    procedure Save;
    procedure Load; virtual; abstract;
  end;

  TConfigList = TObjectList<TConfigParam>;

  TConfig = class
  private
    fConfigList: TConfigList;
    fDirty: boolean;
    fCacheDir: string;
    FConfigFile: string;
    fConfigDir: string;
    FPortableMode: boolean;
    ResourcesPath: string;
    fConfigHolder: TJsonNode;
    fExecutableDir: string;
    fDB: TSQLite3Connection;
    fTR: TSQLTransaction;

    procedure CheckDBStructure;
    function GetCacheDir: string;
    function GetConfigDir: string;
    function GetDbVersion: integer;
    procedure SetDirty(AValue: boolean);
    procedure Attach(cfgobject: TConfigParam);
    procedure Remove(cfgobject: TConfigParam);
    procedure SetupDBConnection;
    procedure UpgradeDBStructure(LoadedDBVersion: integer);

  public
    property PortableMode: boolean read FPortableMode;

    property Dirty: boolean read FDirty write SetDirty;

    // Used to signal changes, not saved
    procedure ReadConfig;
    procedure SaveConfig;
    procedure WriteStrings(const APath: string; Values: TStrings);
    function ReadStrings(const APath: string; Values: TStrings): integer;
    procedure WriteString(const APath: string; const Value: string);
    function ReadString(const APath: string; const ADefault: string): string;
    function GetResourcesPath: string;
    procedure WriteBoolean(const APath: string; Value: boolean);
    function ReadBoolean(const APath: string; ADefault: boolean): boolean;
    procedure WriteInteger(const APath: string; Value: integer);
    function ReadInteger(const APath: string; ADefault: integer): integer;
    procedure WriteRect(const APath: string; Value: TRect);
    function ReadRect(const APath: string; ADefault: TRect): TRect;

    procedure Flush;
    constructor Create;
    destructor Destroy; override;
    // -- //
    property ConfigDir: string read fConfigDir;
    property CacheDir: string read fCacheDir;
    property ConfigFile: string read FConfigFile;
    property DB: TSQLite3Connection read fDB;
    property TR: TSQLTransaction read fTR;
  end;

  { TSimpleHistory }

  TSimpleHistory = class
  private
    FMax: integer;
    IntList: TStringList;
    function GetCount: integer;
    procedure SetMax(AValue: integer);
  public
    function Add(const S: string): integer;
    constructor Create;
    destructor Destroy; override;
    procedure SetList(List: TStrings);

    procedure LoadFromConfig(Config: TConfig; APath: string);
    procedure WriteToConfig(Config: TConfig; APath: string);
    property Max: integer read FMax write SetMax;
    property Count: integer read GetCount;
  end;


function ConfigObj: TConfig;

implementation

{ TConfig }
uses
  Fileutil, AppConsts, LoggerUnit
  // only for default font !
  {$ifdef Darwin}
  , MacOSAll
  {$endif}  ;

var
  FConfigObj: TConfig;

const
  PRAGMAS_COUNT = 3;
  PRAGMAS: array [1..PRAGMAS_COUNT] of string =
    (
    //            'PRAGMA locking_mode = EXCLUSIVE;',
    'PRAGMA temp_store = MEMORY;',
    'PRAGMA count_changes = 0;',
    'PRAGMA encoding = "UTF-8";'
    );
  CURRENTDBVERSION = 3;

  CREATECONFIGTABLE1 =
    'CREATE TABLE config ('
    + 'Version INTEGER COLLATE NOCASE'
    + ');';

  CREATELISTTABLE =
    'CREATE TABLE "Lists" ('
    + 'ID INTEGER'
    + ',Name NUMERIC'
    + ',Position VARCHAR'
    + ',UseNumber INTEGER'
    + ',GetLogo INTEGER'
    + ',EPG VARCHAR'
    + ',PRIMARY KEY("ID" AUTOINCREMENT))';
  CREATECONFIGTABLE2 =
    ' INSERT INTO config (Version) VALUES(1);';
  UPDATECONFIG =
    'UPDATE config SET Version = %d;';

  CREATESCANTABLE1 =
    'CREATE TABLE scans ('
    + ' List Integer'
    + ' ,Epg DATETIME'
    + ' ,Channels DATETIME'
    + ',ChannelsMd5 VARCHAR  '
    + ',PRIMARY KEY("List"))';
  CREATESCANTABLE2 =
    'insert into  scans select 0,0,0,null where not EXISTS (select * from scans);';

  CREATECHANNELTABLE =
    'CREATE TABLE channels ('
    + ' List Integer '
    + ',ID INTEGER'
    + ',Name VARCHAR COLLATE NOCASE'
    + ',ChannelNo VARCHAR COLLATE NOCASE'
    + ',EpgName VARCHAR COLLATE NOCASE'
    + ', primary key (ID AUTOINCREMENT) '
    + ')';
  CREATECHANNELINDEX1 =
    'CREATE INDEX "idx_Channels_Name" on channels (Name ASC);';
  CREATECHANNELINDEX2 =
    'CREATE INDEX "idx_Channels_EpgName" on channels (EpgName ASC);';
  CREATECHANNELINDEX3 =
'  CREATE UNIQUE INDEX idx_Channels_List ON channels (List, ID);';


  CREATEPROGRAMMETABLE =
    'CREATE TABLE programme ('
    + ' List Integer '
    + ',idProgram    integer '
    + ',idChannel    integer'
    + ',sTitle       VARCHAR(128)'
    + ',sPlot        VARCHAR'
    + ',dStartTime   DATETIME'
    + ',dEndTime     DATETIME'
    + ', primary key (idProgram AUTOINCREMENT) '
    + ');';
  CREATEPROGRAMMEINDEX1 =
    'CREATE INDEX "idx_programme_Channel" on programme (idChannel, dStartTime ASC);';
  CREATEPROGRAMMEINDEX2 =
    'CREATE INDEX "idx_programme_iStartTime" on programme (dStartTime ASC);';
  CREATEPROGRAMMEINDEX3 =
'  CREATE UNIQUE INDEX idx_programme_List ON programme (List, idProgram);';

const
  SectionUnix = 'UNIX';
  IdentResourcesPath = 'ResourcesPath';
  ResourceSubDirectory = 'Resources';

  {$ifdef UNIX}
  DefaultDirectory = '/usr/share/ovom3u/';
  {$DEFINE NEEDCFGSUBDIR}
  {$endif}

  {$ifdef DARWIN}
  BundleResourcesDirectory = '/Contents/Resources/';
  {$endif}

function NextToken(const S: string; var SeekPos: integer;
  const TokenDelim: char): string;
var
  TokStart: integer;
begin
  repeat
    if SeekPos > Length(s) then
    begin
      Result := '';
      Exit;
    end;
    if S[SeekPos] = TokenDelim then Inc(SeekPos)
    else
      Break;
  until False;
  TokStart := SeekPos; { TokStart := first character not in TokenDelims }

  while (SeekPos <= Length(s)) and not (S[SeekPos] = TokenDelim) do Inc(SeekPos);

  { Calculate result := s[TokStart, ... , SeekPos-1] }
  Result := Copy(s, TokStart, SeekPos - TokStart);

  { We don't have to do Inc(seekPos) below. But it's obvious that searching
    for next token can skip SeekPos, since we know S[SeekPos] is TokenDelim. }
  Inc(SeekPos);
end;

function ConfigObj: TConfig;
begin
  if not Assigned(FConfigObj) then
    FConfigObj := TConfig.Create;
  Result := FConfigObj;
end;

{ TEnum }

class function TEnum<T>.ToString(const aEnumValue: T): string;
begin
  WriteStr(Result, aEnumValue);
end;

class function TEnum<T>.FromString(const aEnumString: string; const aDefault: T): T;
var
  OrdValue: integer;
begin
  OrdValue := GetEnumValue(TypeInfo(T), aEnumString);
  if OrdValue < 0 then
    Result := aDefault
  else
    Result := T(OrdValue);
end;

{ TConfigParam }

procedure TConfigParam.SetDirty(AValue: boolean);
begin
  if FDirty = AValue then Exit;
  FDirty := AValue;
  if FDirty then
    fOwner.Dirty := True;
end;

constructor TConfigParam.Create(aOwner: TConfig);
begin
  fOwner := AOwner;
  fOwner.Attach(Self);
  FDirty := False;
end;

destructor TConfigParam.Destroy;
begin
  Save;
  fOwner.Remove(Self);

  inherited Destroy;
end;

procedure TConfigParam.Save;
begin
  if FDirty then
    InternalSave;

end;

{ TSimpleHistory }

procedure TSimpleHistory.SetMax(AValue: integer);
begin
  if FMax = AValue then Exit;
  FMax := AValue;

  while IntList.Count > FMax do
    IntList.Delete(IntList.Count - 1);           // -1 since its 0 indexed

end;

function TSimpleHistory.GetCount: integer;
begin
  Result := IntList.Count;
end;

function TSimpleHistory.Add(const S: string): integer;
var
  i: integer;
begin
  i := IntList.IndexOf(S);
  if i <> -1 then
    IntList.Delete(i);

  IntList.Insert(0, S);

  // Trim the oldest files if more than NumFiles
  while IntList.Count > FMax do
    IntList.Delete(IntList.Count - 1);           // -1 since its 0 indexed
  Result := IntList.Count;
end;

constructor TSimpleHistory.Create;
begin
  IntList := TStringList.Create;
end;

destructor TSimpleHistory.Destroy;
begin
  FreeAndNil(IntList);
  inherited Destroy;
end;

procedure TSimpleHistory.SetList(List: TStrings);
begin
  List.Assign(IntList);
end;

procedure TSimpleHistory.LoadFromConfig(Config: TConfig; APath: string);
begin
  Config.ReadStrings(APath, IntList);
end;

procedure TSimpleHistory.WriteToConfig(Config: TConfig; APath: string);
begin
  Config.WriteStrings(APath, IntList);
end;

procedure TConfig.Attach(cfgobject: TConfigParam);
begin
  fConfigList.Add(cfgobject);
  cfgobject.Load;
end;

procedure TConfig.Remove(cfgobject: TConfigParam);
begin
  cfgobject.Save;
  fConfigList.Remove(cfgobject);
end;

constructor TConfig.Create;
begin
  fDirty := False;
  fConfigList := TConfigList.Create(True);

  fExecutableDir := IncludeTrailingPathDelimiter(ProgramDirectory);

  if FileExists(fExecutableDir + 'portable.txt') then
    fPortableMode := True;

  fConfigDir := GetConfigDir;
  fCacheDir := GetCacheDir;


  if FPortableMode then
  begin
    FConfigFile := fConfigDir + ApplicationName + ConfigExtension;
  end
  else
  begin
    FConfigFile := GetAppConfigFile(False
      {$ifdef NEEDCFGSUBDIR}
      , True
      {$ENDIF}
      );

  end;
  fConfigHolder := TJsonNode.Create;
  if not FileExists(FConfigFile) then
    SaveConfig;
  ReadConfig;

  SetupDBConnection;
  CheckDBStructure;

end;

destructor TConfig.Destroy;
begin
  SaveConfig;
  fConfigList.Free;
  fConfigHolder.Free;
  inherited Destroy;
end;


function TConfig.GetConfigDir: string;
var
  Path: string;
begin
  if fPortableMode then
    Path := fExecutableDir + 'config'
  else
    Path := GetAppConfigDir(False);
  ForceDirectories(Path);
  Result := IncludeTrailingPathDelimiter(Path);

end;

procedure TConfig.SetDirty(AValue: boolean);
begin
  if FDirty = AValue then Exit;
  FDirty := AValue;

end;

function TConfig.GetCacheDir: string;
begin
  if FPortableMode then
  begin
    Result := fExecutableDir + 'cache';
    Result := IncludeTrailingPathDelimiter(Result);
  end
  else
  begin
    {$ifdef UNIX}
    Result := GetEnvironmentVariable('XDG_CONFIG_HOME');
    if (Result = '') then
    begin
      Result := GetEnvironmentVariable('HOME');
      if Result <> '' then
        Result := IncludeTrailingPathDelimiter(Result) + '.cache/';
    end
    else
      Result := IncludeTrailingPathDelimiter(Result);

    Result := IncludeTrailingPathDelimiter(Result + ApplicationName);
    {$endif}
    {$ifdef WINDOWS}
    Result := GetEnvironmentVariable('LOCALAPPDATA');
    if Result <> '' then
      Result := IncludeTrailingPathDelimiter(Result) + 'Caches\';

    Result := IncludeTrailingPathDelimiter(Result + ApplicationName);
    {$endif}
  end;
  ForceDirectories(Result);
end;

procedure TConfig.SaveConfig;
var
  i: integer;
begin
  fDirty := False;
  for i := 0 to Pred(fConfigList.Count) do
    if fConfigList[i].Dirty then
    begin
      fConfigList[i].Save;
      fConfigList[i].Dirty := False;
      FDirty := True;
    end;
  if fDirty then
  begin
    WriteString(SectionUnix + '/' + IdentResourcesPath, ResourcesPath);
    fConfigHolder.SaveToFile(FConfigFile, True);
  end;

  fDirty := False;

end;

procedure TConfig.ReadConfig;
begin

  fConfigHolder.LoadFromFile(FConfigFile);
  {$ifdef WINDOWS}
  ResourcesPath := ReadString(SectionUnix + '/' + IdentResourcesPath,
    ExtractFilePath(ExtractFilePath(ParamStr(0))));
  {$else}
  {$ifndef DARWIN}
  ResourcesPath := ReadString(SectionUnix + '/' + IdentResourcesPath, DefaultDirectory);
  {$endif}
  {$endif}

end;

procedure TConfig.WriteStrings(const APath: string; Values: TStrings);
var
  Node: TJsonNode;
  i: integer;
begin
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
  begin
    Node.Clear;
    for i := 0 to Values.Count - 1 do
      node.Add('', Values[i]);
  end
  else
  begin
    Node := fConfigHolder.find(APath, True);  // fConfigHolder.Add(APath, nkArray);
    node.Kind := nkArray;
    for i := 0 to Values.Count - 1 do
      node.Add('', Values[i]);

  end;
end;

function TConfig.ReadStrings(const APath: string; Values: TStrings): integer;
var
  Node: TJsonNode;
  i: integer;
begin
  Values.Clear;
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
  begin
    for i := 0 to node.Count - 1 do
      Values.Add(Node.Child(i).AsString);
  end;

  Result := Values.Count;
end;

procedure TConfig.WriteString(const APath: string; const Value: string);
var
  Node: TJsonNode;
begin
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
    Node.AsString := Value
  else
  begin
    fConfigHolder.find(APath, True).AsString := Value;
  end;

end;

function TConfig.ReadString(const APath: string; const ADefault: string): string;
var
  Node: TJsonNode;
begin
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
    Result := Node.AsString
  else
    Result := ADefault;
end;

procedure TConfig.WriteBoolean(const APath: string; Value: boolean);
var
  Node: TJsonNode;
begin
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
    Node.AsBoolean := Value
  else
    fConfigHolder.find(APath, True).AsBoolean := Value;

end;

function TConfig.ReadBoolean(const APath: string; ADefault: boolean): boolean;
var
  Node: TJsonNode;
begin
  Node := fConfigHolder.find(APath, True);
  if Assigned(Node) then
    Result := Node.AsBoolean
  else
    Result := ADefault;
end;

procedure TConfig.WriteInteger(const APath: string; Value: integer);
var
  Node: TJsonNode;
begin
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
    Node.AsInteger := Value
  else
  begin
    fConfigHolder.find(APath, True).AsInteger := Value;
  end;

end;

function TConfig.ReadInteger(const APath: string; ADefault: integer): integer;
var
  Node: TJsonNode;
begin
  Node := fConfigHolder.find(APath);
  if Assigned(Node) then
    Result := Node.AsInteger
  else
    Result := ADefault;
end;

procedure TConfig.WriteRect(const APath: string; Value: TRect);
begin
  WriteInteger(APath + '/Top', Value.Top);
  WriteInteger(APath + '/Left', Value.Left);
  WriteInteger(APath + '/Heigth', Value.Height);
  WriteInteger(APath + '/Width', Value.Width);
end;

function TConfig.ReadRect(const APath: string; ADefault: TRect): TRect;
begin
  Result.Top := ReadInteger(APath + '/Top', ADefault.Top);
  Result.Left := ReadInteger(APath + '/Left', ADefault.Left);
  Result.Height := ReadInteger(APath + '/Heigth', ADefault.Height);
  Result.Width := ReadInteger(APath + '/Width', ADefault.Width);
end;

procedure TConfig.Flush;
begin
  fConfigHolder.SaveToFile(FConfigFile, True);
end;

function TConfig.GetResourcesPath: string;
  {$ifdef DARWIN}
var
  pathRef: CFURLRef;
  pathCFStr: CFStringRef;
  pathStr: shortstring;
  {$endif}
begin
  {$ifdef UNIX}
  {$ifdef DARWIN}
  pathRef := CFBundleCopyBundleURL(CFBundleGetMainBundle());
  pathCFStr := CFURLCopyFileSystemPath(pathRef, kCFURLPOSIXPathStyle);
  CFStringGetPascalString(pathCFStr, @pathStr, 255, CFStringGetSystemEncoding());
  CFRelease(pathRef);
  CFRelease(pathCFStr);

  Result := pathStr + BundleResourcesDirectory;
  {$else}
  Result := ResourcesPath;
  {$endif}
  {$endif}

  {$ifdef WINDOWS}
  Result := ExtractFilePath(ExtractFilePath(ParamStr(0))) + ResourceSubDirectory + PathDelim;
  {$endif}

end;


procedure TConfig.SetupDBConnection;
var
  i: integer;
begin
  OvoLogger.Log(llINFO, 'Setup EPG database');
  fDB := TSQLite3Connection.Create(nil);
  fDB.OpenFlags := [sofReadWrite, sofCreate, sofFullMutex, sofSharedCache];
  fDB.DatabaseName := FConfigDir + EPGLibraryName;

  ftr := TSQLTransaction.Create(nil);

  fTR.DataBase := fDB;

  for i := 1 to PRAGMAS_COUNT do
    fdb.ExecuteDirect(PRAGMAS[i]);

  fdb.Connected := True;

  fTR.Active := True;

end;

function TConfig.GetDbVersion: integer;
var
  TableList: TStringList;
  tmpQuery: TSQLQuery;
begin
  TableList := TStringList.Create;
  try
    fDB.GetTableNames(TableList, False);
    if TableList.IndexOf('Config') < 0 then
    begin
      Result := 1;
      fDB.ExecuteDirect(CREATECONFIGTABLE1);
      fDB.ExecuteDirect(CREATECONFIGTABLE2);
      ftr.CommitRetaining;
    end
    else
    begin
      tmpQuery := TSQLQuery.Create(fDB);
      tmpQuery.DataBase := fDB;
      tmpQuery.Transaction := fTR;
      tmpQuery.SQL.Text := 'SELECT Version FROM Config';
      tmpQuery.Open;
      Result := tmpQuery.Fields[0].AsInteger;
      tmpQuery.Free;
    end;
  finally
    TableList.Free;
  end;

end;

procedure TConfig.CheckDBStructure;
var
  TableList: TStringList;
  LoadedDBVersion: integer;
begin
  OvoLogger.Log(llINFO, 'Check EPG database');
  try
    TableList := TStringList.Create;
    try
      fDB.GetTableNames(TableList, False);
      if TableList.IndexOf('config') < 0 then
      begin
        OvoLogger.Log(llDEBUG, 'Creating config table');
        fDB.ExecuteDirect(CREATECONFIGTABLE1);
        fDB.ExecuteDirect(CREATECONFIGTABLE2);
        fDB.ExecuteDirect(format(UPDATECONFIG, [CURRENTDBVERSION]));
        fTR.CommitRetaining;
      end;
      if TableList.IndexOf('scans') < 0 then
      begin
        OvoLogger.Log(llDEBUG, 'Creating scans table');
        fDB.ExecuteDirect(CREATESCANTABLE1);
        fTR.CommitRetaining;
      end;
      // Make sure table contains a row
      fDB.ExecuteDirect(CREATESCANTABLE2);
      fTR.CommitRetaining;
      if TableList.IndexOf('channels') < 0 then
      begin
        OvoLogger.Log(llDEBUG, 'Creating channel table');
        fDB.ExecuteDirect(CREATECHANNELTABLE);
        fDB.ExecuteDirect(CREATECHANNELINDEX1);
        fDB.ExecuteDirect(CREATECHANNELINDEX2);
        fDB.ExecuteDirect(CREATECHANNELINDEX3);
        fTR.CommitRetaining;
      end;
      if TableList.IndexOf('programme') < 0 then
      begin
        OvoLogger.Log(llDEBUG, 'Creating programme table');
        fDB.ExecuteDirect(CREATEPROGRAMMETABLE);
        fDB.ExecuteDirect(CREATEPROGRAMMEINDEX1);
        fDB.ExecuteDirect(CREATEPROGRAMMEINDEX2);
        fDB.ExecuteDirect(CREATEPROGRAMMEINDEX3);
        fTR.CommitRetaining;
      end;

    finally
      TableList.Free;
    end;

  except
    on e: Exception do
      OvoLogger.Log(llERROR, 'Error initializing EPG Database : %s', [e.Message]);
  end;

  LoadedDBVersion := GetDbVersion;
  if LoadedDBVersion < CURRENTDBVERSION then
    UpgradeDBStructure(LoadedDBVersion);

end;

procedure TConfig.UpgradeDBStructure(LoadedDBVersion: integer);
const
  ToV2_1 = 'ALTER TABLE "channels" add COLUMN "epgName" varchar NULL;';
  UPDATESTATUS = 'UPDATE confid SET Version = %d;';
var
  MustUpdate: boolean;
begin
  MustUpdate := False;
  OvoLogger.Log(llINFO, 'Upgrading db version from %d to %d:', [LoadedDBVersion, CURRENTDBVERSION]);
  if LoadedDBVersion < 2 then
  begin
    fDB.ExecuteDirect(ToV2_1);
    MustUpdate := True;
  end;

  if MustUpdate then
    FDB.ExecuteDirect(format(UPDATECONFIG, [CURRENTDBVERSION]));

end;


initialization
  FConfigObj := nil;

finalization
  if Assigned(FConfigObj) then
  begin
    FConfigObj.SaveConfig;
    FConfigObj.Free;
  end;

end.
