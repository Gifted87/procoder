# ProCoder Ecto Persistence Layer Requirements

This document outlines the architectural and technical requirements for the Ecto-based persistence layer of the ProCoder system.

## 1. Architectural Mandate
- **Engine**: SQLite, managed via `ecto_sqlite3`.
- **Primary Key**: All entities must use `binary_id` (UUIDv4) for global uniqueness and distributed node compatibility.
- **Goal**: Highly available, consistent, and performant state management for session lifecycles, task DAGs, and AST representations.

## 2. Dependency Specification
- `ecto`: Core toolkit for data modeling and query composition.
- `ecto_sqlite3`: SQLite database adapter.
- `jason`: JSON serialization/deserialization for JSONB-like fields.
- `ecto_sql`: Database migration and constraint management.

## 3. Schema Structure & Constraints

### 3.1. ProCoder.Persistence.Session
- **Purpose**: Lifecycle tracking.
- **Fields**:
    - `id`: `binary_id` (PK)
    - `status`: `enum` [:idle, :planning, :thinking, :tool_execution, :verifying]
    - `context_snapshot`: `map` (JSONB)
    - `git_worktree_path`: `string`
- **Validation**: Changeset must enforce FSM state transitions and validate that `git_worktree_path` resides within the authorized sandbox.

### 3.2. ProCoder.Persistence.TaskNode
- **Purpose**: DAG structure representation for the Planner.
- **Fields**:
    - `id`: `binary_id` (PK)
    - `session_id`: `references` (Session)
    - `task_type`: `atom`
    - `payload`: `map` (JSONB)
    - `status`: `enum` [:pending, :running, :completed, :failed]
    - `retry_count`: `integer`
    - `recovery_node_id`: `references` (TaskNode, optional)
- **Integrity**: Enforce foreign key constraints at the database level to maintain DAG integrity.

### 3.3. ProCoder.Persistence.CodeGraphNode & Relationship
- **Purpose**: AST representation and connectivity.
- **CodeGraphNode Fields**: `id` (`binary_id`), `node_type` (`string`), `source_range` (`map`), `content_hash` (`string`), `file_path` (`string`).
- **Relationship Fields**: `source_id` (`references`), `target_id` (`references`), `relation_type` (`enum`).
- **Required Logic**: Implement `from_ast/1` for all nodes to map AST metadata to schema fields.

## 4. Scaling, Concurrency & Performance
- Use `binary_id` (UUIDv4) to minimize DB contention.
- Implement strict foreign key constraints at the migration layer.
- Dynamically scale `Ecto.Repo` pool size via `RuntimeInitializer`.
- Utilize `on_conflict` (upsert) for CodeGraph AST updates.

## 5. Security & Data Integrity
- **Injection Mitigation**: Strict changeset validation and casting. No direct database modification.
- **Path Validation**: Filesystem paths must be validated against the sandbox root.
- **Credential Isolation**: Secrets must remain in volatile ETS; never persist sensitive data.
- **Traceability**: All schemas must use `timestamps()` (inserted_at/updated_at).

## 6. Implementation & Integration Standards
- Encapsulate schemas in single modules.
- Route all database interactions through `ProCoder.Repo`.
- Implement `changeset/2` as the sole interface for data manipulation.
- Ensure recovery subgraphs are linkable for `/rewind` functionality.
- Provide comprehensive ExUnit tests for all schemas, covering failures, transitions, and integrity constraints.
