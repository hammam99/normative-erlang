%%% scenario_hwh_pairs.erl
%%%
%%% Experiment A: N independent parent-child pairs, 1 duty cycle each.
%%%
%%% Compile (from erlang/ directory):
%%%   erlc eflint.erl scenario_hwh_pairs.erl
%%% Run:
%%%   time erl -noshell -eval "scenario_hwh_pairs:run(100)" -s init stop

-module(scenario_hwh_pairs).
-export([run/1]).

setup(N) ->
    eflint:register_type(parent, person),
    eflint:register_type(child, person),
    eflint:register_schema(natural_parent, [parent, child]),
    eflint:register_schema(adoptive_parent, [parent, child]),
    eflint:register_derivation(legal_parent,
        fun({Parent, Child}) ->
            eflint:holds(natural_parent, {Parent, Child})
            orelse eflint:holds(adoptive_parent, {Parent, Child})
        end),
    lists:foreach(fun(I) ->
        Parent = "Parent_" ++ integer_to_list(I),
        Child  = "Child_"  ++ integer_to_list(I),
        eflint:add(person, Parent),
        eflint:add(person, Child),
        eflint:add(natural_parent, {Parent, Child})
    end, lists:seq(1, N)).

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

run(N) ->
    eflint:init(),
    setup(N),
    register(ask_for_help, spawn(eflint, act_loop, [ask_for_help_act()])),
    register(help,         spawn(eflint, act_loop, [help_act()])),
    lists:foreach(fun(I) ->
        Parent = "Parent_" ++ integer_to_list(I),
        Child  = "Child_"  ++ integer_to_list(I),
        eflint:trigger(ask_for_help, #{child => Child, parent => Parent}),
        % io:format("Triggered ask_for_help for ~p and ~p~n", [Child, Parent]),
        % io:format("is help enabled now? for ~p and ~p: ~p~n", [Child, Parent,
        %     eflint:act_enabled(ask_for_help, #{child => Child, parent => Parent})]),
        % eflint:dump(duties),
        eflint:trigger(help, #{parent => Parent, child => Child})
    end, lists:seq(1, N)),
    ok.
