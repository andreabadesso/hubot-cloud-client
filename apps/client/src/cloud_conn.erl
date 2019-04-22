%% This is the process resposible for exchanging messages via websocket
%% with the cloud server.

-module(cloud_conn).

-behaviour(gen_server).

-export([
         start_link/0,
         init/1,
         connect_http/2,
         handle_message/2,
         handle_info/2,
         handle_cast/2,
         handle_call/3,
         terminate/2,
         code_change/3]).

-record(state, {
          conn_pid      = undefined,
          streams       = undefined,
          connected     = false,
          client_list   = [],
          central_id    = undefined,
          priv_key      = undefined,
          hubot_api     = undefined,
          hubot_server  = undefined,
          cloud_host    = undefined
         }).

-define(PING_INTERVAL, 5000).
-define(CENTRAL_PORT, 80).
-define(CLOUD_PORT, 80).
-define(CLOUD_PATH, "/pi").

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ===================================================================
%% API functions
%% ===================================================================

init(_) ->
  Config = read_config(),
  #{<<"centralUUID">> := CentralId,
    <<"privKey">> := PrivKey,
    <<"hubotApi">> := HubotApi,
    <<"cloudHost">> := CloudHost,
    <<"hubotServer">> := HubotServer } = Config,
  State = #state{
             central_id = CentralId,
             priv_key = PrivKey,
             hubot_api = binary_to_list(HubotApi),
             hubot_server = binary_to_list(HubotServer),
             cloud_host = binary_to_list(CloudHost)
            },
  erlang:send_after(5, self(), connect),
  timer:send_interval(?PING_INTERVAL, ping),
  {ok, State}.

handle_call(Msg, From, State) ->
  lager:info("Unhandled msg: ~p from: ~p", [Msg, From]),
  State.

handle_cast(Msg, State) ->
  lager:info("Unhandled cast: ~p", [Msg]),
  State.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

handle_info(connect, State) ->
  lager:info("Connecting to socket ~p", [State#state.cloud_host]),
  {ok, _} = application:ensure_all_started(gun),
  case connect_http(State#state.cloud_host, ?CLOUD_PORT) of
    {ok, ConnPid} ->
      lager:info("HTTP Connected, upgrading connection"),
      erlang:send_after(5, self(), upgrade_connection),
      {noreply, State#state{conn_pid = ConnPid}};
    {error, _} ->
      lager:info("Connection failed, reconnecting in 5s"),
      erlang:send_after(5 * 1000, self(), connect),
      {noreply, State}
  end;
handle_info(upgrade_connection, State) ->
  gun:ws_upgrade(State#state.conn_pid, ?CLOUD_PATH),
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
  handle_message(MessageType, Data),
  {noreply, State};
handle_info({gun_ws, _, _, _Frame}, State) ->
  {noreply, State};
handle_info({gun_down, ConnPid, _, Reason, _, _}, #state{conn_pid = ConnPid} = State) ->
  lager:info("Received gundown on cloud conn"),
  gun:close(State#state.conn_pid),
  lager:info("Cloud socket closed with reason: ~p will try to reconnect in 5 seconds", [Reason]),
  lager:info("Closing client conns."),
  [Pid ! die || {Pid, _} <- State#state.client_list],
  erlang:send_after(5 * 1000, self(), connect),
  {noreply, State#state{connected = false, client_list = []}};
handle_info({gun_error, _ConnPid, _, Reason}, State) ->
  lager:info("Gun error: ~p", [Reason]),
  {noreply, State};
handle_info({gun_down, ConnPid, _, _, _, _}, State) ->
  lager:info("Gun down, closing pid: ~p", [ConnPid]),
  gun:close(ConnPid),
  {noreply, State};
handle_info({send, Data}, State) ->
  gun:ws_send(State#state.conn_pid, {text, jiffy:encode(Data)}),
  {noreply, State};
handle_info({auth, send}, State) ->
  Token = sign(#{ <<"central_id">> => State#state.central_id }, State#state.priv_key),
  Payload = jiffy:encode(#{ message_type => <<"auth">>,
                  token => Token,
                  central_id => State#state.central_id
                }),
  lager:info("Sending: ~p", [Payload]),
  gun:ws_send(State#state.conn_pid, {text, Payload}),
  {noreply, State};
handle_info({auth, success}, State) ->
  lager:info("Auth success"),
  {noreply, State};
handle_info({auth, failure}, State) ->
  lager:info("Auth fail, will retry in 5 seconds"),
  erlang:send_after(5 * 1000, self(), connect),
  {noreply, State};

handle_info({http_request, Data}, State) ->
  %% TODO: HTTP Requests to the central should be in the client_conn
  %% not here.

  #{<<"data">> := Request,
    <<"uuid">> := Uuid} = Data,

  %% Get the request data
  #{<<"body">> := Body,
    <<"headers">> := Headers,
    <<"method">> := Method,
    <<"path">> := Path} = Request,

  Response = case central_request(Method, Path, Headers, Body, State#state.hubot_server, ?CENTRAL_PORT) of
               {error, Error} ->
                 lager:info("Received error from connection. ~p", [Error]),
                 #{ status => 500 };
               {ConnPid, ConnRef} ->
                 case gun:await(ConnPid, ConnRef) of
                   {response, fin, ResponseStatus, ResponseHeaders} ->
                     lager:info("Received status and headers, there is no body to read."),
                     gun:close(ConnPid),
                     #{ headers => maps:from_list(ResponseHeaders),
                        status => ResponseStatus };
                   {response, nofin, ResponseStatus, ResponseHeaders} ->
                     {ok, ResponseBody} = gun:await_body(ConnPid, ConnRef),
                     gun:close(ConnPid),
                     #{ headers => maps:from_list(ResponseHeaders),
                        status => ResponseStatus,
                        body => ResponseBody };
                   {error, timeout} ->
                     gun:close(ConnPid),
                     #{ status => 408 }
                 end
             end,

  Payload = #{
    message_type => <<"http">>,
    uuid => Uuid,
    data => Response
   },

  self() ! {send, Payload},

  {noreply, State};
handle_info({app_ws, Payload}, State) ->
  #{<<"user_id">> := UserId,
    <<"message">> := Message} = Payload,
  case find(UserId, 2, State#state.client_list) of
    none ->
      %% If the cloud is sending the message, we are safe
      %% to trust this connection and add it.
      lager:info("UserId was not on clients list, adding it.."),
      self() ! {app_connect, Payload},

      %% Send the message again in 500ms
      erlang:send_after(500, self(), {app_ws, Payload});
    {Pid, _} ->
      %% Get message from the payload
      Pid ! {send, Message}
  end,
  {noreply, State};
handle_info({app_connect, Data}, State) ->
  lager:info("Received app_connect"),
  #{<<"user_id">> := UserId} = Data,
  case find(UserId, 2, State#state.client_list) of
    none ->
      lager:info("Not found on current list, adding it."),
      {ok, Pid} = client_conn:start(UserId,
                                    self(),
                                    State#state.priv_key,
                                    State#state.central_id,
                                    State#state.hubot_server),
      erlang:monitor(process, Pid),
      lager:info("Client conn started for user ~p: ~p", [UserId, Pid]),
      NewClientList = [{Pid, UserId} | State#state.client_list],
      {noreply, State#state{client_list = NewClientList}};
    {Pid, _} ->
      %% There was already an app connected with the same UserId,
      %% we will just kill it for now as the cloud will deal with
      %% closing the old app connection and creating the new one.
      Pid ! die,
      {noreply, State}
  end;
handle_info({app_disconnect, Data}, State) ->
  #{<<"user_id">> := UserId} = Data,
  case find(UserId, 2, State#state.client_list) of
    {Pid, _} ->
      %% Kill process and remove from list.
      lager:info("App disconnected, removing Pid ~p", [Pid]),
      Element = find(Pid, 1, State#state.client_list),
      NewClientList = lists:delete(Element, State#state.client_list),
      Pid ! die,
      {noreply, State#state{client_list = NewClientList}};
    none ->
      lager:info("Received app disconnect but UserId was already not on the socket list."),
      {noreply, State}
  end;
handle_info({'DOWN', Ref, process, Pid, Reason}, State) ->
  lager:info("Process ~p died", [Pid]),
  erlang:demonitor(Ref),
  Element = find(Pid, 1, State#state.client_list),
  NewClientList = lists:delete(Element, State#state.client_list),
  lager:info("process ~p died for reason ~p", [Pid, Reason]),
  {noreply, State#state{client_list = NewClientList}};
handle_info({from_ws, UserId, Msg}, State) ->
  Payload = #{
    user_id => UserId,
    message_type => <<"websocket">>,
    message => Msg
   },
  self() ! {send, Payload},
  {noreply, State};
handle_info(Msg, State) ->
  lager:info("Unhandled: ~p", [Msg]),
  {noreply, State}.

connect_http(Host, Port) ->
  case gun:open(Host, Port) of
    {ok, ConnPid} ->
      case gun:await_up(ConnPid) of
        {ok, _} ->
          lager:info("HTTP Connected."),
          {ok, ConnPid};
        {error, Msg} ->
          {error, Msg}
      end;
    {error, Msg} ->
      {error, Msg}
  end.

central_request(Method, Path, Headers, Body, Host, Port) ->
  case connect_http(Host, Port) of
    {ok, Pid} ->
      case Method of
        <<"GET">> ->
          Ref = gun:get(Pid, Path, maps:to_list(Headers)),
          gun:data(Pid, Ref, fin, <<"">>),
          {Pid, Ref};
        <<"POST">> ->
          Ref = gun:post(Pid, Path, maps:to_list(Headers)),
          gun:data(Pid, Ref, fin, Body),
          {Pid, Ref};
        <<"PUT">> ->
          Ref = gun:put(Pid, Path, maps:to_list(Headers)),
          gun:data(Pid, Ref, fin, Body),
          {Pid, Ref};
        <<"DELETE">> ->
          Ref = gun:delete(Pid, Path, maps:to_list(Headers)),
          gun:data(Pid, Ref, fin, Body),
          {Pid, Ref}
      end;
    {error, E} -> {error, E}
  end.

handle_message(<<"auth_req">>, _) ->
  self() ! {auth, send};
handle_message(<<"auth_success">>, _) ->
  self() ! {auth, success};
handle_message(<<"auth_fail">>, _) ->
  self() ! {auth, failure};
handle_message(<<"app_connect">>,Data) ->
  self() ! {app_connect, Data};
handle_message(<<"app_disconnect">>, Data) ->
  self() ! {app_disconnect, Data};
handle_message(<<"websocket">>, Data) ->
  self() ! {app_ws, Data};
handle_message(<<"http">>, Data) ->
  lager:info("Received http request"),
  self() ! {http_request, Data};
handle_message(Message, Data) ->
  lager:info("Unhandled ~p: ~p", [Message, Data]).

% TODO: Move this to a dedicated library
sign(Claims, PrivKey) ->
  {ok, Token} = jwt:encode(<<"HS256">>, Claims, PrivKey),
  Token.

find(K, Index, [H|T]) ->
  case Index of
    1 ->
      case H of
        {K, _} -> H;
        _ -> find(K, Index, T)
      end;
    2 ->
      case H of
        {_, K} -> H;
        _ -> find(K, Index, T)
      end
  end;
find(_, _, []) -> none.

read_config() ->
  % Read config file from env
  ConfigPath = os:getenv("CONFIG_PATH", "/opt/hubot_config.json"),
  lager:info("Config path: ~p", [ConfigPath]),
  {ok, ConfigData} = file:read_file(ConfigPath),
  jiffy:decode(ConfigData, [return_maps]).
