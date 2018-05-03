%%%-------------------------------------------------------------------
%% @doc ex11 top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(ex11_lib_driver_sup).
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

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    io:format("ex11_lib_driver_sup PID ~p~n", [self()]),

    SupFlags = #{strategy  => simple_one_for_one, 
                 intensity => 1, 
                 period    => 5},  % XXX - get a proper values

    ChildSpecs = [#{id       => ex11_lib_driver,
                    start    => {ex11_lib_driver, start_link, []},
                    shutdown => brutal_kill}],  

    {ok, {SupFlags, ChildSpecs}}.

%%====================================================================
%% Internal functions
%%====================================================================
