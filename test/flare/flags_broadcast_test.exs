defmodule Flare.FlagsBroadcastTest do
  use Flare.DataCase, async: false
  use Oban.Testing, repo: Flare.Repo
  alias Flare.{Accounts, Flags, Projects}
  alias Flare.Flags.FlagVersion
  import Ecto.Query

  setup do
    {:ok, org} = Accounts.create_organization(%{name: "A", slug: "a"})
    {:ok, proj} = Projects.create_project(%{name: "P", slug: "p", organization_id: org.id})

    {:ok, env} =
      Projects.create_environment(%{name: "Prod", key: "production", project_id: proj.id})

    {:ok, flag} =
      Flags.create_flag(%{
        project_id: proj.id,
        key: "payment_v2",
        kind: "boolean",
        variants: [%{key: "on", value: true}, %{key: "off", value: false}]
      })

    %{org: org, env: env, flag: flag}
  end

  test "publish bumps version, writes flag_version, enqueues audit, broadcasts", %{
    org: org,
    env: env,
    flag: flag
  } do
    Phoenix.PubSub.subscribe(Flare.PubSub, "env:#{env.id}")

    {:ok, version} =
      Flags.update_env_setting_and_publish(
        flag,
        env,
        %{enabled: true, default_variant_key: "on", off_variant_key: "off"},
        nil
      )

    assert version == 1
    # env row bumped
    assert Flare.Repo.get!(Flare.Projects.Environment, env.id).ruleset_version == 1
    # exactly one flag_version at version 1
    versions = Flare.Repo.all(from v in FlagVersion, where: v.environment_id == ^env.id)
    assert length(versions) == 1
    assert hd(versions).version == 1
    # audit job enqueued
    assert_enqueued(worker: Flare.Audit.LogWorker)
    # broadcast received
    assert_receive {:ruleset_updated, 1}, 2000
    # sanity: org is reachable for audit
    assert org.id
  end

  test "second publish bumps to version 2", %{env: env, flag: flag} do
    {:ok, 1} =
      Flags.update_env_setting_and_publish(
        flag,
        env,
        %{enabled: true, default_variant_key: "on", off_variant_key: "off"},
        nil
      )

    {:ok, 2} =
      Flags.update_env_setting_and_publish(
        flag,
        env,
        %{enabled: false, default_variant_key: "on", off_variant_key: "off"},
        nil
      )
  end
end
