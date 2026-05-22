%%% scenario_voting.erl
%%%
%%% eFLINT voting example translated to Erlang.
%%%
%%% Compile & run:
%%%   erlc eflint.erl scenario_voting.erl
%%%   erl -noshell -s scenario_voting run -s init stop

-module(scenario_voting).

-export([run/0]).

%%%======================================================================
%%% Fact & type declarations
%%%======================================================================

setup() ->
    %% Placeholder other_candidate For candidate
    eflint:register_type(other_candidate, candidate),

    %% Schema for compound facts
    eflint:register_schema(vote, [citizen, candidate]),

    %% Fact citizen Identified by Alice, Bob, Chloe
    eflint:add(citizen, "Alice"),
    eflint:add(citizen, "Bob"),
    eflint:add(citizen, "Chloe"),

    %% Fact candidate Identified by David, Eve
    eflint:add(candidate, "David"),
    eflint:add(candidate, "Eve"),

    %% Fact administrator Identified by Admin
    eflint:add(administrator, "Admin"),

    %% Fact has-voted Identified by citizen
    %%   Holds when (Exists candidate : vote(citizen, candidate))
    eflint:register_derivation(has_voted, fun(Citizen) ->
        eflint:exists(vote, [{citizen, Citizen}])
    end),

    %% Predicate vote-concluded When (Exists candidate : winner(candidate))
    eflint:register_predicate(vote_concluded, fun() ->
        eflint:all(winner) =/= []
    end),

    ok.

%%%======================================================================
%%% Act declarations
%%%======================================================================

%% Act cast-vote
%%   Actor citizen
%%   Recipient administrator
%%   Related to candidate
%%   Conditioned by voter(citizen) && !has-voted(citizen)
%%   Creates vote(citizen, candidate)
%%   Terminates cast-vote-duty(citizen, administrator)
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

%% Act enable-vote
%%   Actor administrator
%%   Recipient citizen
%%   Conditioned by !voter(citizen) && !vote-concluded()
%%   Creates voter(citizen),
%%           cast-vote-duty(citizen, administrator),
%%           (Foreach candidate : cast-vote(citizen, administrator, candidate))
%%
%% Note: the Foreach creates enabled act-instances as facts. In our model,
%% act enablement is checked dynamically by the act process, so we only
%% need to create the voter fact and the duty.
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

%% Act declare-winner
%%   Actor administrator
%%   Recipient candidate
%%   Conditioned by
%%       !vote-concluded()
%%    && (Forall other_candidate :
%%          Count(votes for other_candidate) < Count(votes for candidate)
%%        When other_candidate != candidate)
%%   Creates winner(candidate)
declare_winner_act() -> #{
    name => declare_winner,
    actor => administrator,
    recipient => candidate,
    conditioned_by => fun(#{candidate := Candidate}) ->
        not eflint:holds_predicate(vote_concluded)
            andalso begin
                CandidateVotes = eflint:count(vote, fun(V) ->
                    eflint:get_field(candidate, V) =:= Candidate
                end),
                Others = [C || {candidate, C} <- eflint:all(candidate), C =/= Candidate],
                lists:all(fun(Other) ->
                    OtherVotes = eflint:count(vote, fun(V) ->
                        eflint:get_field(candidate, V) =:= Other
                    end),
                    OtherVotes < CandidateVotes
                end, Others)
            end
    end,
    creates => fun(#{candidate := Candidate}) ->
        [{winner, Candidate}]
    end
}.

%%%======================================================================
%%% Duty declarations
%%%======================================================================

%% Duty cast-vote-duty
%%   Holder citizen
%%   Claimant administrator
%%   (No violated_when specified in the spec — defaults to never violated)
cast_vote_duty(Admin, Citizen) -> #{
    name => cast_vote_duty,
    holder => {citizen, Citizen},
    claimant => {administrator, Admin}
}.

%%%======================================================================
%%% Scenario
%%%======================================================================

run() ->
    eflint:init(),
    setup(),

    %% Spawn act processes
    register(cast_vote,      spawn(eflint, act_loop, [cast_vote_act()])),
    register(enable_vote,    spawn(eflint, act_loop, [enable_vote_act()])),
    register(declare_winner, spawn(eflint, act_loop, [declare_winner_act()])),

    io:format("~n=== Voting Scenario ===~n"),
    eflint:dump(),

    %% enable-vote(Admin, Alice)
    io:format("~n--- enable-vote(Admin, Alice) ---~n"),
    io:format("~p~n", [eflint:trigger(enable_vote, #{
        administrator => "Admin",
        citizen => "Alice"
    })]),

    %% enable-vote(Admin, Bob)
    io:format("~n--- enable-vote(Admin, Bob) ---~n"),
    io:format("~p~n", [eflint:trigger(enable_vote, #{
        administrator => "Admin",
        citizen => "Bob"
    })]),

    %% enable-vote(Admin, Chloe)
    io:format("~n--- enable-vote(Admin, Chloe) ---~n"),
    io:format("~p~n", [eflint:trigger(enable_vote, #{
        administrator => "Admin",
        citizen => "Chloe"
    })]),

    %% cast-vote(Alice, Admin, Eve)
    io:format("~n--- cast-vote(Alice, Admin, Eve) ---~n"),
    io:format("~p~n", [eflint:trigger(cast_vote, #{
        citizen => "Alice",
        administrator => "Admin",
        candidate => "Eve"
    })]),

    %% cast-vote(Bob, Admin, David)
    io:format("~n--- cast-vote(Bob, Admin, David) ---~n"),
    io:format("~p~n", [eflint:trigger(cast_vote, #{
        citizen => "Bob",
        administrator => "Admin",
        candidate => "David"
    })]),

    %% ?!Enabled(declare-winner()) — no candidate has majority yet
    io:format("~n--- Try declare-winner(Admin, David) — should be disabled ---~n"),
    io:format("~p~n", [eflint:trigger(declare_winner, #{
        administrator => "Admin",
        candidate => "David"
    })]),
    io:format("--- Try declare-winner(Admin, Eve) — should be disabled (tied) ---~n"),
    io:format("~p~n", [eflint:trigger(declare_winner, #{
        administrator => "Admin",
        candidate => "Eve"
    })]),

    %% cast-vote(Chloe, Admin, Eve) — Eve now has 2 votes, David has 1
    io:format("~n--- cast-vote(Chloe, Admin, Eve) ---~n"),
    io:format("~p~n", [eflint:trigger(cast_vote, #{
        citizen => "Chloe",
        administrator => "Admin",
        candidate => "Eve"
    })]),

    %% ?!Enabled(declare-winner(candidate=David)) — David lost
    io:format("~n--- Try declare-winner(Admin, David) — should fail ---~n"),
    io:format("~p~n", [eflint:trigger(declare_winner, #{
        administrator => "Admin",
        candidate => "David"
    })]),

    %% ?Enabled(declare-winner(candidate=Eve)) — Eve wins
    io:format("--- declare-winner(Admin, Eve) — should succeed ---~n"),
    io:format("~p~n", [eflint:trigger(declare_winner, #{
        administrator => "Admin",
        candidate => "Eve"
    })]),


    io:format("~n--- Final state ---~n"),
    io:format("winner? ~p~n", [eflint:all(winner)]),
    io:format("vote-concluded? ~p~n", [eflint:holds_predicate(vote_concluded)]),
    eflint:dump(),

    ok.
