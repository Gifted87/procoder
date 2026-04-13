# ProCoder DAG Orchestrator: Architectural and Technical Specification

## 1. Executive Summary
The ProCoder Planner DAG Orchestrator subsystem constitutes the core planning intelligence for the ProCoder autonomous system. It manages the lifecycle of complex task plans by orchestrating state transitions within a Directed Acyclic Graph (DAG) structure. This document provides an exhaustive technical reference for its architecture, concurrent execution models, and self-healing mechanisms.

## 2. Core Architectural Philosophy
The DAG Orchestrator is predicated on three foundational pillars:
- **Atomicity**: Every mutation to the planning graph must be atomic, managed by the central Planner GenServer.
- **Cognitive Persistence**: The planning state is durably persisted using a binary serialization strategy backed by a SQLite repository, allowing for historical reconstruction (/rewind) and session continuity.
- **Fault-Tolerance**: The system is self-healing, utilizing dynamically generated remediation subgraphs when task nodes transition to the `:failed` status.

## 3. Core Components

### 3.1 DAG Orchestration Engine (`graph_engine_server.ex`)
The cognitive hub of the Planner. It maintains the internal state of the plan, processes atomic mutations, and enforces structural validation. It relies on `libgraph` for structural modeling.

### 3.2 Topological Dispatcher (`dispatch_coordinator.ex`)
Orchestrates execution by performing topological sorts on the DAG. It identifies "ready" nodes (in-degree 0, status `:pending`) and offloads their execution to the `SessionManager` via an asynchronous, non-blocking queue.

### 3.3 Resilience and Recovery Manager (`failure_remediator.ex`)
The primary self-healing component. Upon node failure, it performs impact analysis to identify all reachable descendants. It selects compensation strategies (e.g., `:retry`, `:cleanup`, `:branch_prune`) and injects a new remediation subgraph into the live DAG.

### 3.4 Persistence Engine (`persistence.ex`)
Facilitates state snapshots and historical rehydration. It serializes the graph state via `:erlang.term_to_binary` and stores it in the `ProCoder.Repo` SQLite repository.

### 3.5 Graph Validator (`graph_validator.ex`)
Enforces safety guardrails before any graph mutation:
- **Acyclicity Check**: Ensures the DAG remains acyclic.
- **Referential Integrity**: Verifies that all graph edges map to valid nodes in the registry.
- **Orphan Prevention**: Ensures all registered nodes are reachable from the root.

## 4. Lifecycle State Machine
Nodes strictly adhere to the following transition model:
`:pending` -> `:running` -> `:completed` (or `:failed`).

Transitions are guarded to prevent invalid states (e.g., cannot move to `:running` if parents are not `:completed`). Telemetry events are emitted at every transition for full observability.

## 5. Security and Concurrency
- **Process Isolation**: Each Planner instance is encapsulated within an OTP process, eliminating global locks.
- **Input Sanitization**: All incoming data (tasks, dependencies) is validated against the `TaskNode` schema definition before registration.
- **Resource Protection**: Heavy AST operations are offloaded to Rustler NIFs, and graph traversals are guarded by recursion depth limits to ensure system responsiveness.

## 6. Implementation & Roadmap
- **Persistence Layer Integration**: Snapshots are taken before and after any graph mutation, directly supporting the `/rewind` requirement.
- **Diagnostic Observability**: The entire planning lifecycle is instrumented for real-time monitoring of self-healing actions.
- **Conclusion**: By separating the "what" (Planner) from the "how" (SessionManager), the Orchestrator ensures a modular, maintainable, and highly resilient architecture fit for real-world autonomous engineering.
