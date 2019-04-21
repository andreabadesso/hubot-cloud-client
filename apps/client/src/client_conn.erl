%% This is the process resposible for exchanging messages via websocket
%% with the cloud server.

-module(client_conn).

-behaviour(gen_server).

-export([
         start/5,
         init/1,
         handle_message/3,
         handle_info/2,
         handle_cast/2,
         handle_call/3]).

-record(state, {
          conn_pid      = undefined,
          streams       = undefined,
          protocol      = undefined,
          connected     = false,
          user_id       = undefined,
          controller    = undefined,
          priv_key      = undefined,
          central_id    = undefined,
          hubot_server  = undefined
         }).

-define(CENTRAL_PORT, 3000).
-define(CENTRAL_PATH, "/websocket").
-define(PING_INTERVAL, 5000).

start(UserId, Controller, PrivKey, CentralId, HubotServer) ->
    gen_server:start(?MODULE, [UserId, Controller, PrivKey, CentralId, HubotServer], []).

%% ===================================================================
%% API functions
%% ===================================================================

init([UserId, Controller, PrivKey, CentralId, HubotServer]) ->
  lager:info("Received ~p, ~p on init", [UserId, Controller]),
  State = #state{user_id = UserId,
                 controller = Controller,
                 priv_key = PrivKey,
                 central_id = CentralId,
                 hubot_server = HubotServer},
  erlang:send_after(5, self(), connect),
  timer:send_interval(?PING_INTERVAL, ping),
  {ok, State}.

handle_call(Msg, From, State) ->
  lager:info("Unhandled msg: ~p from: ~p", [Msg, From]),
  State.

handle_cast(_, State) ->
  State.

handle_info(connect, State) ->
  lager:info("Connecting to socket"),
  {ok, _} = application:ensure_all_started(gun),
  case gun:open(State#state.hubot_server, ?CENTRAL_PORT) of
    {ok, ConnPid} ->
      case gun:await_up(ConnPid) of
        {ok, Protocol} ->
          lager:info("HTTP Connected, upgrading connection"),
          erlang:send_after(5, self(), upgrade_connection),
          {noreply, State#state{conn_pid = ConnPid, protocol =  Protocol}};
        {error, Error} ->
          lager:info("(Await Up) Connection failed, reconnecting in 5s: ~p", [Error]),
          gun:close(ConnPid),
          erlang:send_after(5 * 1000, self(), connect),
          {noreply, State}
      end;
    {error, Error} ->
      lager:info("(Gun Up) Connection failed, reconnecting in 5s: ~p", [Error]),
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
  Data = jiffy:decode(Msg, [return_maps]),
  #{<<"message_type">> := MessageType} = Data,
  handle_message(MessageType, Data, State),
  {noreply, State};
handle_info({gun_ws, _, _, _Frame}, State) ->
  {noreply, State};
handle_info({gun_down, _, _, Reason, _, _}, State) ->
  gun:close(State#state.conn_pid),
  lager:info("Cloud socket closed with reason: ~p will try to reconnect in 5 seconds", [Reason]),
  erlang:send_after(5 * 1000, self(), connect),
  {noreply, State#state{connected = false}};
handle_info({send, Message}, State) ->
  lager:info("Sending message to socket ~p", [Message]),
  gun:ws_send(State#state.conn_pid, {text, jiffy:encode(Message)}),
  {noreply, State};
handle_info({auth, send}, State) ->
  Claims = #{
    <<"UUID">> => State#state.user_id
   },
  {ok, Token} = jwt:encode(<<"HS256">>, Claims, State#state.priv_key),
  gun:ws_send(State#state.conn_pid, {text, jiffy:encode(#{
                                             message_type => <<"auth">>,
                                             token => Token,
                                             central_id => State#state.central_id
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

handle_message(<<"auth_req">>, _, _) ->
  self() ! {auth, send};
handle_message(<<"auth_success">>, _, _) ->
  self() ! {auth, success};
handle_message(<<"auth_error">>, _, _) ->
  self() ! {auth, failure};
handle_message(_, Data, State) ->
  State#state.controller ! {from_ws, State#state.user_id, Data}.
