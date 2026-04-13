import Config

# Dev environment overrides
config :procoder, ProCoder.SessionManager,
  source_root: "/home/gifted/procoder_system",
  worktree_root: "/tmp/procoder_worktrees"

# Gemini API key rotation pool — rotate on any error.
# Set PROCODER_LLM_API_KEYS in the environment, or the adapter falls back to PROCODER_LLM_API_KEY.
# Example (set in your shell before running):
#   export PROCODER_LLM_API_KEYS="key1,key2,key3,key4"
#
# Current pool:
#   (None hardcoded. Set PROCODER_LLM_API_KEYS in environment)
