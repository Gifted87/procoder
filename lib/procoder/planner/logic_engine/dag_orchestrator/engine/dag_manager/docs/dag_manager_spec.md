# ProCoder DAG Manager: Architectural and Technical Specification

## 1. Executive Summary
The DAG Manager subsystem constitutes the core planning intelligence for the ProCoder autonomous system. It manages the lifecycle of complex task plans by orchestrating state transitions within a Directed Acyclic Graph (DAG) structure. This document provides a exhaustive technical reference for its architecture, concurrent execution models, and self-healing mechanisms.

## 2. Core Architectural Philosophy
The DAG Manager is predicated on three foundational pillars:
- **Atomicity**: Every mutation to the planning graph must be atomic.
- **Cognitive Persistence**: The planning state is durably persisted, allowing for historical reconstruction (/rewind) and session continuity.
- **Fault-Tolerance**: The manager must be self-healing, utilizing automated remediation subgraphs when task nodes transition to :failed status.

## 3. High-Performance Concurrency Model
To meet the requirement of managing millions of nodes, the DAG Manager leverages the BEAM VM's strengths:
- **GenServer State Isolation**: Each planning session is encapsulated within its own GenServer process, preventing global state contention.
- **libgraph Integration**: Structural modeling relies on the `libgraph` library for efficient graph representation and topological sorting.
- **Asynchronous Actuation**: While planning and graph traversal occur within the DAG orchestrator, actual execution is delegated to the SessionManager via an asynchronous, non-blocking queue. This ensures that heavy IO operations or task execution do not stall the orchestration engine.
- **ETS-Backed Metadata**: Rapid access to node statuses (pending, running, completed, failed) is optimized through ETS tables, reducing read-locks on the primary graph structure.

## 4. Graph Orchestration Engine
The orchestrator operates as a lifecycle manager for task nodes.
### 4.1 State Machine Dynamics
The system follows a strict state transition model (Pending -> Running -> Completed/Failed). The GenServer maintains the mapping between internal node representations and the `libgraph` nodes.
### 4.2 Topological Dispatch Sequencer
The Dispatch Coordinator periodically performs `libgraph.topsort/1` to determine the set of 'ready' nodes (those with an in-degree of 0 among pending tasks). Rate-limiting logic is applied here to prevent overwhelming the SessionManager with task bursts.

## 5. Resilience and Self-Healing
### 5.1 Failure Remediator
When a node transitions to `:failed`, the Recovery Manager executes:
1. **Subgraph Pruning**: Identifies all downstream descendants reachable from the failed node and marks them for cancellation.
2. **Dynamic Remediation**: Uses node metadata to choose a compensation strategy (e.g., :retry, :rollback, :branch_prune).
3. **Graph Injection**: Generates and links a new remediation subgraph to the existing DAG, ensuring the execution flow remains structurally valid.

## 6. Persistence and Audit Trail
### 6.1 Two-Tiered Storage
- **Hot Stack (Memory)**: Maintains recent DAG snapshots for rapid /rewind access.
- **Cold Stack (Repo/SQLite)**: Durable binary snapshots of the graph state serialized via `:erlang.term_to_binary`.
### 6.2 Integrity Verification
Every persistence event is checked via a SHA-256 hash. During recovery, the PersistenceEngine verifies the hash against the persisted state before rehydration to prevent malformed graph states from being loaded into memory.

## 7. Security and Integrity Guardrails
### 7.1 GraphValidator
Before any mutation, the GraphValidator enforces:
- **Acyclicity**: Prevention of circular dependencies.
- **Referential Integrity**: All edges must point to existing nodes within the registry.
- **Reachability**: Ensuring no orphan nodes exist that would be unreachable by the orchestrator.
### 7.2 Input Sanitization
The orchestrator treats all external inputs as untrusted. Payloads are validated against a predefined schema (TaskNode) before registration.

## 8. Scalability Strategy
The system is built for massive scaling:
- **Horizontal Session Scaling**: By session-isolating the DAGs, the orchestrator can scale horizontally across multiple BEAM nodes or system cores.
- **NIF-based Compute**: Compute-intensive graph algorithms are offloaded to Rustler NIFs, ensuring the BEAM scheduler is never starved.

## 9. Observability and Telemetry
Every internal transition, dispatch, failure, and recovery is logged to the `:telemetry` bus. This allows for real-time visualization of the planning process and historical analysis of task failures.

## 10. Operational Procedures
- **Rewinding**: Invoking `/rewind <timestamp>` reconstructs the `libgraph` object by querying the persistence layer for the closest available snapshot and re-running any intermediate graph mutations, if necessary.
- **Manual Intervention**: The state machine allows for human-in-the-loop overrides, which are treated as high-priority 'remediation tasks' injected into the DAG.

## 11. Implementation Guidelines
- All graph operations must be contained within the GenServer process.
- Strictly avoid blocking IO calls in any core orchestrator process.
- Use `dialyzer` to enforce type safety on graph mutations.

## 12. Conclusion
The DAG Manager subsystem provides the robust, fault-tolerant, and high-performance backbone for ProCoder's planning engine. By combining structural rigor (libgraph), durable storage (SQLite), and aggressive self-healing, the manager ensures that the agent's goals remain achievable, even under extreme runtime conditions.
