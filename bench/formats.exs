# Parse time of 5,000 one-message files with 6 locales in candidate formats.
#   elixir bench/formats.exs
Mix.install([{:toml, "~> 0.7"}, {:yaml_elixir, "~> 2.11"}, {:expo, "~> 1.1"}])

dir = Path.join(System.tmp_dir!(), "vt_formats")
File.rm_rf!(dir)
File.mkdir_p!(dir)
n = 5000
locales = ~w(fi sv de fr es)

msgs =
  for i <- 1..n,
      do:
        {"Message #{i} for %{name} with \"quotes\"",
         Map.new(locales, &{&1, "[#{&1}] #{i} %{name}"})}

pairs = fn {id, t} -> [{"msgid", id} | Enum.sort(t)] end

writers = %{
  "json" => fn {id, t} -> JSON.encode!(Map.put(t, "msgid", id)) end,
  "toml" => &Enum.map_join(pairs.(&1), "\n", fn {k, v} -> "#{k} = #{JSON.encode!(v)}" end),
  "yaml" => &Enum.map_join(pairs.(&1), "\n", fn {k, v} -> "#{k}: #{JSON.encode!(v)}" end),
  "erl" => &Enum.map_join(pairs.(&1), "", fn {k, v} -> "{#{k}, #{JSON.encode!(v)}}.\n" end),
  "exs" =>
    &("%{" <>
        Enum.map_join(pairs.(&1), ", ", fn {k, v} -> "#{inspect(k)} => #{inspect(v)}" end) <> "}"),
  "po" => fn {id, t} ->
    Enum.map_join(Enum.sort(t), "\n", fn {k, v} ->
      "msgctxt #{JSON.encode!(k)}\nmsgid #{JSON.encode!(id)}\nmsgstr #{JSON.encode!(v)}\n"
    end)
  end
}

erl_terms = fn s ->
  {:ok, tokens, _} = :erl_scan.string(String.to_charlist(s))

  tokens
  |> Enum.chunk_while(
    [],
    fn
      {:dot, _} = d, acc -> {:cont, Enum.reverse([d | acc]), []}
      t, acc -> {:cont, [t | acc]}
    end,
    &{:cont, &1}
  )
  |> Enum.map(fn ts ->
    {:ok, term} = :erl_parse.parse_term(ts)
    term
  end)
end

readers = %{
  "json" => &JSON.decode!/1,
  "toml" => &Toml.decode!/1,
  "yaml" => &YamlElixir.read_from_string!/1,
  "erl" => erl_terms,
  "exs" => fn s ->
    quoted = Code.string_to_quoted!(s)
    true = Macro.quoted_literal?(quoted)
    quoted |> Code.eval_quoted() |> elem(0)
  end,
  "po" => &Expo.PO.parse_string!/1
}

for {format, write} <- Enum.sort(writers) do
  files =
    for {m, i} <- Enum.with_index(msgs) do
      path = Path.join(dir, "#{i}.#{format}")
      File.write!(path, write.(m))
      path
    end

  {us, _} = :timer.tc(fn -> Enum.each(files, &readers[format].(File.read!(&1))) end)

  IO.puts(
    "#{String.pad_trailing(format, 5)} #{div(us, 1000)}ms (#{Float.round(us / n, 1)}µs/file)"
  )
end
