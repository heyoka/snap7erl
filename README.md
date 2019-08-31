snap7erl
=====

Erlang only version of https://github.com/valiot/snapex7

Note: the snap7 sources are included in this library at the moment.

Supported architectures
----------------------

Sucessfully builds on:

+ Linux i386
+ Linux amd64
+ Linux armv6
+ Linux armv7
+ Linux armv7l


Build
-----

    $ rebar3 compile
    
Start
-----
    $ rebar3 shell
    
Useage
------
    %% start a client
    {ok, Client} = snapclient:start([]).
    
    %% connect to a S7
    ok = snapclient:connect_to(Client, [{ip, <<"127.0.0.1">>}, {slot, 1}, {rack, 0}]).
    
    %% read a DB with addressing
    A = <<"DB4.DBR2">>,
    RMap = s7addr:parse(A),
    Par = maps:to_list(CMap),
    snapclient:db_read(Client, Par).
