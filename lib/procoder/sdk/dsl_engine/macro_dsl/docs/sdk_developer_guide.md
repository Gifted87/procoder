# ProCoder SDK Developer Guide

## 1. Architectural Overview & Philosophy

The ProCoder SDK provides a declarative, macro-based Domain Specific Language (DSL) for synthesizing autonomous agents and procedural skills. By mapping high-level constructs (`defagent`, `defskill`) into robust, OTP-supervised `gen_statem` behaviors, the SDK ensures:

- **Cognitive Persistence**: Automatic integration with `Brain.MemoryStore` and `/rewind` history stacks.
- **Zero-Cost Abstractions**: Minimal runtime overhead through compile-time macro expansion.
- **Resilient Supervision**: All agents are automatically managed within the `ProCoder.SessionManager` supervision tree.

---

## 2. API Reference

### 2.1 `defagent`
Synthesizes a full ProCoder agent module.

```elixir
defagent MyCodingAgent do
  # State definitions and skill registration
  persist([:task_id, :context])
end
```

### 2.2 `defskill`
Defines a procedural skill with built-in risk assessment and bubblewrap isolation.

```elixir
defskill :build_project do
  # Bubblewrap execution happens here
  System.cmd("make", ["build"])
end
```

---

## 3. Cognitive Persistence

To ensure agent longevity, utilize the `persist` macro within your agent definition. This registers fields for automatic asynchronous state capture.

```elixir
defagent DataGatherer do
  persist([:buffer, :remote_endpoint])
end
```
*Mechanism*: Upon process transition, the SDK dispatches the state to the `SessionManager`, which persists the memory blob to the SQL-based history stack with atomic integrity checks.

---

## 4. Hardening and Security Protocols

### 4.1 DSL Validation
The `DSLValidator` module intercepts system calls at compile-time. Any usage of raw `System.cmd` or `File.rm` will trigger a compile-time error.

### 4.2 Bubblewrap Enforcement
Every `defskill` block is implicitly wrapped in a bubblewrap container, restricting the agent to its assigned worktree sandbox.

### 4.3 Secret Management
**CRITICAL**: Do not hardcode credentials. Use `System.get_env/1`. The validator scans for regex patterns (e.g., `AIza...`) and raises errors if hardcoded secrets are detected.

---

## 5. Radical Completeness and Integration

### 5.1 /rewind Workflow
The `/rewind` capability is triggered automatically upon detection of task failure in the DAG.
1. **Fetch**: The `RewindManager` retrieves the state blob from the cold storage (SQLite).
2. **Hash**: The integrity is verified using SHA-256.
3. **Revert**: The `FilesystemReverter` performs a Git stash pop or reset to align the worktree with the cognitive state.
4. **Hydrate**: The agent process is re-initialized with the binary memory blob.

### 5.2 Telemetry Integration
Custom skills automatically emit events via `:telemetry`. Custom handlers can be defined:
```elixir
:telemetry.attach("my-handler", [:procoder, :sdk, :skill, :executed], &MyHandler.handle/4, nil)
```

---

## 6. Best Practices

- **State Transitions**: Ensure `gen_statem` transitions are unidirectional and explicit. Avoid shared state between agent processes.
- **Memory API**: Only mutate agent state via `Brain.MemoryStore` interfaces. Direct ETS access is forbidden and will bypass audit logs.
- **Error Recovery**: Always implement `compensate` blocks in `defskill` for non-idempotent operations to ensure DAG consistency.
