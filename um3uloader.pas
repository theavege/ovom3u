{
This file is part of OvoM3U
Copyright (C) 2020 Marco Caselli

OvoPlayer is free software; you can redistribute it and/or
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
unit um3uloader;

interface

uses
  Classes, SysUtils, Generics.Collections, StrUtils;

type
  TProviderKind = (Local, URL);

  TM3UItem = class
  public
    Number: integer;
    tvg_chno: integer;
    tvg_name: string;
    Title: string;
    Mrl: string;
    Id: string;
    Group: string;
    IconUrl: string;
    IconLocal: string;
    IconAvailable: boolean;
    CurrProgram: string;
  end;

  { TM3ULoader }

  TM3ULoader = class(TObjectList<TM3UItem>)
  private
    FFilterCount: integer;
    FFiltered: boolean;
    fLastMessage: string;
    FOnListChanged: TNotifyEvent;
    FFilterArray: array of integer;
    function GetFilterCount: integer;
    procedure SetFilterCount(AValue: integer);
    procedure SetFiltered(AValue: boolean);
    procedure SetOnListChange(AValue: TNotifyEvent);
    function SortbyNumber(constref Left, Right: TM3UItem): integer;

  public
    ListMd5: string;
    Groups: TStringList;
    procedure DoListChanged;
    property Filtered:boolean read FFiltered write SetFiltered;
    property LastMessage: string read fLastMessage;
    property OnListChanged: TNotifyEvent read FOnListChanged write SetOnListChange;
    Property FilterCount: integer read GetFilterCount;
    constructor Create;
    destructor Destroy; override;
    function Load(const ListName: string): boolean;
    function ItemByChno(chno: integer): integer;
    function FilteredToReal(idx: integer): integer;
    Procedure FilterByGroup(Group:string);

    procedure FixChannelNumbering;
    procedure UpdateLogo;

  end;

  { TLogoLoader }

  TLogoLoader = class(TThread)
  private
    fOwner: TM3ULoader;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: TM3ULoader); reintroduce;
  end;

resourcestring
  RSEmpty = 'M3U file is empty';
  RSMissingHeader = 'Missing #EXTM3U Header';
  RSAnyGroup = '<all groups>';

implementation

uses Math, LoggerUnit, Config, GeneralFunc, Generics.Defaults, md5;

const
  CountExt = 4;
  CoverExt: array [0..CountExt - 1] of string =
    ('.png', '.jpg', '.jpeg', '.gif');


{ TLogoLoader }

procedure TLogoLoader.Execute;
var
  i: integer;
  Item: TM3UItem;
begin
  if Terminated then
    exit;

  for item in fOwner do
  begin
    if Terminated then
      exit;

    if not Item.IconLocal.IsEmpty then
    begin
      if FileExists(Item.IconLocal) then
      begin
        Item.IconAvailable := True;
        Queue(fOwner.DoListChanged);
      end
      else
      if not DownloadFromUrl(Item.IconUrl, Item.IconLocal) then
        Item.IconLocal := ''
      else
      begin
        Item.IconAvailable := True;
        Queue(fOwner.DoListChanged);
      end;
    end;
  end;
end;

constructor TLogoLoader.Create(Owner: TM3ULoader);
begin
  inherited Create(False);
  fOwner := Owner;
end;

{ TM3ULoader }

constructor TM3ULoader.Create;
begin
  inherited Create(True);
  Groups := TStringList.Create;
  Groups.Sorted:=true;
  Groups.Duplicates:=dupIgnore;
end;

destructor TM3ULoader.Destroy;
begin
  Groups.free;
  inherited Destroy;
end;

function TM3ULoader.Load(const ListName: string): boolean;
var
  f: textfile;
  s: string;
  p, ext: string;
  Item: TM3UItem;
  fData: boolean;
  index: integer;
  Context: TMD5Context;
  Digest: TMD5Digest;
  i: integer;
  Cachedir: string;


  function FindTag(const tag: string; const st: string): string;
  var
    tagpos: integer;
    TagStart: integer;
  begin
    TagPos := Pos(tag, st);
    if TagPos > 0 then
    begin
      TagStart := PosEx('"', st, tagpos) + 1;
      Result := ExtractSubstr(St, TagStart, ['"']);
    end;
  end;

begin
  Clear;
  Result := False;
  Index := 1;

  if ListName.IsEmpty then
  begin
    OvoLogger.Log(WARN, 'No list to load');
    exit;
  end;

  try
    OvoLogger.Log(INFO, 'Loading list from %s', [ListName]);
    MD5Init(Context);
    Cachedir := IncludeTrailingPathDelimiter(ConfigObj.CacheDir + 'logo');
    ForceDirectories(Cachedir);
    p := ExtractFilePath(ListName);
    assignfile(f, ListName);
    reset(f);
    if EOF(f) then
    begin
      fLastMessage := RSEmpty;
      exit;
    end;

    readln(f, s);
    s := trim(s);
    if uppercase(copy(s, 1, 7)) <> '#EXTM3U' then
    begin
      fLastMessage := RSMissingHeader;
      exit;
    end;
    fData := False;
    while EOF(f) <> True do
    begin
      readln(f, s);
      s := trim(s);
      if (s <> EmptyStr) then
      begin
        MD5Update(Context, s[1], Length(s));
        if (uppercase(copy(s, 1, 7)) = '#EXTINF') then
        begin
          item := TM3UItem.Create;
          Item.Number := index;
          Item.Group := FindTag('group-title', s);
          Groups.Add(Item.Group);
          item.Id := FindTag('tvg-id', s);
          item.IconUrl := FindTag('tvg-logo', s);
          item.tvg_name := FindTag('tvg-name', s);
          item.tvg_chno := StrToIntDef(FindTag('tvg-chno', s), 0);
          Item.Title := copy(s, RPos(',', S) + 1, Length(s));
          if not Trim(item.IconUrl).IsEmpty then
          begin
            ext := LowerCase(ExtractFileExt(Item.IconUrl));
            i := 0;
            while i < CountExt do
              if ext = CoverExt[i] then
                i := CountExt + 1
              else
                Inc(i);
            if i > CountExt then
              Item.IconLocal := CacheDir + CleanupFileName(Item.Title) + ext;
          end;
          item.IconAvailable := False;
          Inc(index);
          Add(Item);
          fData := True;
        end
        else
        if s[1] <> '#' then
          if fData then
          begin
            item.Mrl := s;
            fData := False;
          end;

      end;
    end;
    MD5Final(Context, Digest);
    ListMd5 := MD5Print(Digest);
    Result := True;
    Filtered := false;
    DoListChanged;
  finally
    if not fLastMessage.IsEmpty then
      OvoLogger.Log(WARN, fLastMessage);
    closefile(f);
  end;
end;

function TM3ULoader.ItemByChno(chno: integer): integer;
var
  i: integer;
begin
  Result := -1;
  for i := 0 to Count - 1 do
    if items[i].tvg_chno = chno then
    begin
      Result := i;
      break;
    end;
end;

function TM3ULoader.FilteredToReal(idx: integer): integer;
begin
  if FFiltered then
    Result := FFilterArray[idx]
  else
    Result := idx;
end;

procedure TM3ULoader.FilterByGroup(Group: string);
var i,j:Integer;
begin

  SetLength(FFilterArray, Count);
  i:= 0;
  for j:= 0 to count -1 do
    if FItems[j].Group = Group then
      begin
        FFilterArray[i]:=j;
        inc(i);
      end;
  SetLength(FFilterArray,i);

end;

function TM3ULoader.SortbyNumber(constref Left, Right: TM3UItem): integer;
begin
  Result := CompareValue(left.Number, Right.Number);
end;

procedure TM3ULoader.DoListChanged;
begin
  if Assigned(FOnListChanged) then
    FOnListChanged(self);
end;

procedure TM3ULoader.SetOnListChange(AValue: TNotifyEvent);
begin
  FOnListChanged := AValue;
end;

function TM3ULoader.GetFilterCount: integer;
begin
  if FFiltered then
    Result := Length(FFilterArray)
  else
    Result := Count;
end;

procedure TM3ULoader.SetFilterCount(AValue: integer);
begin

end;

procedure TM3ULoader.SetFiltered(AValue: boolean);
begin
  if FFiltered=AValue then Exit;
  FFiltered:=AValue;
end;

procedure TM3ULoader.FixChannelNumbering;
var
  i: integer;
  MaxChno: integer;
begin
  Maxchno := 0;
  for i := 0 to Count - 1 do
  begin
    items[i].Number := items[i].tvg_chno;
    if items[i].tvg_chno > MaxChno then
      MaxChno := items[i].tvg_chno;
  end;
  for i := 0 to Count - 1 do
    if items[i].Number = 0 then
    begin
      Inc(MaxChno);
      items[i].tvg_chno := MaxChno;
      items[i].Number := MaxChno;
    end;
  Sort(TComparer<TM3UItem>.Construct(SortByNumber));
end;

procedure TM3ULoader.UpdateLogo;
begin
  with TLogoLoader.Create(self) do
  begin
    FreeOnTerminate := True;
    Start;
  end;
end;

end.
