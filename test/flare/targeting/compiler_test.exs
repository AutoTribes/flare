defmodule Flare.Targeting.CompilerTest do
  use ExUnit.Case, async: true
  alias Flare.Targeting.{Compiler, Rule}

  @rule %{
    "op" => "and",
    "conditions" => [
      %{
        "op" => "or",
        "conditions" => [
          %{"attr" => "country", "operator" => "in", "values" => ["KE", "UG"]},
          %{"segment" => "beta"}
        ]
      },
      %{"attr" => "app_version", "operator" => "semver_gte", "values" => ["5.2.0"]}
    ]
  }

  @segments %{
    "beta" => %{
      "op" => "and",
      "conditions" => [%{"attr" => "role", "operator" => "equals", "values" => ["driver"]}]
    }
  }

  test "compiles and inlines segments" do
    compiled = Compiler.compile(@rule, @segments)
    assert Rule.matches?(compiled, %{"country" => "KE", "app_version" => "5.3.0"})

    assert Rule.matches?(compiled, %{
             "country" => "TZ",
             "role" => "driver",
             "app_version" => "5.2.0"
           })

    refute Rule.matches?(compiled, %{
             "country" => "TZ",
             "role" => "rider",
             "app_version" => "5.2.0"
           })

    refute Rule.matches?(compiled, %{"country" => "KE", "app_version" => "5.1.0"})
  end

  test "dangling segment reference compiles to always-false" do
    compiled = Compiler.compile(%{"segment" => "missing"}, %{})
    refute Rule.matches?(compiled, %{})
  end

  test "empty rule matches everything (fallthrough semantics handled by caller)" do
    compiled = Compiler.compile(%{}, %{})
    assert Rule.matches?(compiled, %{"anything" => 1})
  end
end
