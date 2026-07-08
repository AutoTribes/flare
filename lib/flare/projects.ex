defmodule Flare.Projects do
  @moduledoc "Projects context."
  alias Flare.Accounts.Organization
  alias Flare.Projects.{ApiKey, Environment, Project, SdkKey}
  alias Flare.Repo

  def create_project(attrs), do: %Project{} |> Project.changeset(attrs) |> Repo.insert()

  def create_environment(attrs),
    do: %Environment{} |> Environment.changeset(attrs) |> Repo.insert()

  def get_environment!(id), do: Repo.get!(Environment, id)

  @doc "Generate an SDK key. Returns the plaintext token ONCE; only the hash is stored."
  def generate_sdk_key(%Environment{id: env_id}, kind) when kind in [:server, :client, :mobile] do
    prefix = "sdk-" <> random_token(6)
    secret = random_token(32)
    token = prefix <> "." <> secret

    %SdkKey{}
    |> SdkKey.changeset(%{
      kind: to_string(kind),
      prefix: prefix,
      hashed_secret: Argon2.hash_pwd_salt(secret),
      environment_id: env_id
    })
    |> Repo.insert()
    |> case do
      {:ok, sk} -> {:ok, %{sdk_key: sk, plaintext: token}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc "Verify an SDK key token. Constant-time on unknown prefix."
  def verify_sdk_key(token) when is_binary(token) do
    with [prefix, secret] <- String.split(token, ".", parts: 2),
         %SdkKey{} = sk <- Repo.get_by(SdkKey, prefix: prefix),
         true <- not_expired?(sk.expires_at),
         true <- Argon2.verify_pass(secret, sk.hashed_secret) do
      touch_last_used(sk)
      {:ok, sk}
    else
      _ ->
        Argon2.no_user_verify()
        {:error, :invalid}
    end
  end

  def verify_sdk_key(_), do: {:error, :invalid}

  @doc "Generate an org API key with a permissions map."
  def generate_api_key(%Organization{id: org_id}, permissions) when is_map(permissions) do
    prefix = "api-" <> random_token(6)
    secret = random_token(32)
    token = prefix <> "." <> secret

    %ApiKey{}
    |> ApiKey.changeset(%{
      prefix: prefix,
      hashed_secret: Argon2.hash_pwd_salt(secret),
      permissions: permissions,
      organization_id: org_id
    })
    |> Repo.insert()
    |> case do
      {:ok, ak} -> {:ok, %{api_key: ak, plaintext: token}}
      {:error, cs} -> {:error, cs}
    end
  end

  def verify_api_key(token) when is_binary(token) do
    with [prefix, secret] <- String.split(token, ".", parts: 2),
         %ApiKey{} = ak <- Repo.get_by(ApiKey, prefix: prefix),
         true <- not_expired?(ak.expires_at),
         true <- Argon2.verify_pass(secret, ak.hashed_secret) do
      {:ok, ak}
    else
      _ ->
        Argon2.no_user_verify()
        {:error, :invalid}
    end
  end

  def verify_api_key(_), do: {:error, :invalid}

  defp random_token(bytes),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp not_expired?(nil), do: true
  defp not_expired?(%DateTime{} = at), do: DateTime.compare(at, DateTime.utc_now()) == :gt

  defp touch_last_used(%SdkKey{} = sk) do
    sk
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now() |> DateTime.truncate(:microsecond))
    |> Repo.update()
  end
end
