defmodule ObsFactor.CaddyTest do
  use ExUnit.Case, async: true

  alias ObsFactor.{Caddy, Fixtures, Prometheus}

  test "parses every sample line of the real Caddy 2.10.2 page" do
    samples = Prometheus.parse(Fixtures.caddy_text())

    lines =
      Fixtures.caddy_text()
      |> String.split("\n")
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    assert length(samples) == length(lines)

    assert {"caddy_http_requests_total",
            %{"host" => "a.test", "handler" => "subroute", "server" => "srv0"}, 6.0} in samples

    assert {"process_start_time_seconds", %{}, 1_795_041_304.9} in samples
  end

  test "label values with escapes" do
    assert [{"m", %{"a" => ~s(x"y\\z), "b" => "line\nbreak"}, 1.0}] =
             Prometheus.parse(~S(m{a="x\"y\\z",b="line\nbreak"} 1) <> "\n")
  end

  test "an unparseable line raises with the line" do
    assert_raise ArgumentError, ~r/garbage here/, fn -> Prometheus.parse("garbage here\n") end
  end

  test "per-host totals from the real page" do
    r = Caddy.reading(Fixtures.caddy_text(), 0)
    assert r.start == 1_795_041_304.9
    assert r.hosts["a.test"].requests == 6.0
    assert r.hosts["a.test"].dur_count == 6.0
    assert r.hosts["b.test"].requests == 5.0
    assert r.hosts["a.test"][{:code, "5xx"}] == 0.0
    assert_in_delta r.hosts["a.test"].dur_sum, 0.00778213 + 0.000168334, 1.0e-12
  end

  test "first scrape: every rate unknown" do
    rates = Caddy.rates(nil, Caddy.reading(Fixtures.caddy_text(), 0))
    assert rates.total_rps == nil
    assert rates.hosts["a.test"].rps == nil
  end

  test "rates between two scrapes" do
    rates = Fixtures.caddy()
    assert_in_delta rates.hosts["a.test"].rps, 2.0, 1.0e-9
    assert rates.hosts["b.test"].rps == 0.0
    assert_in_delta rates.total_rps, 2.0, 1.0e-9
    refute rates.reset
  end

  test "5xx and latency from duration counts" do
    a = Caddy.reading(Fixtures.caddy_text(), 0)

    extra =
      ~s(caddy_http_request_duration_seconds_count{code="502",handler="subroute",host="a.test",method="GET",server="srv0"} 4\n) <>
        ~s(caddy_http_request_duration_seconds_sum{code="502",handler="subroute",host="a.test",method="GET",server="srv0"} 0.4\n)

    text =
      String.replace(
        Fixtures.caddy_text(),
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 6),
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 10)
      ) <> extra

    b = Caddy.reading(text, 2_000)
    r = Caddy.rates(a, b)
    assert r.hosts["a.test"].rps == 2.0
    assert r.hosts["a.test"].err_rps == 2.0
    assert_in_delta r.hosts["a.test"].avg_ms, 100.0, 1.0e-9
  end

  test "Caddy restart: new start time means no rates, not a spike or a negative" do
    a = Caddy.reading(Fixtures.caddy_text(), 0)

    restarted =
      Fixtures.caddy_text()
      |> String.replace(
        "process_start_time_seconds 1.7950413049e+09",
        "process_start_time_seconds 1.7950414e+09"
      )
      |> String.replace(
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 6),
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 1)
      )

    r = Caddy.rates(a, Caddy.reading(restarted, 5_000))
    assert r.reset
    assert r.total_rps == nil
    assert Enum.all?(r.hosts, fn {_, h} -> h.rps == nil and h.err_rps == nil end)

    # And the scrape after the restart is back to normal rates.
    after_restart = Caddy.reading(restarted, 5_000)

    again =
      String.replace(
        restarted,
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 1),
        ~s(caddy_http_requests_total{handler="subroute",host="a.test",server="srv0"} 3)
      )

    r2 = Caddy.rates(after_restart, Caddy.reading(again, 10_000))
    refute r2.reset
    assert r2.hosts["a.test"].rps == 0.4
  end

  test "a counter that goes backwards without a start time change is a reset too" do
    a = Caddy.reading(Fixtures.caddy_text(), 0)

    b =
      Fixtures.caddy_text()
      |> String.replace(
        ~s(caddy_http_requests_total{handler="subroute",host="b.test",server="srv0"} 5),
        ~s(caddy_http_requests_total{handler="subroute",host="b.test",server="srv0"} 2)
      )
      |> Caddy.reading(5_000)

    r = Caddy.rates(a, b)
    assert r.reset
    assert r.total_rps == nil
  end

  test "the metrics endpoint's own requests are not traffic" do
    text =
      Fixtures.caddy_text() <>
        ~s(caddy_http_requests_total{handler="metrics",host="127.0.0.1:19180",server="srv1"} 9\n)

    r = Caddy.reading(text, 0)
    refute Map.has_key?(r.hosts, "127.0.0.1:19180")
  end

  test "a host that appears between scrapes of one process counts from zero" do
    a = Caddy.reading(Fixtures.caddy_text(), 0)

    text =
      Fixtures.caddy_text() <>
        ~s(caddy_http_requests_total{handler="subroute",host="new.test",server="srv0"} 5\n)

    r = Caddy.rates(a, Caddy.reading(text, 5_000))
    assert r.hosts["new.test"].rps == 1.0
  end

  describe "status classes, bytes and in-flight" do
    # The fixture's own series lines, so a replace that matches nothing fails
    # the test instead of quietly testing the unchanged page.
    @a_200 ~s(caddy_http_request_duration_seconds_count{code="200",handler="subroute",host="a.test",method="GET",server="srv0"} 5)
    @a_404 ~s(caddy_http_request_duration_seconds_count{code="404",handler="subroute",host="a.test",method="GET",server="srv0"} 1)
    @a_in ~s(caddy_http_request_size_bytes_sum{code="200",handler="subroute",host="a.test",method="GET",server="srv0"} 235)
    @a_out ~s(caddy_http_response_size_bytes_sum{code="200",handler="subroute",host="a.test",method="GET",server="srv0"} 15)
    @a_flying ~s(caddy_http_requests_in_flight{handler="subroute",host="a.test",server="srv0"} 0)

    defp swap(text, line, value) do
      assert String.contains?(text, line <> "\n"), "fixture has no line #{line}"
      [series, _old] = String.split(line, ~r/ (?=[^ ]+$)/)
      String.replace(text, line <> "\n", "#{series} #{value}\n")
    end

    defp duration_count(code, host, value) do
      ~s(caddy_http_request_duration_seconds_count{code="#{code}",handler="subroute",host="#{host}",method="GET",server="srv0"} #{value}\n)
    end

    test "class/1 buckets a code label" do
      assert Caddy.class("200") == "2xx"
      assert Caddy.class("299") == "2xx"
      assert Caddy.class("304") == "3xx"
      assert Caddy.class("404") == "4xx"
      assert Caddy.class("599") == "5xx"
      assert Caddy.class("101") == "other"
      assert Caddy.class("0") == "other"
      assert Caddy.class("600") == "other"
      assert Caddy.classes() == ["2xx", "3xx", "4xx", "5xx", "other"]
    end

    test "a code label that is not a number raises with the label" do
      assert_raise ArgumentError, ~r/code label is not a number: "teapot"/, fn ->
        Caddy.reading(Fixtures.caddy_text() <> duration_count("teapot", "a.test", 1), 0)
      end
    end

    test "a duration count without a code label raises with the labels" do
      line = ~s(caddy_http_request_duration_seconds_count{handler="subroute",host="a.test"} 1\n)

      assert_raise ArgumentError, ~r/without a code label: .*"a.test"/, fn ->
        Caddy.reading(Fixtures.caddy_text() <> line, 0)
      end
    end

    test "cumulative class counts, bytes and in-flight from the real page" do
      r = Caddy.reading(Fixtures.caddy_text(), 0)
      a = r.hosts["a.test"]
      assert a[{:code, "2xx"}] == 5.0
      assert a[{:code, "4xx"}] == 1.0
      assert a[{:code, "3xx"}] == 0.0
      assert a[{:code, "5xx"}] == 0.0
      assert a[{:code, "other"}] == 0.0
      # 200 and 404 series together.
      assert a.in_bytes == 235.0 + 51.0
      assert a.out_bytes == 15.0
      assert a.in_flight == 0

      b = r.hosts["b.test"]
      assert b.in_bytes == 235.0
      assert b.out_bytes == 1385.0
      assert b.in_flight == 0

      # The metrics handler's in-flight series (the scrape itself) is dropped.
      assert Map.keys(r.hosts) |> Enum.sort() == ["a.test", "b.test"]
    end

    test "class rates, byte rates and the gauge between two scrapes" do
      a = Caddy.reading(Fixtures.caddy_text(), 0)

      text =
        Fixtures.caddy_text()
        |> swap(@a_200, 15)
        |> swap(@a_404, 3)
        |> swap(@a_in, 1235)
        |> swap(@a_out, 50_015)
        |> swap(@a_flying, 2)
        |> Kernel.<>(duration_count("301", "a.test", 1))
        |> Kernel.<>(duration_count("502", "a.test", 4))
        |> Kernel.<>(duration_count("101", "a.test", 2))
        |> Kernel.<>(duration_count("0", "a.test", 1))
        # A second handler on the same host: gauges add up.
        |> Kernel.<>(
          ~s(caddy_http_requests_in_flight{handler="reverse_proxy",host="a.test",server="srv0"} 3\n)
        )

      r = Caddy.rates(a, Caddy.reading(text, 2_000))
      refute r.reset
      h = r.hosts["a.test"]
      assert h.codes == %{"2xx" => 5.0, "3xx" => 0.5, "4xx" => 1.0, "5xx" => 2.0, "other" => 1.5}
      assert h.err_rps == 2.0
      assert h.in_bps == 500.0
      assert h.out_bps == 25_000.0
      assert h.in_flight == 5

      quiet = r.hosts["b.test"]

      assert quiet.codes == %{
               "2xx" => 0.0,
               "3xx" => 0.0,
               "4xx" => 0.0,
               "5xx" => 0.0,
               "other" => 0.0
             }

      assert quiet.in_bps == 0.0
      assert quiet.out_bps == 0.0
      assert quiet.in_flight == 0
    end

    test "first scrape: rates unknown, the gauge is already known" do
      text = swap(Fixtures.caddy_text(), @a_flying, 4)
      r = Caddy.rates(nil, Caddy.reading(text, 0))
      h = r.hosts["a.test"]
      assert h.codes == nil
      assert h.in_bps == nil
      assert h.out_bps == nil
      assert h.in_flight == 4
    end

    test "a class count going backwards is a reset: no rates, gauge still read" do
      a = Caddy.reading(Fixtures.caddy_text(), 0)
      b = Fixtures.caddy_text() |> swap(@a_404, 0) |> swap(@a_flying, 1) |> Caddy.reading(5_000)

      r = Caddy.rates(a, b)
      assert r.reset
      assert r.total_rps == nil

      for {_, h} <- r.hosts do
        assert h.rps == nil and h.err_rps == nil and h.codes == nil
        assert h.in_bps == nil and h.out_bps == nil
      end

      assert r.hosts["a.test"].in_flight == 1
    end

    test "byte counters going backwards are resets too" do
      a = Caddy.reading(Fixtures.caddy_text(), 0)

      for {line, value} <- [{@a_in, 10}, {@a_out, 1}] do
        b = Fixtures.caddy_text() |> swap(line, value) |> Caddy.reading(5_000)
        r = Caddy.rates(a, b)
        assert r.reset, "#{line} going back to #{value} was not seen as a reset"
        assert r.hosts["b.test"].out_bps == nil
      end
    end

    test "the gauge going down is not a reset" do
      up = Fixtures.caddy_text() |> swap(@a_flying, 7) |> Caddy.reading(0)
      r = Caddy.rates(up, Caddy.reading(Fixtures.caddy_text(), 5_000))
      refute r.reset
      assert r.hosts["a.test"].in_flight == 0
      assert r.hosts["a.test"].rps == 0.0
    end

    test "an in-flight value that is not a count raises with the value" do
      assert_raise ArgumentError, ~r/in_flight for "a.test" is not a count: 0.5/, fn ->
        Fixtures.caddy_text() |> swap(@a_flying, 0.5) |> Caddy.reading(0)
      end
    end

    test "a host known only by its in-flight gauge counts from zero" do
      a = Caddy.reading(Fixtures.caddy_text(), 0)

      text =
        Fixtures.caddy_text() <>
          ~s(caddy_http_requests_in_flight{handler="subroute",host="slow.test",server="srv0"} 1\n)

      r = Caddy.rates(a, Caddy.reading(text, 5_000))
      slow = r.hosts["slow.test"]
      assert slow.rps == 0.0
      assert slow.out_bps == 0.0
      assert slow.in_flight == 1
    end
  end
end
