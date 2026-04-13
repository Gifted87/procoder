#!/bin/bash
# ProCoder Global Launcher

# Ensure we are in the ProCoder installation directory to run mix
cd "/home/gifted/procoder_system"

# Launch the interactive harness with the environment variables provided by the Python intermediary
# We use -noshell to disable the default Elixir/Erlang shell, allowing ProCoder's
# custom TUI (TuiView) to own standard input exclusively.
exec elixir --erl "-noshell" -S mix run --no-halt
