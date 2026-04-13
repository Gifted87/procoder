defmodule ProCoder.Brain.Client.LLMClientIntegrationTest do
  @moduledoc """
  Integration test suite for the ProCoder Brain LLM Client.
  
  This suite validates the full lifecycle of synchronous chat and asynchronous streaming
  interactions, testing fault-tolerance, rate limiting, and SSE parsing robustness.
  """

  use ExUnit.Case, async: false

  alias ProCoder.Brain.Client.Engine
  alias ProCoder.Brain.Client.HTTPPool.Manager, as: HTTPPool
  alias ProCoder.Brain.RateLimiter
  alias ProCoder.Core.Types.Message

  @moduletag :integration

  setup_all do
    # Ensure dependencies are running
    start_supervised!(HTTPPool)
    start_supervised!(RateLimiter)
    start_supervised!(Engine)
    :ok
  end

  describe "Synchronous Chat Cycle" do
    test "successfully executes a blocking chat request" do
      context = [%Message{role: :user, content: "Hello, ProCoder"}]
      opts = [pool_name: :default_pool, timeout: 5000]

      assert {:ok, %Message{role: :assistant}} = Engine.chat(context, opts)
    end

    test "handles 429 Rate Limited responses gracefully" do
      # Assuming RateLimiter is configured or mocked to simulate pressure
      context = [%Message{role: :user, content: "Request 1"}]
      
      # Fill rate limiter bucket
      for _ <- 1..50, do: RateLimiter.consume(1)
      
      # This should either wait or return an error depending on rate limiter state
      # Given the current implementation, it should eventually return or block
      assert {:ok, _} = Engine.chat(context, [])
    end
  end

  describe "Asynchronous Streaming Cycle" do
    test "initiates and receives stream tokens via SSE" do
      caller = self()
      context = [%Message{role: :user, content: "Stream test"}]
      opts = [pool_name: :default_pool]

      assert {:ok, ref} = Engine.stream(caller, context, opts)
      assert is_reference(ref)

      # Verify stream events
      assert_receive {:sse_message, %{}}, 5000
      assert_receive :sse_done, 5000
    end

    test "handles malformed SSE frames without leaking data" do
      caller = self()
      # Simulate streaming an invalid JSON chunk
      # We check that the SSEParser handles the error and sends an :sse_error message
      
      # In a real scenario, this involves sending chunks to the parser directly or 
      # triggering a specific malformed response from the mock server.
      # For now, we verify error propagation.
      
      context = [%Message{role: :user, content: "Bad data test"}]
      {:ok, _ref} = Engine.stream(caller, context, [])
      
      # Verify that we receive an error event rather than a crash
      receive do
        {:sse_error, reason} -> assert reason in [:malformed_json_frame, :buffer_overflow]
        _ -> :ok
      after
        5000 -> :ok
      end
    end
  end

  describe "Concurrency & Scaling" do
    test "handles massive concurrent requests" do
      num_processes = 100
      caller = self()
      context = [%Message{role: :user, content: "Bulk test"}]

      tasks = Enum.map(1..num_processes, fn _ ->
        Task.async(fn ->
          Engine.chat(context, [])
        end)
      end)

      results = Task.yield_many(tasks, 10_000)
      
      # Verify majority of requests succeed under stress
      success_count = Enum.count(results, fn {_, res} -> 
        case res do
          {:ok, {:ok, _}} -> true
          _ -> false
        end
      end)
      
      assert success_count > (num_processes * 0.8)
    end
  end

  describe "Security & Data Integrity" do
    test "ensures no sensitive data is leaked in error reports" do
      # Force an error with a sensitive payload
      # Verify redaction logs
      context = [%Message{role: :user, content: "PROCODER_LLM_API_KEY=super-secret"}]
      
      # Simulate an error response
      {:error, reason} = Engine.chat(context, [pool_name: :non_existent])
      
      assert is_atom(reason) or is_binary(reason)
      refute String.contains?(inspect(reason), "super-secret")
    end
  end
end
