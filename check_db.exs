# check_db.exs
alias ProCoder.Repo
alias ProCoder.Skills.DatabaseDiscoverySkill

IO.inspect(DatabaseDiscoverySkill.describe_schema(%{}), label: "Schema Summary")

IO.puts("Relationship counts:")
{:ok, %{rows: rows}} = Repo.query("SELECT type, COUNT(*) FROM code_relationships GROUP BY type")
Enum.each(rows, fn [type, count] ->
  IO.puts("#{type}: #{count}")
end)

IO.puts("\nLatest 5 relationships:")
{:ok, %{rows: rows}} = Repo.query("SELECT type, from_node, to_node FROM code_relationships ORDER BY id DESC LIMIT 5")
Enum.each(rows, fn [type, from, to] ->
  IO.puts("#{type} | #{from} -> #{to}")
end)

IO.puts("\nChecking for calls relationships specifically:")
{:ok, %{rows: rows}} = Repo.query("SELECT COUNT(*) FROM code_relationships WHERE type = 'calls'")
IO.puts("Calls count: #{List.first(List.first(rows))}")

IO.inspect(DatabaseDiscoverySkill.list_relationships(%{"type" => "calls", "query" => "ProCoder"}), label: "List Relationships (calls, ProCoder)")
