defmodule ProCoder.Brain.PromptEngine.Requirements do
  @moduledoc """
  Requirements and dependency specification for the ProCoder PromptEngine.
  
  This module defines the foundational requirements, constraints, and 
  mandatory dependencies for the PromptEngine logic, ensuring architectural
  consistency with the ProCoder system requirements.
  """

  @doc """
  Returns the mandatory dependency list for the PromptEngine.
  """
  def dependencies do
    [
      {:jason, "~> 1.4.0"},
      {:libgraph, "~> 0.16.0"},
      {:telemetry, "~> 1.2.0"}
    ]
  end

  @doc """
  Returns the architectural constraints for context salience ranking.
  """
  def salience_ranking_config do
    %{
      context_salience_threshold: 0.75,
      scoring_weights: %{
        code_graph: 0.9,
        history: 0.4,
        task_dag: 0.8
      }
    }
  end

  @doc """
  Returns the constraints for unified message formatting and token management.
  """
  def formatting_constraints do
    %{
      max_tokens_per_prompt: 200_000,
      normalization_strategy: :strict,
      redaction_patterns: [
        ~r/(?:AIza[0-9A-Za-z-_]{35})/,
        ~r/(?:sk-(?:live|test)_[a-zA-Z0-9]{32})/
      ]
    }
  end

  @doc """
  Defines the correction loop parameters for malformed tool calls.
  """
  def error_correction_config do
    %{
      max_retries: 3,
      validation_tool: Jason
    }
  end
end
