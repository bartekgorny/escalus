%%%-------------------------------------------------------------------
%%% @author bartek
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 15. Mar 2016 19:53
%%%-------------------------------------------------------------------
-module(escalus_botlib).
-author("bartek").

-behaviour(gen_fsm).

-include_lib("exml/include/exml.hrl").
-include_lib("escalus/include/escalus_botlib.hrl").

%% API
-export([start_link/2,
         start_link/3,
         connect/1,
         disconnect/1,
         sync_status/2,
         sync_status/3,
         sync_unavailable/1,
         sync_msg/3,
         status/2,
         status/3,
         unavailable/1,
         msg/3]).

%% gen_fsm callbacks
-export([init/1,
         offline/2,
         offline/3,
         online/2,
         online/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).

-record(state, {userspec, connection, callback}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Start connector
%% callback is {Mod, Args} where Mod is module on which functions
%% process_message, process_presence and process will be called
%% and Args will be passed to it, so it will be like:
%% process_message(Args, #message{...}, self())
%% where args can contain pid of some gen_server or gen_fsm
%% and self() is sent so that the callback may reply
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link(string(), atom()) ->
    {ok, pid()} | ignore | {error, Reason :: term()}).
start_link(Filename, User) ->
    start_link(Filename, User, undefined).
-spec(start_link(string(), atom(), {atom(), list()}) ->
    {ok, pid()} | ignore | {error, Reason :: term()}).
start_link(Filename, User, Callback) ->
    gen_fsm:start_link({local, ?SERVER}, ?MODULE, [Filename, User, Callback], []).

connect(Pid) ->
    gen_fsm:send_event(Pid, connect).

disconnect(Pid) ->
    gen_fsm:send_event(Pid, disconnect).

sync_status(Pid, Status) ->
    gen_fsm:sync_send_event(Pid, {status, tob(Status)}).

sync_status(Pid, Status, StatusMessage) ->
    gen_fsm:sync_send_event(Pid, {status, tob(Status), tob(StatusMessage)}).

sync_unavailable(Pid) ->
    gen_fsm:sync_send_event(Pid, {status, unavailable}).

sync_msg(Pid, To, Msg) ->
    gen_fsm:sync_send_event(Pid, {chat, To, tob(Msg)}).

status(Pid, Status) ->
    gen_fsm:send_event(Pid, {status, tob(Status)}).

status(Pid, Status, StatusMessage) ->
    gen_fsm:send_event(Pid, {status, tob(Status), tob(StatusMessage)}).

unavailable(Pid) ->
    gen_fsm:send_event(Pid, {status, offline}).

msg(Pid, To, Msg) ->
    gen_fsm:send_event(Pid, {chat, To, tob(Msg)}).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Filename, User, Callback]) ->
    {ok, Config} = file:consult(Filename),
    UserSpec = escalus_users:get_options(Config, User),
    process_flag(trap_exit, true),
    {ok, offline, #state{userspec = UserSpec, callback = Callback}}.

%% offline sync catch-all
offline(Msg, _From, State) ->
    ?PRT({offline_sync, "???", Msg}),
    {reply, ok, offline, State}.

offline(connect, #state{userspec = UserSpec, callback = Cb} = State) ->
    Result = try_to_connect(UserSpec),
    case Result of
        {ok, Conn} ->
            {Mod, Args} = Cb,
            Mod:process(Args, connected, self()),
            {next_state, online, State#state{connection = Conn}};
        econnrefused ->
            ?PRT(connrefused),
            wait_and_reconnect(),
            {next_state, offline, State};
        {error, _} ->
            {stop, error, error, State}
    end;
%% offline async catch-all
offline(Msg, State) ->
    ?PRT({offline_async, "???", Msg}),
    {next_state, offline, State}.

online(disconnect, _From, #state{connection = Conn, callback = Cb} = State) ->
    do_disconnect(Conn),
    {Mod, Args} = Cb,
    Mod:process(Args, disconnected, self()),
    {reply, ok, offline, State#state{connection = undefined}};
online({status, offline}, _From, #state{connection = Conn} = State) ->
    go_unavailable(Conn),
    {reply, ok, online, State};
online({status, Status}, _From, #state{connection = Conn} = State) ->
    send_status(Status, Conn),
    {reply, ok, online, State};
online({status, Status, StatusMessage}, _From, #state{connection = Conn} = State) ->
    send_status(StatusMessage, Status, Conn),
    {reply, ok, online, State};
online({chat, To, Message}, _From, #state{connection = Conn} = State) ->
    escalus_connection:send(Conn, escalus_stanza:chat_to(To, Message)),
    {reply, ok, online, State};
%% online sync catch-all
online(Msg, _From, State) ->
    ?PRT({online_sync, "???", Msg}),
    {reply, ok, online, State}.

online(disconnect, #state{connection = Conn} = State) ->
    do_disconnect(Conn),
    {next_state, offline, State#state{connection = undefined}};
online({status, unavailable}, #state{connection = Conn} = State) ->
    go_unavailable(Conn),
    {next_state, online, State};
online({status, Status}, #state{connection = Conn} = State) ->
    send_status(Status, Conn),
    {next_state, online, State};
online({status, Status, StatusMessage}, #state{connection = Conn} = State) ->
    send_status(StatusMessage, Status, Conn),
    {next_state, online, State};
online({chat, To, Message}, #state{connection = Conn} = State) ->
    escalus_connection:send(Conn, escalus_stanza:chat_to(To, Message)),
    {next_state, online, State};
%% online async catch-all
online(Msg, State) ->
    ?PRT({online_async, "???", Msg}),
    {next_state, online, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info({stanza, _Client, Stanza}, online, #state{callback = Cb} = State) ->
    {Name, Res} = process_stanza(Stanza#xmlel.name, Cb, Stanza),
    ship_stanza(Name, Res, Cb),
    {next_state, online, State};
handle_info({'EXIT', _, normal}, _StateName, State) ->
    wait_and_reconnect(),
    {next_state, offline, State#state{connection = undefined}};
handle_info(Info, StateName, State) ->
    ?PRT({info, "???", Info}),
    {next_state, StateName, State}.

terminate(Reason, _StateName, _State) ->
    ?PRT({terminating_for_reason, Reason}),
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

process_stanza(Name, _Cbmod, Stanza) ->
    Res = stanza_to_record(Name, Stanza),
    {Name, Res}.

stanza_to_record(<<"presence">>, Stanza) ->
    Atts = Stanza#xmlel.attrs,
    From = jid_to_record(proplists:get_value(<<"from">>, Atts)),
    To = jid_to_record(proplists:get_value(<<"to">>, Atts)),
    Show = case exml_query:path(Stanza, [{element, <<"show">>}, cdata]) of
               undefined -> <<"available">>;
               S -> S
           end,
    Status = exml_query:path(Stanza, [{element, <<"status">>}, cdata]),
    #presence{from = From, to = To, show = Show, status = Status};
stanza_to_record(<<"message">>, Stanza) ->
    Atts = Stanza#xmlel.attrs,
    From = jid_to_record(proplists:get_value(<<"from">>, Atts)),
    To = jid_to_record(proplists:get_value(<<"to">>, Atts)),
    Type = exml_query:path(Stanza, [{element, <<"type">>}, cdata]),
    Body = exml_query:path(Stanza, [{element, <<"body">>}, cdata]),
    #message{from = From, to = To, type = Type, body = Body};
stanza_to_record(Name, _Stanza) ->
    ?PRT({unknown_stanza, Name}),
    undefined.

jid_to_record(undefined) ->
    #addr{};
jid_to_record(Jid) ->
    U = escalus_utils:get_username(Jid),
    S = escalus_utils:get_server(Jid),
    B = <<U/binary, "@", S/binary>>,
    #addr{full_jid = Jid, bare_jid = B, user = U, host = S}.

ship_stanza(_, _, undefined) ->
    ok;
ship_stanza(<<"presence">>, S, {Mod, Args}) ->
    Mod:process_presence(Args, S, self());
ship_stanza(<<"message">>, S, {Mod, Args}) ->
    Mod:process_message(Args, S, self());
ship_stanza(_, S, {Mod, Args}) ->
    Mod:process(Args, S, self()).

send_status(none, _Conn) ->
    ok;
send_status(Status, Conn) ->
    Tags = escalus_stanza:tags([
        {<<"show">>, Status}
    ]),
    escalus_connection:send(Conn, escalus_stanza:presence(<<"available">>, Tags)).

send_status(_, none, _Conn) ->
    ok;
send_status(StatusMessage, Status, Conn) ->
    Tags = escalus_stanza:tags([
        {<<"status">>, StatusMessage},
        {<<"show">>, Status}
    ]),
    escalus_connection:send(Conn, escalus_stanza:presence(<<"available">>, Tags)).

go_unavailable(Conn) ->
    escalus_connection:send(Conn, escalus_stanza:presence(<<"unavailable">>)).

do_disconnect(Conn) ->
    escalus_connection:stop(Conn).

wait_and_reconnect() ->
    timer:apply_after(5000, gen_fsm, send_event, [self(), connect]).

try_to_connect(UserSpec) ->
    case (catch escalus_connection:start(UserSpec)) of
        {ok, Conn, _, _} ->
            {ok, Conn};
        {'EXIT',
            {{badmatch,
                {error,
                    {{badmatch,{error,econnrefused}},
                        _}}},
                _}} -> %% such are idiosyncrasies of escalus
            econnrefused;
        E ->
            io:format("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!~nError while trying to connect - terminating~n"),
            io:format("Msg was: ~p~n", [E]),
            {error, E}
    end.

tob(S) ->
    unicode:characters_to_binary(S).
