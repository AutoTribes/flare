defmodule Flare.SDK.ClientTest do
  use ExUnit.Case, async: true
  alias Flare.SDK

  @payload %{
    "version" => 3,
    "segments" => %{},
    "flags" => [
      %{
        "key" => "payment_v2",
        "kind" => "boolean",
        "salt" => "s",
        "enabled" => true,
        "rules" => %{
          "list" => [
            %{
              "id" => "r1",
              "rule" => %{"attr" => "country", "operator" => "equals", "values" => ["KE"]},
              "variant" => "off"
            }
          ]
        },
        "rollout" => %{},
        "default_variant" => "on",
        "off_variant" => "off",
        "variants" => %{"on" => true, "off" => false},
        "targets" => %{},
        "bucket_by" => "user_id"
      },
      %{
        "key" => "theme",
        "kind" => "json",
        "salt" => "s2",
        "enabled" => true,
        "rules" => %{},
        "rollout" => %{},
        "default_variant" => "v1",
        "off_variant" => "v1",
        "variants" => %{"v1" => %{"color" => "teal"}},
        "targets" => %{},
        "bucket_by" => "user_id"
      }
    ]
  }

  defp offline_client do
    {:ok, pid} = SDK.start_link(mode: :offline, bootstrap: @payload)
    pid
  end

  test "is_enabled evaluates locally from bootstrap" do
    c = offline_client()
    assert SDK.is_enabled(c, "payment_v2", %{user_id: "u", country: "UG"}) == true
    assert SDK.is_enabled(c, "payment_v2", %{user_id: "u", country: "KE"}) == false
  end

  test "variation returns the resolved value; default when flag missing" do
    c = offline_client()
    assert SDK.variation(c, "payment_v2", %{country: "KE"}) == false
    assert SDK.variation(c, "nope", %{}, "DEFLT") == "DEFLT"
  end

  test "json returns the JSON variant value" do
    c = offline_client()
    assert SDK.json(c, "theme", %{user_id: "u"}) == %{"color" => "teal"}
  end

  test "identify sets a default context merged into evaluations" do
    c = offline_client()
    :ok = SDK.identify(c, %{country: "KE"})
    # now even without passing country, the KE rule applies
    assert SDK.variation(c, "payment_v2", %{user_id: "u"}) == false
  end

  test "bootstrap reloads the ruleset" do
    {:ok, c} =
      SDK.start_link(
        mode: :offline,
        bootstrap: %{"version" => 1, "segments" => %{}, "flags" => []}
      )

    assert SDK.variation(c, "payment_v2", %{}, :missing) == :missing
    :ok = SDK.bootstrap(c, @payload)
    assert SDK.is_enabled(c, "payment_v2", %{country: "UG"}) == true
  end

  test "subscribe receives a notification on ruleset change" do
    c = offline_client()
    :ok = SDK.subscribe(c, self())
    :ok = SDK.bootstrap(c, %{"version" => 9, "segments" => %{}, "flags" => []})
    assert_receive {:flare_updated, 9}, 1000
  end

  test "offline_mode switches an existing client to offline" do
    c = offline_client()
    assert :ok = SDK.offline_mode(c)
  end

  test "killing a client's stream task does not crash the client (spawn_monitor)" do
    # base_url points nowhere; the stream task will fail fast and the client must survive + keep evaluating offline data
    {:ok, c} =
      Flare.SDK.start_link(
        mode: :streaming,
        base_url: "http://127.0.0.1:1",
        sdk_key: "x.y",
        bootstrap: %{
          "version" => 1,
          "segments" => %{},
          "flags" => [
            %{
              "key" => "f",
              "kind" => "boolean",
              "salt" => "s",
              "enabled" => true,
              "rules" => %{},
              "rollout" => %{},
              "default_variant" => "on",
              "off_variant" => "off",
              "variants" => %{"on" => true, "off" => false},
              "targets" => %{},
              "bucket_by" => "user_id"
            }
          ]
        },
        reconnect_backoff: 50
      )

    # even though streaming fails to connect, local eval from bootstrap works and the client stays alive
    assert Flare.SDK.variation(c, "f", %{}) == true
    Process.sleep(150)
    assert Process.alive?(c)
    assert Flare.SDK.variation(c, "f", %{}) == true
  end
end
