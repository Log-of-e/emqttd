%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqtt broker.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqtt_broker).

-include("emqtt_packet.hrl").

-include("emqtt_systop.hrl").

-behaviour(gen_server).

-define(SERVER, ?MODULE).

-define(BROKER_TAB, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

-export([version/0, uptime/0, datetime/0, sysdescr/0]).

%% Statistics.
-export([getstats/0, getstat/1, setstat/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {started_at, sys_interval, tick_timer}).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Start emqtt broker.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start_link([tuple()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Options], []).

%%------------------------------------------------------------------------------
%% @doc
%% Get broker version.
%%
%% @end
%%------------------------------------------------------------------------------
-spec version() -> string().
version() ->
    {ok, Version} = application:get_key(emqtt, vsn), Version.

%%------------------------------------------------------------------------------
%% @doc
%% Get broker description.
%%
%% @end
%%------------------------------------------------------------------------------
-spec sysdescr() -> string().
sysdescr() ->
    {ok, Descr} = application:get_key(emqtt, description), Descr.

%%------------------------------------------------------------------------------
%% @doc
%% Get broker uptime.
%%
%% @end
%%------------------------------------------------------------------------------
-spec uptime() -> string().
uptime() ->
    gen_server:call(?SERVER, uptime).

%%------------------------------------------------------------------------------
%% @doc
%% Get broker datetime.
%%
%% @end
%%------------------------------------------------------------------------------
-spec datetime() -> string().
datetime() ->
    {{Y, M, D}, {H, MM, S}} = calendar:local_time(),
    lists:flatten(
        io_lib:format(
            "~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w", [Y, M, D, H, MM, S])).

%%------------------------------------------------------------------------------
%% @doc
%% Get broker statistics.
%%
%% @end
%%------------------------------------------------------------------------------
-spec getstats() -> [{atom(), non_neg_integer()}].
getstats() ->
    ets:tab2list(?BROKER_TAB).

%%------------------------------------------------------------------------------
%% @doc
%% Get stats by name.
%%
%% @end
%%------------------------------------------------------------------------------
-spec getstat(atom()) -> non_neg_integer() | undefined.
getstat(Name) ->
    case ets:lookup(?BROKER_TAB, Name) of
        [{Name, Val}] -> Val;
        [] -> undefined
    end.

%%------------------------------------------------------------------------------
%% @doc
%% Set broker stats.
%%
%% @end
%%------------------------------------------------------------------------------
-spec setstat(atom(), pos_integer()) -> boolean().
setstat(Name, Val) ->
    ets:insert(?BROKER_TAB, {Name, Val}).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

init([Options]) ->
    random:seed(now()),
    % Create $SYS Topics
    [{atomic, _} = create(systop(Name)) || Name <- ?SYSTOP_BROKERS],
    [{atomic, _} = create(systop(Name)) || Name <- ?SYSTOP_CLIENTS],
    [{atomic, _} = create(systop(Name)) || Name <- ?SYSTOP_SESSIONS],
    [{atomic, _} = create(systop(Name)) || Name <- ?SYSTOP_PUBSUB],
    ets:new(?BROKER_TAB, [set, public, named_table, {write_concurrency, true}]),
    SysInterval = proplists:get_value(sys_interval, Options, 60),
    State = #state{started_at = os:timestamp(), sys_interval = SysInterval},
    {ok, tick(random:uniform(SysInterval), State)}.

handle_call(uptime, _From, State) ->
    {reply, uptime(State), State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, State) ->
    retain(systop(version), list_to_binary(version())),
    retain(systop(sysdescr), list_to_binary(sysdescr())),
    publish(systop(uptime), list_to_binary(uptime(State))),
    publish(systop(datetime), list_to_binary(datetime())),
    [publish(systop(Stat), i2b(Val)) 
        || {Stat, Val} <- ets:tab2list(?BROKER_TAB)],
    {noreply, tick(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

systop(Name) when is_atom(Name) ->
    list_to_binary(lists:concat(["$SYS/brokers/", node(), "/", Name])).

create(Topic) ->
    emqtt_pubsub:create(Topic).

retain(Topic, Payload) when is_binary(Payload) ->
    emqtt_router:route(#mqtt_message{retain = true,
                                     topic = Topic,
                                     payload = Payload}).

publish(Topic, Payload) when is_binary(Payload) ->
    emqtt_router:route(#mqtt_message{topic = Topic,
                                     payload = Payload}).

uptime(#state{started_at = Ts}) ->
    Secs = timer:now_diff(os:timestamp(), Ts) div 1000000,
    lists:flatten(uptime(seconds, Secs)).

uptime(seconds, Secs) when Secs < 60 ->
    [integer_to_list(Secs), " seconds"];
uptime(seconds, Secs) ->
    [uptime(minutes, Secs div 60), integer_to_list(Secs rem 60), " seconds"];
uptime(minutes, M) when M < 60 ->
    [integer_to_list(M), " minutes, "];
uptime(minutes, M) ->
    [uptime(hours, M div 60), integer_to_list(M rem 60), " minutes, "];
uptime(hours, H) when H < 24 ->
    [integer_to_list(H), " hours, "];
uptime(hours, H) ->
    [uptime(days, H div 24), integer_to_list(H rem 24), " hours, "];
uptime(days, D) ->
    [integer_to_list(D), " days,"].

tick(State = #state{sys_interval = SysInterval}) ->
    tick(SysInterval, State).

tick(Delay, State) ->
    State#state{tick_timer = erlang:send_after(Delay * 1000, self(), tick)}.

i2b(I) when is_integer(I) ->
    list_to_binary(integer_to_list(I)).

