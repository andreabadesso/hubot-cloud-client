%% This is the process resposible for exchanging messages via websocket
%% with the cloud server.

-module(client_conn).

-behaviour(gen_server).

-export([
         start/2,
         init/1,
         handle_message/3,
         handle_info/2,
         handle_call/3]).

-record(state, {
          conn_pid    = undefined,
          streams     = undefined,
          protocol    = undefined,
          connected   = false,
          user_id     = undefined,
          controller  = undefined
         }).

-define(CENTRAL_HOST, "hubot.local").
-define(CENTRAL_PORT, 3000).
-define(CENTRAL_PATH, "/websocket").
-define(PING_INTERVAL, 5000).

start(UserId, Controller) ->
    gen_server:start(?MODULE, [UserId, Controller], []).

%% ===================================================================
%% API functions
%% ===================================================================

init([UserId, Controller]) ->
  lager:info("Received ~p, ~p on init", [UserId, Controller]),
  State = #state{user_id = UserId, controller = Controller},
  erlang:send_after(5, self(), connect),
  timer:send_interval(?PING_INTERVAL, ping),
  {ok, State}.

handle_call(Msg, From, State) ->
  lager:info("Unhandled msg: ~p from: ~p", [Msg, From]),
  State.

handle_info(connect, State) ->
  lager:info("Connecting to socket"),
  {ok, _} = application:ensure_all_started(gun),
  case gun:open(?CENTRAL_HOST, ?CENTRAL_PORT) of
    {ok, ConnPid} ->
      case gun:await_up(ConnPid) of
        {ok, Protocol} ->
          lager:info("HTTP Connected, upgrading connection"),
          erlang:send_after(5, self(), upgrade_connection),
          {noreply, State#state{conn_pid = ConnPid, protocol =  Protocol}};
        {error, _} ->
          lager:info("Connection failed, reconnecting in 5s"),
          gun:close(ConnPid),
          erlang:send_after(5 * 1000, self(), connect),
          {noreply, State}
      end;
    {error, _} ->
      lager:info("Connection failed, reconnecting in 5s"),
      erlang:send_after(5 * 1000, self(), connect),
      {noreply, State}
  end;
handle_info(upgrade_connection, State) ->
  gun:ws_upgrade(State#state.conn_pid, ?CENTRAL_PATH),
  {noreply, State};
handle_info(ping, State) ->
  gun:ws_send(State#state.conn_pid, ping),
  {noreply, State};
handle_info({gun_upgrade, _, _, [<<"websocket">>], _}, State) ->
  lager:info("Success on upgrade."),
  {noreply, State#state{connected = true}};
handle_info({gun_ws, _, _, {text, Msg}}, State) ->
  lager:info("Received message: ~p", [Msg]),
  Data = jiffy:decode(Msg, [return_maps]),
  #{<<"message_type">> := MessageType} = Data,
  handle_message(MessageType, Data, State),
  {noreply, State};
handle_info({gun_ws, _, _, Frame}, State) ->
  lager:info("Received message: ~p", [Frame]),
  {noreply, State};
handle_info({gun_down, _, _, Reason, _, _}, State) ->
  gun:close(State#state.conn_pid),
  lager:info("Cloud socket closed with reason: ~p will try to reconnect in 5 seconds", [Reason]),
  erlang:send_after(5 * 1000, self(), connect),
  {noreply, State#state{connected = false}};
handle_info({auth, send}, State) ->
  gun:ws_send(State#state.conn_pid, {text, jiffy:encode(#{
                                             message_type => <<"auth">>,
                                             token => <<"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJVVUlEIjoiNzU4NzQzNDEtZDQ0ZC00N2Y3LTkyY2ItODhhZTc0Y2ZmMTllIiwicmVnaXN0ZXJlZCI6dHJ1ZSwic2VyaWFsIjoiNDItN2QtYjYtMjAtODAtOTgiLCJuYW1lIjoiUEVOU0kgSWJpdHVydW5hIDM1IiwiaWF0IjoxNTU1NTQ5NTE1fQ.UqoSPjYNXkIcN8eHCLMKjMA8IeqyHimYSXj0Dw21ows">>,
                                             central_id => 3,
                                             user_id => 1
                                            })}),
  {noreply, State};
handle_info({auth, success}, State) ->
  lager:info("Auth success"),
  {noreply, State};
handle_info({auth, failure}, State) ->
  lager:info("Auth fail"),
  {noreply, State};
handle_info(die, State) ->
  {stop, normal, State};
handle_info(Msg, State) ->
  lager:info("Unhandled: ~p", [Msg]),
  {noreply, State}.

handle_message(<<"auth_req">>, Data, _) ->
  self() ! {auth, send};
handle_message(<<"auth_success">>, Data, _) ->
  self() ! {auth, success};
handle_message(<<"auth_error">>, Data, _) ->
  self() ! {auth, failure};
handle_message(Message, Data, State) ->
  State#state.controller ! {from_ws, State#state.user_id, Data}.
