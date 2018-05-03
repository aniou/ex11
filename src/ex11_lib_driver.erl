%%%----------------------------------------------------------------------------
%%% @doc An OTP gen_server example
%%% @author Hans Christian v. Stockhausen 
%%% @end

%% Copyright (C) 2004 by Joe Armstrong (joe@sics.se)
%% All rights reserved.
%% The copyright holder hereby grants the rights of usage, distribution
%% and modification of this software to everyone and for any purpose, as
%% long as this license and the copyright notice above are preserved and
%% not modified. There is no warranty for this software.

%% 2004-01-01 Origional version by by joe@sics.se
%% 2004-01-17 Improved handling of code to resolve display addresses by
%%            Shawn Pearce <spearce@spearce.org>
%% 2004-01-28 Fixed get_connect_reply which only worked if the
%%            complete reply was read in one go with no extra data.
%%            Frej Drejhammar <frej@stacken.kth.se>
%% 2004-01-31 Added code from Luke Gorrie for handling of unix domain
%%            sockets


%%%----------------------------------------------------------------------------

-module(ex11_lib_driver).
-behaviour(gen_server).

-define(SERVER, ?MODULE).
-include("ex11_lib.hrl").

-import(ex11_lib, [pError/1, pEvent/1]).
-import(lists, [map/2,reverse/1]).

-record(driver, {client_pid,       % Pid of client, ex11_lib_control usually
                 fd,               % file descriptor of connection to X serv
                 in_buffer,        % incoming buffer <<binary>>
                 max_request_size, % max req. len of Xserv see out_queue_len
                 out_queue,        % out queue [<<bin>>, ...]
                 out_queue_size    % out queue size len(<<bin>>) + len(<<bin
                }).

%%-----------------------------------------------------------------------------
%% API Function Exports
%%-----------------------------------------------------------------------------

-export([
    start/1,
    start_link/0,
    send_cmd/2
]).

%% ---------------------------------------------------------------------------
%% gen_server Function Exports
%% ---------------------------------------------------------------------------

-export([
    init/1,                      % - initializes our process
    handle_call/3,               % - handles synchronous calls (with response)
    handle_cast/2,               % - handles asynchronous calls  (no response)
    handle_info/2,               % - handles out of band messages (sent with !)
    terminate/2,                 % - is called on shut-down
    code_change/3                % - called to handle code changes
]).

%% ---------------------------------------------------------------------------
%% API Function Definitions
%% ---------------------------------------------------------------------------

%% it should be called from ex11_lib_control

% there is a room for multiple drivers supervised by ex11_lib_driver_sup
% in future (maybe multiple drivers for single ex11_lib_control?)
start(Target) ->
    {ok, DriverPid} = supervisor:start_child(ex11_lib_driver_sup, []),
    case gen_server:call(DriverPid, {start_driver, Target}) of
        {ok, {Display, Screen}} ->
            {ok, {DriverPid, Display, Screen}};
        Other ->
            Other
    end.

send_cmd(DriverPid, C) -> 
    gen_server:cast(DriverPid, {cmd, C}).


% that one is called from supervisor
start_link() ->
    io:format("start link called~n",[]),
    gen_server:start_link(?MODULE, [], []).

%% ---------------------------------------------------------------------------
%% gen_server Function Definitions
%% ---------------------------------------------------------------------------

init([]) ->
    State = #driver{client_pid       = false,
                    fd               = false,
                    in_buffer        = <<>>,
                    max_request_size = 0, 
                    out_queue        = [],
                    out_queue_size   = 0},

    {ok, State}.

%% ---------------------------------------------------------------------------
%% ex11_connect only handles the connection
%%   connection is complex - mainly because some large data structures need
%%   parsing.

%%
%%

handle_call({start_driver, Target}, {From, _Tag}, State) ->
    io:format("init driver Display=~p~n",[Target]),
    case ex11_lib_connect:start(Target) of
        {ok, {Display, Screen, Fd}} ->
            %% io:format("Display=~p~n",[Display]),
            %% ?PRINT_DISPLAY(Display),
            %% Max command length 
            Max = Display#display.max_request_size,  
            %% io:format("Max RequestSize=~p~n",[Max]),
            {reply, {ok, {Display, Screen}},
                    State#driver{fd=Fd, 
                                 client_pid=From,
                                 max_request_size=Max}, 2000};
        Error -> 
            {reply, {error, Error}, State}
    end;


handle_call(_Request, _From, State) ->
    {reply,  ok, State, 2000}.

%% ---------------------------------------------------------------------------
handle_cast({cmd, C}, State) ->
    LO  = State#driver.out_queue_size,
    Max = State#driver.max_request_size,
    OB  = State#driver.out_queue,
    if
    size(C) + LO < Max ->
        %% io:format("storing~p bytes~n",[size(C)]),
        {noreply, State#driver{out_queue=[C|OB],
                               out_queue_size=LO+size(C)}, 2000};
    true ->
        send(State#driver.fd, reverse(OB)),
        {noreply, State#driver{out_queue=[C],
                               out_queue_size=size(C)}, 2000}
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.  

%% ---------------------------------------------------------------------------
handle_info(timeout, State) ->
    io:format("ex11_lib_driver timeout~n"),
    LO  = State#driver.out_queue_size,
    if
        LO > 0 ->
        io:format("Flushing (forgotten xFlush() ???)~n"),
        send(State#driver.fd, reverse(State#driver.out_queue));
    true ->
        {noreply, State#driver{out_queue=[],
                               out_queue_size=0}, 2000}
    end,
    {noreply, State#driver{out_queue=[],
                           out_queue_size=0}, 2000};

handle_info(flush, State) ->
    %% io:format("Driver got flush~n"),
    send(State#driver.fd, reverse(State#driver.out_queue)),
    {noreply, State#driver{out_queue=[],
                           out_queue_size=0}, 2000};

handle_info({tcp, Port, BinX}, State) ->
    %% io:format("received:~p bytes~n",[size(BinX)]),
    Bin  = State#driver.in_buffer,
    Bin1 = handle(State#driver.client_pid, <<Bin/binary, BinX/binary>>),
    {noreply, State#driver{in_buffer=Bin1}, 2000};

handle_info({unixdom, Socket, BinX}, State) ->
    Bin  = State#driver.in_buffer,
    Bin1 = handle(State#driver.client_pid, <<Bin/binary, BinX/binary>>),
    {noreply, State#driver{in_buffer=Bin1}, 2000};

% XXX - change it!
handle_info({'EXIT', _, die}, State) ->
    gen_tcp:close(State#driver.fd),
    {stop, killed, State};

% XXX - change it!
handle_info({tcp_closed,_Port}, State) ->
    init:stop();
    %{stop, tcp_closed, State};

handle_info(Info, State) ->
    io:format("top_loop (driver) got:~p~n",[Info]),
    {noreply, State, 2000}.


%% ---------------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%% ---------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle(Client, <<0:8,_/binary>>= B1) when size(B1) >= 31 ->
    %% error
    {E, Bin1} = split_binary(B1, 32),
    %% TODO 'using a matched out sub binary will prevent delayed sub binary optimization'
    <<0:8,Error:8,_/binary>> = E,
    io:format("Xerr:~p~n",[error_to_string(Error)]),
    Client ! pError(E),
    handle(Client, Bin1);
handle(Client, <<1:8,_/binary>>= B1) when size(B1) >= 31 ->
    %% io:format("Bingo got a reply~n"),
    decode_reply(Client, B1);
handle(Client, B1) when size(B1) >= 32 ->
    {E, Bin1} = split_binary(B1, 32),
    Client ! pEvent(E),
    handle(Client, Bin1);
handle(Client, Bin) when size(Bin) < 32 ->
    Bin.

decode_reply(Client, <<_:32,Len:32,_/binary>> = Bin) ->
    Need = 32 + 4*Len,
    Size = size(Bin),
    %% io:format("Need=~p Size=~p~n",[Need,Size]),
    if
    Need =< Size ->
        {Bin0, Bin1} = split_binary(Bin, Need),
        dispatch(Client, Bin0),
        handle(Client, Bin1);
    Need > Size ->
        Bin
    end.

dispatch(Client, <<1:8,_:8,Seq:16,_/binary>> = B) ->
    Client ! {reply, Seq, B}.

send({unix, S}, Bin) ->
    unixdom2:send(S, Bin),
    true;
send({tcp, Fd}, Bin) ->
    %% io:format("[~w] Sending ~w bytes to server~n~p~n",
    %% [Seq, size(Bin), Bin]),
    gen_tcp:send(Fd, Bin),
    %sleep(1500).
    true.

% sleep(T) ->
%   receive
%     after T ->
%        true
%    end.

error_to_string(1) -> request;
error_to_string(2) -> value;
error_to_string(3) -> window;
error_to_string(4) -> pixmap;
error_to_string(5) -> atom;
error_to_string(6) -> cursor;
error_to_string(7) -> font;
error_to_string(8) -> match;
error_to_string(9) -> drawable;
error_to_string(10) -> access;
error_to_string(11) -> alloc;
error_to_string(12) -> colormap;
error_to_string(13) -> gcontext;
error_to_string(14) -> idchoice;
error_to_string(15) -> name;
error_to_string(16) -> length;
error_to_string(17) -> implementation;
error_to_string(X) -> X.

% eof
