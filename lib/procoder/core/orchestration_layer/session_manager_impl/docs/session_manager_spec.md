# SessionManager Subsystem: Architectural and Technical Documentation

## 1. Executive Summary
The SessionManager is the foundational execution container of the ProCoder swarm architecture. It acts as the 'DynamicSupervisor' responsible for the lifecycle management, isolation, and observability of autonomous agent processes. By design, the SessionManager ensures that ProCoder can scale to thousands of concurrent agent sessions, each securely sandboxed and independently supervised within the BEAM VM. This document details the orchestration logic, security hardening, and fault-tolerance mechanisms that underpin the SessionManager.

## 2. Architectural Mandate & Supervision Tree
The SessionManager is implemented as an OTP `DynamicSupervisor`. This architectural choice is non-negotiable as it provides the core mechanism for dynamic process spawning and failure isolation.
- Supervision Strategy: The `:one_for_one` strategy is utilized. In this configuration, if an individual agent process (AgentFSM) crashes, the supervisor terminates only that specific process and restarts it, leaving the rest of the swarm unaffected. This ensures the granular fault-tolerance required by the Prime Directive.
- Process Naming & Registry: Agents are not tracked by hardcoded names. Instead, each agent is registered globally via the `ProCoder.Registry` module using a `via_tuple(session_id)`. This decoupling allows for O(1) discovery across the entire cluster, essential for efficient message routing and swarm observability.

## 3. Worktree Isolation & Security
Security is a primary design constraint for the SessionManager, focusing on preventing cross-session contamination.
- Filesystem Sandboxing: Every agent is pinned to a unique, isolated Git worktree path. The SessionManager resolves these paths against a strictly configured `WORKTREE_ROOT` (default: `/tmp/procoder/worktrees`).
- Bubblewrap Enforcement: The SessionManager coordinates with the `Actuator.PortWrapper` to ensure that all shell interactions within an agent's worktree are encapsulated using Bubblewrap. This creates a hard security boundary, preventing any agent from performing unauthorized operations outside its assigned sandbox (mitigating directory traversal and system command injection risks).
- Pre-flight Checks: The `WorktreeManager` performs rigorous validation of write permissions and path containment before an agent process is permitted to initialize. If a worktree fails to initialize, the agent is barred from the supervisor pool, preventing rapid-restart crash loops.

## 4. Swarm Orchestration Logic
- Concurrent Provisioning: The SessionManager leverages `DynamicSupervisor.start_child/2` to scale spawns horizontally. This is designed for high-throughput, massive parallelization across all available BEAM schedulers.
- Session Metadata & Observability: An ETS table acts as a high-performance metadata repository, tracking session ID-to-PID mappings and worktree locations. Every lifecycle transition—spawn, termination, or restart—emits standard `telemetry` events, providing real-time data on agent density, churn rates, and swarm health.

## 5. Resilience, Fault-Tolerance & Persistence
The system is built to survive transient process failures without losing cognitive state.
- State Re-hydration: Upon an agent process restart, the supervisor triggers a state recovery workflow. The agent re-synchronizes its memory state from the Ecto-backed database (SQL-backed history stack) and the filesystem state is verified against the Git worktree.
- Graceful Shutdown: The SessionManager implements a clean shutdown routine. When a session terminates, the agent memory state is persisted to the Ecto repository before the process is decommissioned.
- DAG-based Remediation: If an AgentFSM reaches a terminal failure state that the standard restart cannot resolve, the SessionManager invokes the DAG-based failure remediation subgraphs defined by the Planner, ensuring that the system can autonomously compensate or prune faulty tasks.

## 6. Hardening & Compliance Protocols
- Credential Safety: Hardcoded credentials, API keys, or environment secrets are strictly prohibited. The SessionManager mandates configuration injection via `System.get_env/1`.
- Resource Limiting: The SessionManager interfaces directly with the system-wide 'RateLimiter' and monitors OS process usage to dynamically constrain agent density, preventing CPU and memory exhaustion that would compromise host stability.
- Zero-Destructive Ops: All file operations are restricted to non-destructive scopes. The system avoids global destructive commands (like `rm -rf`) entirely, preferring Git worktree lifecycle management which is inherently more stable and traceable.

## 7. Scaling Strategy
The SessionManager is designed to scale across nodes in a cluster. By relying on global process registries and Ecto-backed persistence, session state is consistent across the swarm. The DynamicSupervisor pattern allows the system to adjust worker capacity dynamically based on load, with telemetry hooks enabling automated autoscaling workflows.

## 8. Conclusion
The SessionManager provides the essential harness for the autonomous agent swarm. Its robust adherence to OTP principles, strict filesystem sandboxing, and autonomous recovery subgraphs create a stable, secure, and infinitely scalable foundation for the ProCoder platform. Developers must maintain this modular approach when extending agent capabilities to ensure the stability of the entire system.
