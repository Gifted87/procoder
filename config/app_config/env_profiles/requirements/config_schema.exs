defmodule ProCoder.Config.Schema do
  @moduledoc """
  DSL for defining and validating application configuration schemas.
  This module allows for structured declaration of environment variables,
  type coercion, default value handling, and cross-variable validation.
  """

  defstruct fields: %{}, validations: []

  @type type :: :integer | :string | :boolean | :atom
  @type field_definition :: %{
          type: type(),
          default: any() | nil,
          required: boolean(),
          sensitive: boolean()
        }

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)
      @before_compile unquote(__MODULE__)
      Module.register_attribute(__MODULE__, :fields, accumulate: true)
      Module.register_attribute(__MODULE__, :validations, accumulate: true)
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote do
      @fields {unquote(name), %{type: unquote(type), opts: unquote(opts)}}
    end
  end

  defmacro validate(name, fun) do
    quote do
      @validations {unquote(name), unquote(fun)}
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      def schema, do: %{fields: @fields, validations: @validations}

      def validate_config!(config) do
        Enum.each(@fields, fn {name, meta} ->
          val = Map.get(config, name)
          opts = meta[:opts] || []

          if opts[:required] && is_nil(val) do
            raise "Configuration error: #{name} is required."
          end

          if val && opts[:sensitive] && Mix.env() == :prod do
             # SecurityAudit: Ensure sensitive values are not logged if system allowed it
          end
        end)

        Enum.each(@validations, fn {name, fun} ->
          val = Map.get(config, name)
          unless fun.(val, config), do: raise("Validation failed for #{name}")
        end)
      end
    end
  end

  def load_and_cast(field_meta, raw_value) when is_binary(raw_value) do
    case field_meta[:type] do
      :integer -> String.to_integer(raw_value)
      :boolean -> String.downcase(raw_value) in ["true", "1", "yes"]
      :atom -> String.to_existing_atom(raw_value)
      _ -> raw_value
    end
  end
  def load_and_cast(_, value), do: value
end
