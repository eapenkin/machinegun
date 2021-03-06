%%%
%%% Copyright 2018 RBKmoney
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%

-module(mg_timer_retry_SUITE).
-include_lib("common_test/include/ct.hrl").

%% tests descriptions
-export([all           /0]).
-export([groups        /0]).
-export([init_per_group/2]).
-export([end_per_group /2]).
-export([init_per_suite/1]).
-export([end_per_suite /1]).

%% tests
-export([transient_fail/1]).
-export([permanent_fail/1]).

%% mg_machine
-behaviour(mg_machine).
-export([pool_child_spec/2, process_machine/7]).

-export([start/0]).

%% Pulse
-export([handle_beat/2]).

%%
%% tests descriptions
%%
-type test_name () :: atom().
-type group     () :: {Name :: atom(), Opts :: list(), [test_name()]}.
-type config    () :: [{atom(), _}].

-spec all() ->
    [test_name()] | {group, atom()}.
all() ->
    [
       {group, all}
    ].

-spec groups() ->
    [group()].
groups() ->
    [
       {all, [parallel, shuffle], [
           transient_fail,
           permanent_fail
       ]}
    ].

%%
%% starting/stopping
%%
-spec init_per_suite(config()) ->
    config().
init_per_suite(C) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({mg_machine, '_', '_'}, x),
    Apps = mg_ct_helper:start_applications([mg]),
    [{apps, Apps} | C].

-spec end_per_suite(config()) ->
    ok.
end_per_suite(C) ->
    mg_ct_helper:stop_applications(?config(apps, C)).

-spec init_per_group(GroupName :: atom(), config()) ->
    config().
init_per_group(_GroupName, C) ->
    C.

-spec end_per_group(GroupName :: atom(), config()) ->
    ok.
end_per_group(_GroupName, C) ->
    C.

%%
%% tests
%%
-define(req_ctx, <<"req_ctx">>).

-spec transient_fail(config()) ->
    _.
transient_fail(_C) ->
    BinTestName = genlib:to_binary(transient_fail),
    NS = BinTestName,
    ID = BinTestName,
    Options = automaton_options(NS, {intervals, [1000, 1000, 1000, 1000, 1000, 1000, 1000]}),
    Pid = start_automaton(Options),

    ok = mg_machine:start(Options, ID, <<"normal">>, ?req_ctx, mg_deadline:default()),
    0  = mg_machine:call(Options, ID, get, ?req_ctx, mg_deadline:default()),
    ok = mg_machine:call(Options, ID, {set_mode, <<"failing">>}, ?req_ctx, mg_deadline:default()),
    ok = timer:sleep(3000),
    0  = mg_machine:call(Options, ID, get, ?req_ctx, mg_deadline:default()),
    ok = mg_machine:call(Options, ID, {set_mode, <<"counting">>}, ?req_ctx, mg_deadline:default()),
    ok = timer:sleep(3000),
    I  = mg_machine:call(Options, ID, get, ?req_ctx, mg_deadline:default()),
    true = I > 0,

    ok = stop_automaton(Pid).

-spec permanent_fail(config()) ->
    _.
permanent_fail(_C) ->
    BinTestName = genlib:to_binary(permanent_fail),
    NS = BinTestName,
    ID = BinTestName,
    Options = automaton_options(NS, {intervals, [1000]}),
    Pid = start_automaton(Options),

    ok = mg_machine:start(Options, ID, <<"normal">>, ?req_ctx, mg_deadline:default()),
    0  = mg_machine:call(Options, ID, get, ?req_ctx, mg_deadline:default()),
    ok = mg_machine:call(Options, ID, {set_mode, <<"failing">>}, ?req_ctx, mg_deadline:default()),
    ok = timer:sleep(4000),
    {logic, machine_failed} = (catch mg_machine:call(Options, ID, get, ?req_ctx, mg_deadline:default())),

    ok = stop_automaton(Pid).

%%
%% processor
%%
-spec pool_child_spec(_Options, atom()) ->
    supervisor:child_spec().
pool_child_spec(_Options, Name) ->
    #{
        id    => Name,
        start => {?MODULE, start, []}
    }.

-spec process_machine(_Options, mg:id(), mg_machine:processor_impact(), _, _, _, mg_machine:machine_state()) ->
    mg_machine:processor_result() | no_return().
process_machine(_, _, {init, Mode}, _, ?req_ctx, _, null) ->
    {{reply, ok}, build_timer(), [Mode, 0]};
process_machine(_, _, {call, get}, _, ?req_ctx, _, [_Mode, Counter] = State) ->
    {{reply, Counter}, build_timer(), State};
process_machine(_, _, {call, {set_mode, NewMode}}, _, ?req_ctx, _, [_Mode, Counter]) ->
    {{reply, ok}, build_timer(), [NewMode, Counter]};
process_machine(_, _, timeout, _, ?req_ctx, _, [<<"normal">>, _Counter] = State) ->
    {{reply, ok}, build_timer(), State};
process_machine(_, _, timeout, _, ?req_ctx, _, [<<"counting">> = Mode, Counter]) ->
    {{reply, ok}, build_timer(), [Mode, Counter + 1]};
process_machine(_, _, timeout, _, ?req_ctx, _, [<<"failing">>, _Counter]) ->
    erlang:throw({transient, oops}).

%%
%% utils
%%
-spec start()->
    ignore.
start() ->
    ignore.

-spec start_automaton(mg_machine:options()) ->
    pid().
start_automaton(Options) ->
    mg_utils:throw_if_error(mg_machine:start_link(Options)).

-spec stop_automaton(pid()) ->
    ok.
stop_automaton(Pid) ->
    ok = proc_lib:stop(Pid, normal, 5000),
    ok.

-spec automaton_options(mg:ns(), mg_retry:policy()) ->
    mg_machine:options().
automaton_options(NS, RetryPolicy) ->
    Scheduler = #{
        min_scan_delay => 1000,
        target_cutoff  => 15
    },
    #{
        namespace => NS,
        processor => ?MODULE,
        storage   => mg_ct_helper:build_storage(NS, mg_storage_memory),
        worker    => #{
            registry => mg_procreg_gproc
        },
        pulse     => ?MODULE,
        retries   => #{
            timers         => RetryPolicy
        },
        schedulers => #{
            timers         => Scheduler,
            timers_retries => Scheduler,
            overseer       => Scheduler
        }
    }.

-spec handle_beat(_, mg_pulse:beat()) ->
    ok.
handle_beat(_, Beat) ->
    ct:pal("~p", [Beat]).

-spec build_timer() ->
    mg_machine:processor_flow_action().
build_timer() ->
    {wait, genlib_time:unow() + 1, ?req_ctx, 5000}.
