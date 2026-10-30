defmodule VerifiedTranslations.TasksTest do
  # changes the global :path config, so not async
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias VerifiedTranslations.Message

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:verified_translations, :path, dir)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Application.delete_env(:verified_translations, :path)
      Mix.shell(Mix.Shell.IO)
    end)
  end

  defp run(task, args) do
    Mix.Task.reenable(task)
    Mix.Task.run(task, args)
  end

  test "put creates and merges, missing lists what is left", %{tmp_dir: dir} do
    run("verified_translations.put", ["Hello %{name}", "fi=Hei %{name}"])
    path = Message.path(dir, "default", "Hello %{name}")
    assert {:ok, %{"msgid" => "Hello %{name}", "fi" => "Hei %{name}"}, _} = Message.read(path)

    json = capture_io(fn -> run("verified_translations.missing", ["--json"]) end)

    assert [%{"msgid" => "Hello %{name}", "missing" => ["sv"], "fi" => "Hei %{name}"}] =
             JSON.decode!(json)

    batch = Path.join(dir, "batch.json")
    File.write!(batch, JSON.encode!([%{"msgid" => "Hello %{name}", "sv" => "Hej %{name}"}]))
    run("verified_translations.put", ["--from", batch])

    assert {:ok, %{"fi" => "Hei %{name}", "sv" => "Hej %{name}"}, _} = Message.read(path)
    assert capture_io(fn -> run("verified_translations.missing", ["--json"]) end) == "[]\n"
  end

  test "put validates everything before writing", %{tmp_dir: dir} do
    error =
      assert_raise Mix.Error, fn ->
        run("verified_translations.put", ["Hi %{name}", "fi=Moi %{nimi}", "xx=Nope"])
      end

    assert error.message =~ "fi uses unknown %{nimi}"
    assert error.message =~ ~s("xx" is not in configured locales)
    refute File.exists?(Message.path(dir, "default", "Hi %{name}"))
  end

  test "plural messages round-trip through missing --json and put --from", %{tmp_dir: dir} do
    forms = [{"one", "%{count} file"}, {"other", "%{count} files"}]
    path = Message.path(dir, "default", "%{count} files", plural: forms)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Message.encode("%{count} files", %{}, plural: true))

    [entry] = JSON.decode!(capture_io(fn -> run("verified_translations.missing", ["--json"]) end))
    assert entry["fi"] == %{"one" => "", "other" => ""}
    assert entry["path"] == path

    filled =
      Map.merge(entry, %{
        "fi" => %{"one" => "%{count} tiedosto", "other" => "%{count} tiedostoa"},
        "sv" => %{"one" => "%{count} fil", "other" => "%{count} filer"}
      })

    batch = Path.join(dir, "batch.json")
    File.write!(batch, JSON.encode!([filled]))
    run("verified_translations.put", ["--from", batch])

    assert {:ok, data, content} = Message.read(path)
    assert data["kind"] == "plural"
    assert data["fi"] == %{"one" => "%{count} tiedosto", "other" => "%{count} tiedostoa"}
    assert content =~ ~s({\n  "kind": "plural",\n  "msgid": "%{count} files")
    assert capture_io(fn -> run("verified_translations.missing", ["--json"]) end) == "[]\n"
  end

  test "put records machine origin with the model; review lists and approves", %{tmp_dir: dir} do
    run("verified_translations.put", [
      "Save",
      "fi=Tallenna",
      "sv=Spara",
      "--model",
      "claude-opus-5-5"
    ])

    path = Message.path(dir, "default", "Save")

    assert {:ok, %{"origin" => origin}, content} = Message.read(path)
    assert origin["fi"] == %{"by" => "machine", "model" => "claude-opus-5-5"}
    # provenance goes after the locales
    assert content =~ ~r/"sv": "Spara",\n  "origin"/

    listed = JSON.decode!(capture_io(fn -> run("verified_translations.review", ["--json"]) end))

    assert Enum.map(listed, &{&1["locale"], &1["model"]}) == [
             {"fi", "claude-opus-5-5"},
             {"sv", "claude-opus-5-5"}
           ]

    run("verified_translations.review", ["--approve", "--locale", "fi"])
    {:ok, %{"origin" => origin}, _} = Message.read(path)
    assert origin["fi"] == %{"by" => "machine", "model" => "claude-opus-5-5", "reviewed" => true}
    assert origin["sv"]["reviewed"] == nil

    # a person's edit removes the machine marker
    run("verified_translations.put", ["Save", "sv=Spara!", "--human"])
    {:ok, %{"origin" => origin}, _} = Message.read(path)
    refute Map.has_key?(origin, "sv")
    assert capture_io(fn -> run("verified_translations.review", ["--json"]) end) == "[]\n"
  end
end
