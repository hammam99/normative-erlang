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

    print(f"\nDone. {len(SIZES) * 3} eFLINT files.")


if __name__ == "__main__":
    main()
