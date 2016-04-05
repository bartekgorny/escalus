%%%-------------------------------------------------------------------
%%% @author bartek
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Mar 2016 21:18
%%%-------------------------------------------------------------------
-author("bartek").

-record(addr, {user, host, full_jid, bare_jid}).
-record(presence, {from, to, status, show}).
-record(message, {from, to, type, body}).

-define(PRT(X), io:format("~p~n", [X])).
