%%% voting.erl
%%%
%%% Compile & run:
%%%   erlc voting.erl
%%%   erl -noshell -s voting run -s init stop

-module(voting_try2).

-export([run/0]).
-export([enable_vote_loop/0, cast_vote_loop/0, declare_winner_loop/0,
         cast_vote_duty_loop/1]).


factsbank_init() ->
    ets:new(facts,       [set, public, named_table]),
    ets:new(subscribers, [bag, public, named_table]).

holds(Fact) -> ets:member(facts, Fact).

add_fact(Fact) ->
    case ets:insert_new(facts, {Fact}) of
        true  -> notify(Fact, created);
        false -> ok
    end,
    ok.

terminate_fact(Fact) ->
    case ets:lookup(facts, Fact) of
        []  -> ok;
        [_] ->
            ets:delete(facts, Fact),
            notify(Fact, terminated)
    end,
    ok.

notify(Fact, Change) ->
    Pids = [P || {_, P} <- ets:lookup(subscribers, Fact)],
    [Pid ! {fact_changed, Fact, Change} || Pid <- Pids],
    ok.

%%%======================================================================
%%% Derived facts and helpers
%%%
%%% These correspond to the Holds-when / Derived-from clauses in the
%%% spec. They are recomputed from the ETS table every time; nothing
%%% is cached, so they cannot drift out of sync with the
%%% configuration.
%%%======================================================================

%% Fact has-voted Identified by citizen
%%   Holds when (Exists candidate : vote(citizen, candidate))
has_voted(Citizen) ->
    ets:match(facts, {{vote, Citizen, '_'}}) =/= [].

%% Predicate vote-concluded When (Exists candidate : winner(candidate))
vote_concluded() ->
    ets:match(facts, {{winner, '_'}}) =/= [].

%% Count(Foreach vote : vote.citizen When vote && vote.candidate == C)
count_votes_for(Candidate) ->
    length(ets:match(facts, {{vote, '_', Candidate}})).

%% All candidates in the domain, from the Identified-by clause:
%%   Fact candidate Identified by David, Eve
all_candidates() ->
   ["David", "Eve"].
   % [Name || [Name] <- ets:match(facts, {candidate, '$1'})].


%%%======================================================================
%%% Act: enable-vote
%%%   Actor     administrator
%%%   Recipient citizen
%%%   Conditioned by !voter(citizen) && !vote-concluded()
%%%   Creates   voter(citizen),
%%%             cast-vote-duty(citizen, administrator),
%%%             (Foreach candidate : cast-vote(citizen, administrator,
%%%                                            candidate))
%%%
%%% The `Foreach candidate : cast-vote(...)` post-condition creates
%%% act-instances, which in reference eFLINT means "these specific
%%% cast-vote actions are enabled". In this runtime enablement is
%%% computed live from the precondition by cast_vote_loop, so we do
%%% not materialise one fact per candidate.
%%%
%%% Args convention: {Administrator, Citizen}
%%%======================================================================

enable_vote_loop() ->
    receive
        {trigger, {Admin, Citizen}, From} ->
            Enabled =
                (not holds({voter, Citizen}))
                andalso (not vote_concluded()),
            case Enabled of
                false ->
                    From ! {enable_vote_result, {disabled, Citizen}},
                    enable_vote_loop();
                true ->
                    add_fact({voter, Citizen}),
                    %% Creating the duty fact is what the duty actor
                    %% reacts to; see cast_vote_duty_loop.
                    add_fact({cast_vote_duty, Citizen, Admin}),
                    From ! {enable_vote_result,
                            {enabled, {voter_created, Citizen},
                                      {duty_created, Citizen, Admin}}},
                    enable_vote_loop()
            end;
        stop -> ok
    end.

%%%======================================================================
%%% Act: cast-vote
%%%   Actor     citizen
%%%   Recipient administrator
%%%   Related to candidate
%%%   Conditioned by voter(citizen) && !has-voted(citizen)
%%%   Creates    vote(citizen, candidate)
%%%   Terminates cast-vote-duty(citizen, administrator)
%%%
%%% Args convention: {Citizen, Administrator, Candidate}
%%%======================================================================

cast_vote_loop() ->
    receive
        {trigger, {Citizen, Admin, Candidate}, From} ->
            Enabled =
                holds({voter, Citizen})
                andalso (not has_voted(Citizen)),
            case Enabled of
                false ->
                    From ! {cast_vote_result, {disabled, Citizen, Candidate}},
                    cast_vote_loop();
                true ->
                    add_fact({vote, Citizen, Candidate}),
                    terminate_fact({cast_vote_duty, Citizen, Admin}),
                    From ! {cast_vote_result,
                            {enabled, {vote_created, Citizen, Candidate},
                                      {duty_terminated, Citizen, Admin}}},
                    cast_vote_loop()
            end;
        stop -> ok
    end.

%%%======================================================================
%%% Act: declare-winner
%%%   Actor     administrator
%%%   Recipient candidate
%%%   Conditioned by
%%%     !vote-concluded()
%%%     && (Forall other candidate :
%%%           Count(Foreach vote : vote.citizen
%%%                   When vote && vote.candidate == other candidate) <
%%%           Count(Foreach vote : vote.citizen
%%%                   When vote && vote.candidate == candidate)
%%%         When other candidate != candidate)
%%%   Creates winner(candidate)
%%%
%%% The Forall expands over the finite candidate domain; for each
%%% other candidate we check that their tally is strictly less than
%%% the nominee's.
%%%
%%% Args convention: {Administrator, Candidate}
%%%======================================================================

declare_winner_loop() ->
    receive
        {trigger, {_Admin, Candidate}, From} ->
            MyVotes = count_votes_for(Candidate),
            Others  = [C || C <- all_candidates(), C =/= Candidate],
            StrictlyHigher =
                lists:all(fun(Other) ->
                              count_votes_for(Other) < MyVotes
                          end, Others),
            Enabled = (not vote_concluded()) andalso StrictlyHigher,
            case Enabled of
                false ->
                    From ! {declare_winner_result, {disabled, Candidate}},
                    declare_winner_loop();
                true ->
                    add_fact({winner, Candidate}),
                    From ! {declare_winner_result,
                            {enabled, {winner_created, Candidate}}},
                    declare_winner_loop()
            end;
        stop -> ok
    end.

%%%======================================================================
%%% Duty: cast-vote-duty
%%%   Holder    citizen
%%%   Claimant  administrator
%%%
%%% The spec declares no `Violated when` clause for this duty, so
%%% there is nothing for the duty actor to enforce proactively. It
%%% still runs: it subscribes to its own fact creations and
%%% terminations and logs lifecycle events, which is the hook a duty
%%% WITH a violation clause would use to message its claimant.
%%%
%%% The actor receives fact_changed messages because it registered
%%% itself as a subscriber in `run/0`. In a real deployment you would
%%% subscribe dynamically: when a cast-vote-duty fact appears the
%%% duty actor would also subscribe to whatever facts its violation
%%% clause mentions.
%%%======================================================================

cast_vote_duty_loop(Active) ->
    receive
        {fact_changed, {cast_vote_duty, H, C}, created} ->
            io:format("  [duty cast-vote-duty] active: holder=~p claimant=~p~n",
                      [H, C]),
            cast_vote_duty_loop(sets:add_element({H, C}, Active));
        {fact_changed, {cast_vote_duty, H, C}, terminated} ->
            io:format("  [duty cast-vote-duty] terminated: holder=~p claimant=~p~n",
                      [H, C]),
            cast_vote_duty_loop(sets:del_element({H, C}, Active));
        {is_active, HC, From} ->
            From ! {is_active_result, sets:is_element(HC, Active)},
            cast_vote_duty_loop(Active);
        stop -> ok
    end.

%%%======================================================================
%%% Synchronous wrappers
%%%======================================================================

trigger_enable_vote(Args) ->
    enable_vote_proc ! {trigger, Args, self()},
    receive {enable_vote_result, R} -> R end.

trigger_cast_vote(Args) ->
    cast_vote_proc ! {trigger, Args, self()},
    receive {cast_vote_result, R} -> R end.

trigger_declare_winner(Args) ->
    declare_winner_proc ! {trigger, Args, self()},
    receive {declare_winner_result, R} -> R end.

%% Query helper: would `declare-winner(Candidate)` be enabled right
%% now? Evaluates the precondition without mutating facts. Used for
%% the ?Enabled / ?!Enabled queries in the scenario.
is_declare_winner_enabled(Candidate) ->
    MyVotes = count_votes_for(Candidate),
    Others  = [C || C <- all_candidates(), C =/= Candidate],
    StrictlyHigher = lists:all(fun(O) -> count_votes_for(O) < MyVotes end,
                               Others),
    (not vote_concluded()) andalso StrictlyHigher.

%%%======================================================================
%%% Scenario  (bottom of voting.eflint, lines 55-64)
%%%
%%%   enable-vote(Admin, Alice).
%%%   enable-vote(Admin, Bob).
%%%   enable-vote(Admin, Chloe).
%%%   cast-vote(Alice, Admin, Eve).
%%%   cast-vote(Bob,   Admin, David).
%%%   ?!Enabled(declare-winner()).                  // tied 1-1
%%%   cast-vote(Chloe, Admin, Eve).
%%%   ?!Enabled(declare-winner(candidate=David)).   // David trails
%%%   ?Enabled(declare-winner(candidate=Eve)).      // Eve leads
%%%   declare-winner(candidate=Eve).
%%%======================================================================

run() ->
    factsbank_init(),
    register(enable_vote_proc,    spawn(?MODULE, enable_vote_loop,    [])),
    register(cast_vote_proc,      spawn(?MODULE, cast_vote_loop,      [])),
    register(declare_winner_proc, spawn(?MODULE, declare_winner_loop, [])),

    %% Duty actor, plus subscriptions to the lifecycle of its own
    %% duty facts. `sets:new()` is the initial set of active
    %% (holder, claimant) pairs.
    DutyPid = spawn(?MODULE, cast_vote_duty_loop, [sets:new()]),
    register(cast_vote_duty_proc, DutyPid),
    lists:foreach(
      fun(Citizen) ->
          ets:insert(subscribers,
                     {{cast_vote_duty, Citizen, "Admin"}, DutyPid})
      end,
      ["Alice", "Bob", "Chloe"]),

    Admin = "Admin",

    io:format("~n--- enable-vote(Admin, Alice) ---~n"),
    io:format("~p~n", [trigger_enable_vote({Admin, "Alice"})]),

    io:format("~n--- enable-vote(Admin, Bob) ---~n"),
    io:format("~p~n", [trigger_enable_vote({Admin, "Bob"})]),

    io:format("~n--- enable-vote(Admin, Chloe) ---~n"),
    io:format("~p~n", [trigger_enable_vote({Admin, "Chloe"})]),

    io:format("~n--- cast-vote(Alice, Admin, Eve) ---~n"),
    io:format("~p~n", [trigger_cast_vote({"Alice", Admin, "Eve"})]),

    io:format("~n--- cast-vote(Bob, Admin, David) ---~n"),
    io:format("~p~n", [trigger_cast_vote({"Bob", Admin, "David"})]),

    io:format("~n--- ?!Enabled(declare-winner) after 1-1 tie ---~n"),
    io:format("declare-winner(Eve)   enabled? ~p  (expected false)~n",
              [is_declare_winner_enabled("Eve")]),
    io:format("declare-winner(David) enabled? ~p  (expected false)~n",
              [is_declare_winner_enabled("David")]),

    io:format("~n--- cast-vote(Chloe, Admin, Eve) ---~n"),
    io:format("~p~n", [trigger_cast_vote({"Chloe", Admin, "Eve"})]),

    io:format("~n--- ?!Enabled(declare-winner(David)) ---~n"),
    io:format("declare-winner(David) enabled? ~p  (expected false)~n",
              [is_declare_winner_enabled("David")]),

    io:format("~n--- ?Enabled(declare-winner(Eve)) ---~n"),
    io:format("declare-winner(Eve)   enabled? ~p  (expected true)~n",
              [is_declare_winner_enabled("Eve")]),

    io:format("~n--- declare-winner(Eve) ---~n"),
    io:format("~p~n", [trigger_declare_winner({Admin, "Eve"})]),

    %% Give the duty actor a moment to drain any remaining
    %% fact_changed messages before we dump state.
    timer:sleep(50),

    io:format("~n--- Final facts ---~n"),
    io:format("~p~n", [[F || {F} <- ets:tab2list(facts)]]),

    ok.
