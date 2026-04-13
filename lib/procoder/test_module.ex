defmodule ProCoder.TestModule do
  def hello do
    IO.puts "Hello"
    ProCoder.Repo.query("SELECT 1")
  end
end
