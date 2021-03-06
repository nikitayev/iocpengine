// The contents of this file are used with permission, subject to
// the Mozilla Public License Version 1.1 (the "License"); you may
// not use this file except in compliance with the License. You may
// obtain a copy of the License at
// http://www.mozilla.org/MPL/MPL-1.1.html
//
// Software distributed under the License is distributed on an
// "AS IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
// implied. See the License for the specific language governing
// rights and limitations under the License.

{$I DnConfig.inc}
unit DnTcpListener;

interface
uses  JwaWinsock2, Classes, SysUtils, Windows,
      SyncObjs, DnConst, DnRtl,
      DnAbstractExecutor, DnAbstractLogger,
      DnTcpReactor, DnTcpChannel, DnTcpRequest;

type
  TDnClientTcpConnect = procedure (Context: TDnThreadContext; Channel: TDnTcpChannel) of object;
  TDnCreateTcpChannel = procedure (Context: TDnThreadContext; Socket: TSocket; Addr: TSockAddrIn;
      Reactor: TDnTcpReactor; var ChannelImpl: TDnTcpChannel) of object;
  TDnTcpListener = class;

  TDnTcpAcceptRequest = class(TDnTcpRequest)
  protected
    FListener:          TDnTcpListener;
    FAcceptSocket:      JwaWinsock2.TSocket;
    FAcceptBuffer:      String;
    FAcceptReceived:    Cardinal;
    FLocalAddr,
    FRemoteAddr:        JwaWinsock2.TSockAddrIn;
    FTransferred:       Cardinal;
    
  public
    constructor Create(Listener: TDnTcpListener);
    destructor Destroy; override;

    procedure Execute; override;
    function  IsComplete: Boolean; override;
    procedure ReExecute; override;
    function  RequestType: TDnIORequestType; override;

    procedure CallHandler(Context: TDnThreadContext); override;

    procedure SetTransferred(Transferred: Cardinal); override;

  end;

  TDnTcpListener = class(TComponent)
  protected
    FActive:                Boolean;
    FNagle:                 Boolean;
    FSocket:                TSocket;
    FAddress:               AnsiString;
    FAddr:                  TSockAddrIn;
    FPort:                  Word;
    FBackLog:               Integer;
    FReactor:               TDnTcpReactor;
    FExecutor:              TDnAbstractExecutor;
    FLogger:                TDnAbstractLogger;
    FLogLevel:              TDnLogLevel;
    FKeepAlive:             Boolean;
    FOnClientConnect:       TDnClientTcpConnect;
    FOnCreateChannel:       TDnCreateTcpChannel;
    FGuard:                 TDnMutex;
    FRequest:               TDnTcpAcceptRequest;
    FRequestActive:         TDnSemaphore;
    FTurningOffSignal:      THandle;
    
    procedure SetAddress(Address: AnsiString);
    procedure SetActive(Value: Boolean);
    function  TurnOn: Boolean;
    function  TurnOff: Boolean;
    procedure CheckSocketError(Code: Cardinal; Msg: String);
    function  DoCreateChannel(Context: TDnThreadContext; Socket: TSocket;
                              Addr: TSockAddrIn): TDnTcpChannel;
    procedure DoClientConnect(Context: TDnThreadContext; Channel: TDnTcpChannel);
    procedure DoLogMessage(S: String);
    procedure QueueRequest;
    procedure RequestFinished;

    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    //This method can be called after Active := False to ensure all IOCP activities are stopped for this listener object
    procedure WaitForShutdown(TimeoutInMilliseconds: Cardinal = INFINITE);

    //This method can be called after Active := False to poll if the listener is shutdowned
    //It should NOT be mixed with WaitForShutdown - both of them resets the Win32 event
    function  IsShutdowned: Boolean;

    procedure Lock;
    procedure Unlock;

  published
    property Active: Boolean read FActive write SetActive;
    property Port: Word read FPort write FPort;
    property Address: AnsiString read FAddress write SetAddress;

    property UseNagle: Boolean read FNagle write FNagle;
    property BackLog: Integer read FBackLog write FBackLog;
    property Reactor: TDnTcpReactor read FReactor write FReactor;
    property Executor: TDnAbstractExecutor read FExecutor write FExecutor;
    property Logger: TDnAbstractLogger read FLogger write FLogger;
    property LogLevel: TDnLogLevel read FLogLevel write FLogLevel;
    property KeepAlive: Boolean read FKeepAlive write FKeepAlive;
    property OnCreateChannel: TDnCreateTcpChannel read FOnCreateChannel write FOnCreateChannel;
    property OnIncoming: TDnClientTcpConnect read FOnClientConnect write FOnClientConnect;
  end;

procedure Register;

function AcceptEx(sListenSocket, sAcceptSocket: TSocket; lpOutputBuffer: Pointer; dwReceiveDataLength, dwLocalAddressLength, dwRemoteAddressLength: DWORD; var lpdwBytesReceived: DWORD;  lpOverlapped: POverlapped): BOOL; stdcall;
procedure GetAcceptExSockaddrs(lpOutputBuffer: Pointer; dwReceiveDataLength, dwLocalAddressLength, dwRemoteAddressLength: DWORD;  var LocalSockaddr: PSockAddr; var LocalSockaddrLength: Integer;  var RemoteSockaddr: PSockAddr; var RemoteSockaddrLength: Integer); stdcall;

implementation

function  AcceptEx;               external 'mswsock.dll' name 'AcceptEx';
procedure GetAcceptExSockaddrs;   external 'mswsock.dll' name 'GetAcceptExSockaddrs';

//------------------ TDnTcpAcceptRequest-------------------------

constructor TDnTcpAcceptRequest.Create(Listener: TDnTcpListener);
begin
  inherited Create(Nil, Nil);

  //allocate buffer for remote address
  SetLength(FAcceptBuffer, 64);

  FListener := Listener;
end;

destructor TDnTcpAcceptRequest.Destroy;
begin
  inherited Destroy;
end;

procedure TDnTcpAcceptRequest.Execute;
begin
  inherited Execute;
  
  //create socket for future channel
  FAcceptSocket := JwaWinsock2.WSASocketA(AF_INET, SOCK_STREAM, 0, Nil, 0, WSA_FLAG_OVERLAPPED);
  if FAcceptSocket = INVALID_SOCKET then
    raise EDnWindowsException.Create(WSAGetLastError());

  //run acceptex query
  if AcceptEx(FListener.FSocket, FAcceptSocket, @FAcceptBuffer[1], 0, sizeof(TSockAddrIn)+16,
              sizeof(TSockAddrIn)+16, FAcceptReceived, POverlapped(@Self.FContext)) = FALSE then
  begin
    if WSAGetLastError() <> ERROR_IO_PENDING then
      raise EDnWindowsException.Create(WSAGetLastError());
  end;
end;

const
 MY_SO_UPDATE_ACCEPT_CONTEXT = $700B;
procedure TDnTcpAcceptRequest.CallHandler(Context: TDnThreadContext);
var Channel: TDnTcpChannel;
    ResCode, LocalAddrLen, RemoteAddrLen: Integer;
    LocalAddrP, RemoteAddrP: PSockAddr;
begin
  FListener.Lock;
  try
    //extract remote address
    //OutputDebugString('Firing AcceptEx event');
    if FErrorCode = 0 then
    begin
      LocalAddrLen := Sizeof(TSockAddrIn); RemoteAddrLen := Sizeof(TSockAddrIn);

      // UPDATE_ACCEPT_CONTEXT
      ResCode := JwaWinsock2.setsockopt(FAcceptSocket, SOL_SOCKET, MY_SO_UPDATE_ACCEPT_CONTEXT, PAnsiChar(@FListener.FSocket), sizeof(FListener.FSocket));
      if ResCode <> 0 then
        FListener.FLogger.LogMsg(llMandatory, Format('setSockOpt with SO_UPDATE_ACCEPT_CONTEXT is failed. Error code is %d.', [JwaWinsock2.WSAGetLastError()]));

      // Extract addresses
      GetAcceptExSockaddrs(@FAcceptBuffer[1], 0, sizeof(TSockAddrIn)+16,
          sizeof(TSockAddrIn)+16, LocalAddrP, LocalAddrLen,
          RemoteAddrP, RemoteAddrLen); //}//there was a good idea but it is not working so just KISS :)


      FLocalAddr := PSockAddrIn(LocalAddrP)^;
      FRemoteAddr := PSockAddrIn(RemoteAddrP)^;

      Channel := FListener.DoCreateChannel(Context, FAcceptSocket, FRemoteAddr);

      // Post channel to reactor
      FListener.FReactor.PostChannel(Channel);

      // Fire event for new connection
      FListener.DoClientConnect(Context, Channel);
    end
    else
      if Assigned(FListener.FLogger) then
        FListener.FLogger.LogMsg(llCritical, 'Failed to AcceptEx. Error code is ' + IntToStr(FErrorCode));

    FListener.RequestFinished;

    // Re-execute the request if it is possible
    if not FListener.FActive then
    begin
      // We are in shutdown process
      Windows.SetEvent(FListener.FTurningOffSignal);

      // Exit from procedure
      Exit;
    end;

    FTransferred := 0;
    FErrorCode := 0;
    FAcceptSocket := INVALID_SOCKET;

    FListener.QueueRequest;
  finally
    FListener.Unlock;
  end;
end;


function  TDnTcpAcceptRequest.IsComplete: Boolean;
begin
  Result := True;
end;

procedure TDnTcpAcceptRequest.ReExecute;
begin
  Execute;
end;

function  TDnTcpAcceptRequest.RequestType: TDnIORequestType;
begin
  Result := rtAccept;
end;

procedure TDnTcpAcceptRequest.SetTransferred(Transferred: Cardinal);
begin
  FAcceptReceived := 0;
end;


constructor TDnTcpListener.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Self._AddRef;
  FActive := False;
  FPort := 7080;
  FAddress := '0.0.0.0';
  FOnCreateChannel := Nil;
  FOnClientConnect := Nil;
  FKeepAlive := False;
  FNagle := True;
  FSocket := INVALID_SOCKET;
  FBackLog := 5;
  FLogger := Nil;
  FLogLevel := llMandatory;
  FReactor := Nil;
  FExecutor := Nil;
  FGuard := TDnMutex.Create;
  FRequestActive := TDnSemaphore.Create(1, 1);
end;

destructor TDnTcpListener.Destroy;
begin
  if Active then
    Active := False;

  FreeAndNil(FRequest);
  FreeAndNil(FRequestActive);
  FreeAndNil(FGuard);

  inherited Destroy;
end;

procedure TDnTcpListener.WaitForShutdown(TimeoutInMilliseconds: Cardinal);
begin
  Windows.WaitForSingleObject(FTurningOffSignal, TimeoutInMilliseconds);
end;

function  TDnTcpListener.IsShutdowned: Boolean;
begin
  Result := Windows.WaitForSingleObject(FTurningOffSignal, 0) = WAIT_OBJECT_0;
end;

procedure TDnTcpListener.Notification(AComponent: TComponent; Operation: TOperation);
begin
  if Operation = opRemove then
  begin
    if AComponent = FExecutor then
      FExecutor := Nil
    else
    if AComponent = FLogger then
      FLogger := Nil
    else
    if AComponent = FReactor then
      FReactor := Nil;
  end;
end;

procedure TDnTcpListener.DoLogMessage(S: String);
begin
  if FLogger<>Nil then
  try
    FLogger.LogMsg(FLogLevel, S);
  except
    ;
  end;
end;

procedure TDnTcpListener.CheckSocketError(Code: Cardinal; Msg: String);
begin
  if (FLogger <> Nil) and (Code = INVALID_SOCKET) then
  try
    FLogger.LogMsg(FLogLevel, Msg);
  except
    ; // Suppress exception
  end
end;

procedure TDnTcpListener.SetActive(Value: Boolean);
begin
  Lock;
  try
    if not FActive and Value then
      FActive := TurnOn
    else if FActive and not Value then
      FActive := TurnOff;
  finally
    Unlock;
  end;
end;

function TDnTcpListener.TurnOn: Boolean;
var TempBool: LongBool;
begin
  FTurningOffSignal := Windows.CreateEvent(Nil, True, False, Nil);
  FActive := True;

  // Create listening socket
  FSocket := JwaWinsock2.WSASocket(AF_INET, SOCK_STREAM, 0, Nil, 0, WSA_FLAG_OVERLAPPED);
  if FSocket = INVALID_SOCKET then
    raise EDnWindowsException.Create(WSAGetLastError());
  FillChar(FAddr, SizeOf(FAddr), 0);
  FAddr.sin_family := AF_INET;
  FAddr.sin_port := JwaWinsock2.htons(FPort);
  FAddr.sin_addr.S_addr := inet_addr(PAnsiChar(FAddress));

  // Associate with completion port
  CreateIOCompletionPort(FSocket, FReactor.PortHandle, 0, 1);

  // Set SO_REUSEADDR
  TempBool := True;
  SetSockOpt(FSocket, SOL_SOCKET, SO_REUSEADDR, PAnsiChar(@TempBool), SizeOf(TempBool));

  // Bind socket
  if JwaWinsock2.Bind(TSocket(FSocket), @FAddr, sizeof(FAddr)) = -1 then
    raise EDnWindowsException.Create(WSAGetLastError());

  if JwaWinsock2.Listen(FSocket, FBackLog) = -1 then
    raise EDnWindowsException.Create(WSAGetLastError());

  // Queue AcceptEx request
  QueueRequest;

  Result := True;
end;

procedure TDnTcpListener.QueueRequest;
begin
  //OutputDebugString('Running the next AcceptEx request.');
  FRequestActive.Wait;

  if FRequest = Nil then
    FRequest := TDnTcpAcceptRequest.Create(Self);

  FRequest.Execute;
end;

procedure TDnTcpListener.Lock;
begin
  FGuard.Acquire;
end;

procedure TDnTcpListener.Unlock;
begin
  if assigned(FGuard) then
    FGuard.Release
  else
   FLogger.LogMsg(llMandatory,'FGuard is nil');
end;

procedure TDnTcpListener.RequestFinished;
begin
  FRequestActive.Release;
end;

function  TDnTcpListener.DoCreateChannel(Context: TDnThreadContext; Socket: TSocket; Addr: TSockAddrIn): TDnTcpChannel;
var SockObj: TDnTcpChannel;
begin
  SockObj := Nil;
  try
    if Assigned(FOnCreateChannel) then
      FOnCreateChannel(Context, Socket, Addr, FReactor, SockObj);
  except
    on E: Exception do
          begin
            DoLogMessage(E.Message);
            SockObj := Nil;
          end;
  end;
  if not Assigned(SockObj) then
    SockObj := TDnTcpChannel.Create(FReactor, Socket, Addr);

  Result := SockObj;
end;

procedure TDnTcpListener.DoClientConnect(Context: TDnThreadContext; Channel: TDnTcpChannel);
begin
  if Assigned(FOnClientConnect) then
  try
    FOnClientConnect(Context, Channel);
  except
    on E: Exception do
      DoLogMessage(E.Message);
  end;
end;

function TDnTcpListener.TurnOff: Boolean;
var Sock: TSocket;
begin
  FActive := False;
  if FSocket <> INVALID_SOCKET then
  begin
    Sock := FSocket; FSocket := INVALID_SOCKET;
    JwaWinsock2.Shutdown(Sock, SD_BOTH); //yes, I known that SD_BOTH is bad idea... But this is LISTENING socket :)
    JwaWinsock2.CloseSocket(Sock);
  end;
  // Wait while acceptex query will finish
  Unlock();
  Windows.WaitForSingleObject(FTurningOffSignal, INFINITE);
  Lock();
  Windows.CloseHandle(FTurningOffSignal);
  FTurningOffSignal := 0;

  Result := False;
end;

procedure TDnTcpListener.SetAddress(Address: AnsiString);
var addr: Cardinal;
begin
  addr := inet_addr(PAnsiChar(Address));
  if addr <> INADDR_NONE then
  begin
    FAddress := Address;
  end;
end;

//------------------------------------------------------------------------------

procedure Register;
begin
  RegisterComponents('DNet', [TDnTcpListener]);
end;

end.
