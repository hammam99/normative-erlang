%%% scenario_hwh_duties.erl
%%%
%%% Experiment B: 1 parent with M children — M duties alive simultaneously.
%%%
%%% Compile (from erlang/ directory):
%%%   erlc eflint.erl scenario_hwh_duties.erl
%%% Run:
%%%   time erl -noshell -eval "scenario_hwh_duties:run(100)" -s init stop

-module(scenario_hwh_duties).
-export([run/1]).

setup(M) ->
    eflint:register_type(parent, person),
    eflint:register_type(child, person),
    eflint:register_schema(natural_parent, [parent, child]),
    eflint:register_schema(adoptive_parent, [parent, child]),
    eflint:register_derivation(legal_parent,
        fun({Parent, Child}) ->
            eflint:holds(natural_parent, {Parent, Child})
            orelse eflint:holds(adoptive_parent, {Parent, Child})
        end),
    eflint:add(person, "Parent"),
    lists:foreach(fun(I) ->
        Child = "Child_" ++ integer_to_list(I),
        eflint:add(person, Child),
        eflint:add(natural_parent, {"Parent", Child})
    end, lists:seq(1, M)).

ask_for_help_act() ->
    #{name => ask_for_help,
      actor => child,
      recipient => parent,
      holds_when =>
          fun(#{child := Child, parent := Parent}) ->
              eflint:holds(legal_parent, {Parent, Child})
          end,
      creates_duty =>
          fun(#{child := Child, parent := Parent}) ->
              help_with_homework_duty(Parent, Child)
          end}.

help_act() ->
    #{name => help,
      actor => parent,
      recipient => child,
      holds_when =>
          fun(#{parent := Parent, child := Child}) ->
              eflint:lookup_duty({help_with_homework, Parent, Child}) =/= not_found
          end,
      terminates_duty =>
          fun(#{parent := Parent, child := Child}) ->
              {help_with_homework, Parent, Child}
          end}.

help_with_homework_duty(Parent, Child) ->
    #{name => help_with_homework,
      holder        => {parent, Parent},
      claimant      => {child, Child},
      violated_when => fun() -> eflint:holds(homework_due, Child) end,
      subscribes_to => [{homework_due, Child}]}.

run(M) ->
    eflint:init(),
    setup(M),
    register(ask_for_help, spawn(eflint, act_loop, [ask_for_help_act()])),
    register(help,         spawn(eflint, act_loop, [help_act()])),
    %% Phase 1: create all M duties simultaneously
    lists:foreach(fun(I) ->
        Child = "Child_" ++ integer_to_list(I),
        eflint:trigger(ask_for_help, #{child => Child, parent => "Parent"})
    end, lists:seq(1, M)),
    %% Phase 2: add homework_due for each child
    lists:foreach(fun(I) ->
        Child = "Child_" ++ integer_to_list(I),
        eflint:add(homework_due, Child)
    end, lists:seq(1, M)),
    %% Phase 3: terminate all duties
    lists:foreach(fun(I) ->
        Child = "Child_" ++ integer_to_list(I),
        eflint:trigger(help, #{parent => "Parent", child => Child})
    end, lists:seq(1, M)),
    ok.
