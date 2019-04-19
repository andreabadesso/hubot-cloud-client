%%%-------------------------------------------------------------------
%% @doc client top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(client_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init([]) ->
  CloudConn = {cloud_conn,
               {cloud_conn, start_link, []},
               permanent,
               5000,
               worker,
               [cloud_conn]},
  {ok, {{rest_for_one, 3, 10}, [CloudConn]}}.

%%====================================================================
%% Internal functions
%%====================================================================
