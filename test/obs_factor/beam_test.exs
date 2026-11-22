defmodule ObsFactor.BeamTest do
  use ExUnit.Case, async: false
  require Logger

  test "the log ring keeps what the observer logs, filterable by level" do
    tag = "beam-test-#{System.unique_integer([:positive])}"
    Logger.warning("#{tag} warning")
    Logger.error("#{tag} error")
    # :logger runs handlers in the caller; the insert is done on return.
    mine = Enum.filter(ObsFactor.LogRing.recent(500), &String.starts_with?(&1.text, tag))
    assert [%{level: :warning, text: _, at: at, pid: "<" <> _, where: "ObsFactor.BeamTest." <> _}, %{level: :error}] = mine
    assert_in_delta at, System.system_time(:millisecond), 5_000
    assert [%{level: :error}] = Enum.filter(ObsFactor.LogRing.recent(500, :error), &String.starts_with?(&1.text, tag))
  end

  test "the report reads the VM and the supervision tree as they are" do
    # The ring is empty until something logs; under some seeds this test runs first.
    Logger.warning("beam-test report")
    r = ObsFactor.Beam.report()
    assert r.vm.process_count > 0 and r.vm.schedulers > 0 and r.vm.memory.total > 0
    assert r.vm.otp == to_string(:erlang.system_info(:otp_release))

    ring = Enum.find(r.processes, &(&1.id == "LogRing"))
    assert ring.alive and ring.type == :worker and is_integer(ring.message_queue_len)
    assert Enum.any?(r.tables, &(&1.name == "LogRing" and &1.size > 0))
    # Encodes as the API serves it.
    assert {:ok, _} = Jason.encode(r)
  end

  test "events carry an id to tail from and the logger metadata as attributes" do
    before = ObsFactor.LogRing.since(0) |> List.last() |> then(&((&1 && &1.id) || 0))
    Logger.warning("beam-test attrs", source: :docker, request_id: "F1x", job: "deci-1")
    assert [%{text: "beam-test attrs", id: id, attrs: attrs}] = ObsFactor.LogRing.since(before) |> Enum.filter(&(&1.text == "beam-test attrs"))
    assert id > before
    assert %{source: "docker", request_id: "F1x", job: "deci-1", line: line} = attrs
    assert is_integer(line) and is_binary(attrs.file)
    refute Map.has_key?(attrs, :gl) or Map.has_key?(attrs, :pid)
    assert [] = ObsFactor.LogRing.since(id) |> Enum.filter(&(&1.text == "beam-test attrs"))
  end
end
