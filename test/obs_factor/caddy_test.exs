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
    assert r.hosts["a.test"].errors == 0.0
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
end
