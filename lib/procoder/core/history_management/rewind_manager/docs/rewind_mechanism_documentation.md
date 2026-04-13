# ProCoder Rewind Mechanism: Technical Documentation

## 1. Executive Summary
The Rewind mechanism serves as the cognitive and filesystem safety layer for the ProCoder autonomous system. It enables atomic rollback capabilities, allowing the agent to revert to previous stable states (both memory context and filesystem worktree) in the event of task failures, logical drift, or environment corruption.

## 2. Core Architectural Philosophy
The system is built upon three pillars of persistence:
- **Atomicity**: Rollback operations are strictly transactional. If the filesystem revert (via Git) fails, the system aborts before injecting potentially corrupt or mismatched memory states into the agent process.
- **Cognitive Persistence**: The agent's `AgentContext` is serialized, compressed, and persisted, allowing exact state rehydration to resume FSM transitions at the point of the last checkpoint.
- **Security Isolation**: Filesystem mutations are strictly scoped using `bubblewrap` (bwrap) sandboxing, ensuring the agent cannot modify files outside its authorized session worktree.

## 3. HistoryStackEngine (LIFO Stack)
The rewind system employs a two-tiered LIFO history management system:
- **Hot Stack (ETS)**: Recent history (last 5 snapshots) is cached in ETS tables for near-instantaneous (<1ms) recovery during active debugging loops.
- **Cold Stack (SQLite)**: Historical snapshots are serialized into binary blobs and persisted in the `ProCoder.Repo` SQLite database.
- **Integrity**: Every snapshot is paired with a SHA-256 integrity hash. During rehydration, the `HistoryStackEngine` validates the blob to prevent unauthorized state tampering.

## 4. Atomic Rollback Engine (RewindCoordinator)
The `RewindCoordinator` orchestrates the rollback sequence:
1. **Pre-flight Check**: Verification of the repository's dirty state (index/stash) and worktree integrity.
2. **Execution**: The `FilesystemReverter` performs a `git reset --hard` and `git checkout` within a hardened sandbox.
3. **Memory Rehydration**: Upon successful filesystem synchronization, the `MemorySnapshotManager` deserializes the state, performs structural validation, and re-injects it into the agent's `gen_statem` process.
4. **Failure Handling**: Any failure in this sequence triggers a system-wide diagnostic log, aborts the operation, and prevents state re-hydration, maintaining the system in its last known "safe" configuration.

## 5. Security Isolation Protocols
Security is integrated at the orchestration level:
- **Bubblewrap (bwrap)**: All filesystem operations are delegated to `PortWrapper`, which spawns processes with restricted filesystem namespace access.
- **Path Traversal Mitigation**: Absolute path validation is enforced before any command execution; any attempt to reference paths outside the assigned worktree root results in immediate session termination.
- **Credential Sanitization**: The `MemorySnapshotManager` performs mandatory key redaction on the `AgentContext` struct (stripping API keys/secrets) prior to serialization.

## 6. Fault Tolerance
- **Supervision**: Each component of the Rewind system (`RewindCoordinator`, `HistoryStackEngine`, `FilesystemReverter`) is integrated into a robust OTP supervision tree.
- **Concurrency**: Statefulness is managed per `session_id` using process-isolated GenServers, eliminating race conditions during concurrent `/rewind` requests.
- **Recovery**: Integration with the Planner engine enables the generation of 'Remediation Subgraphs', allowing the agent to re-plan tasks from the restored state, avoiding infinite failure loops.

## 7. Scaling and Performance
- **Storage Optimization**: Using Erlang's binary term serialization (`:erlang.term_to_binary/1`) minimizes storage overhead.
- **Non-blocking I/O**: Filesystem revert operations are offloaded to background Tasks to ensure the Agent's primary FSM loop remains responsive.
