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
end
