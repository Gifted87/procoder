defmodule ProCoder.Brain.Client.KeyRotator do
  @moduledoc """
  Manages a pool of API keys and performs sequential rotation.
  Loads keys from the PROCODER_LLM_API_KEYS environment variable.
  """
  use GenServer
  require Logger

  @name __MODULE__

  # --- Client API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Returns the full list of API keys, rotated so the 'next' key is at the head.
  Advances the rotation index for the next call.
  """
  def get_keys do
    GenServer.call(@name, :get_keys_and_rotate)
  end

  @doc """
  Returns just the next single API key and advances the rotation.
  """
  def get_next_key do
    case get_keys() do
      [key | _] -> key
      [] -> nil
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    keys = load_keys()
    if keys == [] do
      Logger.warning("[KeyRotator] No API keys found in PROCODER_LLM_API_KEYS environment variable.")
    else
      Logger.info("[KeyRotator] Initialized with #{length(keys)} API keys.")
    end
    {:ok, %{keys: keys, index: 0}}
  end

  @impl true
  def handle_call(:get_keys_and_rotate, _from, %{keys: [], index: _} = state) do
    {:reply, [], state}
  end

  @impl true
  def handle_call(:get_keys_and_rotate, _from, %{keys: keys, index: index}) do
    count = length(keys)
    rotated_keys = rotate_list(keys, index)
    
    # Sequential rotation: increment index for the NEXT call
    new_index = rem(index + 1, count)
    
    {:reply, rotated_keys, %{keys: keys, index: new_index}}
  end

  # --- Private Helpers ---

  defp load_keys do
    System.get_env("PROCODER_LLM_API_KEYS")
    |> case do
      nil -> []
      str -> 
        str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  defp rotate_list(list, 0), do: list
  defp rotate_list(list, index) do
    {left, right} = Enum.split(list, index)
    right ++ left
  end
end
