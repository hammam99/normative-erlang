%%% help_with_homework.erl
%%% eFLINT translation using the reusable facts module.

-module(help_with_homework).

-export([run/0]).
-export([ask_for_help_loop/0, help_loop/0, duty_loop/3]).

%%%======================================================================
%%% Schema & type setup
%%%======================================================================

setup_schemas() ->
    %% Placeholders: parent and child are both persons
    facts:register_type(parent, person),
    facts:register_type(child, person),

    %% Fact schemas: only needed for compound facts with named fields
    facts:register_schema(natural_parent,  [parent, child]),
    facts:register_schema(adoptive_parent, [parent, child]),

    %% Derived facts
    %% legal_parent Holds when natural_parent(parent,child)
    %%                     || adoptive_parent(parent,child)
    facts:register_derivation(legal_parent, fun({Parent, Child}) ->
        facts:holds(natural_parent, {Parent, Child})
            orelse facts:holds(adoptive_parent, {Parent, Child})
    end),

    ok.

%%%======================================================================
%%% Act: ask_for_help
%%%   Actor      child
%%%   Recipient  parent
%%%   Creates    help-with-homework(parent, child)
%%%   Holds when legal-parent(parent, child)
%%%======================================================================

ask_for_help_loop() ->
    receive
        {trigger, {Child, Parent}, From} ->
            case facts:holds(legal_parent, {Parent, Child}) of
                false ->
                    From ! {ask_for_help_result, disabled},
                    ask_for_help_loop();
                true ->
                    Pid = spawn(?MODULE, duty_loop,
                                [help_with_homework, {Parent, Child}, false]),
                    facts:register_duty(help_with_homework, {Parent, Child}, Pid),
                    From ! {ask_for_help_result, {enabled, Pid}},
                    ask_for_help_loop()
            end;
        stop ->
            ok
    end.

%%%======================================================================
%%% Act: help
%%%   Actor      parent
%%%   Recipient  child
%%%   Holds when help-with-homework(parent, child)
%%%   Terminates help-with-homework(parent, child)
%%%======================================================================

help_loop() ->
    receive
        {trigger, {Parent, Child}, From} ->
            case facts:lookup_duty(help_with_homework, {Parent, Child}) of
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

%%%======================================================================
%%% Duty: help_with_homework
%%%   Holder     parent
%%%   Claimant   child
%%%   Violated when homework-due(child)
%%%======================================================================

duty_loop(Name = help_with_homework, Args = {_Parent, Child}, Violated) ->
    case get(subscribed) of
        undefined ->
            facts:subscribe(homework_due, self()),
            put(subscribed, true),
            InitViolated = facts:holds(homework_due, Child),
            duty_loop(Name, Args, InitViolated);
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
                    facts:unsubscribe_all(self()),
                    facts:unregister_duty(Name, Args),
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
    case facts:lookup_duty(Name, Args) of
        not_found -> not_found;
        {ok, Pid} ->
            Pid ! {is_violated, self()},
            receive {violated_reply, B} -> B end
    end.

%%%======================================================================
%%% Scenario (matching the eFLINT script)
%%%======================================================================

run() ->
    facts:init(),
    setup_schemas(),

    register(ask_for_help, spawn(?MODULE, ask_for_help_loop, [])),
    register(help,         spawn(?MODULE, help_loop, [])),

    %% Fact person Identified by Alice, Bob, Chloe, David.
    io:format("~n--- Initial facts ---~n"),
    facts:add(person, "Alice"),
    facts:add(person, "Bob"),
    facts:add(person, "Chloe"),
    facts:add(person, "David"),

    %% +natural-parent(Alice, Bob).
    facts:add(natural_parent, {"Alice", "Bob"}),
    %% +adoptive-parent(Chloe, David).
    facts:add(adoptive_parent, {"Chloe", "David"}),

    facts:dump(),

    %% ?legal-parent(Alice, Bob).         → true
    io:format("~nlegal_parent(Alice, Bob)?    ~p~n",
              [facts:holds(legal_parent, {"Alice", "Bob"})]),
    %% ?legal-parent(Chloe, David).       → true
    io:format("legal_parent(Chloe, David)? ~p~n",
              [facts:holds(legal_parent, {"Chloe", "David"})]),
    %% ?!legal-parent(Alice, Chloe).      → false
    io:format("legal_parent(Alice, Chloe)? ~p (expected false)~n",
              [facts:holds(legal_parent, {"Alice", "Chloe"})]),
    %% ?!legal-parent(Alice, David).      → false
    io:format("legal_parent(Alice, David)? ~p (expected false)~n",
              [facts:holds(legal_parent, {"Alice", "David"})]),

    %% ask-for-help(Bob, Alice).
    io:format("~n--- ask_for_help(Bob, Alice) ---~n"),
    io:format("~p~n", [trigger_ask_for_help({"Bob", "Alice"})]),

    %% Violated before deadline?
    io:format("~n--- Violated before deadline? ---~n"),
    io:format("~p~n", [duty_violated(help_with_homework, {"Alice", "Bob"})]),

    %% +homework-due(Bob).
    io:format("~n--- +homework_due(Bob) ---~n"),
    facts:add(homework_due, "Bob"),
    timer:sleep(50),

    %% ?Violated(help-with-homework(Alice,Bob)).
    io:format("Violated now? ~p~n",
              [duty_violated(help_with_homework, {"Alice", "Bob"})]),

    %% help(Alice, Bob).
    io:format("~n--- help(Alice, Bob) ---~n"),
    io:format("~p~n", [trigger_help({"Alice", "Bob"})]),
    timer:sleep(50),

    %% Duty should be gone
    io:format("~n--- Duty lookup after terminate ---~n"),
    io:format("~p~n", [facts:lookup_duty(help_with_homework, {"Alice", "Bob"})]),

    ok.
