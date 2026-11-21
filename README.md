# ProCoder

ProCoder is an experimental Elixir/OTP coding agent that accepts a task in a terminal interface, plans work, and uses configured language model and development tools to inspect or modify a codebase. The project includes modules for task orchestration, code search, memory, skills, and a supervised command-line interface.

This repository is under active development. Descriptions of intended capabilities in older design notes may not reflect implemented or verified behavior.

## Features

- Terminal interface for submitting tasks and viewing agent activity.
- OpenAI-compatible and Gemini model adapters, selected through runtime configuration.
- Elixir supervision tree for the agent, memory, search, tooling, and control-plane components.
- Code indexing and search backed by SQLite and native dependencies.
- Optional skill discovery and Git worktree support.

Tool availability and safeguards depend on the configured adapters and execution environment. Review the code and run ProCoder in an isolated workspace before giving it access to valuable files or credentials.

## Requirements

- Elixir 1.14 or later and Erlang/OTP.
- Git for worktree features.
- A Rust toolchain may be needed to build native dependencies.
- Access to a supported model endpoint for model-backed tasks.

## Getting started

From the repository root:

```sh
mix deps.get
```

Set the model endpoint and credentials in your shell. The default adapter reads `PROCODER_LLM_URL`, `PROCODER_LLM_MODEL`, and `PROCODER_LLM_API_KEY`; the Gemini adapter can also read `PROCODER_LLM_API_KEYS`.

```sh
export PROCODER_LLM_URL="https://your-model-endpoint/v1"
export PROCODER_LLM_MODEL="your-model-name"
export PROCODER_LLM_API_KEY="your-api-key"
```

Then start the application:

```sh
mix run --no-halt
```

The terminal interface accepts a task description and displays available commands when started. Configuration and adapter behavior can change as the project evolves; check the implementation under `lib/procoder/brain/client_engine/llm_client/` before connecting a provider.

## Configuration

- `PROCODER_LLM_API_KEY` — credential for the configured model provider.
- `PROCODER_LLM_API_KEYS` — optional key list used by the Gemini key-rotation module.
- `PROCODER_LLM_URL` — model API base URL.
- `PROCODER_LLM_MODEL` — model identifier.
- `PROCODER_LOG_LEVEL` — console log level.
- `PROCODER_SOURCE_ROOT` and `WORKTREE_ROOT` — source and worktree locations.

The runtime initializer can load a local `.env` file. Keep real credentials in environment variables or a local ignored file; do not commit them. Model requests may include task instructions and source snippets, so configure a provider whose data handling you trust.

## Development

```sh
mix test
```

The repository also contains exploratory scripts and additional checks under `tests/` and `scripts/`. Review a script before running it, since some tools can access or change files in the configured source workspace.

## Project layout

- `lib/procoder/brain/` — model adapters and prompt handling.
- `lib/procoder/core/` — agent lifecycle, planning, and execution logic.
- `lib/procoder/search/` — source indexing and search.
- `lib/procoder/memory/` — session context and persistence.
- `lib/procoder/actuator/` and `lib/procoder/tooling/` — tool execution and integrations.
- `config/` — runtime configuration.
- `native/` — native components and build support.

## Security

ProCoder is an experimental developer tool, not a hardened production service. Agent tools can read or write files and may run shell commands. Use a disposable repository or container, avoid exposing secrets to model context, and inspect proposed changes before keeping them. The configured model provider may receive prompts and selected code context.

## License

No license file is included. All rights remain with the author unless a license is added.
