%%% scenario_voting.erl (scalable, Experiment C)
%%%
%%% Experiment C: N voters.
%%% Tests: N duty creations, N act triggers with conditioned_by checks,
%%%
%%% Compile (from erlang/ directory):
%%%   erlc eflint.erl scenario_voting.erl
%%% Run:
%%%   time erl -noshell -eval "scenario_voting:run(100)" -s init stop

-module(scenario_voting).
-export([run/1]).

setup(N) ->
    eflint:register_type(other_candidate, candidate),
    eflint:register_schema(vote, [citizen, candidate]),
    eflint:add(candidate, "David"),
    eflint:add(candidate, "Eve"),
    eflint:add(administrator, "Admin"),
    eflint:register_derivation(has_voted, fun(Citizen) ->
        eflint:exists(vote, [{citizen, Citizen}])
    end),
    eflint:register_predicate(vote_concluded, fun() ->
        eflint:all(winner) =/= []
    end),
    lists:foreach(fun(I) ->
        Citizen = "Citizen_" ++ integer_to_list(I),
        eflint:add(citizen, Citizen)
    end, lists:seq(1, N)).

cast_vote_act() -> #{
    name => cast_vote,
    actor => citizen,
    recipient => administrator,
    related_to => candidate,
    conditioned_by => fun(#{citizen := Citizen}) ->
        eflint:holds(voter, Citizen)
            andalso not eflint:holds(has_voted, Citizen)
    end,
    creates => fun(#{citizen := Citizen, candidate := Candidate}) ->
        [{vote, {Citizen, Candidate}}]
    end,
    terminates_duty => fun(#{citizen := Citizen, administrator := Admin}) ->
        {cast_vote_duty, Citizen, Admin}
    end
}.

enable_vote_act() -> #{
    name => enable_vote,
    actor => administrator,
    recipient => citizen,
    conditioned_by => fun(#{citizen := Citizen}) ->
        not eflint:holds(voter, Citizen)
            andalso not eflint:holds_predicate(vote_concluded)
    end,
    creates => fun(#{citizen := Citizen}) ->
        [{voter, Citizen}]
    end,
    creates_duty => fun(#{citizen := Citizen, administrator := Admin}) ->
        cast_vote_duty(Admin, Citizen)
    end
}.

declare_winner_act() -> #{
    name => declare_winner,
    actor => administrator,
    recipient => candidate,
    conditioned_by => fun(#{candidate := Candidate}) ->
        not eflint:holds_predicate(vote_concluded)
            andalso begin
                CandVotes = eflint:count(vote, fun(V) ->
                    eflint:get_field(candidate, V) =:= Candidate
                end),
                Others = [C || {candidate, C} <- eflint:all(candidate), C =/= Candidate],
                lists:all(fun(Other) ->
                    OtherVotes = eflint:count(vote, fun(V) ->
                        eflint:get_field(candidate, V) =:= Other
                    end),
                    OtherVotes < CandVotes
                end, Others)
            end
    end,
    creates => fun(#{candidate := Candidate}) ->
        [{winner, Candidate}]
    end
}.

cast_vote_duty(Admin, Citizen) -> #{
    name     => cast_vote_duty,
    holder   => {citizen, Citizen},
    claimant => {administrator, Admin}
}.

run(N) ->
    eflint:init(),
    setup(N),
    register(cast_vote,      spawn(eflint, act_loop, [cast_vote_act()])),
    register(enable_vote,    spawn(eflint, act_loop, [enable_vote_act()])),
    register(declare_winner, spawn(eflint, act_loop, [declare_winner_act()])),
    %% Enable voting for each citizen
    lists:foreach(fun(I) ->
        Citizen = "Citizen_" ++ integer_to_list(I),
        eflint:trigger(enable_vote, #{administrator => "Admin", citizen => Citizen})
    end, lists:seq(1, N)),
    %% All citizens vote for Eve (Eve wins N-0)
    lists:foreach(fun(I) ->
        Citizen = "Citizen_" ++ integer_to_list(I),
        eflint:trigger(cast_vote, #{
            citizen       => Citizen,
            administrator => "Admin",
            candidate     => "Eve"
        })
    end, lists:seq(1, N)),
    %% Declare winner
    eflint:trigger(declare_winner, #{
        administrator => "Admin",
        candidate     => "Eve"
    }),
    io:format("Created ~p voters, cast ~p votes~n", [N, length(eflint:all(vote))]),
    % eflint:dump(facts),
    ok.
