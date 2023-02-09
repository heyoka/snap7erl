%%%-------------------------------------------------------------------
%%% @author heyoka
%%% @copyright (C) 2019
%%% @doc
%%%
%%% siemens s7 addressing
%%% (simatic (german) and IEC (english) mnemonics are supported)
%%%
%%% node-red-contib-s7 style of addressing is supported
%%% @see https://www.npmjs.com/package/node-red-contrib-s7
%%%
%%% no peripheral addresses supported, no string addresses supported!
%%%
%%% offset is a integer offset for the start-addresses
%%% DB addresses only at the moment
%%%
%%% @end
%%% Created : 15. Jun 2019 20:05
%%%-------------------------------------------------------------------
-module(s7addr).
-author("heyoka").

%% API
-export([parse/1, parse/2, parse/3]).

parse(Address, Offset, return_list) when is_binary(Address), is_integer(Offset) ->
   maps:to_list(parse(Address, Offset)).
parse(Address) when is_binary(Address) ->
   parse(Address, 0).
parse(Address, return_list) when is_binary(Address) ->
   parse(Address, return_list);
parse(Address, Offset) when is_binary(Address), is_integer(Offset) ->
   Addr = string:uppercase(Address),
   %% trim whitespace
   Clean = binary:replace(Addr, <<" ">>, <<>>, [global]),
   %% check for addressing format // "DB" starts at index 0
   case string:find(Clean, <<"DB">>) of
      Clean ->
         Pattern =
            case string:find(Clean, <<",">>) of
               nomatch  -> <<".">>;
               _        -> <<",">>
            end,
         do_parse(binary:split(Clean, Pattern, [trim_all]), Offset);

      _ ->  do_parse(Clean, Offset)
   end.

%% non db address
-spec do_parse(list(binary()), map()) -> map() | {error, invalid}.
do_parse([<<First/binary>>], Offset) ->
   Parts = binary:split(First, <<".">>, [trim_all]),
   parse_non_db(Parts, #{amount => 1}, Offset);
%% db address step7 style
do_parse([<<"DB", _DbNumber/binary>> = First, <<"DB", Part2/binary>>], Offset) ->
   do_parse([First, Part2], Offset);
%% db address node-red style
do_parse([<<"DB", DbNumber/binary>>, Part2], Offset) ->
   P = #{area => db, amount => 1, db_number => binary_to_integer(DbNumber)},
   Parts = binary:split(Part2, <<".">>, [trim_all]),
   parse_db(Parts, P, Offset);
do_parse(_, _) -> {error, invalid}.

%% second part after comma !
parse_db([NoBitAccess], Params, Offset) ->
   DataType = clear_numbers(NoBitAccess),
   case DataType of
      _ when DataType == <<"X">> orelse DataType == <<"S">> ->
         {error, invalid};
      _ ->
         Size = byte_size(DataType),
         <<DataType:Size/binary, StartAddr/binary>> = NoBitAccess,
         case (catch binary_to_integer(StartAddr)) of
            Start when is_integer(Start) ->
               {DType, CDType} = data_type(DataType),
               Params#{word_len => DType, start => Start + Offset, dtype => CDType};
            _ -> {error, invalid}
         end
   end;
parse_db([BitAccess, Bit], Params, Offset) ->
   DataType = clear_numbers(BitAccess),
   case DataType of
      _ when DataType == <<"X">> orelse DataType == <<"S">> ->
%%         logger:notice("BitAccess: ~p, Bit: ~p, Params: ~p :: ~nDataType: ~p",[BitAccess, Bit, Params, DataType]),
         Size = byte_size(DataType),
         <<DataType:Size/binary, StartAddr/binary>> = BitAccess,
         {DType,CDType} = data_type(DataType),
         {Start, Amount} = start_amount(DType, binary_to_integer(StartAddr)+Offset, Bit),
         Params#{start => Start, amount => Amount, word_len => DType, dtype => CDType};
      _ -> {error, invalid}
   end.

%% @doc
%% non db
%%
parse_non_db([NoBitAccess], Par, Offset) ->
   % clear numbers to get the area
   Area = clear_numbers(NoBitAccess),
   Size = byte_size(Area),
   <<Area:Size/binary, StartAddr/binary>> = NoBitAccess,
%%   P = type(Area, Par#{start => binary_to_integer(StartAddr)+Offset}),
   P = type(Area, Par#{}),
   case P of
      _ when is_map(P) -> {P#{start => binary_to_integer(StartAddr)+Offset}, NoBitAccess};
      _ -> P
   end;
parse_non_db([WithBitAccess, Bit], Par, Offset) ->
   Area = clear_numbers(WithBitAccess),
   Size = byte_size(Area),
   <<Area:Size/binary, StartAddr/binary>> = WithBitAccess,
   P = type(Area, Par#{}),
   case P of
      _ when is_map(P) ->
         {Start, Amount} = start_amount(maps:get(word_len, P), binary_to_integer(StartAddr)+Offset, Bit),
         {P#{start => Start, amount => Amount}, WithBitAccess, Bit};
      {error, invalid} -> {error, invalid}
   end.

clear_numbers(Bin) ->
   re:replace(Bin, "[0-9]", <<>>, [{return, binary}, global]).

%%%% standard inputs

-spec type(binary(), map()) -> map().
type(<<"I">>, P) ->
   type(<<"E">>, P);
type(<<"E">>, P) ->
   P#{area => pe, word_len => bit, dtype => bool};
type(<<"IB">>, P) ->
   type(<<"EB">>, P);
type(<<"EB">>, P) ->
   P#{area => pe, word_len => byte, dtype => byte};
type(<<"IC">>, P) ->
   type(<<"EC">>, P);
type(<<"EC">>, P) ->
   P#{area => pe, word_len => byte, dtype => char}; %% char
type(<<"IW">>, P) ->
   type(<<"EW">>, P);
type(<<"EW">>, P) ->
   P#{area => pe, word_len => word, dtype => word};
type(<<"II">>, P) ->
   type(<<"EI">>, P);
type(<<"EI">>, P) ->
   P#{area => pe, word_len => byte, dtype => int}; %% integer

type(<<"ID">>, P) ->
   type(<<"ED">>, P);
type(<<"ED">>, P) ->
   P#{area => pe, word_len => d_word, dtype => d_word};
type(<<"IDI">>, P) ->
   type(<<"EDI">>, P);
type(<<"EDI">>, P) ->
   P#{area => pe, word_len => d_word, dtype => d_int}; %% DINT ?

type(<<"IR">>, P) ->
   type(<<"ER">>, P);
type(<<"ER">>, P) ->
   P#{area => pe, word_len => real, dtype => float};

%%% standard outputs
type(<<"Q">>, P) ->
   type(<<"A">>, P);
type(<<"A">>, P) ->
   P#{area => pa, word_len => bit, dtype => bool};
type(<<"QB">>, P) ->
   type(<<"AB">>, P);
type(<<"AB">>, P) ->
   P#{area => pa, word_len => byte, dtype => byte};
type(<<"QC">>, P) ->
   type(<<"AC">>, P);
type(<<"AC">>, P) ->
   P#{area => pa, word_len => byte, dtype => char}; %% char

type(<<"QW">>, P) ->
   type(<<"AW">>, P);
type(<<"AW">>, P) ->
   P#{area => pa, word_len => word, dtype => word};
type(<<"QI">>, P) ->
   type(<<"AI">>, P);
type(<<"AI">>, P) ->
   P#{area => pa, word_len => byte, dtype => int}; %% integer

type(<<"QD">>, P) ->
   type(<<"AD">>, P);
type(<<"AD">>, P) ->
   P#{area => pa, word_len => d_word, dtype => dword};
type(<<"QDI">>, P) ->
   type(<<"ADI">>, P);
type(<<"ADI">>, P) ->
   P#{area => pa, word_len => d_word, dtype => d_int}; %% DINT ?

type(<<"QR">>, P) ->
   type(<<"AR">>, P);
type(<<"AR">>, P) ->
   P#{area => pa, word_len => real, dtype => float};

%%% markers
type(<<"M">>, P) ->
   P#{area => mk, word_len => bit, dtype => bool};
type(<<"MB">>, P) ->
   P#{area => mk, word_len => byte, dtype => byte};
type(<<"MC">>, P) ->
   P#{area => mk, word_len => byte, dtype => char}; %% char
type(<<"MW">>, P) ->
   P#{area => mk, word_len => word, dtype => word};
type(<<"MI">>, P) ->
   P#{area => mk, word_len => byte, dtype => int}; %% integer
type(<<"MD">>, P) ->
   P#{area => mk, word_len => d_word, dtype => d_int};
type(<<"MDI">>, P) ->
   P#{area => mk, word_len => d_word, dtype => d_int}; %% DINT ?
type(<<"MR">>, P) ->
   P#{area => mk, word_len => real, dtype => float};

%%% others
type(<<"T">>, P) ->
   P#{area => tm, word_len => timer, dtype => timer};
type(<<"C">>, P) ->
   P#{area => ct, word_len => counter, dtype => counter};

type(_, _) -> {error, invalid}.

%% dtype for db
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec data_type(binary()) -> {Snap7WordType :: atom(), DesiredType :: atom()}.
data_type(<<"I">>) -> data_type(<<"INT">>);
data_type(<<"INT">>) -> {word, int};

data_type(<<"D">>) -> data_type(<<"DINT">>);
data_type(<<"DI">>) -> data_type(<<"DINT">>);
data_type(<<"DINT">>) -> {d_word, d_int};

data_type(<<"DR">>) -> data_type(<<"REAL">>);
data_type(<<"R">>) -> data_type(<<"REAL">>);
data_type(<<"REAL">>) -> {real, float};

data_type(<<"X">>) -> {bit, bool};

data_type(<<"B">>) -> data_type(<<"BYTE">>);
data_type(<<"BYTE">>) -> {byte, byte};

data_type(<<"SI">>) -> data_type(<<"SINT">>);
data_type(<<"SINT">>) -> {byte, sint};

data_type(<<"USI">>) -> data_type(<<"USINT">>);
data_type(<<"USINT">>) -> {byte, usint};

data_type(<<"C">>) -> data_type(<<"CHAR">>);
data_type(<<"CHAR">>) -> {byte, char};

data_type(<<"W">>) -> data_type(<<"WORD">>);
data_type(<<"WORD">>) -> {word, word};

data_type(<<"DW">>) -> data_type(<<"DWORD">>);
data_type(<<"DWORD">>) -> {d_word, d_word};

data_type(<<"S">>) -> data_type(<<"STRING">>);
data_type(<<"STRING">>) -> {byte, string}.


%%%%%
start_amount(WordType, StartMarker, BitMarker) ->
   case WordType of
      bit   -> {StartMarker * 8 + binary_to_integer(BitMarker), 1};
      _     -> {StartMarker, binary_to_integer(BitMarker)}
   end.


-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
basic_test() ->
   A = <<"DB34.DBX32.4">>,
   Res = #{amount => 1, area => db, db_number => 34, dtype => bool, start => 260, word_len => bit},
   ?assertEqual(Res, parse(A)).
basic_bool_offset_test() ->
   A = <<"DB34.DBX32.4">>,
   Offset = 30,
   Res = #{amount => 1, area => db, db_number => 34, dtype => bool, start => 500, word_len => bit},
   ?assertEqual(Res, parse(A, Offset)).
basic_real_offset_test() ->
   A = <<"DB34.DBR14">>,
   Offset = 30,
   Res = #{amount => 1, area => db, db_number => 34, dtype => float, start => 44, word_len => real},
   ?assertEqual(Res, parse(A, Offset)).
%%basic_nondb_test() ->
%%   A = <<"QM3.2">>,
%%   Res = #{amount => 1, area => db, db_number => 34, dtype => bool, start => 26, word_len => bit},
%%   ?assertEqual(Res, parse(A)).
basic_invalid_test() ->
   A = <<"DB34.DBR14.0">>,
   ?assertEqual({error, invalid}, parse(A)).
basic_bool_invalid_test() ->
   A = <<"DB34.DBX3">>,
   ?assertEqual({error, invalid}, parse(A)).
basic_invalid_2_test() ->
   A = <<"DB34.DBW">>,
   ?assertEqual({error, invalid}, parse(A)).

-endif.