#!/usr/bin/env python3
"""
generate_experiments.py

Generates all scenario files for scalability experiments A, B, and C.

Output layout:
  eflint/exp_a_{N}.eflint  — Exp A: N independent parent-child pairs
  eflint/exp_b_{M}.eflint  — Exp B: 1 parent with M children (M duties)
  eflint/exp_c_{N}.eflint  — Exp C: N voters
  erlang/eflint.erl                   — copy of runtime, for compiling in-place
  erlang/scenario_hwh_pairs.erl       — Exp A parameterised by N
  erlang/scenario_hwh_duties.erl      — Exp B parameterised by M
  erlang/scenario_voting.erl          — Exp C parameterised by N

Compile Erlang scenarios from the erlang/ directory:
  cd erlang && erlc eflint.erl scenario_hwh_pairs.erl scenario_hwh_duties.erl scenario_voting.erl

Run (examples):
  time erl -noshell -eval "scenario_hwh_pairs:run(100)"  -s init stop
  time erl -noshell -eval "scenario_hwh_duties:run(100)" -s init stop
"""

import os
import shutil

# SIZES = [50, 100, 150, 200, 250, 300, 350, 400, 450, 500]
SIZES = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

os.makedirs("eflint", exist_ok=True)
os.makedirs("erlang", exist_ok=True)


# =============================================================================
# eFLINT shared headers
# =============================================================================

HWH_HEADER = """\
Fact person Identified by String
Placeholder parent    For person
Placeholder child     For person

Fact natural-parent   Identified by parent * child
Fact adoptive-parent  Identified by parent * child
Fact legal-parent     Identified by parent * child
  Holds when adoptive-parent(parent,child)
          || natural-parent(parent,child)

Act ask-for-help
  Actor      child
  Recipient  parent
  Creates    help-with-homework(parent,child)
  Holds when legal-parent(parent,child)

Fact homework-due Identified by child

Duty help-with-homework
  Holder        parent
  Claimant      child
  Violated when homework-due(child)

Act help
  Actor      parent
  Recipient  child
  Terminates help-with-homework(parent,child)
  Holds when help-with-homework(parent,child).

"""

VOTING_HEADER = """\
Fact citizen       Identified by String
Fact candidate     Identified by David, Eve
Fact administrator Identified by Admin
Fact voter         Identified by citizen
Fact winner        Identified by candidate
Fact vote          Identified by citizen * candidate

Placeholder other candidate For candidate

Duty cast-vote-duty Holder citizen Claimant administrator

Fact has-voted Identified by citizen
  Holds when (Exists candidate : vote(citizen,candidate))

Predicate vote-concluded When (Exists candidate : winner(candidate))

Act cast-vote
  Actor citizen
  Recipient administrator
  Related to candidate
  Conditioned by voter(citizen) && !has-voted(citizen)
  Creates vote(citizen,candidate)
  Terminates cast-vote-duty(citizen,administrator)

Act enable-vote
  Actor administrator
  Recipient citizen
  Conditioned by !voter(citizen) && !vote-concluded()
  Creates voter(citizen),
          cast-vote-duty(citizen,administrator),
          (Foreach candidate : cast-vote(citizen,administrator,candidate))

Act declare-winner
  Actor administrator
  Recipient candidate
  Conditioned by
      !vote-concluded()
   && (Forall other candidate :
         Count(Foreach vote : vote.citizen
                 When vote && vote.candidate == other candidate) <
         Count(Foreach vote : vote.citizen
                 When vote && vote.candidate == candidate)
        When other candidate != candidate)
  Creates winner(candidate).

+enable-vote.
+cast-vote.
+declare-winner.

"""


# =============================================================================
# eFLINT generators
# =============================================================================

def eflint_exp_a(n):
    """N independent parent-child pairs: ask-for-help then help for each."""
    lines = [HWH_HEADER]

    parents  = [f"Parent{i}" for i in range(1, n + 1)]
    children = [f"Child{i}"  for i in range(1, n + 1)]

    lines.append("Fact person Identified by " + ", ".join(parents)  + ".")
    lines.append("Extend Fact person Identified by " + ", ".join(children) + ".")
    lines.append("")

    for i in range(1, n + 1):
        lines.append(f"+natural-parent(Parent{i}, Child{i}).")
    lines.append("")

    for i in range(1, n + 1):
        lines.append(f"ask-for-help(Child{i}, Parent{i}).")
    lines.append("")

    for i in range(1, n + 1):
        lines.append(f"help(Parent{i}, Child{i}).")

    return "\n".join(lines) + "\n"


def eflint_exp_b(m):
    """1 parent, M children: create all M duties, add homework-due for all, then help for all.
    In the Erlang runtime each add(homework-due) notifies every live duty process, so the
    notification phase is O(M^2) total — the key architectural bottleneck."""
    lines = [HWH_HEADER]

    children = [f"Child{i}" for i in range(1, m + 1)]

    lines.append("Fact person Identified by Parent.")
    lines.append("Extend Fact person Identified by " + ", ".join(children) + ".")
    lines.append("")

    for i in range(1, m + 1):
        lines.append(f"+natural-parent(Parent, Child{i}).")
    lines.append("")

    # Create all M duties first
    for i in range(1, m + 1):
        lines.append(f"ask-for-help(Child{i}, Parent).")
    lines.append("")

    # Add homework-due for every child (all M duties still alive)
    for i in range(1, m + 1):
        lines.append(f"+homework-due(Child{i}).")
    lines.append("")

    # Terminate all duties
    for i in range(1, m + 1):
        lines.append(f"help(Parent, Child{i}).")

    return "\n".join(lines) + "\n"


def eflint_exp_c(n):
    """N voters: enable-vote for each, every citizen votes for Eve, declare winner."""
    lines = [VOTING_HEADER]

    citizens = [f"Citizen{i}" for i in range(1, n + 1)]
    lines.append("Fact citizen Identified by " + ", ".join(citizens) + ".")
    lines.append("")

    for i in range(1, n + 1):
        lines.append(f"enable-vote(Admin, Citizen{i}).")
    lines.append("")

    # All citizens vote for Eve so she wins
    for i in range(1, n + 1):
        lines.append(f"cast-vote(Citizen{i}, Admin, Eve).")
    lines.append("")

    lines.append("declare-winner(candidate=Eve).")

    return "\n".join(lines) + "\n"


# =============================================================================
# Erlang scenario generators
# =============================================================================

def erlang_hwh_pairs():
    return r"""%%% scenario_hwh_pairs.erl
%%%
%%% Experiment A: N independent parent-child pairs, 1 duty cycle each.
%%% Tests sequential overhead: N process spawns, N triggers, N terminations.
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
        eflint:trigger(help,         #{parent => Parent, child => Child})
    end, lists:seq(1, N)),
    ok.
"""


def erlang_hwh_duties():
    return r"""%%% scenario_hwh_duties.erl
%%%
%%% Experiment B: 1 parent with M children — M duties alive simultaneously.
%%% Directly probes the synchronous subscriber-notification bottleneck:
%%% each eflint:add/2 call notifies all M live duty processes sequentially.
%%% Total notification work is O(M^2).
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
    %% Phase 2: add homework_due for each child — each add notifies all M live duty processes
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
"""


def erlang_voting():
    return r"""%%% scenario_voting.erl (scalable, Experiment C)
%%%
%%% Experiment C: N voters.
%%% Tests: N duty creations, N act triggers with conditioned_by checks,
%%% and declare-winner which evaluates count/2 over all N votes — O(N).
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
    ok.
"""


# =============================================================================
# Main
# =============================================================================

def main():
    print("Generating eFLINT files...")
    for n in SIZES:
        path = f"eflint/exp_a_{n}.eflint"
        with open(path, "w") as f:
            f.write(eflint_exp_a(n))
        print(f"  {path}")

    for m in SIZES:
        path = f"eflint/exp_b_{m}.eflint"
        with open(path, "w") as f:
            f.write(eflint_exp_b(m))
        print(f"  {path}")

    for n in SIZES:
        path = f"eflint/exp_c_{n}.eflint"
        with open(path, "w") as f:
            f.write(eflint_exp_c(n))
        print(f"  {path}")

    print("\nGenerating Erlang files...")
    shutil.copy("eflint.erl", "erlang/eflint.erl")
    print("  erlang/eflint.erl  (copied)")

    with open("erlang/scenario_hwh_pairs.erl", "w") as f:
        f.write(erlang_hwh_pairs())
    print("  erlang/scenario_hwh_pairs.erl")

    with open("erlang/scenario_hwh_duties.erl", "w") as f:
        f.write(erlang_hwh_duties())
    print("  erlang/scenario_hwh_duties.erl")

    with open("erlang/scenario_voting.erl", "w") as f:
        f.write(erlang_voting())
    print("  erlang/scenario_voting.erl")

    print(f"\nDone. {len(SIZES) * 3} eFLINT files + 3 Erlang scenarios.")


if __name__ == "__main__":
    main()
