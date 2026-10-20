program trkstream;

{
  trkStreamDesc - a very thin "now playing" proxy for the Traktor DJ Pro broadcast.
  Independent project, not affiliated with Native Instruments.

  Source side (default port 8000)
    The program pretends to be an Icecast server. Traktor connects with a
    SOURCE/PUT request and streams Ogg Vorbis. The audio is discarded; only the
    Vorbis comment header (ARTIST, TITLE, ...) is extracted from the Ogg pages.
    Traktor starts a new logical Ogg stream - with a new comment header - for
    every track change. The shoutcast-style /admin/metadata?song=... update
    (used with MP3 streams) is accepted as well.

  Client side (default port 80)
    A minimal HTTP server that serves the web files from the program folder,
    plus a hand-written WebSocket (RFC 6455) endpoint that pushes track
    changes and answers simple JSON requests.

  Concurrency
    Every connection runs on its own thread. Shared state is guarded by
    critical sections; lock order is never nested (see Broadcast/SetTrack).
}

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads, BaseUnix,{$endif}
  {$ifdef windows}Windows,{$endif}
  SysUtils, Classes, Sockets, DateUtils, sha1, base64;

const
  APP_VERSION     = '1.1';
  WS_GUID         = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';  // RFC 6455 magic
  CRLF            = #13#10;

  MAX_HEADER      = 16384;            // max size of an HTTP request header
  MAX_HISTORY     = 50;               // remembered previous tracks
  MAX_PACKET      = 4 * 1024 * 1024;  // max reassembled Ogg packet (cover art can be big)
  MAX_WS_PAYLOAD  = 64 * 1024;        // max incoming WebSocket message
  MAX_CONNECTIONS = 256;              // max concurrent connection threads

  HEADER_TIMEOUT  = 10000;  // ms to receive a complete request header
  SOURCE_TIMEOUT  = 30000;  // ms of silence after which the source is dropped

type
  TTrack = record
    Artist, Title, Album, Genre, Year: string;
    Tags: string;      // JSON object holding every comment tag
    Started: Int64;    // unix time in ms when the track became current
  end;

  { A connected WebSocket client. Sending is serialized by Lock because both
    the client's own thread and broadcasting threads write to the socket. }
  TWSClient = class
    Sock: TSocket;
    Lock: TRTLCriticalSection;
    constructor Create(ASock: TSocket);
    destructor Destroy; override;
    function SendFrame(Op: Byte; const Payload: RawByteString): Boolean;
    function SendText(const S: string): Boolean;
  end;

  { Incremental Ogg page parser: reassembles packets and reports comment headers. }
  TOggParser = class
  private
    FBuf, FPacket: RawByteString;
    FDropPacket: Boolean;  // current packet exceeded MAX_PACKET, skip until its end
    procedure HandlePacket(const Pk: RawByteString);
  public
    procedure Feed(const Data: RawByteString);
  end;

  { Accept loop of one listening socket. }
  TListener = class(TThread)
  private
    FSock: TSocket;
    FIsSource: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ASock: TSocket; AIsSource: Boolean);
  end;

  { One accepted connection: either a Traktor source or an HTTP/WebSocket client. }
  TConn = class(TThread)
  private
    FSock: TSocket;
    FIsSource: Boolean;
    FPeer: string;
    FBuf: RawByteString;    // received but not yet consumed bytes
    FHeaders: TStringList;  // lowercase-name=value
    FMethod, FTarget: string;
    function RecvMore: Boolean;
    function ReadRequest: Boolean;
    function Header(const Name: string): string;
    function Authorized: Boolean;
    function ReadFrame(out Op: Byte; out Payload: RawByteString; out Fin: Boolean): Boolean;
    procedure HandleHttp;
    procedure HandleWebSocket(const Key: string);
    procedure HandleSource;
    procedure ServeFile;
    procedure SendResponse(const Status, ContentType: string; const Body: RawByteString;
      const Extra: string = '');
  protected
    procedure Execute; override;
  public
    constructor Create(ASock: TSocket; AIsSource: Boolean; const APeer: string);
    destructor Destroy; override;
  end;

var
  LogLock, StateLock, ClientsLock: TRTLCriticalSection;
  Clients: TList;               // of TWSClient, guarded by ClientsLock
  Current: TTrack;              // guarded by StateLock (with the fields below)
  HasTrack: Boolean = False;
  History: array of TTrack;     // newest first
  SourceCount: Integer = 0;
  SourceInfo: string = '';
  ConnCount: LongInt = 0;       // live TConn threads (interlocked)
  StartMs: Int64;
  BaseDir: string;              // program folder, with trailing delimiter
  Pages: TStringList;           // html pages given on the command line
  HttpPort: Word = 80;
  SourcePort: Word = 8000;
  SourcePassword: string = '';  // empty = no authentication
  SourceAnyHost: Boolean = False;

{ ---------------------------------------------------------------- helpers }

procedure Log(const S: string);
begin
  EnterCriticalSection(LogLock);
  try
    WriteLn(FormatDateTime('hh:nn:ss', Now), '  ', S);
  finally
    LeaveCriticalSection(LogLock);
  end;
end;

function NowMs: Int64;
var
  N: TDateTime;
begin
  N := LocalTimeToUniversal(Now);
  Result := DateTimeToUnix(N) * 1000 + MilliSecondOf(N);
end;

function SockOk(S: TSocket): Boolean;
begin
  Result := PtrInt(S) >= 0;  // INVALID_SOCKET / -1 are negative as PtrInt
end;

{ Sets the receive timeout of a socket; 0 means wait forever. }
procedure SetRecvTimeout(S: TSocket; Ms: Integer);
{$ifdef windows}
var
  V: DWORD;
begin
  V := Ms;
  fpSetSockOpt(S, SOL_SOCKET, SO_RCVTIMEO, @V, SizeOf(V));
end;
{$else}
var
  V: TTimeVal;
begin
  V.tv_sec := Ms div 1000;
  V.tv_usec := (Ms mod 1000) * 1000;
  fpSetSockOpt(S, SOL_SOCKET, SO_RCVTIMEO, @V, SizeOf(V));
end;
{$endif}

{ Sends the whole buffer, looping over partial sends. }
function SendAll(S: TSocket; const Data: RawByteString): Boolean;
var
  P, N: Integer;
begin
  P := 1;
  while P <= Length(Data) do
  begin
    N := fpSend(S, @Data[P], Length(Data) - P + 1, 0);
    if N <= 0 then Exit(False);
    Inc(P, N);
  end;
  Result := True;
end;

{ True when S is well-formed UTF-8 (no overlong forms, surrogates or values
  above U+10FFFF). }
function IsValidUtf8(const S: RawByteString): Boolean;
const
  MIN_CP: array[1..3] of Cardinal = ($80, $800, $10000);  // by continuation count
var
  I, J, Need, L: Integer;
  B: Byte;
  CP: Cardinal;
begin
  I := 1;
  L := Length(S);
  while I <= L do
  begin
    B := Ord(S[I]);
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end
    else if (B and $E0) = $C0 then begin Need := 1; CP := B and $1F; end
    else if (B and $F0) = $E0 then begin Need := 2; CP := B and $0F; end
    else if (B and $F8) = $F0 then begin Need := 3; CP := B and $07; end
    else Exit(False);
    if I + Need > L then Exit(False);
    for J := I + 1 to I + Need do
    begin
      B := Ord(S[J]);
      if (B and $C0) <> $80 then Exit(False);
      CP := (CP shl 6) or (B and $3F);
    end;
    if (CP < MIN_CP[Need]) or (CP > $10FFFF) or ((CP >= $D800) and (CP <= $DFFF)) then
      Exit(False);
    Inc(I, Need + 1);
  end;
  Result := True;
end;

{ Returns S as valid UTF-8. Text that is not UTF-8 (e.g. metadata of an MP3
  source in the system ANSI code page) is converted from the ANSI code page
  on Windows and from Latin-1 elsewhere, so clients never get broken frames. }
function ToUtf8(const S: RawByteString): string;
var
  W: UnicodeString;
  {$ifndef windows}I: Integer;{$endif}
begin
  if IsValidUtf8(S) then Exit(S);
  {$ifdef windows}
  SetLength(W, MultiByteToWideChar(GetACP, 0, PChar(S), Length(S), nil, 0));
  if Length(W) > 0 then
    MultiByteToWideChar(GetACP, 0, PChar(S), Length(S), PWideChar(W), Length(W));
  {$else}
  SetLength(W, Length(S));
  for I := 1 to Length(S) do W[I] := WideChar(Ord(S[I]));
  {$endif}
  Result := UTF8Encode(W);
end;

{ Quotes and escapes a string as a JSON string literal. The result is always
  valid UTF-8: browsers drop the connection on an invalid text frame. }
function JS(const Raw: string): string;
var
  I: Integer;
  C: Char;
  S: string;
begin
  S := ToUtf8(Raw);
  Result := '"';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case C of
      '"': Result += '\"';
      '\': Result += '\\';
      #8:  Result += '\b';
      #9:  Result += '\t';
      #10: Result += '\n';
      #12: Result += '\f';
      #13: Result += '\r';
      #0..#7, #11, #14..#31: Result += '\u' + IntToHex(Ord(C), 4);
    else
      Result += C;
    end;
  end;
  Result += '"';
end;

function JBool(B: Boolean): string;
begin
  if B then Result := 'true' else Result := 'false';
end;

function HtmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

// Minimal JSON field reader for flat request objects:
//   JsonGet('{"cmd":"get","id":5}', 'id') = '5'. Not a full parser by design.
function JsonGet(const Json, Key: string): string;
var
  P, L: Integer;
begin
  Result := '';
  P := Pos('"' + Key + '"', Json);
  if P = 0 then Exit;
  P := P + Length(Key) + 2;
  L := Length(Json);
  while (P <= L) and (Json[P] in [' ', #9, #10, #13, ':']) do Inc(P);
  if P > L then Exit;
  if Json[P] = '"' then
  begin
    // string value, with the common escapes
    Inc(P);
    while (P <= L) and (Json[P] <> '"') do
    begin
      if (Json[P] = '\') and (P < L) then
      begin
        Inc(P);
        case Json[P] of
          'n': Result += #10;
          't': Result += #9;
          'r': Result += #13;
        else
          Result += Json[P];
        end;
      end
      else
        Result += Json[P];
      Inc(P);
    end;
  end
  else
  begin
    // number / literal value
    while (P <= L) and not (Json[P] in [',', '}', ']']) do
    begin
      Result += Json[P];
      Inc(P);
    end;
    Result := Trim(Result);
  end;
end;

{ Decodes %XX escapes and '+' (as used in query strings). }
function UrlDecode(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) then
    begin
      Result += Chr(StrToIntDef('$' + Copy(S, I + 1, 2), Ord('?')));
      Inc(I, 3);
      Continue;
    end;
    if S[I] = '+' then Result += ' ' else Result += S[I];
    Inc(I);
  end;
end;

{ Returns the decoded value of one parameter of a query string ('a=1&b=2'). }
function QueryParam(const Query, Name: string): string;
var
  Parts: TStringList;
  I, Eq: Integer;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := '&';
    Parts.DelimitedText := Query;
    for I := 0 to Parts.Count - 1 do
    begin
      Eq := Pos('=', Parts[I]);
      if (Eq > 0) and SameText(Copy(Parts[I], 1, Eq - 1), Name) then
        Exit(UrlDecode(Copy(Parts[I], Eq + 1, MaxInt)));
    end;
  finally
    Parts.Free;
  end;
end;

{ ------------------------------------------------------------ track state }

function TrackJson(const T: TTrack): string;
begin
  Result := '{"artist":' + JS(T.Artist) + ',"title":' + JS(T.Title) +
    ',"album":' + JS(T.Album) + ',"genre":' + JS(T.Genre) +
    ',"year":' + JS(T.Year) + ',"started":' + IntToStr(T.Started) +
    ',"tags":' + T.Tags + '}';
end;

{ Current track message of the given type. The caller must hold StateLock. }
function NowJsonLocked(const Typ: string): string;
var
  TJ: string;
begin
  if HasTrack then TJ := TrackJson(Current) else TJ := 'null';
  Result := '{"type":' + JS(Typ) + ',"serverTime":' + IntToStr(NowMs) +
    ',"source":' + JBool(SourceCount > 0) + ',"track":' + TJ + '}';
end;

function NowJson(const Typ: string): string;
begin
  EnterCriticalSection(StateLock);
  try
    Result := NowJsonLocked(Typ);
  finally
    LeaveCriticalSection(StateLock);
  end;
end;

{ Previous tracks, newest first. Limit <= 0 means all of them. }
function HistoryJson(Limit: Integer): string;
var
  I: Integer;
begin
  EnterCriticalSection(StateLock);
  try
    if (Limit <= 0) or (Limit > Length(History)) then Limit := Length(History);
    Result := '{"type":"history","serverTime":' + IntToStr(NowMs) + ',"items":[';
    for I := 0 to Limit - 1 do
    begin
      if I > 0 then Result += ',';
      Result += TrackJson(History[I]);
    end;
    Result += ']}';
  finally
    LeaveCriticalSection(StateLock);
  end;
end;

function ClientCount: Integer;
begin
  EnterCriticalSection(ClientsLock);
  try
    Result := Clients.Count;
  finally
    LeaveCriticalSection(ClientsLock);
  end;
end;

function StatusJson: string;
var
  N: Integer;
begin
  N := ClientCount;  // taken before StateLock: the two locks are never nested
  EnterCriticalSection(StateLock);
  try
    Result := '{"type":"status","serverTime":' + IntToStr(NowMs) +
      ',"source":' + JBool(SourceCount > 0) + ',"sourceInfo":' + JS(SourceInfo) +
      ',"clients":' + IntToStr(N) + ',"uptime":' + IntToStr((NowMs - StartMs) div 1000) +
      ',"version":' + JS(APP_VERSION) + '}';
  finally
    LeaveCriticalSection(StateLock);
  end;
end;

{ Sends a text message to every WebSocket client. A client whose send fails
  is shut down; its own thread then notices and removes it. }
procedure Broadcast(const Msg: string);
var
  I: Integer;
  C: TWSClient;
begin
  EnterCriticalSection(ClientsLock);
  try
    for I := 0 to Clients.Count - 1 do
    begin
      C := TWSClient(Clients[I]);
      if not C.SendText(Msg) then fpShutdown(C.Sock, 2);
    end;
  finally
    LeaveCriticalSection(ClientsLock);
  end;
end;

{ Makes T the current track (moving the old one to the history) and notifies
  the clients. Repeated updates with the same artist/title are ignored. }
procedure SetTrack(T: TTrack);
var
  Msg: string;
  I, P: Integer;
begin
  T.Artist := ToUtf8(Trim(T.Artist));
  T.Title := ToUtf8(Trim(T.Title));
  T.Album := ToUtf8(T.Album);
  T.Genre := ToUtf8(T.Genre);
  T.Year := ToUtf8(T.Year);
  // "Artist - Title" in a single field (typical for /admin/metadata)
  if T.Artist = '' then
  begin
    P := Pos(' - ', T.Title);
    if P > 0 then
    begin
      T.Artist := Trim(Copy(T.Title, 1, P - 1));
      T.Title := Trim(Copy(T.Title, P + 3, MaxInt));
    end;
  end;
  if (T.Artist = '') and (T.Title = '') then Exit;
  if T.Tags = '' then T.Tags := '{}';

  EnterCriticalSection(StateLock);
  try
    if HasTrack and (Current.Artist = T.Artist) and (Current.Title = T.Title) then Exit;
    T.Started := NowMs;
    if HasTrack then
    begin
      if Length(History) < MAX_HISTORY then SetLength(History, Length(History) + 1);
      for I := High(History) downto 1 do History[I] := History[I - 1];
      History[0] := Current;
    end;
    Current := T;
    HasTrack := True;
    Msg := NowJsonLocked('track');
  finally
    LeaveCriticalSection(StateLock);
  end;
  Log('NOW PLAYING: ' + T.Artist + ' - ' + T.Title);
  Broadcast(Msg);
end;

{ Called when a source connects (+1) or disconnects (-1). }
procedure SourceChanged(Delta: Integer; const Info: string);
begin
  EnterCriticalSection(StateLock);
  try
    Inc(SourceCount, Delta);
    if Delta > 0 then SourceInfo := Info
    else if SourceCount = 0 then SourceInfo := '';
  finally
    LeaveCriticalSection(StateLock);
  end;
  Broadcast(StatusJson);
end;

{ -------------------------------------------------------------- TWSClient }

constructor TWSClient.Create(ASock: TSocket);
begin
  Sock := ASock;
  InitCriticalSection(Lock);
end;

destructor TWSClient.Destroy;
begin
  DoneCriticalSection(Lock);
  inherited;
end;

{ Sends one unmasked, unfragmented frame (server frames are never masked). }
function TWSClient.SendFrame(Op: Byte; const Payload: RawByteString): Boolean;
var
  H: RawByteString;
  L: Int64;
  I: Integer;
begin
  L := Length(Payload);
  H := Chr($80 or Op);  // FIN + opcode
  if L < 126 then
    H += Chr(L)
  else if L < 65536 then
    H += #126 + Chr(L shr 8) + Chr(L and $FF)
  else
  begin
    H += #127;
    for I := 7 downto 0 do H += Chr((L shr (I * 8)) and $FF);
  end;
  EnterCriticalSection(Lock);
  try
    Result := SendAll(Sock, H + Payload);
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function TWSClient.SendText(const S: string): Boolean;
begin
  Result := SendFrame(1, S);
end;

{ ------------------------------------------------------------- TOggParser }

{ Reads a little-endian uint32 at S[P] and advances P. }
function RdU32(const S: RawByteString; var P: Integer; out V: Cardinal): Boolean;
begin
  V := 0;
  if (P < 1) or (P + 3 > Length(S)) then Exit(False);
  V := Ord(S[P]) or (Ord(S[P + 1]) shl 8) or (Ord(S[P + 2]) shl 16) or
       (Cardinal(Ord(S[P + 3])) shl 24);
  Inc(P, 4);
  Result := True;
end;

{ Parses a Vorbis comment block starting at Pk[P]:
  vendor_length, vendor, count, then count x (length, "KEY=value"). }
procedure ParseComments(const Pk: RawByteString; P: Integer);
var
  Len, Cnt, I: Cardinal;
  C, K, V, Tags: string;
  Eq: Integer;
  T: TTrack;

  // multi-valued tags (e.g. several ARTIST entries) are joined
  procedure AddTo(var Field: string);
  begin
    if Field = '' then Field := V else Field := Field + ', ' + V;
  end;

begin
  T := Default(TTrack);
  if not RdU32(Pk, P, Len) or (Int64(P) + Len - 1 > Length(Pk)) then Exit;
  Inc(P, Len);  // skip vendor string
  if not RdU32(Pk, P, Cnt) then Exit;
  Tags := '';
  for I := 1 to Cnt do
  begin
    if not RdU32(Pk, P, Len) or (Int64(P) + Len - 1 > Length(Pk)) then Break;
    C := Copy(Pk, P, Len);
    Inc(P, Len);
    Eq := Pos('=', C);
    if Eq = 0 then Continue;
    K := UpperCase(Copy(C, 1, Eq - 1));
    V := Copy(C, Eq + 1, MaxInt);
    if K = 'METADATA_BLOCK_PICTURE' then Continue;  // embedded cover art
    if K = 'ARTIST' then AddTo(T.Artist)
    else if K = 'TITLE' then AddTo(T.Title)
    else if K = 'ALBUM' then AddTo(T.Album)
    else if K = 'GENRE' then AddTo(T.Genre)
    else if (K = 'DATE') or (K = 'YEAR') then T.Year := V;
    if Length(V) < 2048 then
    begin
      if Tags <> '' then Tags += ',';
      Tags += JS(LowerCase(K)) + ':' + JS(V);
    end;
  end;
  T.Tags := '{' + Tags + '}';
  SetTrack(T);
end;

{ Only comment headers are interesting: Vorbis (type 3) and Opus. }
procedure TOggParser.HandlePacket(const Pk: RawByteString);
begin
  if Copy(Pk, 1, 7) = #3'vorbis' then
    ParseComments(Pk, 8)
  else if Copy(Pk, 1, 8) = 'OpusTags' then
    ParseComments(Pk, 9);
end;

{ Appends stream data and processes every complete Ogg page in the buffer.
  Page layout: "OggS", version, flags, granule(8), serial(4), seq(4), crc(4),
  segment count, segment table, body. A packet ends at a segment < 255. }
procedure TOggParser.Feed(const Data: RawByteString);
var
  P, NSeg, I, SegLen, BodyLen, HdrLen, BodyPos: Integer;
  Flags: Byte;
begin
  FBuf += Data;
  while True do
  begin
    P := Pos('OggS', FBuf);
    if P = 0 then
    begin
      // no capture pattern: keep only a possible partial "OggS" at the end
      if Length(FBuf) > 3 then Delete(FBuf, 1, Length(FBuf) - 3);
      Exit;
    end;
    if P > 1 then Delete(FBuf, 1, P - 1);
    if Length(FBuf) < 27 then Exit;
    if FBuf[5] <> #0 then
    begin
      Delete(FBuf, 1, 1);  // false sync (version must be 0), search on
      Continue;
    end;
    Flags := Ord(FBuf[6]);
    NSeg := Ord(FBuf[27]);
    HdrLen := 27 + NSeg;
    if Length(FBuf) < HdrLen then Exit;
    BodyLen := 0;
    for I := 1 to NSeg do Inc(BodyLen, Ord(FBuf[27 + I]));
    if Length(FBuf) < HdrLen + BodyLen then Exit;  // wait for the full page

    // beginning of a new logical stream (new track) or a non-continued page
    if ((Flags and $02) <> 0) or ((Flags and $01) = 0) then
    begin
      FPacket := '';
      FDropPacket := False;
    end;

    BodyPos := HdrLen + 1;
    for I := 1 to NSeg do
    begin
      SegLen := Ord(FBuf[27 + I]);
      if not FDropPacket then
      begin
        if Length(FPacket) + SegLen > MAX_PACKET then
        begin
          FDropPacket := True;
          FPacket := '';
        end
        else
          FPacket += Copy(FBuf, BodyPos, SegLen);
      end;
      Inc(BodyPos, SegLen);
      if SegLen < 255 then
      begin
        if not FDropPacket then HandlePacket(FPacket);
        FPacket := '';
        FDropPacket := False;
      end;
    end;
    Delete(FBuf, 1, HdrLen + BodyLen);
  end;
end;

{ -------------------------------------------------------------- TListener }

{ Opens a listening TCP socket; returns an invalid socket on failure. }
function OpenListener(Port: Word; LoopbackOnly: Boolean): TSocket;
var
  A: TInetSockAddr;
  {$ifdef unix}One: Integer;{$endif}
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  if not SockOk(Result) then Exit;
  {$ifdef unix}
  // on Windows SO_REUSEADDR would allow port hijacking, so unix only
  One := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  {$endif}
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  if LoopbackOnly then A.sin_addr := StrToNetAddr('127.0.0.1');
  if (fpBind(Result, @A, SizeOf(A)) <> 0) or (fpListen(Result, 32) <> 0) then
  begin
    CloseSocket(Result);
    Result := TSocket(-1);
  end;
end;

constructor TListener.Create(ASock: TSocket; AIsSource: Boolean);
begin
  FSock := ASock;
  FIsSource := AIsSource;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TListener.Execute;
var
  CS: TSocket;
  A: TInetSockAddr;
  L: TSockLen;
begin
  while not Terminated do
  begin
    L := SizeOf(A);
    CS := fpAccept(FSock, @A, @L);
    if not SockOk(CS) then
    begin
      Sleep(50);
      Continue;
    end;
    // connection limit: protects against thread exhaustion
    if ConnCount >= MAX_CONNECTIONS then
    begin
      CloseSocket(CS);
      Continue;
    end;
    try
      TConn.Create(CS, FIsSource, NetAddrToStr(A.sin_addr) + ':' + IntToStr(ntohs(A.sin_port)));
    except
      on E: Exception do
      begin
        Log('Cannot start connection thread: ' + E.Message);
        CloseSocket(CS);
      end;
    end;
  end;
end;

{ ------------------------------------------------------------------ TConn }

constructor TConn.Create(ASock: TSocket; AIsSource: Boolean; const APeer: string);
begin
  FSock := ASock;
  FIsSource := AIsSource;
  FPeer := APeer;
  FHeaders := TStringList.Create;
  FreeOnTerminate := True;
  InterLockedIncrement(ConnCount);
  inherited Create(False);  // the thread starts after the constructor
end;

destructor TConn.Destroy;
begin
  FHeaders.Free;
  InterLockedDecrement(ConnCount);
  inherited;
end;

{ Receives the next chunk into FBuf. False on close, error or timeout. }
function TConn.RecvMore: Boolean;
var
  Buf: array[0..16383] of Byte;
  N, Old: Integer;
begin
  N := fpRecv(FSock, @Buf[0], SizeOf(Buf), 0);
  if N <= 0 then Exit(False);
  Old := Length(FBuf);
  SetLength(FBuf, Old + N);
  Move(Buf[0], FBuf[Old + 1], N);
  Result := True;
end;

{ Reads and parses the request line and headers. Anything after the header
  (stream data, WebSocket frames) stays in FBuf. }
function TConn.ReadRequest: Boolean;
var
  P, I, C: Integer;
  Line: string;
  Lines: TStringList;
begin
  Result := False;
  repeat
    P := Pos(CRLF + CRLF, FBuf);
    if P > 0 then Break;
    if Length(FBuf) > MAX_HEADER then Exit;
    if not RecvMore then Exit;
  until False;

  Lines := TStringList.Create;
  try
    Lines.Text := Copy(FBuf, 1, P - 1);
    Delete(FBuf, 1, P + 3);
    if Lines.Count = 0 then Exit;
    // "METHOD target HTTP/x.y"
    Line := Lines[0];
    P := Pos(' ', Line);
    if P = 0 then Exit;
    FMethod := UpperCase(Copy(Line, 1, P - 1));
    FTarget := Copy(Line, P + 1, MaxInt);
    P := Pos(' ', FTarget);
    if P > 0 then FTarget := Copy(FTarget, 1, P - 1);
    for I := 1 to Lines.Count - 1 do
    begin
      C := Pos(':', Lines[I]);
      if C > 0 then
        FHeaders.Add(LowerCase(Trim(Copy(Lines[I], 1, C - 1))) + '=' +
          Trim(Copy(Lines[I], C + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
  Result := True;
end;

function TConn.Header(const Name: string): string;
begin
  Result := FHeaders.Values[Name];
end;

{ Checks the HTTP Basic password of a source (the user name is ignored,
  Traktor sends "source"). Always true when no password is configured. }
function TConn.Authorized: Boolean;
var
  A: string;
  P: Integer;
begin
  if SourcePassword = '' then Exit(True);
  A := Header('authorization');
  if not SameText(Copy(A, 1, 6), 'Basic ') then Exit(False);
  A := DecodeStringBase64(Trim(Copy(A, 7, MaxInt)));
  P := Pos(':', A);
  Result := (P > 0) and (Copy(A, P + 1, MaxInt) = SourcePassword);
end;

procedure TConn.Execute;
begin
  try
    try
      SetRecvTimeout(FSock, HEADER_TIMEOUT);  // against slow / idle connections
      if ReadRequest then
        if FIsSource then HandleSource else HandleHttp;
    except
      on E: Exception do Log('Error (' + FPeer + '): ' + E.Message);
    end;
  finally
    CloseSocket(FSock);
  end;
end;

procedure TConn.SendResponse(const Status, ContentType: string; const Body: RawByteString;
  const Extra: string);
var
  H: string;
begin
  H := 'HTTP/1.1 ' + Status + CRLF +
       'Server: trkStreamDesc/' + APP_VERSION + CRLF +
       'Content-Type: ' + ContentType + CRLF +
       'Content-Length: ' + IntToStr(Length(Body)) + CRLF +
       'Cache-Control: no-cache' + CRLF +
       'Access-Control-Allow-Origin: *' + CRLF +
       'X-Content-Type-Options: nosniff' + CRLF +
       Extra +
       'Connection: close' + CRLF + CRLF;
  if FMethod = 'HEAD' then SendAll(FSock, H) else SendAll(FSock, H + Body);
end;

procedure TConn.HandleHttp;
var
  Key: string;
begin
  Key := Header('sec-websocket-key');
  if (Pos('websocket', LowerCase(Header('upgrade'))) > 0) and (Key <> '') then
    HandleWebSocket(Key)
  else
    ServeFile;
end;

{ Content type by extension; '' for types that are never served. }
function MimeType(const Ext: string): string;
var
  E: string;
begin
  E := LowerCase(Ext);
  if (E = '.html') or (E = '.htm') then Result := 'text/html; charset=utf-8'
  else if E = '.js' then Result := 'application/javascript; charset=utf-8'
  else if E = '.css' then Result := 'text/css; charset=utf-8'
  else if E = '.json' then Result := 'application/json; charset=utf-8'
  else if E = '.png' then Result := 'image/png'
  else if (E = '.jpg') or (E = '.jpeg') then Result := 'image/jpeg'
  else if E = '.gif' then Result := 'image/gif'
  else if E = '.svg' then Result := 'image/svg+xml'
  else if E = '.webp' then Result := 'image/webp'
  else if E = '.ico' then Result := 'image/x-icon'
  else if E = '.woff2' then Result := 'font/woff2'
  else if E = '.ttf' then Result := 'font/ttf'
  else Result := '';
end;

{ Generated page listing the available overlays and API endpoints. }
function IndexPage: string;
var
  SR: TSearchRec;
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    if Pages.Count > 0 then
      L.Assign(Pages)
    else if FindFirst(BaseDir + '*.html', faAnyFile, SR) = 0 then
    begin
      repeat
        L.Add(SR.Name);
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    L.Sort;
    Result := '<!doctype html><html><head><meta charset="utf-8"><title>trkStreamDesc</title>' +
      '<style>body{font-family:system-ui,sans-serif;background:#111;color:#eee;padding:40px}' +
      'a{color:#7cf;font-size:20px;line-height:2}code{color:#fc7}</style></head><body>' +
      '<h1>trkStreamDesc</h1><p>WebSocket: <code>ws://&lt;host&gt;/ws</code> &middot; ' +
      '<a href="/api/now">/api/now</a> &middot; <a href="/api/history">/api/history</a> &middot; ' +
      '<a href="/api/status">/api/status</a></p><ul>';
    for I := 0 to L.Count - 1 do
      Result += '<li><a href="/' + HtmlEsc(L[I]) + '">' + HtmlEsc(L[I]) + '</a></li>';
    Result += '</ul></body></html>';
  finally
    L.Free;
  end;
end;

{ Serves the API endpoints and static files from the program folder. }
procedure TConn.ServeFile;
var
  Path, Fn, Full, Mime: string;
  P, I: Integer;
  FS: TFileStream;
  Body: RawByteString;
begin
  if (FMethod <> 'GET') and (FMethod <> 'HEAD') then
  begin
    SendResponse('405 Method Not Allowed', 'text/plain', 'Method Not Allowed');
    Exit;
  end;
  Path := FTarget;
  P := Pos('?', Path);
  if P > 0 then Path := Copy(Path, 1, P - 1);
  Path := UrlDecode(Path);

  if Path = '/api/now' then begin SendResponse('200 OK', MimeType('.json'), NowJson('now')); Exit; end;
  if Path = '/api/history' then begin SendResponse('200 OK', MimeType('.json'), HistoryJson(0)); Exit; end;
  if Path = '/api/status' then begin SendResponse('200 OK', MimeType('.json'), StatusJson); Exit; end;

  if (Path = '/') or (Path = '') then
  begin
    if Pages.Count = 0 then Path := '/index' else Path := '/' + Pages[0];
  end;
  if Path = '/index' then begin SendResponse('200 OK', MimeType('.html'), IndexPage); Exit; end;

  // path safety: relative to BaseDir, no traversal, no drive / stream names,
  // no control characters (a decoded %00 etc.)
  Fn := Copy(Path, 2, MaxInt);
  for I := 1 to Length(Fn) do
    if Fn[I] < ' ' then Fn := '';
  if (Fn = '') or (Pos('..', Fn) > 0) or (Pos(':', Fn) > 0) or (Fn[1] in ['/', '\']) then
  begin
    SendResponse('400 Bad Request', 'text/plain', 'Bad Request');
    Exit;
  end;
  // only known web file types are served (never the exe, sources etc.), and
  // when pages were given on the command line, only those html files
  Mime := MimeType(ExtractFileExt(Fn));
  Full := BaseDir + StringReplace(Fn, '/', PathDelim, [rfReplaceAll]);
  if (Mime = '') or not FileExists(Full) or
     ((Pages.Count > 0) and SameText(ExtractFileExt(Fn), '.html') and (Pages.IndexOf(Fn) < 0)) then
  begin
    SendResponse('404 Not Found', 'text/plain', 'Not Found');
    Exit;
  end;
  FS := TFileStream.Create(Full, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Body, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Body[1], FS.Size);
  finally
    FS.Free;
  end;
  SendResponse('200 OK', Mime, Body);
end;

{ Reads one WebSocket frame from FBuf (receiving more as needed) and unmasks it. }
function TConn.ReadFrame(out Op: Byte; out Payload: RawByteString; out Fin: Boolean): Boolean;
var
  B1: Byte;
  Len: Int64;
  Off, I: Integer;
  Masked: Boolean;
  Mask: array[0..3] of Byte;

  function Need(N: Int64): Boolean;
  begin
    while Length(FBuf) < N do
      if not RecvMore then Exit(False);
    Result := True;
  end;

begin
  Result := False;
  Payload := '';
  Op := 0;
  Fin := True;
  if not Need(2) then Exit;
  Fin := (Ord(FBuf[1]) and $80) <> 0;
  Op := Ord(FBuf[1]) and $0F;
  B1 := Ord(FBuf[2]);
  Masked := (B1 and $80) <> 0;
  Len := B1 and $7F;
  Off := 2;
  if Len = 126 then
  begin
    if not Need(4) then Exit;
    Len := (Ord(FBuf[3]) shl 8) or Ord(FBuf[4]);
    Off := 4;
  end
  else if Len = 127 then
  begin
    if not Need(10) then Exit;
    Len := 0;
    for I := 3 to 10 do Len := (Len shl 8) or Ord(FBuf[I]);
    Off := 10;
  end;
  // the size limit is checked before buffering, so a client cannot make us
  // allocate more than MAX_WS_PAYLOAD per frame
  if (Len < 0) or (Len > MAX_WS_PAYLOAD) then Exit;
  if Masked then
  begin
    if not Need(Off + 4) then Exit;
    for I := 0 to 3 do Mask[I] := Ord(FBuf[Off + 1 + I]);
    Inc(Off, 4);
  end;
  if not Need(Off + Len) then Exit;
  Payload := Copy(FBuf, Off + 1, Len);
  Delete(FBuf, 1, Off + Len);
  if Masked then
    for I := 1 to Len do
      Payload[I] := Chr(Ord(Payload[I]) xor Mask[(I - 1) and 3]);
  Result := True;
end;

// Answers one client request. Accepts JSON ({"cmd":"history","limit":5,"id":1})
// or a bare command word ("status"). The optional id is echoed back.
function HandleWsRequest(const Msg: string): string;
var
  Cmd, Id: string;
begin
  Cmd := LowerCase(JsonGet(Msg, 'cmd'));
  if Cmd = '' then Cmd := LowerCase(Trim(Msg));
  Id := JsonGet(Msg, 'id');
  if (Cmd = 'get') or (Cmd = 'now') then Result := NowJson('now')
  else if Cmd = 'history' then Result := HistoryJson(StrToIntDef(JsonGet(Msg, 'limit'), 0))
  else if Cmd = 'status' then Result := StatusJson
  else if Cmd = 'ping' then Result := '{"type":"pong","serverTime":' + IntToStr(NowMs) + '}'
  else Result := '{"type":"error","error":' + JS('unknown command: ' + Copy(Cmd, 1, 64)) + '}';
  if Id <> '' then
    Result := Copy(Result, 1, Length(Result) - 1) + ',"id":' + JS(Copy(Id, 1, 64)) + '}';
end;

{ Completes the handshake, registers the client and serves its requests
  until it disconnects. }
procedure TConn.HandleWebSocket(const Key: string);
var
  D: TSHA1Digest;
  Raw, Msg, Pl: RawByteString;
  C: TWSClient;
  Op: Byte;
  Fin: Boolean;
begin
  // Sec-WebSocket-Accept = base64(sha1(key + GUID))
  D := SHA1String(Key + WS_GUID);
  SetLength(Raw, SizeOf(D));
  Move(D, Raw[1], SizeOf(D));
  if not SendAll(FSock, 'HTTP/1.1 101 Switching Protocols' + CRLF +
    'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Accept: ' + EncodeStringBase64(Raw) + CRLF + CRLF) then Exit;
  SetRecvTimeout(FSock, 0);  // overlays may stay silent for hours

  C := TWSClient.Create(FSock);
  EnterCriticalSection(ClientsLock);
  try
    Clients.Add(C);
  finally
    LeaveCriticalSection(ClientsLock);
  end;
  Log('WS client connected: ' + FPeer + ' (' + IntToStr(ClientCount) + ' clients)');
  try
    C.SendText(NowJson('hello'));
    Msg := '';
    while ReadFrame(Op, Pl, Fin) do
    begin
      case Op of
        0, 1, 2:  // continuation / text / binary: collect fragments
          begin
            if Op <> 0 then Msg := Pl else Msg += Pl;
            if Length(Msg) > MAX_WS_PAYLOAD then Break;
            if Fin then
            begin
              if not C.SendText(HandleWsRequest(Msg)) then Break;
              Msg := '';
            end;
          end;
        8:  // close: echo the status code and stop
          begin
            C.SendFrame(8, Copy(Pl, 1, 2));
            Break;
          end;
        9: C.SendFrame(10, Pl);  // ping -> pong
      end;
    end;
  finally
    // after removal no broadcast can reach C, so it is safe to free
    EnterCriticalSection(ClientsLock);
    try
      Clients.Remove(C);
    finally
      LeaveCriticalSection(ClientsLock);
    end;
    C.Free;
    Log('WS client disconnected: ' + FPeer);
  end;
end;

{ Handles a connection on the source port: a metadata update or a stream. }
procedure TConn.HandleSource;
var
  P: Integer;
  Query, Song, Info: string;
  T: TTrack;
  Parser: TOggParser;
  Total: Int64;
begin
  if not Authorized then
  begin
    SendResponse('401 Unauthorized', 'text/plain', 'Unauthorized',
      'WWW-Authenticate: Basic realm="Icecast2 Server"' + CRLF);
    Log('Rejected source (bad password): ' + FPeer);
    Exit;
  end;

  // shoutcast/Icecast style metadata update (MP3 streams)
  if (FMethod = 'GET') and (Pos('/admin/metadata', FTarget) = 1) then
  begin
    P := Pos('?', FTarget);
    if P > 0 then Query := Copy(FTarget, P + 1, MaxInt) else Query := '';
    T := Default(TTrack);
    Song := QueryParam(Query, 'song');
    T.Title := Song;
    T.Artist := QueryParam(Query, 'artist');
    if QueryParam(Query, 'title') <> '' then T.Title := QueryParam(Query, 'title');
    T.Tags := '{"song":' + JS(Song) + '}';
    SetTrack(T);
    SendResponse('200 OK', 'text/xml', '<?xml version="1.0"?>' + CRLF +
      '<iceresponse><message>Metadata update successful</message><return>1</return></iceresponse>');
    Exit;
  end;

  if (FMethod <> 'SOURCE') and (FMethod <> 'PUT') then
  begin
    SendResponse('404 Not Found', 'text/plain', 'trkStreamDesc: SOURCE/PUT streams only');
    Exit;
  end;

  // Icecast handshake: PUT clients may wait for "100 Continue"
  if LowerCase(Header('expect')) = '100-continue' then
    SendAll(FSock, 'HTTP/1.1 100 Continue' + CRLF + CRLF)
  else
    SendAll(FSock, 'HTTP/1.0 200 OK' + CRLF + 'Server: Icecast 2.4.4' + CRLF + CRLF);
  SetRecvTimeout(FSock, SOURCE_TIMEOUT);  // a live stream is never silent

  Info := Copy(FTarget + ' ' + Header('content-type') + ' ' + Header('ice-name'), 1, 200);
  Log('Traktor (source) connected: ' + FPeer + ' ' + Info);
  SourceChanged(1, Info);
  Parser := TOggParser.Create;
  Total := 0;
  try
    repeat
      if FBuf <> '' then
      begin
        Inc(Total, Length(FBuf));
        Parser.Feed(FBuf);
        FBuf := '';
      end;
    until not RecvMore;
  finally
    Parser.Free;
    SourceChanged(-1, '');
    Log('Traktor (source) disconnected: ' + FPeer + ' (' + IntToStr(Total div 1024) + ' KiB)');
  end;
end;

{ ------------------------------------------------------------------- main }

procedure Usage;
begin
  WriteLn('trkStreamDesc ', APP_VERSION, ' - Traktor broadcast -> WebSocket "now playing" proxy');
  WriteLn;
  WriteLn('Not affiliated with Native Instruments; works with Traktor''s broadcast output.');
  WriteLn;
  WriteLn('Usage: trkstream [options] [page1.html page2.html ...]');
  WriteLn('  -p, --http <port>        HTTP/WebSocket port (default: 80)');
  WriteLn('  -s, --source <port>      Traktor broadcast (Icecast) port (default: 8000)');
  WriteLn('  -k, --password <pass>    broadcast password set in Traktor (default: none)');
  WriteLn('      --source-any         accept the source from other hosts too');
  WriteLn('                           (default: localhost only)');
  WriteLn('  -h, --help               this help');
  WriteLn;
  WriteLn('The first page given is served at "/". Without pages every .html in the');
  WriteLn('program folder is served and "/" shows a list.');
  WriteLn;
  WriteLn('Console: t <artist> - <title> (test track), s (status), n (now), q (quit)');
end;

{ True when -h / --help / /? is on the command line. A separate function, so
  its temporary strings are released before the caller halts. }
function WantsHelp: Boolean;
var
  I: Integer;
  A: string;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if (A = '-h') or (A = '--help') or (A = '/?') then Exit(True);
  end;
  Result := False;
end;

procedure ParseArgs;
var
  I: Integer;
  A, Fn: string;
begin
  I := 1;
  while I <= ParamCount do
  begin
    A := ParamStr(I);
    if (A = '-p') or (A = '--http') then
    begin
      Inc(I);
      HttpPort := StrToIntDef(ParamStr(I), HttpPort);
    end
    else if (A = '-s') or (A = '--source') then
    begin
      Inc(I);
      SourcePort := StrToIntDef(ParamStr(I), SourcePort);
    end
    else if (A = '-k') or (A = '--password') then
    begin
      Inc(I);
      SourcePassword := ParamStr(I);
    end
    else if A = '--source-any' then
      SourceAnyHost := True
    else
    begin
      Fn := ExtractFileName(A);  // pages always come from the program folder
      if not FileExists(BaseDir + Fn) then
        WriteLn('Warning: ', Fn, ' not found in the program folder (', BaseDir, ')');
      Pages.Add(Fn);
    end;
    Inc(I);
  end;
end;

{ Reads one line of user input as UTF-8; False at end of input. On a Windows
  console ReadLn would deliver accented letters in the OEM/ANSI code page, so
  the UTF-16 console API is used there. Redirected input is taken as is. }
function ReadInputLine(out Line: string): Boolean;
{$ifdef windows}
var
  H: THandle;
  Mode, N: DWORD;
  Buf: array[0..511] of WideChar;
  W, Chunk: UnicodeString;
begin
  Line := '';
  H := GetStdHandle(STD_INPUT_HANDLE);
  if not GetConsoleMode(H, Mode) then
  begin
    // not a console (pipe / file)
    if Eof(Input) then Exit(False);
    ReadLn(Line);
    Line := ToUtf8(Line);
    Exit(True);
  end;
  W := '';
  repeat
    if not ReadConsoleW(H, @Buf[0], Length(Buf), @N, nil) or (N = 0) then Exit(False);
    SetString(Chunk, PWideChar(@Buf[0]), N);
    W += Chunk;
  until Buf[N - 1] = #10;
  Line := UTF8Encode(TrimRight(W));
  Result := True;
end;
{$else}
begin
  Line := '';
  if Eof(Input) then Exit(False);
  ReadLn(Line);
  Line := ToUtf8(Line);
  Result := True;
end;
{$endif}

{ Interactive console; returns when the user quits. }
procedure CommandLoop;
var
  Line: string;
  T: TTrack;
begin
  while True do
  begin
    if not ReadInputLine(Line) then
      while True do Sleep(1000);  // no console input (e.g. started detached)
    Line := Trim(Line);
    if Line = '' then Continue;
    case LowerCase(Line[1]) of
      'q': Exit;
      't':
        begin
          T := Default(TTrack);
          T.Title := Trim(Copy(Line, 2, MaxInt));
          T.Tags := '{"test":"1"}';
          SetTrack(T);
        end;
      's': Log(StatusJson);
      'n': Log(NowJson('now'));
    else
      WriteLn('Commands: t <artist> - <title> | s | n | q');
    end;
  end;
end;

var
  HttpSock, SrcSock: TSocket;

begin
  // help first, before anything is allocated (keeps heaptrc quiet)
  if WantsHelp then
  begin
    Usage;
    Halt(0);
  end;

  // all strings of the program hold UTF-8; this also stops the RTL from
  // converting UTF8Encode results back to the ANSI code page
  DefaultSystemCodePage := CP_UTF8;
  {$ifdef windows}
  SetConsoleOutputCP(CP_UTF8);
  {$endif}
  InitCriticalSection(LogLock);
  InitCriticalSection(StateLock);
  InitCriticalSection(ClientsLock);
  Clients := TList.Create;
  Pages := TStringList.Create;
  Pages.CaseSensitive := False;
  StartMs := NowMs;
  BaseDir := IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))));

  ParseArgs;

  SrcSock := OpenListener(SourcePort, not SourceAnyHost);
  if not SockOk(SrcSock) then
  begin
    WriteLn('Cannot open port ', SourcePort, ' (in use?)');
    Halt(1);
  end;
  HttpSock := OpenListener(HttpPort, False);
  if not SockOk(HttpSock) then
  begin
    WriteLn('Cannot open port ', HttpPort, ' (in use? try -p 8080)');
    Halt(1);
  end;

  WriteLn('trkStreamDesc ', APP_VERSION);
  WriteLn('  Traktor broadcast -> localhost:', SourcePort, '  (Icecast, Ogg Vorbis)');
  WriteLn('  Overlay / WebSocket -> http://localhost:', HttpPort, '/   ws://localhost:', HttpPort, '/ws');
  if Pages.Count > 0 then WriteLn('  Default page: ', Pages[0]);
  WriteLn('  Commands: t <artist> - <title> | s | n | q');
  WriteLn;

  TListener.Create(SrcSock, True);
  TListener.Create(HttpSock, False);

  CommandLoop;

  // Connection threads may still be running, so the shared objects are not
  // freed here; the process exit releases them.
  CloseSocket(HttpSock);
  CloseSocket(SrcSock);
  Log('Bye.');
  Halt(0);
end.
