defmodule ProCoder.Actuator.PolicyLogic.PolicyEngine do
  @moduledoc """
  The PolicyEngine is the critical decision-making gatekeeper of the ProCoder autonomous system.
  It implements a multi-factor risk heuristic to assess agent actions (e.g., shell commands, code modifications)
  and determine if they should be executed, reviewed, or rejected.

  Heuristic: R = W_c * Entropy + W_u * Uncertainty + W_i * Impact
  """

  use GenServer
  require Logger

  @table_name :policy_engine_state
  @default_weights %{entropy: 0.4, uncertainty: 0.3, impact: 0.3}
  @type action_data :: %{
          risk: float(),          # 0.1 to 0.9
          uncertainty: float(),   # 0.0 to 1.0
          repetition: integer(),  # Count of same action in loop
          idle_time_ms: integer(), # Time since last user activity
          type: :shell | :code_mod
        }

  @type evaluation_result :: :execute | :verify | :suspend

  @doc """
  Evaluates an action and returns the authorization decision based on Blueprint v2.0.
  """
  @spec evaluate_action(action_data()) :: evaluation_result()
  def evaluate_action(data) do
    cond do
      # 1. The "Auto-Pilot" Rule: (R < 0.4) AND (U < 0.2) -> EXECUTE
      data.risk < 0.4 and data.uncertainty < 0.2 ->
        :execute

      # 2. The "Verify" Rule: (R > 0.6) OR (U > 0.5) -> INTERRUPT
      data.risk > 0.6 or data.uncertainty > 0.5 ->
        :verify

      # Default to verify for safety in mid-range
      true ->
        :verify
    end
  end

  def calculate_risk(type, path) do
    base_risk = case type do
      :read -> 0.1
      :edit -> 0.5
      :shell -> 0.9
      :delete -> 0.9
    end

    site_risk = cond do
      String.starts_with?(path, "config/") -> 0.4
      String.starts_with?(path, "mix.exs") -> 0.4
      true -> 0.0
    end

    min(0.9, base_risk + site_risk)
  end



  # --- GenServer Implementation ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, read_concurrency: true])
    :ets.insert(@table_name, {:weights, @default_weights})
    {:ok, %{}}
  end
end
