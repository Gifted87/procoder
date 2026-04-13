defmodule ProCoder.Search.Coordinator.SearchCascadeTest do
  @moduledoc """
  Integration verification suite for the 'Gradient of Precision' search cascade.
  Validates cascade fidelity, fault tolerance, and concurrency performance.
  """
  use ExUnit.Case, async: false

  alias ProCoder.Search.Coordinator.Server, as: Coordinator
  alias ProCoder.Core.Types.SearchResult
  alias ProCoder.SessionManager

  @moduletag :integration

  setup_all do
    # Provision isolated worktree for tests
    {:ok, worktree_id} = SessionManager.provision_worktree("integration_test_suite")
    {:ok, %{worktree_id: worktree_id}}
  end

  describe "Cascade Fidelity and Degradation" do
    test "Exact Match Propagation (LSP)", %{worktree_id: wt_id} do
      # LSP is the first layer, should return high-fidelity results
      assert {:ok, results} = Coordinator.search("defmodule", [worktree_id: wt_id])
      assert Enum.any?(results, fn r -> r.source == :lsp end)
    end

    test "Graceful Degradation (LSP Failure)", %{worktree_id: wt_id} do
      # Simulate LSP failure (Requires ChaosAdapter injection)
      # This test ensures TextEngine handles the fallback
      SessionManager.inject_failure(wt_id, :lsp, :hard)
      
      assert {:ok, results} = Coordinator.search("defmodule", [worktree_id: wt_id])
      assert Enum.any?(results, fn r -> r.source == :text_engine end)
    end

    test "Fallback Verification (LSP + TextEngine Failure)", %{worktree_id: wt_id} do
      SessionManager.inject_failure(wt_id, :lsp, :hard)
      SessionManager.inject_failure(wt_id, :text_engine, :hard)
      
      assert {:ok, results} = Coordinator.search("defmodule", [worktree_id: wt_id])
      assert Enum.any?(results, fn r -> r.source == :vector_store end)
    end
  end

  describe "Fault-Tolerance and Recovery" do
    test "Transient Error Handling (Timeout)", %{worktree_id: wt_id} do
      SessionManager.inject_failure(wt_id, :lsp, :transient)
      
      # Should proceed to next layer instead of failing the request
      assert {:ok, _results} = Coordinator.search("defmodule", [worktree_id: wt_id])
    end

    test "Hard Failure Isolation (Supervision Tree)", %{worktree_id: wt_id} do
      # Assert that hard failure at a layer does not kill the coordinator
      SessionManager.inject_failure(wt_id, :lsp, :hard)
      
      # Execute many queries to ensure stability
      Enum.each(1..10, fn _ ->
        Coordinator.search("defmodule", [worktree_id: wt_id])
      end)
      
      assert Process.alive?(Process.whereis(Coordinator))
    end
  end

  describe "Concurrent Performance and Load" do
    test "High-Entropy Workload Throughput", %{worktree_id: wt_id} do
      queries = ["defmodule", "alias", "def", "use", "import", "GenServer"]
      tasks = 
        for _ <- 1..500 do
          Task.async(fn ->
            Coordinator.search(Enum.random(queries), [worktree_id: wt_id])
          end)
        end

      results = Task.yield_many(tasks, 30_000)
      
      success_count = Enum.count(results, fn {_, res} -> 
        case res do
          {:ok, {:ok, _}} -> true
          _ -> false
        end
      end)
      
      assert success_count > 450
    end
  end

  describe "Security and Robustness" do
    test "Sandbox Isolation (Traversal Attack)", %{worktree_id: wt_id} do
      # TextEngine should reject directory traversal attempts
      assert {:error, _} = Coordinator.search("../../../etc/passwd", [worktree_id: wt_id])
    end

    test "Credential Protection (Redaction)", %{worktree_id: wt_id} do
      # Ensure secrets are not in the result set or logs
      # Using a hypothetical search that would return sensitive info if leaked
      assert {:ok, results} = Coordinator.search("SECRET_KEY", [worktree_id: wt_id])
      
      Enum.each(results, fn res ->
        refute String.contains?(res.content, "SECRET_KEY")
      end)
    end
  end
end
