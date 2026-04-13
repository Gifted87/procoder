# ProCoder Root Supervision Tree: Architectural Specification

## 1. Executive Summary
The ProCoder root supervision tree is the structural foundation of the autonomous coding harness, ensuring system resilience, fault isolation, and autonomous recovery. It utilizes a hierarchical OTP supervisor structure to govern four primary domains: Core, Planner, Brain, and Actuator.

## 2. Root Supervision Topology (`ProCoder.SupervisionTree.RootSupervisor`)
The `RootSupervisor` acts as the system's apex. It adheres to the `:one_for_one` supervision strategy to guarantee that failures in one domain are contained and do not cascade.

### Child Domain Supervisors:
1.  **Core Domain (`CoreSupervisor`)**: Manages session orchestration, global registry, and persistence history.
    -   *Strategy*: `:permanent`
    -   *Shutdown*: 15,000ms
2.  **Planner Domain (`PlannerSupervisor`)**: Manages the Directed Acyclic Graph (DAG) for goal decomposition and failure remediation.
    -   *Strategy*: `:permanent`
    -   *Shutdown*: 10,000ms
3.  **Brain Domain (`Brain.Supervisor`)**: Governs LLM connectivity, memory management, and rate limiting.
    -   *Strategy*: `:permanent`
    -   *Shutdown*: 10,000ms
4.  **Actuator Domain (`Actuator.Supervisor`)**: Manages command routing and sandboxed shell execution (Bubblewrap).
    -   *Strategy*: `:permanent`
    -   *Shutdown*: 10,000ms

## 3. Health Monitoring & Fault-Isolation
The system utilizes the `ProCoder.SupervisionTree.RootSupervisor.Monitoring.HealthCheck` service.
-   **Heartbeat Mechanism**: Periodic pings to registered PIDs in the `Registry`.
-   **Emergency Escalation**: If a domain remains unhealthy for > 30s (or > 5 consecutive failures), the `HealthCheck` triggers the `RootSupervisor` to log a critical error and potentially restart the domain supervisor.

## 4. Graceful Shutdown Protocol
When a system shutdown signal (`SIGTERM`) is received, the `RootSupervisor` coordinates a tiered, orderly exit:
1.  **Brain Domain**: Cease network intake (Finch client termination).
2.  **Planner Domain**: Flush active DAG snapshots to the PersistenceEngine and cancel pending node execution.
3.  **Core Domain**: Serialize active agent contexts to the Ecto Repo and close transaction logs.
4.  **Actuator Domain**: Release filesystem locks on sandboxed worktrees and close Erlang Ports.

This sequence guarantees state persistence and prevents data corruption within the agent swarm.

## 5. Fault Isolation & Resource Management
-   **Environment Injection**: Credentials and configuration are injected via the `RuntimeInitializer` at boot, preventing hardcoded secrets in the supervision tree.
-   **Back-pressure**: Dynamic spawning of agents is controlled through the SessionManager's supervision tree, providing inherent back-pressure to protect BEAM VM schedulers.
-   **Observability**: Lifecycle transitions are emitted via the `:telemetry` bus for real-time monitoring and TUI-based visualization.
