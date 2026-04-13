defmodule ProCoder.Brain.PromptLogic.Engine.Tests.PromptEngineTest do
  @moduledoc """
  Comprehensive integration and property-based test suite for the PromptEngine subsystem.
  Covers salience ranking, message formatting, JSON correction, and pipeline integration.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ProCoder.Brain.PromptEngine.{SalienceRanker, Corrector}
  alias ProCoder.Brain.PromptLogic.Engine.Formatter
  alias ProCoder.Brain.PromptLogic.Engine.Core.Orchestrator
  alias ProCoder.Core.Types.Message

  describe "Salience Ranking Logic" do
    test "ranks and prunes segments based on weighted salience" do
      segments = [
        %{role: :user, content: "low", components: [history: 0.1]},
        %{role: :user, content: "high", components: [code_graph: 1.0, task_dag: 1.0]}
      ]

      ranked = SalienceRanker.rank(segments)
      assert length(ranked) == 1
      assert hd(ranked)[:salience_score] > 0.75
    end
  end

  describe "Message Formatting and Redaction" do
    test "formats input into Message struct and redacts PII" do
      input = %{role: :user, content: "API Key: AIza1234567890abcdef1234567890abcdef"}
      formatted = Formatter.format(input)
      
      assert String.contains?(formatted["content"], "[REDACTED]")
      refute String.contains?(formatted["content"], "AIza")
    end
  end

  describe "JSON Correction (Property-Based)" do
    property "corrects or identifies malformed JSON" do
      check all json_str <- StreamData.string(:printable, min_length: 5) do
        schema = %{"type" => "object"}
        result = Corrector.correct_tool_call(json_str, schema)
        
        case result do
          {:ok, parsed} -> assert is_map(parsed), "Parsed successfully"
          {:retry, feedback} -> assert is_binary(feedback), "Emitted correction prompt"
          {:error, :unrecoverable} -> :ok
        end
      end
    end
  end

  describe "Integration Workflow" do
    test "orchestrates full pipeline successfully" do
      raw_segments = [
        %{role: :user, content: "task details", components: [task_dag: 1.0]}
      ]

      {:ok, messages} = Orchestrator.orchestrate(raw_segments)
      assert is_list(messages)
      assert %Message{} = hd(messages)
    end

    test "handles broken context resiliently" do
      broken_segments = [%{content: nil}]
      assert {:error, :orchestration_failed} = Orchestrator.orchestrate(broken_segments)
    end
  end

  describe "Security and Hardening" do
    test "verifies complete redaction of secrets" do
      secret = "sk-live_1234567890abcdef1234567890abcdef"
      segments = [%{role: :user, content: "Secret: #{secret}", components: [history: 1.0]}]
      
      {:ok, messages} = Orchestrator.orchestrate(segments)
      content = hd(messages).content
      
      refute String.contains?(content, secret)
      assert String.contains?(content, "[REDACTED]")
    end
  end
end
