defmodule ProCoder.MixProject do
  use Mix.Project

  def project do
    [
      app: :procoder,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon, :inets],
      mod: {ProCoder.Application, []}
    ]
  end

  defp deps do
    [
      # Graph-based orchestration for Planner
      {:libgraph, "~> 0.16.0"},
      
      # High-performance NIF bridge for AST/Tree-sitter
      {:rustler, "~> 0.31.0"},
      
      # HTTP/2 Client for LLM interactions
      {:finch, "~> 0.17.0"},
      
      # High-speed JSON serialization
      {:jason, "~> 1.4.0"},
      
      # Robust API interaction helper
      {:req, "~> 0.3.0"},
      
      # Visual TUI layer for interactive diffs
      {:owl, "~> 0.11.0"},
      
      # SQLite persistence for CodeGraph and Memory
      {:ecto_sqlite3, "~> 0.13.0"},
      
      
      # SQLite Vector Similarity Search
      {:sqlite_vss, "~> 0.1"},
      {:exqlite, "~> 0.35.0", override: true},
      
      # CDMS WebSocket Telemetry
      {:websockex, "~> 0.4.3"}
    ]
  end
end
