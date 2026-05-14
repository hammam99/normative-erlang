%%% help_with_homework.erl
%%%

-module(help_with_homework).


-export([run/0]).
-export([ask_for_help_loop/0, help_loop/0, duty_loop/3]).


%% Let's see types later
% -type person() :: string().
% -type parent() :: person().
% -type child() :: person().
% % In eFLINT a fact can be data unit or identefied by a tuple of data GENERAL
% -type fact() :: atom() | tuple().

factsbank_init() ->
  ets:new(facts,       [set, public, named_table]),
  ets:new(subscribers, [bag, public, named_table]),
  ets:new(duties,      [set, public, named_table]).

holds(Fact) -> ets:member(facts, Fact).

%% {Fact, Arguments}
add_fact(Fact) ->
    case ets:insert_new(facts, {Fact}) of
        true  -> notify(Fact, created);
        false -> ok      %% fact already held — no change, no notification
    end,
    ok.

terminate_fact(Fact) ->
    case ets:lookup(facts, Fact) of
        [] ->
            ok;          %% didn't hold — paper says this is a no-op
        [_] ->
            ets:delete(facts, Fact),
            notify(Fact, terminated)
    end,
    ok.

subscribe(FactKey, Pid) ->
    ets:insert(subscribers, {FactKey, Pid}),
    ok.

%% do this after a duty is terminated for example
unsubscribe_all(Pid) ->
    ets:match_delete(subscribers, {'_', Pid}),
    ok.
 
notify(Fact, Change) ->
    Pids = [P || {_, P} <- ets:lookup(subscribers, Fact)],
    [Pid ! {fact_changed, Fact, Change} || Pid <- Pids],
    ok.


register_duty(Name, Args, Pid) -> ets:insert(duties, {{Name, Args}, Pid}).

unregister_duty(Name, Args) -> ets:delete(duties, {Name, Args}).
 
lookup_duty(Name, Args) ->
    case ets:lookup(duties, {Name, Args}) of
        [{_, Pid}] -> {ok, Pid};
        []         -> not_found
    end.

%%% Act: ask_for_help
%%%   Actor     child
%%%   Recipient parent
%%%   Holds when legal-parent(parent, child)
%%%   Creates help-with-homework(parent, child)
ask_for_help_loop() ->
    % io:format("ask_for_help accessed~n"),
    receive
        {trigger, {Child, Parent}, From} ->
            io:format("i'm triggerd~n"),
            case legal_parent(Parent, Child) of
                false ->
                    io:format("i'm fals~n"),
                    From ! {ask_for_help_result, disabled},
                    ask_for_help_loop();
                true ->
                    io:format("trying to create duty~n"),
                    Pid = spawn(?MODULE, duty_loop,
                                [help_with_homework, {Parent, Child}, false]),
                    register_duty(help_with_homework, {Parent, Child}, Pid),
                    From ! {ask_for_help_result, {enabled, Pid}},
                    ask_for_help_loop()
            end;
        stop ->
            ok;
        _ ->
          io:format("I don't know what to do~n")

    end.


legal_parent(Parent, Child) ->
    holds({natural_parent, Parent, Child})
        orelse holds({adoptive_parent, Parent, Child}).

%%% Act: help
%%%   Actor     parent
%%%   Recipient child
%%%   Holds when help-with-homework(parent, child)
%%%   Terminates help-with-homework(parent, child)
help_loop() ->
    receive
        {trigger, {Parent, Child}, From} ->
            case lookup_duty(help_with_homework, {Parent, Child}) of
                not_found ->
                    From ! {help_result, disabled},
                    help_loop();
                {ok, DutyPid} ->
                    DutyPid ! terminate,
                    From ! {help_result, {enabled, duty_terminated}},
                    help_loop()
            end;
        stop ->
            ok
    end.

%%% Duty: help_with_homework
%%%   Violated when homework-due(child)
%%%
%%% On spawn, the duty subscribes to the facts its violation condition
%%% depends on. It then receives push notifications and updates its
%%% local Violated state. No polling. The is_violated call just reads
%%% the duty's current state — no ETS lookup required.

duty_loop(Name = help_with_homework, Args = {_Parent, Child}, Violated) ->
    %% Subscribe exactly once, on first entry.
    case get(subscribed) of
        undefined ->
            subscribe({homework_due, Child}, self()),
            put(subscribed, true),
            %% Seed Violated from the current configuration in case the
            %% fact already held at spawn time.
            duty_loop(Name, Args, holds({homework_due, Child}));
        true ->
            receive
                {fact_changed, {homework_due, C}, created} when C =:= Child ->
                    io:format("  [duty ~p] became violated~n", [Args]),
                    duty_loop(Name, Args, true);
                {fact_changed, {homework_due, C}, terminated} when C =:= Child ->
                    io:format("  [duty ~p] no longer violated~n", [Args]),
                    duty_loop(Name, Args, false);
                {is_violated, From} ->
                    From ! {violated_reply, Violated},
                    duty_loop(Name, Args, Violated);
                terminate ->
                    unsubscribe_all(self()),
                    unregister_duty(Name, Args),
                    io:format("  [duty ~p] terminated~n", [Args]),
                    ok
            end
    end.
 
%%%======================================================================
%%% Synchronous wrappers
%%%======================================================================
 
trigger_ask_for_help(Args) ->
    ask_for_help ! {trigger, Args, self()},
    receive {ask_for_help_result, R} -> R end.
 
trigger_help(Args) ->
    help ! {trigger, Args, self()},
    receive {help_result, R} -> R end.
 
duty_violated(Name, Args) ->
    case lookup_duty(Name, Args) of
      not_found -> not_found;
      {ok, Pid} -> 
        Pid ! {is_violated, self()},
        receive {violated_reply, B} -> B end 
    end.
 
%%%======================================================================
%%% Scenario (Figure 5)
%%%======================================================================
 
run() ->
    factsbank_init(),
    register(ask_for_help, spawn(?MODULE, ask_for_help_loop, [])),
    register(help,         spawn(?MODULE, help_loop, [])),
 
    io:format("~n--- Initial facts ---~n"),
    add_fact({natural_parent, "alice", "bob"}),
    add_fact({adoptive_parent, "chloe", "david"}),

 
    io:format("~n--- ask_for_help(bob, alice) ---~n"),
    {enabled, DutyPid} = trigger_ask_for_help({"bob", "alice"}),
    % timer:sleep(20),  %% let duty finish its initial subscribe
 
    io:format("~n--- Violated before deadline? ---~n"),
    io:format("~p~n", [duty_violated(help_with_homework, {"alice", "bob"})]),
 
    io:format("~n--- +homework_due(bob) (push: duty gets notified) ---~n"),
    add_fact({homework_due, "bob"}),
    % timer:sleep(20),
    % io:format("Violated now? ~p~n", [duty_violated(DutyPid)]),
    io:format("Violated now? ~p~n", [duty_violated(help_with_homework, {"alice", "bob"})]),
 
    io:format("~n--- Demonstrating retraction: -homework_due(bob) ---~n"),
    terminate_fact({homework_due, "bob"}),
    % timer:sleep(20),
    io:format("Violated now? ~p~n", [duty_violated(help_with_homework, {"alice", "bob"})]),
 
    io:format("~n--- help(alice, bob) ---~n"),
    io:format("~p~n", [trigger_help({"alice", "bob"})]),
    % timer:sleep(20),
 
    io:format("~n--- Duty lookup after terminate ---~n"),
    io:format("~p~n", [lookup_duty(help_with_homework, {"alice", "bob"})]),
 
    ok.
