defmodule ProCoder.Planner.LogicEngine.DAGOrchestrator.Validation.GraphValidator do
  @moduledoc """
  The GraphValidator component acts as the safety and integrity layer for the
  ProCoder DAG orchestrator. It ensures the structural soundness of execution
  plans by enforcing acyclicity, reachability, and referential integrity.
  """

  require Logger

  @doc """
  Atomic validation guardrail for the Planner.
  Validates graph structural integrity before persistence.
  Returns :ok if valid, or {:error, violation_type, details} if invalid.
  """
  @spec validate_all!(Graph.t(), map()) :: :ok | {:error, atom(), term()}
  def validate_all!(graph, node_registry) do
    with :ok <- check_dependencies!(graph, node_registry),
         :ok <- check_cycle!(graph),
         :ok <- check_orphans!(graph) do
      :telemetry.execute([:procoder, :planner, :validation, :success], %{})
      :ok
    else
      {:error, reason, details} ->
        :telemetry.execute([:procoder, :planner, :validation, :failure], %{reason: reason})
        {:error, reason, details}
    end
  end

  @doc """
  Performs cycle detection using libgraph's acyclic verification.
  """
  @spec check_cycle!(Graph.t()) :: :ok | {:error, :cyclic, String.t()}
  def check_cycle!(graph) do
    if Graph.is_acyclic?(graph) do
      :ok
    else
      {:error, :cyclic, "Graph contains a circular dependency."}
    end
  end

  @doc """
  Identifies orphan nodes by verifying reachability from the graph's root(s).
  Orphans are nodes that are not reachable from the entry points.
  """
  @spec check_orphans!(Graph.t()) :: :ok | {:error, :orphan_nodes, list()}
  def check_orphans!(graph) do
    all_nodes = Graph.vertices(graph)
    # Roots defined as nodes with in-degree 0
    roots = Graph.vertices(graph) |> Enum.filter(&(Graph.in_degree(graph, &1) == 0))
    
    reachable = 
      roots
      |> Enum.flat_map(&Graph.reachable(graph, [&1]))
      |> MapSet.new()

    orphans = Enum.reject(all_nodes, &MapSet.member?(reachable, &1))

    if Enum.empty?(orphans) do
      :ok
    else
      {:error, :orphan_nodes, orphans}
    end
  end

  @doc """
  Ensures referential integrity between graph edges and the node registry.
  All node_ids present in the graph must exist in the registry.
  """
  @spec check_dependencies!(Graph.t(), map()) :: :ok | {:error, :dangling_reference, list()}
  def check_dependencies!(graph, node_registry) do
    graph_nodes = Graph.vertices(graph)
    dangling = Enum.reject(graph_nodes, &Map.has_key?(node_registry, &1))

    if Enum.empty?(dangling) do
      :ok
    else
      {:error, :dangling_reference, dangling}
    end
  end

  @doc """
  Public helper to check if graph contains a cycle.
  """
  @spec contains_cycle?(Graph.t()) :: boolean()
  def contains_cycle?(graph), do: not Graph.is_acyclic?(graph)

  @doc """
  Public helper to find orphan nodes.
  """
  @spec find_orphans(Graph.t()) :: list()
  def find_orphans(graph) do
    all_nodes = Graph.vertices(graph)
    roots = Graph.vertices(graph) |> Enum.filter(&(Graph.in_degree(graph, &1) == 0))
    reachable = roots |> Enum.flat_map(&Graph.reachable(graph, [&1])) |> MapSet.new()
    Enum.reject(all_nodes, &MapSet.member?(reachable, &1))
  end
end
