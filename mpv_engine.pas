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
unit MPV_Engine;

interface

uses
  Classes, SysUtils, libmpv, decoupler, BaseTypes, render,
  OpenGLContext, Forms, LCLType, Renderer;

type
  TTrackType = (trkAudio, trkVideo, trkSub, trkUnknown);

  { TTrack }

  TTrack = record
    Kind: TTrackType;
    Selected: boolean;
    Id: int64;
    Title: string;
    Lang: string;
    Channels: int64;
    Codec: string;
    w, h: int64;
    BitRate: int64;
    SampleRate: int64;
    Fps: double;
    procedure Init;
  end;

  TTrackList = array of TTrack;
  { TMPVEngine }

  TMPVEngine = class
  private
    FGLRenderControl: TOpenGlControl;
    fHandle: Pmpv_handle;
    fdecoupler: TDecoupler;
    fisGlEnabled: boolean;
    fIsRenderActive: boolean;
    FOnLoadingState: TNotifyEvent;
    fOnTrackChange: TNotifyEvent;
    fTrackList: TTrackList;
    fMuted: boolean;
    fOldVolume: integer;
    EngineState: TEngineState;
    Loading: boolean;
    ClientVersion: DWORD;
    RenderObj: TRender;

    function GetBoolProperty(const PropertyName: string): boolean;
    function GetMainVolume: integer;
    procedure InitRenderer(Data: PtrInt);
    procedure PostCommand(Command: TEngineCommand; Param: integer);
    procedure ReceivedCommand(Sender: TObject; Command: TEngineCommand; Param: integer);
    procedure SetBoolProperty(const PropertyName: string; AValue: boolean);
    procedure SetGLRenderControl(AValue: TOpenGlControl);
    procedure SetMainVolume(const AValue: integer);
    procedure SetOnLoadingState(AValue: TNotifyEvent);
  public
    property GLRenderControl: TOpenGlControl read FGLRenderControl write SetGLRenderControl;
    property isRenderActive: boolean read fIsRenderActive write fIsRenderActive;
    property isGlEnabled: boolean read fisGlEnabled write fisGlEnabled;
    property OnLoadingState: TNotifyEvent read FOnLoadingState write SetOnLoadingState;
    property OnTrackChange: TNotifyEvent read fOnTrackChange write fOnTrackChange;
    property TrackList: TTrackList read fTrackList;
    property Volume: integer read GetMainVolume write SetMainVolume;
    function Initialize(Renderer: TOpenGLControl): boolean;
    function IsIdle: boolean;
    procedure LoadTracks;
    procedure SetTrack(TrackType: TTrackType; Id: integer); overload;
    procedure SetTrack(Index: integer); overload;
    procedure OsdMessage(msg: string = '');
    procedure ShowStats;
    procedure OsdEpg(const ChannelDesc: string; EpgInfo: REpgInfo; Show: boolean);
    procedure Play(mrl: string);
    procedure PlayIMG(mrl: string);
    procedure Stop;
    procedure Seek(Seconds: integer);
    function Pause: boolean;
    procedure Mute;
    constructor Create;
    destructor Destroy; override;
    procedure Test;
    class function CheckMPV: boolean;

  end;

implementation

uses
  GeneralFunc, LoggerUnit, Config, LCLIntf
{$ifdef LINUX}
  , ctypes
{$endif};

{$ifdef LINUX}
function setlocale(category: cint; locale: PChar): PChar; cdecl; external 'c' Name 'setlocale';
{$endif}

// Callbacks
procedure LibMPVEvent(Data: Pointer); cdecl;
begin
  if (Data = nil) then
    exit;
  TMPVEngine(Data).PostCommand(ecEvent, 1);
end;

{ TTrack }

procedure TTrack.Init;
begin
  Kind := trkUnknown;
  Selected := False;
  Id := 0;
  Title := '';
  Lang := '';
  Channels := 0;
  Codec := '';
  w := 0;
  h := 0;
  Bitrate := 0;
  fps := 0;
end;

{ TMPVEngine }

procedure TMPVEngine.SetGLRenderControl(AValue: TOpenGlControl);
begin
  if FGLRenderControl = AValue then
    Exit;
  FGLRenderControl := AValue;
end;

procedure TMPVEngine.SetOnLoadingState(AValue: TNotifyEvent);
begin
  FOnLoadingState := AValue;
end;

function TMPVEngine.Initialize(Renderer: TOpenGLControl): boolean;
var
  ServerVersion: PChar;
  i: integer;
begin
  Result := True;
  try
    fhandle := mpv_create();
    if ConfigObj.MPVProperties.HardwareAcceleration then
      mpv_set_option_string(fHandle^, 'hwdec', 'auto');

    mpv_set_option_string(fHandle^, 'input-cursor', 'no');   // no mouse handling
    mpv_set_option_string(fHandle^, 'cursor-autohide', 'no');
    mpv_request_log_messages(fhandle^, 'error');
    mpv_set_option_string(fHandle^, 'msg-level', 'all=error');
    mpv_initialize(fHandle^);
    ClientVersion := mpv_client_api_version;
    for i := 0 to ConfigObj.MPVProperties.CustomOptions.Count - 1 do
      mpv_set_option_string(fHandle^, PChar(ConfigObj.MPVProperties.CustomOptions.Names[i]),
        PChar(ConfigObj.MPVProperties.CustomOptions.ValueFromIndex[i]));

    fdecoupler := TDecoupler.Create;
    fdecoupler.OnCommand := ReceivedCommand;
    ServerVersion := mpv_get_property_string(fHandle^, 'mpv-version');
    OvoLogger.Log(FORCED, StrPas(ServerVersion));

    mpv_observe_property(fHandle^, 0, 'aid', MPV_FORMAT_INT64);
    mpv_observe_property(fHandle^, 0, 'sid', MPV_FORMAT_INT64);
    mpv_observe_property(fHandle^, 0, 'core-idle', MPV_FORMAT_FLAG);
    mpv_set_wakeup_callback(fhandle^, @LibMPVEvent, self);

    GLRenderControl := Renderer;

    Application.QueueAsyncCall(InitRenderer, 0);

  except
    Result := False;
  end;
end;

constructor TMPVEngine.Create;
begin
  {$ifdef LINUX}
  setlocale(1, 'C');
  {$endif}
  fdecoupler := nil;
  Load_libmpv(libmpv.External_library);
  Loadrender(libmpv.External_library);
  EngineState := ENGINE_IDLE;
  fHandle := nil;
  fMuted := False;
end;

destructor TMPVEngine.Destroy;
begin
  if Assigned(fHandle) then
  begin
    RenderObj.Free;
    mpv_set_wakeup_callback(fhandle^, nil, self);
    mpv_terminate_destroy(fhandle^);
  end;
  if Assigned(fdecoupler) then
    fdecoupler.Free;

  Free_libmpv;
  inherited Destroy;
end;

// initialize OpenGL rendering
procedure TMPVEngine.InitRenderer(Data: PtrInt);
begin
  isRenderActive := True;
  GLRenderControl.Visible := False;
  GLRenderControl.ReleaseContext;
  Application.ProcessMessages;
  RenderObj := TRender.Create(FGLRenderControl, fHandle);
  PlayIMG(ConfigObj.GetResourcesPath + 'empty.png');

end;

// Handle player messages to avoid threading issues
procedure TMPVEngine.PostCommand(Command: TEngineCommand; Param: integer);
begin
  fdecoupler.SendCommand(Command, Param);
end;

procedure TMPVEngine.ReceivedCommand(Sender: TObject; Command: TEngineCommand; Param: integer);
var
  Event: Pmpv_event;
  p: integer;
begin

  if (Command = ecEvent) and (param = 1) then
  begin
    Event := mpv_wait_event(fhandle^, 0);
    while Event^.event_id <> MPV_EVENT_NONE do
    begin
      case (Event^.event_id) of
        MPV_EVENT_LOG_MESSAGE:
          OvoLogger.Log(INFO, Pmpv_event_log_message(Event^.Data)^.Text);
        MPV_EVENT_QUEUE_OVERFLOW:
          OvoLogger.Log(ERROR, 'Event owerflow');
        MPV_EVENT_PLAYBACK_RESTART:
        begin
          Loading := False;
          if Assigned(FOnLoadingState) then
            FOnLoadingState(self);
        end;
        MPV_EVENT_PROPERTY_CHANGE:
        begin
          if Pmpv_event_property(Event^.Data)^.Name = 'core-idle' then
            if Loading then
            begin
              mpv_get_property(fhandle^, 'core-idle', MPV_FORMAT_FLAG, @p);
              Loading := P = 1;

              if not loading then
                if Assigned(FOnLoadingState) then
                  FOnLoadingState(self);
            end;
          if ((Pmpv_event_property(Event^.Data)^.Name = 'aid') or
            (Pmpv_event_property(Event^.Data)^.Name = 'vid')) and
            (Pmpv_event_property(Event^.Data)^.format = MPV_FORMAT_INT64) then
            LoadTracks;
        end;
      end;
      Event := mpv_wait_event(fhandle^, 0);
    end;
  end;
end;

procedure TMPVEngine.Play(mrl: string);
var
  Args: array of PChar;
begin

  args := nil;
  setlength(args, 4);
  args[0] := 'loadfile';
  args[1] := PChar(mrl);
  args[2] := 'replace';
  args[3] := nil;
  mpv_command(fhandle^, ppchar(@args[0]));
  Loading := True;

end;

procedure TMPVEngine.PlayIMG(mrl: string);
var
  Args: array of PChar;
begin

  args := nil;
  setlength(args, 5);
  args[0] := 'loadfile';
  args[1] := PChar(mrl);
  args[2] := 'replace';
  args[3] := 'image-display-duration=inf';
  args[4] := nil;
  mpv_command(fhandle^, ppchar(@args[0]));

end;

procedure TMPVEngine.ShowStats;
var
  Args: array of PChar;
  res: longint;
begin

  args := nil;
  setlength(args, 3);
  args[0] := 'script-binding';
  args[1] := 'display-stats-toggle';
  args[2] := nil;
  res := mpv_command(fhandle^, ppchar(@args[0]));

end;

procedure TMPVEngine.LoadTracks;
var
  Node: mpv_node;
  Map: mpv_node;
  Detail: mpv_Node;
  i, j: integer;
  pc: ppchar;
  Value, Value2: string;
begin
  SetLength(fTrackList, 0);
  try
    mpv_get_property(fhandle^, 'track-list', MPV_FORMAT_NODE, @Node);
    SetLength(fTrackList, Node.u.list_^.num);
    for i := 0 to Node.u.list_^.num - 1 do
    begin
      map := Node.u.list_^.values[i]; // pmpv_node(PtrUInt(Node.u.list_^.values) + i * 16)^;
      pc := map.u.list_^.keys;
      TrackList[i].Init;
      for j := 0 to map.u.list_^.num - 1 do
      begin
        Detail := map.u.list_^.values[j]; // Pmpv_node(PtrUInt(map.u.list_^.values) + j * 16)^;
        Value := strpas(pc^);
        if Value = 'id' then
          fTrackList[i].Id := Detail.u.int64_;
        if Value = 'title' then
          fTrackList[i].Title := strpas(Detail.u.string_);
        if Value = 'type' then
        begin
          Value2 := Detail.u.string_;
          if Value2 = 'audio' then
            fTrackList[i].kind := trkAudio
          else if Value2 = 'video' then
            fTrackList[i].kind := trkVideo
          else if Value2 = 'sub' then
            fTrackList[i].kind := trkSub
          else
            fTrackList[i].kind := trkUnknown;
        end;
        if Value = 'lang' then
          fTrackList[i].Lang := strpas(Detail.u.string_);
        if Value = 'codec' then
          fTrackList[i].Codec := strpas(Detail.u.string_);
        if Value = 'demux-w' then
          fTrackList[i].w := Detail.u.int64_;
        if Value = 'demux-h' then
          fTrackList[i].h := Detail.u.int64_;
        if Value = 'demux-channel-count' then
          fTrackList[i].Channels := Detail.u.int64_;
        if Value = 'demux-samplerate' then
          fTrackList[i].samplerate := Detail.u.int64_;
        if Value = 'demux-bitrate' then
          fTrackList[i].Bitrate := Detail.u.int64_;
        if Value = 'demux-fps' then
          fTrackList[i].fps := Detail.u.double_;
        if Value = 'selected' then
          fTrackList[i].Selected := Detail.u.flag_ = 1;
        Inc(pc);
      end;
    end;
    mpv_free_node_contents(node);
  except
  end;
  if Assigned(fOnTrackChange) then
    fOnTrackChange(self);
end;

function TMPVEngine.GetBoolProperty(const PropertyName: string): boolean;
var
  p: integer;
begin
  mpv_get_property(fhandle^, PChar(PropertyName), MPV_FORMAT_FLAG, @p);
  Result := boolean(p);
end;

procedure TMPVEngine.SetBoolProperty(const PropertyName: string; AValue: boolean);
var
  p: integer;
begin
  if AValue then
    p := 1
  else
    p := 0;
  mpv_set_property(fhandle^, PChar(PropertyName), MPV_FORMAT_FLAG, @p);
end;


function TMPVEngine.IsIdle: boolean;
begin
  Result := GetBoolProperty('core-idle');
  if Result then
    EngineState := ENGINE_IDLE
  else
    EngineState := ENGINE_PLAY;
end;

procedure TMPVEngine.SetTrack(TrackType: TTrackType; Id: integer);
var
  TrackTypeString: string;
  Num: int64;
begin
  case TrackType of
    trkAudio: TrackTypeString := 'aid';
    trkVideo: TrackTypeString := 'vid';
    trkSub: TrackTypeString := 'sid';
    else
      exit;
  end;
  Num := id;
  mpv_set_property(fHandle^, PChar(TrackTypeString), MPV_FORMAT_INT64, @num);
end;

procedure TMPVEngine.SetTrack(Index: integer);
begin
  SetTrack(TrackList[index].Kind, TrackList[index].Id);
end;

function TMPVEngine.GetMainVolume: integer;
var
  vol: double;
begin
  mpv_get_property(fhandle^, 'volume', MPV_FORMAT_DOUBLE, @vol);
  Result := trunc(vol);
end;

procedure TMPVEngine.SetMainVolume(const AValue: integer);
var
  vol: double;
begin
  vol := AValue;
  mpv_set_property(fhandle^, 'volume', MPV_FORMAT_DOUBLE, @vol);

end;


procedure TMPVEngine.Stop;
var
  Args: array of PChar;
begin
  setlength(args, 2);
  args[0] := 'stop';
  args[1] := nil;
  mpv_command(fhandle^, ppchar(@args[0]));
  EngineState := ENGINE_STOP;

end;

procedure TMPVEngine.Seek(Seconds: integer);

var
  Args: array of PChar;
begin

  args := nil;
  setlength(args, 3);
  args[0] := 'seek';
  args[1] := PChar(IntToStr(seconds));
  args[2] := nil;
  mpv_command(fhandle^, ppchar(@args[0]));
  Loading := True;

end;

procedure TMPVEngine.OsdMessage(msg: string = '');
var
  num: int64;
  Node: mpv_node;
  List: mpv_node_list;
  Keys: array of PChar;
  values: mpv_node_array;
  res: mpv_node;
begin
  if ClientVersion <= $00010065 then
  begin
    num := 1;
    mpv_set_property(fHandle^, 'osd-level', MPV_FORMAT_INT64, @num);
    mpv_set_property_string(fHandle^, 'osd-align-y', 'top');
    num := 55;
    mpv_set_property(fHandle^, 'osd-font-size', MPV_FORMAT_INT64, @num);
    num := 0;
    mpv_set_property(fHandle^, 'osd-border-size', MPV_FORMAT_INT64, @num);
    mpv_set_property_string(fHandle^, 'osd-msg1', PChar(msg));
  end
  else
  begin
    SetLength(Keys, 4);
    Keys[0] := 'name';
    values[0].format := MPV_FORMAT_STRING;
    values[0].u.string_ := 'osd-overlay';
    Keys[1] := 'id';
    values[1].format := MPV_FORMAT_INT64;
    values[1].u.int64_ := 1;
    Keys[2] := 'format';
    values[2].format := MPV_FORMAT_STRING;
    if True then
      values[2].u.string_ := 'ass-events'
    else
      values[2].u.string_ := 'none';
    Keys[3] := 'data';
    values[3].format := MPV_FORMAT_STRING;
    values[3].u.string_ := PChar(format('{\bord1\an7}%s', [msg]));
    List.num := 4;
    List.keys := @Keys[0];
    List.values := @values[0];
    Node.format := MPV_FORMAT_NODE_MAP;
    Node.u.list_ := @list;

    mpv_command_node(fHandle^, node, res);

  end;
end;

procedure TMPVEngine.OsdEpg(const ChannelDesc: string; EpgInfo: REpgInfo; Show: boolean);
var
  num: int64;
  Node: mpv_node;
  List: mpv_node_list;
  Keys: array of PChar;
  values: mpv_node_array;
  res: mpv_node;
begin
  mpv_set_property_string(fHandle^, 'osd-back-color', '#80000000');

  if ClientVersion <= $00010065 then
  begin
    num := 3;
    mpv_set_property(fHandle^, 'osd-level', MPV_FORMAT_INT64, @num);
    mpv_set_property_string(fHandle^, 'osd-align-y', 'bottom');
    num := 36;
    mpv_set_property(fHandle^, 'osd-font-size', MPV_FORMAT_INT64, @num);
    num := 2;
    mpv_set_property(fHandle^, 'osd-border-size', MPV_FORMAT_INT64, @num);
    mpv_set_property_string(fHandle^, 'osd-msg3', PChar(format('%s' + #10 + '%s    %s ' + #10 + ' %s',
      [ChannelDesc, FormatTimeRange(EpgInfo.StartTime, EpgInfo.EndTime, True), EpgInfo.Title, EpgInfo.Plot])));
  end
  else
  begin
    SetLength(Keys, 4);
    Keys[0] := 'name';
    values[0].format := MPV_FORMAT_STRING;
    values[0].u.string_ := 'osd-overlay';
    Keys[1] := 'id';
    values[1].format := MPV_FORMAT_INT64;
    values[1].u.int64_ := 1;
    Keys[2] := 'format';
    values[2].format := MPV_FORMAT_STRING;
    if Show then
      values[2].u.string_ := 'ass-events'
    else
      values[2].u.string_ := 'none';
    Keys[3] := 'data';
    values[3].format := MPV_FORMAT_STRING;

    // \3c&HFFFFFF&\3a&H80&
    values[3].u.string_ := PChar(format('{\bord1\an7}%s', [ChannelDesc]) + #10 +
      format('{\bord1\an1}{\fscx50\fscy50}%s - {\fscx75\fscy75}{\b1}%s{\b0}\N{\fscx50\fscy50}%s',
      [FormatTimeRange(EpgInfo.StartTime, EpgInfo.EndTime, True), EpgInfo.Title, EpgInfo.Plot]));

    List.num := 4;
    List.keys := @Keys[0];
    List.values := @values[0];
    Node.format := MPV_FORMAT_NODE_MAP;
    Node.u.list_ := @list;

    mpv_command_node(fHandle^, node, res);

  end;

end;

function TMPVEngine.Pause: boolean;
begin
  if (EngineState = ENGINE_PAUSE) then
  begin
    SetBoolProperty('pause', False);
    Result := False;
    EngineState := ENGINE_PLAY;
  end
  else if EngineState = ENGINE_PLAY then
  begin
    SetBoolProperty('pause', True);
    Result := True;
    EngineState := ENGINE_Pause;
  end;

end;

procedure TMPVEngine.Mute;
begin
  if fMuted then
  begin
    Volume := fOldVolume;
    fMuted := False;
  end
  else
  begin
    fOldVolume := Volume;
    Volume := 0;
    fMuted := True;
  end;
end;

procedure TMPVEngine.Test;
var
  s: int64;
begin
  mpv_get_property(fHandle^, 'osd-font-size', MPV_FORMAT_INT64, @s);
  OsdMessage(IntToStr(s));
end;

class function TMPVEngine.CheckMPV: boolean;
begin
  Result := Check_libmpv and Check_Renderer;
end;

end.
