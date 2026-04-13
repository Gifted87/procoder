# ProCoder PromptEngine: Technical Specification

## 1. Overview
The ProCoder PromptEngine acts as the central cognitive gateway for the system, responsible for transforming heterogeneous input (AST data, task DAGs, historical context) into high-salience, secure message arrays for LLM consumption. It is designed as a stateless transformation library, optimized for the BEAM VM.

## 2. Salience Ranking Pipeline (Gradient of Precision)
The engine utilizes a weighted ranking algorithm to ensure context salience.

### Weighting Schema
| Component | Weight | Reasoning |
| :--- | :--- | :--- |
| `:code_graph` | 0.9 | High structural importance for AST traversal. |
| `:task_dag` | 0.8 | Critical for maintaining task orchestration flow. |
| `:history` | 0.4 | Essential for session coherence and context continuity. |
| Default | 0.1 | Base weight for unsorted or low-salience input. |

### Ranking Logic
Segments are ranked by the weighted sum of their components. The engine evaluates tokens based on proximity to the current goal, historical relevance from MemoryStore, and structural importance defined by the CodeGraph. 

- **Pruning**: Any segment failing to meet the `0.75` salience threshold is automatically pruned from the prompt array to preserve token capacity and maintain high context density.

## 3. Contextual Message Formatting
The `MessageFormatter` standardizes heterogeneous data structures into the `ProCoder.Core.Types.Message` struct.

### Constraints
- **Normalization**: Timestamps, roles, and structural metadata are normalized to ensure consistent LLM parsing.
- **Redaction**: All outgoing messages pass through a regex-based sanitization layer to remove potential PII, API keys (`AIza...`, `sk-live...`), and other secrets.
- **Token Compliance**: The engine enforces a strict 4096-token limit. If the aggregate size of high-salience segments exceeds this limit, lower-salience messages are truncated or dropped until the constraint is met.

## 4. One-Shot Error-Conditioned JSON Correction
To support fault-tolerant tool-call execution, the PromptEngine implements a multi-stage validation loop:

1. **Capture**: Intercept raw tool-call outputs from the assistant.
2. **Sanitize**: Apply PII/redaction filters.
3. **Parse**: Validate syntax using `Jason`.
4. **Validation**: Validate the structure against the dynamic tool schema.
5. **Correction**: If invalid, construct a one-shot feedback prompt containing the offending string, the syntax error details, and the target schema.
6. **Retry**: Automatically feedback to the LLM. 
   - *Note*: If errors persist after 3 retries, an `:unrecoverable` signal is dispatched to the SessionManager.

## 5. Architectural Reliability & Scalability
- **Concurrency**: Leverages BEAM functional pipes (`|>`) and process-isolated GenServer wrappers for linear scalability.
- **Compute Offloading**: AST heavy-lifting and grammar parsing are delegated to Rustler NIFs to prevent blocking system schedulers.
- **Observability**: Every stage of the transformation emits Telemetry events to monitor context salience and error-correction overhead.
- **Fault-Tolerance**: Centralized `try-rescue` blocks ensure malformed inputs are caught, logged, and handled without stalling the orchestration engine.

## 6. Security and Data Protection
- **Gateway**: The PromptEngine serves as the security bottleneck, applying regex-based sanitization for all input streams.
- **Isolation**: Path sanitization ensures that all filesystem operations are strictly scoped to the agent's sandboxed worktree.

## 7. Operational Recovery
- **Default Behavior**: If the `SalienceRanker` fails, the system defaults to passing unsorted context rather than blocking the LLM interaction.
- **Error Propagation**: Failures in the correction loop exceeding `max_retries` trigger the pre-defined failure recovery subgraph in the DAG planner.
- **Observability**: Errors are structured for centralized logging to facilitate system-wide debugging of context health.
