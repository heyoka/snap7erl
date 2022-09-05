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
-export([start_link/0, start_link/1, start/1, stop/1, do/0]).

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
  max_parallel_jobs = 1 :: non_neg_integer(),
  socket                :: inet:socket(),
  reconnector           :: modbus_s7backoff:reconnector(),
  recipient             :: pid(),
  buffer  = <<>>        :: binary(),
  ref_id = 1            :: 1..16#ffff,
  requests = []         :: list(),
  requests_waiting = [] :: list()

}).




%%%%%%%%%%%%%%%%%%%%%%%
%%%% TESTS
%%%%%%%%%%%%%%%%%%%%%%%%
do() ->
  {ok, S7} = s7client:start_link([{host, "192.168.121.206"},{port, 102},{rack, 0}, {slot, 2}]),
  receive
    {s7_connected, S7, PDUSize} ->
      lager:notice("S7 now connected, pdu-size is ~p, let's start reading ...",[PDUSize]),
      gen_statem:call(S7, {read, [
        #{amount => 2,area => db,db_number => 4002,start => 0,word_len => word},
        #{amount => 3,area => db,db_number => 4002,start => 8,word_len => word}]}),
      gen_statem:call(S7, {read, [
        #{amount => 2,area => db,db_number => 4001,start => 0,word_len => word},
        #{amount => 5,area => db,db_number => 4002,start => 8,word_len => word}]}),
      gen_statem:call(S7, {read, [
        #{amount => 2,area => db,db_number => 4002,start => 0,word_len => word},
        #{amount => 3,area => db,db_number => 4002,start => 8,word_len => word}]}),
      gen_statem:call(S7, {read, [
        #{amount => 1,area => db,db_number => 4002,start => 0,word_len => word},
        #{amount => 3,area => db,db_number => 4002,start => 0,word_len => word}]})
  after 3000 ->
    {error, timeout}
  end
  .









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

connecting(state_timeout, connect, State) ->
  lager:info("[~p] connecting ...~n",[?MODULE]),
  connect(State);
connecting(cast, stop, _State) ->
  {stop, normal}.

disconnected(info, {reconnect, timeout}, State) ->
  connect(State);
disconnected({call, From}, _Whatever, _State) ->
  {keep_state_and_data, [{reply, From, {error, disconnected}}]};
disconnected(cast, stop, _State) ->
  {stop, normal};
%%disconnected({call, _From} = Req, What, State) ->
%%  handle_common(Req, What, State);
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
connected(Type, What, State) ->
  handle_common(Type, What, State).

connected_iso(state_timeout, negotiate_pdu, State = #state{socket = Socket}) ->
  inet:setopts(Socket, [{active, once}]),
  negotiate_pdu(State),
  keep_state_and_data;
connected_iso(info, {tcp, Socket, Data}, State=#state{recipient = Rec}) ->
  inet:setopts(Socket, [{active, once}]),
  lager:notice("connected_iso got tcp data: ~p",[Data]),
  case handle_neg_pdu_response(Data) of
    {ok, NewPDUSize, MaxParallelJobs} ->
      lager:alert("got confirm for negotiate_pdu, pdu size now ~p, max amqp is  ~p, now ready for read requests",
        [NewPDUSize, MaxParallelJobs]),
      %% tell recipient we are connected
      Rec ! {s7_connected, self(), NewPDUSize},
      %% here we should do all the waiting requests
      {next_state, ready, State#state{pdu_size = NewPDUSize, max_parallel_jobs = MaxParallelJobs}};
    {error, What} ->
      lager:warning("waiting for confirm for negotiate_pdu, got error: ~p",[What]),
      try_reconnect(negotiate_pdu_failed, State#state{socket = undefined})
  end;
connected_iso(Type, What, State) ->
  handle_common(Type, What, State).

%% ready to receive read requests
ready(info, {tcp, Socket, Data}, State=#state{recipient = Rec, requests = CurrentRequests}) ->
  inet:setopts(Socket, [{active, once}]),
  lager:notice("ready got tcp data: ~p",[Data]),
  NewState =
  case handle_read_response(Data) of
    {ok, PDURef, ResultList} ->
      Rec ! {s7_data, PDURef, ResultList},
      NewCurrentList = lists:keydelete(PDURef, 1, CurrentRequests),
      State#state{requests = NewCurrentList};
    {error, PDURef, Error} ->
      Rec ! {s7_read_error, PDURef, Error},
      NewCurrentList = lists:keydelete(PDURef, 1, CurrentRequests),
      State#state{requests = NewCurrentList};
  {error, What} ->
    %% how to get rid of the accompaning entry in #state.requests ?
    Rec ! {s7_read_error, What},
    State
  end,
  NewState1 = maybe_start_next(NewState),
  {keep_state, NewState1};
%%%%%%%%%%%% read %%%%%%%%%%%%%
ready({call, From}, {read, VarList}, State = #state{requests = CurrentRequests, max_parallel_jobs = Max})
    when length(CurrentRequests) < Max ->
  NewState = #state{ref_id = RefId} = next_refid(State),
  Res = read_multiple(VarList, RefId, NewState),
  lager:info("result from sending: ~p",[Res]),
  NewRequests = CurrentRequests ++ [{RefId, From, VarList}],
  lager:info("new current requests: ~p",[NewRequests]),
  {keep_state, NewState#state{requests = NewRequests}, [{reply, From, {ok, RefId}}]};
ready({call, From}, {read, VarList}, State = #state{requests_waiting = WaitingList}) ->
  NewState0 = #state{ref_id = RefId} = next_refid(State),
  lager:notice("Request has to wait ~p",[RefId]),
  NewState = NewState0#state{requests_waiting = WaitingList ++ [{RefId, From, VarList}]},
  {keep_state, NewState, [{reply, From, {ok, RefId}}]};
ready({call, From}, get_cpu_info, State) ->
  NewState =  next_refid(State),
  Res = get_cpu_info(State),
  lager:info("result from sending: ~p",[Res]),
  {keep_state, NewState, [{reply, From, ok}]};
ready({call, From}, get_cp_info, State) ->
  NewState =  next_refid(State),
  Res = get_cp_info(State),
  lager:info("result from sending: ~p",[Res]),
  {keep_state, NewState, [{reply, From, ok}]};
ready({call, From}, get_plc_status, State) ->
  NewState =  next_refid(State),
  Res = get_plc_status(State),
  lager:info("result from sending: ~p",[Res]),
  {keep_state, NewState, [{reply, From, ok}]};
ready({call, From}, get_plc_datetime, State) ->
  NewState =  next_refid(State),
  Res = get_plc_datetime(State),
  lager:info("result from sending: ~p",[Res]),
  {keep_state, NewState, [{reply, From, ok}]};
ready(info, What, State) ->
  handle_common(info, What, State).



%% common handlers, different states
handle_common({call, From}, Req, State = #state{requests_waiting = ReqWaiting}) ->
  NewState0 = #state{ref_id = RefId} = next_refid(State),
  NewState = NewState0#state{requests_waiting = ReqWaiting ++ [{RefId, From, Req}]},
  {keep_state, NewState, [{reply, From, {ok, RefId}}]};
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
%%request({read, RefId, VarList}, State) ->
%%  NewState =  next_refid(State),
%%  Res = read_multiple(VarList, NewState),
%%  lager:info("result from sending: ~p",[Res]),
%%  {Res, }
%%  {keep_state, NewState, [{reply, From, ok}]};
%%request({call, From}, get_cpu_info, State) ->
%%  NewState =  next_refid(State),
%%  Res = get_cpu_info(State),
%%  lager:info("result from sending: ~p",[Res]),
%%  {keep_state, NewState, [{reply, From, ok}]};
%%request({call, From}, get_cp_info, State) ->
%%  NewState =  next_refid(State),
%%  Res = get_cp_info(State),
%%  lager:info("result from sending: ~p",[Res]),
%%  {keep_state, NewState, [{reply, From, ok}]};
%%request({call, From}, get_plc_status, State) ->
%%  NewState =  next_refid(State),
%%  Res = get_plc_status(State),
%%  lager:info("result from sending: ~p",[Res]),
%%  {keep_state, NewState, [{reply, From, ok}]}.


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
maybe_start_next(State = #state{requests_waiting = []}) ->
  lager:info("no requests waiting at the moment"),
  State;
maybe_start_next(State = #state{requests_waiting = [{RefId, _From, VarList} = Req|RestWaiting],
    requests = Reqs, max_parallel_jobs = Max}) when length(Reqs) < Max ->
  Res = read_multiple(VarList, RefId, State),
  lager:notice("starting WAITING request: ~p",[RefId]),
  lager:info("result from sending: ~p",[Res]),
  NewRequests = Reqs ++ [Req],
  lager:info("new current requests: ~p",[NewRequests]),
  State#state{requests = NewRequests, requests_waiting = RestWaiting};
maybe_start_next(State) ->
  State.


%% tcp connect
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
    8:16, %% max AmQ caller (parallel jobs with ACK) calling: 8
    8:16, %% max AmQ callee (parallel jobs with ACK) called: 8
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
  _DataLength:16,
  ErrorClass, ErrorCode, %% byte 17, 18
  _Func, 0,
  MAX_amq_caller:16,
  MAX_amq2_callee:16,
  PDUSize:16
  >>) ->
  lager:info("neg_pdu:: max_amq_caller: ~p max_amq_callee: ~p / ErrorClass: ~p, ErrorCode: ~p",
    [MAX_amq_caller, MAX_amq2_callee, ErrorClass, ErrorCode]),
  case ErrorClass /= 0 orelse ErrorCode /= 0 of
    true ->
      {error, {
        proplists:get_value(ErrorClass, ?ERROR_CLASSES, <<"unknown error class">>),
        proplists:get_value(ErrorCode, ?ERROR_CODES, <<"unknown error code">>)
        }
      };
    false -> {ok, PDUSize, MAX_amq_caller}
  end;
handle_neg_pdu_response(_Other) ->
  {error, unexpected_pdu}.


read_multiple(Vars, RefId, State=#state{socket = Sock}) when is_list(Vars) ->

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
  _RedIdent:16, PDURef:16, _Length:16,
  _DataLength:16,
  ErrorClass, ErrorCode, %% byte 17, 18
  ?S7PDU_FUNCTION_READ_VAR,
  ItemCount,
  Data/binary
  >>) ->
  lager:info("read ErrorClass: ~p, ErrorCode: ~p",[ErrorClass, ErrorCode]),
  case ErrorClass /= 0 orelse ErrorCode /= 0 of
    true ->
      {error, PDURef, {
        proplists:get_value(?ERROR_CLASSES, ErrorClass, <<"unknown error class">>),
        proplists:get_value(?ERROR_CODES, ErrorCode, <<"unknown error code">>)
        }
      };
    false ->
      lager:notice("reading returned ~p items ~p",[ItemCount, Data]),
      {ok, PDURef, decode_items(Data, [])}
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
  lager:warning("got return code ~p for read item ~p",
    [ReturnCode, proplists:get_value(ReturnCode, ?DATA_ITEM_ERRORS, <<"unknown error">>)]),
  <<_Data:Count, NextItem/binary>> = Rest,
  decode_items(NextItem, Acc).

get_plc_status(_State = #state{socket = Sock}) ->
  Msg = ?REQUEST_GET_PLC_STATUS,
  lager:notice("send get plc status request ~p bytes",[byte_size(Msg)]),
  inet:setopts(Sock, [{active, false}]),
  Res = gen_tcp:send(Sock, Msg),
  Out =
    case Res of
      ok ->
        case gen_tcp:recv(Sock, 0, 4000) of
          {ok, Data} -> lager:notice("got plc status response: ~p",[Data]), decode_plc_status_response(Data);
          {error, What} -> lager:warning("error receiving from socket: ~p",[What]), {error, What}
        end;
      {error, What1} -> lager:warning("error sending plc_status request : ~p",[What1]), {error, What1}
    end,
  inet:setopts(Sock, [{active, false}]),
  Out.

%%<<3,0,0,61,2,240,128,50,7,0,0,44,0,0,12,0,32,0,1,18,8,18,132,1,1,0,0,0,0,255,9,0,28,4,36,0,0,0,20,0,1,81,2,255,8,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>
decode_plc_status_response(Data) ->
  Status = binary:at(Data, 44),
  #{run => (Status == 8), stop => (Status /= 8)}.


get_cpu_info(State) ->
  {error, not_implemented}.

get_cp_info(State) ->
  {error, not_implemented}.

get_plc_datetime(_State = #state{socket = Sock}) ->
  lager:notice("send get plc status request ~p bytes",[byte_size(?REQUEST_GET_DATETIME)]),
  inet:setopts(Sock, [{active, false}]),
  Res = gen_tcp:send(Sock, ?REQUEST_GET_DATETIME),
  Out =
  case Res of
    ok ->
      case gen_tcp:recv(Sock, 0, 4000) of
        {ok, Data} -> lager:notice("got data datetime response: ~p",[Data]), decode_datetime_response(Data);
        {error, What} -> lager:warning("error receiving from socket: ~p",[What]), {error, What}
      end;
    {error, What1} -> lager:warning("error sending datetime_request : ~p",[What1]), {error, What1}
  end,
  inet:setopts(Sock, [{active, false}]),
  Out
  .
%% 300 : <<3,0,0,43,2,240,128,50,7,0,0,56,0,0,12,0,14,0,1,18,8,18,135,1,5,0,0,0,0,255,9,0,10,0,25,34,8,48,33,25,22,113,3>>
%% 1500: <<3,0,0,33, 2,240,128, 50,7, 0,0, SeqNr:56, Lenghts:0,0, ErrorClass:12,ErrorCode: 0,4, 0,1,18,8,18,135,1,0,0,0,129,4,10,0,0,0>>
%% 12 is also S5TIME datatype
decode_datetime_response(Resp) ->
  %% 27:16 => 0, 29:8 => 16#ff, datetime at 35:48
  Dt = binary:part(Resp, 35, 6),
  lager:notice("datetime of plc is :~p",[Dt]),
  <<Year:16, Month, Day, Hour, Min, Sec, MilliSec, DayOfWeek>> = <<25,34,8,48,33,25,22,113,3>>,
  <<Year:16, Month, Day, Hour, Min, Sec, MilliSec, DayOfWeek>> = Dt,
  {ok, Dt};
%%  case binary:part(Resp, 27, 2) of
%%    0 ->
%%      case binary:at(Resp, 29) of
%%        16#ff ->
%%          Dt = binary:part(Resp, 35, 6),
%%          lager:notice("datetime of plc is :~p",[Dt]),
%%          {ok, Dt};
%%        _ -> {error, invalid_pdu}
%%      end;
%%    _ -> {error, invalid_pdu}
%%  end;
decode_datetime_response(_) ->
  {error, unexpected_pdu}.


%%%%%% internal %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
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



next_refid(State = #state{ref_id = Tid}) when Tid >= ?S7PDU_MAX_REF_ID ->
  State#state{ref_id = 1};
next_refid(State = #state{ref_id = Tid}) ->
  State#state{ref_id = Tid+1}.


