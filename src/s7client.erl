%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2019
%%% @doc
%%% rewrite of modbus_device as a gen_statem process with configurable reconnecting
%%% @end
%%% Created : 06. Jul 2019 10:28
%%%-------------------------------------------------------------------
-module(s7client).

-author("Alexander Minichmair").

-behaviour(gen_statem).


-include("s7erl.hrl").
%% API
-export([start_link/0, start_link/1, start/1, stop/1]).

%% gen_statem callbacks
-export([
  init/1,
%%   format_status/2,
  terminate/3,
  code_change/4,
  callback_mode/0]).

%% state.functions
-export([
  connecting/3,
  disconnected/3,
  connected/3,
  connected_iso/3,
  ready/3 %% ready to receive read requests
]).

-define(SERVER, ?MODULE).

-define(TCP_OPTS, [
  {mode, binary},
  {active,false},
  {packet, tpkt}, %% RFC1006
  {send_timeout, 500},
%%   {reuseaddr, true},
  {nodelay, true},
  {delay_send, false}
]).

-define(START_TIMEOUT, 5000).
-define(RECV_TIMEOUT, 10000).

-record(state, {
  port = 102            :: non_neg_integer(),
  host = "localhost"    :: inet:ip_address() | string(),
  rack = 0              :: non_neg_integer(),
  slot = 1              :: non_neg_integer(),
  pdu_size = 240        :: non_neg_integer(),
  socket                :: inet:socket(),
  reconnector           :: modbus_s7backoff:reconnector(),
  recipient             :: pid(),
  buffer  = <<>>        :: binary(),
  ref_id = 1            :: 1..16#ffff,
  requests = []         :: list()
}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc start, no link
%%
%% @spec start(list()) -> {ok, Pid} | ignore | {error, Error}.
start(Opts) when is_list(Opts) ->
  gen_statem:start(?MODULE, [self(), Opts], [{timeout, ?START_TIMEOUT}]).

stop(Server) ->
  gen_statem:stop(Server).

%%--------------------------------------------------------------------
%% @doc
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
  gen_statem:start_link(?MODULE, [self(), []], []).
start_link(Opts) when is_list(Opts) ->
  gen_statem:start_link(?MODULE, [self(), Opts], [{timeout, ?START_TIMEOUT}]).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

init([Recipient, Opts]) ->
  logger:set_primary_config(level, info),
  Reconnector = s7backoff:new({500, 8000}),
  State = init_opt(Opts, #state{reconnector = Reconnector, recipient = Recipient}),
  {ok, connecting, State, [{state_timeout, 0, connect}]}.

init_opt([{host, Host}|R], State) ->
  init_opt(R, State#state{host = Host});
init_opt([{port, Port}|R], State) ->
  init_opt(R, State#state{port = Port});
init_opt([{rack, Rack} | R], State) ->
  init_opt(R, State#state{rack = Rack});
init_opt([{slot, Slot} | R], State) ->
  init_opt(R, State#state{slot = Slot});
init_opt([{min_interval, Min} | R], State) when is_integer(Min) ->
  init_opt(R, State#state{
    reconnector = s7backoff:set_min_interval(State#state.reconnector, Min)});
init_opt([{max_interval, Max} | R], State) when is_integer(Max) ->
  init_opt(R, State#state{
    reconnector = s7backoff:set_max_interval(State#state.reconnector, Max)});
init_opt([{max_retries, Retries} | R], State) when is_integer(Retries) orelse Retries =:= infinity ->
  init_opt(R, State#state{
    reconnector = s7backoff:set_max_retries(State#state.reconnector, Retries)});
init_opt(_, State) ->
  State.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_statem when it needs to find out
%% the callback mode of the callback module.
%%
%% @spec callback_mode() -> atom().
%% @end
%%--------------------------------------------------------------------
callback_mode() ->
  state_functions.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Called (1) whenever sys:get_status/1,2 is called by gen_statem or
%% (2) when gen_statem terminates abnormally.
%% This callback is optional.
%%
%% @spec format_status(Opt, [PDict, StateName, State]) -> term()
%% @end
%%--------------------------------------------------------------------
%%format_status(_Opt, [_PDict, _StateName, _State]) ->
%%   Status = some_term,
%%   Status.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% start state functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connecting(enter, _OldState, _Data) ->
  keep_state_and_data;
connecting(state_timeout, connect, State) ->
  lager:info("[~p] connecting ...~n",[?MODULE]),
  connect(State);
connecting(cast, stop, _State) ->
  {stop, normal}.

disconnected(enter, _OldState, _Data) ->
  keep_state_and_data;
disconnected(info, {reconnect, timeout}, State) ->
  connect(State);
disconnected({call, From}, _Whatever, _State) ->
  {keep_state_and_data, [{reply, From, {error, disconnected}}]};
disconnected(cast, stop, _State) ->
  {stop, normal};
disconnected(_, _, _State) ->
  keep_state_and_data.

%%%%%%%%%%%%%% connected

%%%%% recv tcp data
connected(state_timeout, connect_iso, State=#state{recipient = _Rec, socket = Socket}) ->
  inet:setopts(Socket, [{active, once}]),
  connect_iso(State),
  keep_state_and_data;
connected(info, {tcp, Socket, Data}, State=#state{recipient = _Rec}) ->
  inet:setopts(Socket, [{active, once}]),
  lager:notice("connected got tcp data: ~p",[Data]),
  case Data of
    <<3, 0, 22:16, 17, ?COTP_HEADER_PDU_TYPE_CONN_CONFIRM, _Rest/binary>> ->
      lager:alert("got connect confirm for iso connection with code: ~p",[208]),
      {next_state, connected_iso, State, [{state_timeout, 0, negotiate_pdu}]};
    _ ->
      lager:warning("waiting for connect confirm for iso, got other data"),
      try_reconnect(connect_iso_failed, State#state{socket = undefined})
  end;
connected(info, What, State) ->
  handle_common(info, What, State).

connected_iso(state_timeout, negotiate_pdu, State = #state{socket = Socket}) ->
  inet:setopts(Socket, [{active, once}]),
  negotiate_pdu(State),
  keep_state_and_data;
connected_iso(info, {tcp, Socket, Data}, State=#state{recipient = Rec}) ->
  inet:setopts(Socket, [{active, once}]),
  lager:notice("connected_iso got tcp data: ~p",[Data]),
  case handle_neg_pdu_response(Data) of
    {ok, NewPDUSize} ->
      lager:alert("got confirm for negotiate_pdu, pdu size now ~p, now ready for read requests",[NewPDUSize]),
      %% tell recipient we are connected
      Rec ! {s7, self(), {connected, NewPDUSize}},
      {next_state, ready, State#state{pdu_size = NewPDUSize}};
    {error, What} ->
      lager:warning("waiting for confirm for negotiate_pdu, got error: ~p",[What]),
      try_reconnect(negotiate_pdu_failed, State#state{socket = undefined})
  end;
connected_iso(info, What, State) ->
  handle_common(info, What, State).

%% ready to receive read requests
ready(info, {tcp, Socket, Data}, _State=#state{recipient = Rec}) ->
  inet:setopts(Socket, [{active, once}]),
  lager:notice("ready got tcp data: ~p",[Data]),
  case handle_read_response(Data) of
    {ok, ResultList} -> Rec ! {s7_data, ResultList};
    {error, What} -> Rec ! {s7_read_error, What}
  end,
  keep_state_and_data;
%%%%%%%%%%%% read %%%%%%%%%%%%%
ready({call, From}, {read, VarList}, State) ->
  NewState =  next_refid(State),
  Res = read_multiple(VarList, NewState),
  lager:info("result from sending: ~p",[Res]),
  {keep_state, NewState, [{reply, From, ok}]};
ready(info, What, State) ->
  handle_common(info, What, State).



%% common handlers, different states
handle_common(info, {tcp_closed, _Socket}, State = #state{recipient = Rec}) ->
  lager:warning("got tcp closed, when connected"),
  Rec ! {s7, self(), disconnected},
  try_reconnect(tcp_closed, State);
handle_common(info, {tcp_error, _Socket}, #state{recipient = Rec}) ->
  lager:warning("got tcp error, when connected"),
  Rec ! {s7, self(), tcp_error},
  keep_state_and_data;
handle_common(info, stop, _State) ->
  {stop, normal}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% end state functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

terminate(_Reason, _StateName, #state{socket = Sock, reconnector = Recon}) ->
  lager:notice("~p terminate", [?MODULE]),
  s7backoff:reset(Recon),
  %% @todo maybe send cotp disconnect request here
  catch gen_tcp:close(Sock).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, StateName, State, Extra) ->
%%                   {ok, StateName, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
handle_buffer(<<>>, State = #state{buffer = <<>>}) ->
  {ok, State};
handle_buffer(Data, State = #state{buffer = StateBuffer}) ->
  Buffer = <<StateBuffer/binary, Data/binary>>,
  do_handle_buffer(Buffer, State).
do_handle_buffer(<<TransId:16, _:16, Length:16, Data1:Length/binary, Buf1/binary>> = Buffer, State) ->
  case Data1 of
    <<UnitID, Func, Len, Params:Len/binary>> ->
      State1 =
        handle_reply_pdu(TransId, UnitID, Func, Params, State#state{buffer = Buf1}),
      case State1 of
        {ok, NewState} ->
          handle_buffer(<<>>, NewState);
        Other ->
          lager:warning("[~p] State after buffer handler not ok",[Other]),
          Other
      end;
    _ ->
      lager:error("### ### data too short ~p~n", [Buffer]),
      {error, data_too_short, State#state{buffer = <<>>}}
  end;
do_handle_buffer(Buffer, State) ->
  lager:notice("### ### [~p]waiting for more data...~n",[?MODULE]),
  {ok, State#state{buffer = Buffer}}.

%% also do the COTP connect after tcp connect was successful
connect(State = #state{host = Host, port = Port}) ->
  case gen_tcp:connect(Host, Port, ?TCP_OPTS) of
    {ok, Socket} ->
      inet:setopts(Socket, [{active, once}]),
      {next_state, connected, State#state{socket = Socket}, [{state_timeout, 0, connect_iso}]};
    {error, Reason} ->
      lager:info("[Client: ~p] connect error to: ~p Reason: ~p~n" ,[self(), {Host, Port}, Reason]),
      try_reconnect(Reason, State)
  end.

connect_iso(_State = #state{socket = Sock, rack = Rack, slot = Slot}) ->
  DestinationRef = 16#00, %% ????????
  SourceRef = 16#00, %% ???????
  Class = 16#00, %% ????????
  ParameterLength_tpdusize = 16#01,
  ParameterLength_tsap = 16#02,

  RemoteTSAP = Rack * 32 + Slot,


  Msg = <<
    ?TPKT_HEADER/binary,

    ?COTP_CONNECT_LENGTH,
    ?COTP_HEADER_PDU_TYPE_CONN_REQ,
    DestinationRef:16,
    SourceRef:16,
    Class,
    %% P1
    %% pdu-size
    ?COTP_HEADER_PDU_PARAM_CODE_TPDUSIZE,
    %% pdu-size length
    ParameterLength_tpdusize, %% !!! mokka7 does not use this, why !
    ?COTP_HEADER_PDU_TPDUSIZE,
    %% P2
    ?COTP_HEADER_PDU_PARAM_CODE_SRC_TSAP,
    ParameterLength_tsap,
    1:8, ?LOCAL_TSAP:8,
    %% P3
    ?COTP_HEADER_PDU_PARAM_CODE_DEST_TSAP,
    ParameterLength_tsap,
    1:8, RemoteTSAP:8
    >>,
  lager:notice("send iso connect ~p bytes",[byte_size(Msg)]),
  Res = gen_tcp:send(Sock, Msg),
  lager:notice("ret from gen_tcp:send: ~p",[Res]),
  Res.
%%  case gen_tcp:send(Sock, Msg) of
%%    ok ->
%%%%      Req = {TId, Request, Opts, From},
%%
%%      {keep_state, State};%, [{reply, From, {ok, TId}}]};
%%    {error, closed} ->
%%      lager:error("~p error sending iso-connect request ~p closed~n",[self(), Msg]),
%%%%      gen_statem:reply(From, {error, disconnected}),
%%      try_reconnect(closed, State);
%%    {error, Reason} ->
%%      lager:error("************** ~p error sending iso-connect request ~p ~p~n",[self(), Msg, Reason]),
%%      {keep_state, State}%, [{reply, From, {error, Reason}}]}
%%  end.

%%  Msg.

negotiate_pdu(_State = #state{socket = Sock}) ->
  Msg =
  <<
    %% TPKT header
    3, %% version
    0, %% reserved
    25:16, %% length

    %% TPDU
    2, %% length
    ?COTP_HEADER_PDU_TYPE_DATA, %% code
    16#80, %% ??

    %% SPDU s7 comm
    %% header
    ?S7PDU_PROTOCOL_ID, %% protocol ID
    ?S7PDU_ROSCTR_JOB, %% ROSCTR: 1 job
    0:16, %% redundancy identification
    1:16, %% pdu reference
    8:16, %% parameter length: 8
    0:16, %% data length: 0

    %% parameter
    16#f0, %% function-code: setup communication
    0:8, %% reserved
    8:16, %% max AmQ (parallel jobs with ACK) calling: 8
    8:16, %% max AmQ (parallel jobs with ACK) called: 8
    ?S7PDU_MAX_PDUSIZE:16 %% PDU length: 960
  >>,
  lager:notice("send iso negotiate PDU ~p bytes",[byte_size(Msg)]),
  Res = gen_tcp:send(Sock, Msg),
  lager:notice("ret from gen_tcp:send: ~p",[Res]),
  Res.

%% for s7 300 for example
%%<<3,0,0,27,2,240,128,50,3,0,0,0,1,0,8,0,0,0,0,240,0,0,2,0,2,0,240>>
handle_neg_pdu_response(<<
  %% tpkt header
  _:16, 27:16,
  %% tpdu
  2, ?COTP_HEADER_PDU_TYPE_DATA, 16#80,
  %% S7
  ?S7PDU_PROTOCOL_ID,
  ?S7PDU_ROSCTR_ACK_DATA,
  _RedIdent:16, _:16, _:16,
  ErrorClass, ErrorCode, %% byte 17, 18
  _DataLength:16,
  _Func, 0, _MAX_amq:16, _MAX_amq2:16,
  PDUSize:16
  >>) ->
  lager:info("neg_pdu ErrorClass: ~p, ErrorCode: ~p",[ErrorClass, ErrorCode]),
  case ErrorClass /= 0 orelse ErrorCode /= 0 of
    true -> {error, {ErrorClass, ErrorCode}};
    false -> {ok, PDUSize}
  end;
handle_neg_pdu_response(_Other) ->
  {error, unexpected_pdu}.


read_multiple(Vars, State=#state{socket = Sock}) when is_list(Vars) ->

  RefId = State#state.ref_id,
  ItemCount = length(Vars),

  ReadItems = encode_read_items(Vars, <<>>),
  ReadItemsSize = byte_size(ReadItems),
  ParamLength = ReadItemsSize + 2,
  DataLength = 0, % returns byte_size(ReadItems) + 4,
  TptkLength = ReadItemsSize + 19,

  Msg =
    <<
      %% TPKT header
      3, %% version
      0, %% reserved
      TptkLength:16, %% length of the whole thing

      %% TPDU
      2, %% length
      ?COTP_HEADER_PDU_TYPE_DATA, %% code
      16#80, %% ??

      %% SPDU s7 comm
      %% header
      ?S7PDU_PROTOCOL_ID, %% protocol ID
      ?S7PDU_ROSCTR_JOB, %% ROSCTR: 1 job
      0:16, %% redundancy identification
      RefId:16, %% pdu reference
      ParamLength:16, %% parameter length
      DataLength:16, %% (Data length = Size(bytes) + 4)

      %% item read function
      ?S7PDU_FUNCTION_READ_VAR, %% function code
      ItemCount, %% item_count

      %% items
      ReadItems/binary
    >>,
  lager:notice("send read multivar request ~p bytes",[byte_size(Msg)]),
  Res = gen_tcp:send(Sock, Msg),
  lager:notice("ret from gen_tcp:send: ~p",[Res]),
  Res.



encode_read_items([], Ret) ->
  Ret;
encode_read_items(
    [#{amount := Amount, area := Area, word_len := WordLen, db_number := DB, start := Start}|Items], Acc) ->

  AreaType = proplists:get_value(Area, ?S7PDU_AREA),
  VarType = proplists:get_value(WordLen, ?S7PDU_TRANSPORT_TYPE),

  Item =
  <<
  16#12, %% var spec, always 16#12
  10, % length of remaining bytes
  16#10, % syntax ID (S7ANY)
  VarType, % transport size in BYTE
  Amount:16, % read length/amount
  DB:16, %% DB number
  AreaType, %% area Type (DB storage area, in this case)
  Start:24 %% area offset
  >>,
  encode_read_items(Items, <<Acc/binary, Item/binary>>)
.

%%<<3,0,0,29, 2,240,128, 50,3, 0,0, 0,2, 0,2 ,0,8 ,0,0, 4,1, 255,4,0,32, 38,56,4,180>>
handle_read_response(<<
  %% tpkt header
  _:16, _TotalLength:16,
  %% tpdu
  2, ?COTP_HEADER_PDU_TYPE_DATA, 16#80,
  %% S7
  ?S7PDU_PROTOCOL_ID,
  ?S7PDU_ROSCTR_ACK_DATA,
  _RedIdent:16, _PDURef:16, _Length:16,
  _DataLength:16,
  ErrorClass, ErrorCode, %% byte 17, 18
  ?S7PDU_FUNCTION_READ_VAR,
  ItemCount,
  Data/binary
  >>) ->
  lager:info("read ErrorClass: ~p, ErrorCode: ~p",[ErrorClass, ErrorCode]),
  case ErrorClass /= 0 orelse ErrorCode /= 0 of
    true -> {error, {ErrorClass, ErrorCode}};
    false ->
      lager:notice("reading returned ~p items ~p",[ItemCount, Data]),
      {ok, decode_items(Data, [])}
  end;
handle_read_response(_Other) ->
  {error, unexpected_pdu}.

decode_items(<<>>, Ret) ->
  Ret;
decode_items(<<16#ff, _VarType, Count:16, Rest/binary>>, Acc) ->
  Data = binary:part(Rest, 0, erlang:trunc(Count/8)),
  <<_Data:Count, NextItem/binary>> = Rest,
  decode_items(NextItem, Acc ++ [Data]);
decode_items(<<ReturnCode, _VarType, Count:16, Rest/binary>>, Acc) ->
  lager:warning("got return code ~p for read item",[ReturnCode]),
  <<_Data:Count, NextItem/binary>> = Rest,
  decode_items(NextItem, Acc).

try_reconnect(Reason, State = #state{reconnector = undefined}) ->
  {stop, {shutdown, Reason}, State};
try_reconnect(Reason, State = #state{reconnector = Reconnector}) ->
  lager:info("[Client: ~p] try reconnecting...~n",[self()]),
  case s7backoff:execute(Reconnector, {reconnect, timeout}) of
    {ok, Reconnector1} ->
      {next_state, disconnected, State#state{reconnector = Reconnector1, buffer = <<>>, requests = []}};
    {stop, Error} -> lager:error("[Client: ~p] reconnects exhausted: ~p!",[?MODULE, Error]),
      {stop, {shutdown, Reason}, State}
  end.



%%%%
%% Opts :: opt_list() -> [{signed, true|false} | {output, int16|int32|float32|coils|acii|binary}].
%%send_pdu(Request, Opts, State=#state{requests = Requests, tid = TId, socket = Sock}, From) ->
%%  Message =  generate_request(Request),
%%  case gen_tcp:send(Sock, Message) of
%%    ok ->
%%      Req = {TId, Request, Opts, From},
%%      NewState = State#state{requests = [Req|Requests]},
%%      {keep_state, NewState, [{reply, From, {ok, TId}}]};
%%    {error, closed} ->
%%      lager:error("~p error sending pdu for tid ~p closed~n",[self(), TId]),
%%      gen_statem:reply(From, {error, disconnected}),
%%      try_reconnect(closed, State);
%%    {error, Reason} ->
%%      lager:error("************** ~p error sending pdu for tid ~p ~p~n",[self(), TId, Reason]),
%%      {keep_state, State, [{reply, From, {error, Reason}}]}
%%  end.

handle_reply_pdu(TransId, UnitID1, Func1, Pdu, State) ->
  ok.
%%  case lists:keytake(TransId, 1, State#state.requests) of
%%    false ->
%%      lager:warning("### ### [~p]transaction-id ~p not found~n", [?MODULE, TransId]),
%%      {error, unknown_transaction_id, State#state{buffer = <<>>}};
%%    {value, {_, _Request = #tcp_request{address = UnitId, function = Func, data = Offset, ts = _Ts}, Opts, {From, _}}, Reqs}
%%      when UnitId =:= UnitID1; UnitId =:= 255 ->
%%      case Pdu of
%%        <<ErrorCode>> when  Func + 16#80 =:= Func1 ->
%%          From ! {modbusdata, {error, TransId, err(ErrorCode)}},
%%          {ok, State#state{requests = Reqs}};
%%        Data when Func =:= Func1 ->
%%          Data0 = output(Data, Opts, coils),
%%          FinalData =
%%            case (Func == ?FC_READ_COILS) andalso (length(Data0) > Offset) of
%%              true ->
%%                {ResultHead, _} = lists:split(Offset, Data0),
%%                ResultHead;
%%              false -> Data0
%%            end,
%%
%%          From ! {modbusdata, {ok, TransId, FinalData}},
%%          {ok, State#state{requests = Reqs}};
%%        _ ->
%%          lager:error("### ### unmatched response pdu ~p~n", [Pdu]),
%%          From ! {modbusdata, {error, TransId, internal}},
%%          {ok, State#state{requests = Reqs}}
%%      end;
%%    _ ->
%%      lager:warning("### ### reply from other unit ~p~n", [Pdu]),
%%      {error, unit_mismatch, State#state{buffer = <<>>}}
%%  end.


next_refid(State = #state{ref_id = Tid}) when Tid >= ?S7PDU_MAX_REF_ID ->
  State#state{ref_id = 1};
next_refid(State = #state{ref_id = Tid}) ->
  State#state{ref_id = Tid+1}.


%% read requests
generate_request(#tcp_request{tid = Tid, address = Address, function = Code, start = Start, data = Data}) ->
  Message = <<Address:8, Code:8, Start:16, Data:16>>,
  Size = byte_size(Message),
  <<Tid:16, 0:16, Size:16, Message/binary>>.


%% @doc Function to validate the response header and get the data from the tcp socket.
%% @end
-spec get_response(State::#tcp_request{}) -> ok | {error, term()}.
get_response(Req = #tcp_request{}) ->
  recv(Req).

recv(Req) ->
  case recv(header, Req) of
    {ok, HeaderLength} ->
      recv(payload, HeaderLength, Req);
    {error,Error} ->
      {error,Error}
  end.

recv(header, #tcp_request{tid = Tid, sock = Sock}) ->
  case gen_tcp:recv(Sock, ?COTP_DATA_LENGTH, ?RECV_TIMEOUT) of
    {ok, <<Tid:16, _:16, Len:16>>} ->
      {ok, Len};
    {ok, Header} ->
      lager:error("Response cannot match request: request tid=~p, response header =~p", [Tid, Header]),
      {error, badheader};
    {error, Reason} ->
      {error, Reason}
  end.

recv(payload, Len, #tcp_request{sock = Sock, function = Code, start = Start}) ->
  BadCode = Code + 16#80,
  case gen_tcp:recv(Sock, Len, ?RECV_TIMEOUT) of
    {ok, <<_UnitId:8, BadCode:8, ErrorCode:8>>} -> {error, err(ErrorCode)};
    {ok, <<_UnitId:8, Code:8, Start:16, Data:16>>} -> {ok, Data};
    {ok, <<_UnitId:8, Code:8, Size, Payload:Size/binary>>} -> {ok, Payload};
    {ok, <<_:8>>}      ->   {error, too_short_modbus_payload};
    {error, Reason}    ->   {error, Reason}
  end.


%% @doc Function convert data to the selected output.
%% @end
-spec output(Data::binary(), Opts::modbus:opt_list(), Default::atom()) -> list().
%%output(Data, _Opts, _Default) ->
%%   [X || <<X:16>> <= Data];
output(Data, Opts, Default) ->
  Output = proplists:get_value(output, Opts, Default),
  Signed = proplists:get_value(signed, Opts, false),
  case {Output, Signed} of
%%    {int16, false} -> modbus_util:binary_to_int16(Data);
%%    {int16, true} -> modbus_util:binary_to_int16s(Data);
%%    {int32, false} -> modbus_util:binary_to_int32(Data);
%%    {int32, true} -> modbus_util:binary_to_int32s(Data);
%%    {float32, _} -> modbus_util:binary_to_float32(Data);
%%    {float64, _} -> modbus_util:binary_to_float64(Data);
%%    {double, _} -> modbus_util:binary_to_float64(Data);
%%    {coils, _} -> modbus_util:binary_to_coils(Data);
%%    {ascii, _} -> modbus_util:binary_to_ascii(Data);
    {binary, _} -> Data;
    _ -> Data
  end.

err(<<Code:8>>) -> err(Code);
err(1)  -> illegal_function;
err(2)  -> illegal_data_address;
err(3)  -> illegal_data_value;
err(4)  -> slave_device_failure;
err(5)  -> acknowledge;
err(6)  -> slave_device_busy;
err(8)  -> memory_parity_error;
err(10) -> gateway_path_unavailable;
err(11) -> gateway_target_device_failed_to_respond;
err(_)  -> unknown_response_code.
