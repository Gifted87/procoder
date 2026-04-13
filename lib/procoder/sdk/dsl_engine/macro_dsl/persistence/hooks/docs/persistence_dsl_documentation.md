# ProCoder Persistence Macro DSL: Architectural and Technical Specification

## 1. Introduction
The ProCoder Persistence Macro DSL provides a high-level, declarative interface for cognitive state management in autonomous coding agents. By integrating with the Erlang/OTP supervision tree, the system offers zero-cost, type-safe abstractions for state snapshotting and atomic rollback capabilities. This document details the persistence architecture, serialization standards, and the operational rewind strategies that enable cognitive longevity in the ProCoder ecosystem.

## 2. Cognitive Persistence Architecture
The persistence layer operates as a distributed, supervision-aware subsystem. It bridges volatile agent memory (gen_statem state) with a durable, transactionally-consistent storage backend (SQLite/Repo).

### 2.1 The 'persist' Macro (Declarative State Tracking)
- **Design Philosophy**: Reduces developer overhead by automating the registration of state variables for historical capture.
- **Implementation**: The macro expands at compile-time to inject lifecycle hooks into the host agent (`handle_event` for `gen_statem` or `handle_call` for `GenServer`).
- **Concurrency**: State capture is dispatched as an asynchronous task to ensure the agent remains non-blocking during high-frequency I/O operations.
- **Redaction Pipeline**: Before any data is pushed to the persistent layer, it is processed by the `ProCoder.Brain.Client.Telemetry.EventMonitor` to strip PII and credentials.

### 2.2 The 'snapshot' Macro (Atomic Point-in-Time Capture)
- **Design Philosophy**: Provides manual control over cognitive state snapshots.
- **Serialization**: Utilizes :erlang.term_to_binary/1 for compact, high-performance serialization. 
- **Integrity**: Every binary blob is hashed with SHA-256 and verified upon retrieval to prevent cognitive corruption.
- **Atomicity**: Snapshots are persisted within an Ecto.Repo.transaction_atomic/1 block, guaranteeing database consistency in the event of partial failures.

## 3. Serialization Standards
The persistence system leverages a multi-tier serialization approach to maximize I/O efficiency:
- **Hot Tier (ETS)**: Stores recent state changes as raw Elixir terms, facilitating sub-millisecond retrieval by the agent process.
- **Cold Tier (SQLite)**: Stores compressed, serialized binary blobs. This minimizes disk I/O and facilitates rapid, reliable recovery of long-term history.
- **Compatibility**: Every snapshot carries a `:version` tag, ensuring that schema evolution in the agent definition does not render historical snapshots unreadable.

## 4. The Rewind Strategy (Atomic Rollback)
The `rewind` mechanism is the cornerstone of ProCoder's reliability, facilitating coordinated recovery of both memory state and filesystem worktrees.

### 4.1 Rollback Sequence
1. **LIFO Stack Query**: The `RewindCoordinator` fetches the requested snapshot from the history stack.
2. **Integrity Validation**: The stored SHA-256 hash is compared against the binary payload hash.
3. **Coordinated Revert**: 
   - **Filesystem**: The `FsReverter` issues a Git stash pop or reset command to align the worktree with the cognitive state.
   - **Cognitive State**: The agent is signaled to terminate, and the session manager re-initializes it using the deserialized binary payload.
4. **Recovery Subgraph**: If any stage of this atomic transition fails, a compensation process triggers a reset to the 'init' state to prevent zombie-process loops.

## 5. Scalability and Concurrency
The system is built to scale across thousands of agent instances without global bottlenecks.
- **Process Isolation**: Each agent session manages its own history stack, minimizing contention.
- **Resource Management**: The LIFO stack implements an eviction strategy (configurable via `MemoryStore.Config`) to prevent unlimited history growth.
- **Finch Integration**: HTTP communication during persistence (when required) utilizes high-concurrency Finch-based HTTP/2 connection pooling.

## 6. Security and Data Privacy
Persistence is not a backdoor for data leakage.
- **Mandatory Redaction**: The `RedactionPipeline` acts as a fail-closed firewall. Any data not explicitly marked for persistence, or matching known credential patterns, is stripped before storage.
- **Sandbox Enforcement**: All filesystem operations within the `rewind` pipeline are gated by the Actuator's `bubblewrap` runtime, preventing unauthorized access to the root file system.

## 7. Fault Tolerance
The subsystem is designed to survive partial system failures.
- **Unreliable History Stacks**: If a snapshot fails, the agent flags its history stack as 'unreliable', preventing subsequent faulty rollbacks.
- **Supervision Tree**: All persistence services (Compactor, Summarizer, HistoryStackEngine) are managed under the `MemoryStore.Supervisor`, enabling granular recovery of independent memory components without system-wide interruption.

## 8. Conclusion
The ProCoder Persistence Macro DSL enables a high-reliability autonomous state machine by treating cognitive history as a first-class citizen. Through the union of declarative state annotation, atomic binary serialization, and coordinated filesystem restoration, agents maintain context across system reboots and long-term execution, fulfilling the core mission of robust AI cognitive longevity.
