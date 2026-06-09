%%% scenario_help_with_homework.erl
%%%
%%% eFLINT help_with_homework translated to Erlang.
%%%
%%% Compile & run:
%%%   erlc eflint.erl scenario_help_with_homework.erl
%%%   erl -noshell -s scenario_help_with_homework run -s init stop
%%%   erl -noshell -s scenario_help_with_homework run_silent -s init stop

-module(scenario_help_with_homework).

-export([run/0, run_silent/0, run_big/0]).

%%%======================================================================
%%% Fact & type declarations
%%%======================================================================

setup() ->
    %% Placeholder parent For person
    %% Placeholder child  For person
    eflint:register_type(parent, person),
    eflint:register_type(child, person),

    %% Schemas for compound facts
    eflint:register_schema(natural_parent, [parent, child]),
    eflint:register_schema(adoptive_parent, [parent, child]),

    %% Derived fact: legal-parent Holds when adoptive-parent || natural-parent
    eflint:register_derivation(legal_parent,
                               fun({Parent, Child}) ->
                                  eflint:holds(natural_parent, {Parent, Child})
                                  orelse eflint:holds(adoptive_parent, {Parent, Child})
                               end),

    %% Initial facts
    eflint:add(person, "Alice"),
    eflint:add(person, "Bob"),
    eflint:add(person, "Chloe"),
    eflint:add(person, "David"),

    %% +natural-parent(Alice, Bob)
    eflint:add(natural_parent, {"Alice", "Bob"}),
    %% +adoptive-parent(Chloe, David)
    eflint:add(adoptive_parent, {"Chloe", "David"}),

    ok.

%%%======================================================================
%%% Act declarations
%%%======================================================================

%% Act ask-for-help
%%   Actor child
%%   Recipient parent
%%   Holds when legal-parent(parent, child)
%%   Creates help-with-homework(parent, child)   ← duty
ask_for_help_act() ->
    #{name => ask_for_help,
      actor => child,
      recipient => parent,
      holds_when =>
          fun(#{child := Child, parent := Parent}) -> eflint:holds(legal_parent, {Parent, Child})
          end,
      creates_duty =>
          fun(#{child := Child, parent := Parent}) -> help_with_homework_duty(Parent, Child) end}.

%% Act help
%%   Actor parent
%%   Recipient child
%%   Holds when help-with-homework(parent, child)   ← duty exists
%%   Terminates help-with-homework(parent, child)    ← duty
help_act() ->
    #{name => help,
      actor => parent,
      recipient => child,
      holds_when =>
          fun(#{parent := Parent, child := Child}) ->
             eflint:lookup_duty({help_with_homework, Parent, Child}) =/= not_found
          end,
      terminates_duty =>
          fun(#{parent := Parent, child := Child}) -> {help_with_homework, Parent, Child} end}.

%%%======================================================================
%%% Duty declarations
%%%======================================================================

%% Duty help-with-homework
%%   Holder parent
%%   Claimant child
%%   Violated when homework-due(child)
help_with_homework_duty(Parent, Child) ->
    #{name => help_with_homework,
      holder => {parent, Parent},
      claimant => {child, Child},
      violated_when => fun() -> eflint:holds(homework_due, Child) end,
      subscribes_to => [{homework_due, Child}]
      }.

%%%======================================================================
%%% Scenario
%%%======================================================================

run() ->
    eflint:init(),
    setup(),

    %% Spawn act processes
    register(ask_for_help, spawn(eflint, act_loop, [ask_for_help_act()])),
    register(help, spawn(eflint, act_loop, [help_act()])),

    io:format("~n--- Initial facts ---~n"),
    eflint:dump(),

    %% ?legal-parent(Alice, Bob).         → true
    io:format("~nlegal_parent(Alice, Bob)?    ~p~n",
              [eflint:holds(legal_parent, {"Alice", "Bob"})]),
    %% ?legal-parent(Chloe, David).       → true
    io:format("legal_parent(Chloe, David)? ~p~n",
              [eflint:holds(legal_parent, {"Chloe", "David"})]),
    %% ?!legal-parent(Alice, Chloe).      → false
    io:format("legal_parent(Alice, Chloe)? ~p (expected false)~n",
              [eflint:holds(legal_parent, {"Alice", "Chloe"})]),
    %% ?!legal-parent(Alice, David).      → false
    io:format("legal_parent(Alice, David)? ~p (expected false)~n",
              [eflint:holds(legal_parent, {"Alice", "David"})]),

    %% ask-for-help(Bob, Alice)
    io:format("~n--- ask-for-help(Bob, Alice) ---~n"),
    io:format("~p~n", [eflint:trigger(ask_for_help, #{child => "Bob", parent => "Alice"})]),

    %% Before homework deadline — not violated
    io:format("~nViolated before deadline? ~p~n",
              [eflint:is_violated({help_with_homework, "Alice", "Bob"})]),

    %% +homework-due(Bob)
    io:format("~n--- +homework_due(Bob) ---~n"),
    eflint:add(homework_due, "Bob"),

    %% ?Violated(help-with-homework(Alice, Bob))
    io:format("Violated now? ~p~n",
              [eflint:is_violated({help_with_homework, "Alice", "Bob"})]),

    %% help(Alice, Bob)
    io:format("~n--- help(Alice, Bob) ---~n"),
    io:format("~p~n", [eflint:trigger(help, #{parent => "Alice", child => "Bob"})]),

    %% Duty should be gone
    io:format("~nDuty after help? ~p~n",
              [eflint:lookup_duty({help_with_homework, "Alice", "Bob"})]),

    io:format("~n--- help(Alice, Bob) should be disabled ---~n"),
    io:format("~p~n", [eflint:trigger(help, #{parent => "Alice", child => "Bob"})]),
    io:format("~p~n", [eflint:act_enabled(help, #{parent => "Alice", child => "Bob"})]),

    io:format("~n--- Final facts ---~n"),
    eflint:dump(),

    ok.

run_silent() ->
    eflint:init(),
    setup(),

    register(ask_for_help, spawn(eflint, act_loop, [ask_for_help_act()])),
    register(help, spawn(eflint, act_loop, [help_act()])),

    eflint:holds(legal_parent, {"Alice", "Bob"}),
    eflint:holds(legal_parent, {"Chloe", "David"}),
    eflint:holds(legal_parent, {"Alice", "Chloe"}),
    eflint:holds(legal_parent, {"Alice", "David"}),

    eflint:trigger(ask_for_help, #{child => "Bob", parent => "Alice"}),
    eflint:is_violated({help_with_homework, "Alice", "Bob"}),

    eflint:add(homework_due, "Bob"),
    eflint:is_violated({help_with_homework, "Alice", "Bob"}),

    eflint:trigger(help, #{parent => "Alice", child => "Bob"}),
    eflint:lookup_duty({help_with_homework, "Alice", "Bob"}),

    ok.

run_big() ->
    eflint:init(),
    setup(),

    register(ask_for_help, spawn(eflint, act_loop, [ask_for_help_act()])),
    register(help,         spawn(eflint, act_loop, [help_act()])),

    %% Generate 1000 parent-child pairs
    lists:foreach(fun(I) ->
        Parent = "Parent_" ++ integer_to_list(I),
        Child  = "Child_"  ++ integer_to_list(I),
        eflint:add(person, Parent),
        eflint:add(person, Child),
        eflint:add(natural_parent, {Parent, Child})
    end, lists:seq(1, 1000)),

    %% For each pair: ask-for-help, add homework_due, then help
    lists:foreach(fun(I) ->
        Parent = "Parent_" ++ integer_to_list(I),
        Child  = "Child_"  ++ integer_to_list(I),
        eflint:trigger(ask_for_help, #{child => Child, parent => Parent}),
        io:format("[~s] violated after ask-for-help? ~p~n",
            [Child, eflint:is_violated({help_with_homework, Parent, Child})]),
        % eflint:add(homework_due, Child),
        eflint:trigger(help, #{parent => Parent, child => Child}),
        io:format("[~s] duty after help? ~p~n",
            [Child, eflint:lookup_duty({help_with_homework, Parent, Child})])
    end, lists:seq(1, 1000)),

    % io:format("~n--- Final facts (big) ---~n"),
    % eflint:dump(),

    ok.
