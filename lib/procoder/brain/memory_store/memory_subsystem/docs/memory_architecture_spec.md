# ProCoder Brain Memory Subsystem: Architectural Specification

## 1. Executive Summary
The ProCoder Brain Memory Subsystem is a fault-tolerant, cognitively persistent memory layer designed for high-concurrency autonomous agent operation on the BEAM VM. It provides sub-millisecond access to session-isolated volatile memory and robust semantic log summarization.

## 2. Architectural Components

### 2.1 CacheEngine (`ProCoder.Brain.MemoryStore.Cache.CacheEngine`)
- **Role**: Provides session-isolated, ETS-backed storage.
- **Storage Strategy**: Employs `:ordered_set` for time-series log entries and `:set` for lookup-intensive state.
- **Isolation**: Each session operates within a dedicated, named ETS table.
- **Constraints**: Enforces strict memory usage limits per session to prevent system-wide exhaustion.

### 2.2 Compactor (`ProCoder.Brain.MemoryStore.Compactor`)
- **Role**: Heartbeat monitor and memory garbage collector.
- **Operation**: Periodically scans session tables for entries exceeding the TTL (Time-To-Live).
- **Back-pressure**: Monitors system memory through `:memsup`, accelerating compaction under high load.
- **Execution**: Dispatches stale log segments to the `Summarizer` asynchronously.

### 2.3 Summarizer (`ProCoder.Brain.MemoryStore.Summarizer`)
- **Role**: Performs cognitive distillation and log redaction.
- **Privacy**: Implements regex-based redaction to strip sensitive information (secrets, API keys) before external LLM interaction.
- **Idempotency**: Guarantees identical summaries for identical input segments.
- **Graceful Degradation**: Resorts to heuristic-based summary extraction if LLM connectivity fails.

### 2.4 Supervisor (`ProCoder.Brain.MemoryStore.Supervisor`)
- **Role**: Manages the lifecycle of memory subsystem components.
- **Strategy**: Employs a `:one_for_one` supervision tree.
- **Integrity**: Ensures atomic cleanup and synchronization with the persistent SQLite `Repo` upon process shutdown.

## 3. Concurrency and Scalability
- **Lock-free Access**: Designed to avoid global contention; session-level storage allows high-throughput parallel I/O.
- **Actor Model**: Leverages GenServer messaging for inter-process communication, ensuring complete isolation.
- **Compute Offloading**: Heavy computational tasks (pattern analysis, cryptographic hashing) are designated for Rustler NIFs to maintain BEAM responsiveness.

## 4. Security and Integrity
- **Credential Safety**: Unredacted raw logs are kept strictly in volatile memory and purged upon compaction. Only final, summarized snapshots are persisted to the SQLite Repo.
- **Input Validation**: All data entering the memory stores must adhere to defined structural schemas.
- **Observability**: Metrics are emitted via `:telemetry` for monitoring cache efficiency, compaction latency, and resource pressure.

## 5. Performance and Reliability
- **Fault Tolerance**: Implements recovery strategies for all components as per DAG specification.
- **Graceful Shutdown**: Handles `SIGTERM/SIGINT` to ensure all pending summaries are flushed to the SQLite persistence layer before termination.
- **Idempotency**: Design allows cluster-wide state resumption in the event of partial process failures.
