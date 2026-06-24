#!/usr/bin/env python3
"""
analyse_results.py
Reads raw timing data from results/, computes mean + stddev per N,
and writes 3 graphs per experiment to results/graphs/.

Graphs per experiment:
  exp_<X>_erlang.png     — Erlang only
  exp_<X>_eflint.png     — eFLINT only
  exp_<X>_comparison.png — both on a log-scale axis

Run from evaluation/ directory:
  python3 analyse_results.py
"""

import os
import statistics
import matplotlib.pyplot as plt

RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results")
# RESULTS_DIR = os.path.join(os.path.dirname(__file__), "results/erlang_scaling")
GRAPHS_DIR  = os.path.join(RESULTS_DIR, "graphs")
os.makedirs(GRAPHS_DIR, exist_ok=True)

EXPERIMENTS = [
    ("A", "N pairs",   "help-with-homework — varying pairs"),
    ("B", "M duties",  "help-with-homework — varying duties"),
    ("C", "N voters",  "voting — varying voters"),
]

ERLANG_COLOR = "#1565C0"
EFLINT_COLOR = "#C62828"


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def parse_file(path):
    """Return list of (n, [ms, ms, ms]) from a result file."""
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            n     = int(parts[0])
            times = [int(x) for x in parts[1:]]
            rows.append((n, times))
    return rows


def summarise(rows):
    """Return (xs, means, stds)."""
    xs    = [r[0] for r in rows]
    means = [statistics.mean(r[1]) for r in rows]
    stds  = [statistics.stdev(r[1]) if len(r[1]) > 1 else 0.0 for r in rows]
    return xs, means, stds


# ---------------------------------------------------------------------------
# Plotting helpers
# ---------------------------------------------------------------------------

def add_series(ax, xs, ys, errs, label, color, marker):
    ax.errorbar(xs, ys, yerr=errs,
                label=label, color=color,
                marker=marker, linewidth=1.8,
                markersize=5, capsize=3, elinewidth=1)


def save(fig, path):
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)
    print(f"  saved {path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

print(f"{'Exp':<4} {'N':>6}  {'Erlang mean':>13} {'±':>2} {'std':>8}   "
      f"{'eFLINT mean':>13} {'±':>2} {'std':>8}")
print("-" * 70)

for exp_id, x_label, title in EXPERIMENTS:
    erl_rows = parse_file(os.path.join(RESULTS_DIR, f"exp_{exp_id}_erlang.txt"))
    efl_rows = parse_file(os.path.join(RESULTS_DIR, f"exp_{exp_id}_eflint.txt"))

    erl_xs, erl_ys, erl_err = summarise(erl_rows)
    efl_xs, efl_ys, efl_err = summarise(efl_rows)

    for i, n in enumerate(erl_xs):
        print(f"  {exp_id}  {n:>6}  "
              f"{erl_ys[i]:>12.1f} ms  {erl_err[i]:>7.1f}   "
              f"{efl_ys[i]:>12.1f} ms  {efl_err[i]:>7.1f}")
    print()

    # --- Graph 1: Erlang only ---
    fig, ax = plt.subplots(figsize=(7, 4))
    add_series(ax, erl_xs, erl_ys, erl_err, "Erlang", ERLANG_COLOR, "o")
    ax.set_xlabel(x_label)
    ax.set_ylabel("Wall-clock time (ms)")
    ax.set_title(f"Experiment {exp_id}: {title}\nErlang runtime")
    ax.legend()
    ax.grid(True, linestyle="--", alpha=0.4)
    # save(fig, os.path.join(GRAPHS_DIR, f"exp_{exp_id}_erlang.png"))
    save(fig, os.path.join(GRAPHS_DIR, f"exp_{exp_id}_erlang_scaling.png"))

    # --- Graph 2: eFLINT only ---
    fig, ax = plt.subplots(figsize=(7, 4))
    add_series(ax, efl_xs, efl_ys, efl_err, "eFLINT (Haskell)", EFLINT_COLOR, "s")
    ax.set_xlabel(x_label)
    ax.set_ylabel("Wall-clock time (ms)")
    ax.set_title(f"Experiment {exp_id}: {title}\neFLINT (Haskell)")
    ax.legend()
    ax.grid(True, linestyle="--", alpha=0.4)
    save(fig, os.path.join(GRAPHS_DIR, f"exp_{exp_id}_eflint.png"))

    # --- Graph 3: Combined, log-scale Y ---
    fig, ax = plt.subplots(figsize=(7, 4))
    add_series(ax, erl_xs, erl_ys, erl_err, "Erlang",           ERLANG_COLOR, "o")
    add_series(ax, efl_xs, efl_ys, efl_err, "eFLINT (Haskell)", EFLINT_COLOR, "s")
    ax.set_yscale("log")
    ax.set_xlabel(x_label)
    ax.set_ylabel("Wall-clock time (ms, log scale)")
    ax.set_title(f"Experiment {exp_id}: {title}\nComparison (log scale)")
    ax.legend()
    ax.grid(True, linestyle="--", alpha=0.4, which="both")
    save(fig, os.path.join(GRAPHS_DIR, f"exp_{exp_id}_comparison.png"))

def plot_erlang_all_experiments(results_dir, graphs_dir):
    """Plot all three Erlang experiments in a single figure."""
    fig, ax = plt.subplots(figsize=(9, 5))
    markers = ["o", "s", "^"]
    colors = [ERLANG_COLOR, "#2E7D32", EFLINT_COLOR]
    for (exp_id, x_label, title), marker, color in zip(EXPERIMENTS, markers, colors):
        path = os.path.join(results_dir, f"exp_{exp_id}_erlang.txt")
        if not os.path.exists(path):
            print(f"  missing {path}, skipping")
            continue
        rows = parse_file(path)
        xs, ys, errs = summarise(rows)
        add_series(ax, xs, ys, errs, f"Exp {exp_id}", color, marker)
    ax.set_xlabel("Variable parameter (per experiment)")
    ax.set_ylabel("Wall-clock time (ms)")
    # ax.set_title("Erlang scaling — all experiments")
    ax.legend()
    ax.grid(True, linestyle="--", alpha=0.4)
    save(fig, os.path.join(graphs_dir, "erlang_scaling_all_experiments.png"))


plot_erlang_all_experiments(RESULTS_DIR, GRAPHS_DIR)

print(f"\nAll graphs written to {GRAPHS_DIR}/")
