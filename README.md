
This repository contains Erlang implementations of translating eFLINT scenarios and evaluation scripts.

## Running Erlang Scenarios

To compile and run the Erlang scenarios, follow these steps:

    ```bash
    erlc eflint.erl scenario_help_with_homework.erl
    ```
    ```bash
    erl -noshell -s scenario_help_with_homework run -s init stop
    ```
## Evaluation Scripts

The `evaluation/` directory contains scripts used for the experiments.

*   **`generate_experiments.py`**: This script programmatically creates multiple eFLINT `.eflint` or Erlang `.erl` scenario files for various experiment configurations (e.g., different sizes or complexities). Not generic, works only with the specefied scenarios of the thesis.

*   **`run_all.sh`**: This is a shell script runs the generated scripts 3 times per parameter and saves the results into text files in the `results/` directory.

*   **`analyse_results.py`**: This Python script is responsible for parsing and plotting the output from the experimentsa runs.

**Note on `sizes` array**:
All the scripts rely on a `sizes` array parameters of the experiments. This array needs to be **modified manually within the script files** to adjust the range of the expiremnt, but it's also needed for naming and plotting.