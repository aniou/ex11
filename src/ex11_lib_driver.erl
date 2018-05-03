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

%%-----------------------------------------------------------------------------
%% API Function Exports
%%-----------------------------------------------------------------------------

-export([
  start_link/2,
  send_cmd/2,
  get_display/1 
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

start_link(From, Display) ->
	gen_server:start_link(?MODULE, [From, Display], []).

send_cmd(DriverPid, C) -> 
	gen_server:cast(DriverPid, {cmd, C}).

get_display(DriverPid) ->
	gen_server:call(DriverPid, get_display).


%% ---------------------------------------------------------------------------
%% gen_server Function Definitions
%% ---------------------------------------------------------------------------

%% ex11_connect only handles the connection
%%   connection is complex - mainly because some large data structures need
%%   parsing.

init([From, Target]) ->
  io:format("child pid ~p~n", [self()]),
  io:format("init driver Display=~p~n",[Target]),
  case ex11_lib_connect:start(Target) of
    {ok, {Display, Screen, Fd}} ->
      %% io:format("Display=~p~n",[Display]),
      %% ?PRINT_DISPLAY(Display),
      %% Max command length 
      Max = Display#display.max_request_size,
      %% io:format("Max RequestSize=~p~n",[Max]),
	  {ok, {From, Fd, <<>>, Max, [], 0, Display, Screen}, 2000};
    Error -> 
		{stop, {error, connect}}
  end.



handle_call(get_display, _From,  {From, Fd, <<>>, Max, [], 0, Display, Screen}) ->
	{reply,  {ok, {self(), Display, Screen}},  {From, Fd, <<>>, Max, [], 0, Display, Screen}, 2000};

handle_call(_Request, _From, State) ->
	{reply,  ok, State, 2000}.



handle_cast({cmd, C}, {Client, Fd, Bin, Max, OB, LO, Display, Screen}) ->
	    if
		size(C) + LO < Max ->
		    %% io:format("storing~p bytes~n",[size(C)]),
			{noreply, {Client, Fd, Bin, Max, [C|OB], LO + size(C), Display, Screen}, 2000};
		true ->
		    send(Fd, reverse(OB)),
			{noreply, {Client, Fd, Bin, Max, [C], size(C), Display, Screen}, 2000}
	    end;

handle_cast(_Msg, State) ->
	    {noreply, State}.  


handle_info(timeout, {Client, Fd, Bin, Max, OB, LO, Display, Screen}) ->
		%io:format("ex11_lib_driver timeout~n"),
		if
		    LO > 0 ->
			io:format("Flushing (forgotten xFlush() ???)~n"),
			send(Fd, reverse(OB));
		    true ->
		      {noreply, {Client, Fd, Bin, Max, [], 0, Display, Screen}, 2000}
		end,
		{noreply, {Client, Fd, Bin, Max, [], 0, Display, Screen}, 2000};


% XXX: crude workaround - conversion in progress
%
handle_info(Info, {Client, Fd, Bin, Max, OB, LO, Display, Screen}) ->
    case Info of
	flush ->
	    %% io:format("Driver got flush~n"),
	    send(Fd, reverse(OB)),
		{noreply, {Client, Fd, Bin, Max, [], 0, Display, Screen}, 2000};
	{tcp, Port, BinX} ->
	    %% io:format("received:~p bytes~n",[size(BinX)]),
	    Bin1 = handle(Client, <<Bin/binary, BinX/binary>>),
		{noreply, {Client, Fd, Bin1, Max, OB, LO, Display, Screen}, 2000};
	{unixdom, Socket, BinX} ->
	    Bin1 = handle(Client, <<Bin/binary, BinX/binary>>),
		{noreply, {Client, Fd, Bin1, Max, OB, LO, Display, Screen}, 2000};
	{'EXIT', _, die} ->
	    gen_tcp:close(Fd),
	    exit(killed); %% XXX - change it!
  % XXX - change it!
  {tcp_closed,_Port} -> init:stop();
	Any ->
	    io:format("top_loop (driver) got:~p~n",[Any]),
		{noreply, {Client, Fd, Bin, Max, OB, LO, Display, Screen}, 2000}
  end.


terminate(_Reason, _State) ->
  ok.


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
%	    true
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
