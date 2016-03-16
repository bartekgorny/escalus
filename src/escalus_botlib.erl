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
         status/2,
         status/3,
         unavailable/1,
         msg/3,
         a_status/2,
         a_status/3,
         a_unavailable/1,
         a_msg/3]).

%% gen_fsm callbacks
-export([init/1,
         offline/3,
         online/2,
         online/3,
         handle_event/3,
         handle_sync_event/4,
         handle_info/3,
         terminate/3,
         code_change/4]).

-define(SERVER, ?MODULE).

-define(PRT(X), io:format("~p~n", [X])).
-record(state, {userspec, connection, listener, callback}).

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
    gen_fsm:sync_send_event(Pid, connect).

disconnect(Pid) ->
    gen_fsm:sync_send_event(Pid, disconnect).

status(Pid, Status) ->
    gen_fsm:sync_send_event(Pid, {status, Status}).

status(Pid, Status, StatusMessage) ->
    gen_fsm:sync_send_event(Pid, {status, Status, StatusMessage}).

unavailable(Pid) ->
    gen_fsm:sync_send_event(Pid, {status, offline}).

msg(Pid, To, Msg) ->
    gen_fsm:sync_send_event(Pid, {chat, To, Msg}).

a_status(Pid, Status) ->
    gen_fsm:send_event(Pid, {status, Status}).

a_status(Pid, Status, StatusMessage) ->
    gen_fsm:send_event(Pid, {status, Status, StatusMessage}).

a_unavailable(Pid) ->
    gen_fsm:send_event(Pid, {status, offline}).

a_msg(Pid, To, Msg) ->
    gen_fsm:send_event(Pid, {chat, To, Msg}).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Filename, User, Callback]) ->
    {ok, Config} = file:consult(Filename),
    UserSpec = escalus_users:get_options(Config, User),
    {ok, offline, #state{userspec = UserSpec, callback = Callback}}.

offline(connect, _From, #state{userspec = UserSpec} = State) ->
    {ok, Conn, _, _} = escalus_connection:start(UserSpec),
    Pid = self(),
    Lstn = spawn_link(escalus_connection, proxy, [Conn, Pid]),
    {reply, ok, online, State#state{connection = Conn, listener = Lstn}}.

online(disconnect, _From, #state{connection = Conn, listener = Lstn} = State) ->
    disconnect(Lstn, Conn),
    {reply, ok, offline, State#state{connection = undefined}};
online({status, offline}, _From, #state{connection = Conn} = State) ->
    go_offline(Conn),
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
online(Msg, _From, State) ->
    ?PRT({whaaaat, Msg, "???"}),
    {reply, ok, online, State}.

online(disconnect, #state{connection = Conn, listener = Lstn} = State) ->
    disconnect(Lstn, Conn),
    {next_state, offline, State#state{connection = undefined}};
online({status, offline}, #state{connection = Conn} = State) ->
    go_offline(Conn),
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
online(Msg, State) ->
    ?PRT({whaaaat, Msg, "???"}),
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
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
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

send_status(Status, Conn) ->
    Tags = escalus_stanza:tags([
        {<<"show">>, Status}
    ]),
    escalus_connection:send(Conn, escalus_stanza:presence(<<"available">>, Tags)).

send_status(StatusMessage, Status, Conn) ->
    Tags = escalus_stanza:tags([
        {<<"status">>, StatusMessage},
        {<<"show">>, Status}
    ]),
    escalus_connection:send(Conn, escalus_stanza:presence(<<"available">>, Tags)).

go_offline(Conn) ->
    escalus_connection:send(Conn, escalus_stanza:presence(<<"unavailable">>)).

disconnect(Lstn, Conn) ->
    Lstn ! stop,
    escalus_connection:stop(Conn).

