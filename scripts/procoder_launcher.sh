#!/bin/bash
# ProCoder Global Launcher

# Ensure we are in the ProCoder installation directory to run mix
cd "/home/gifted/procoder_system"

# Start the application without IEx so the supervised TuiView owns the terminal.
exec mix run --no-halt
