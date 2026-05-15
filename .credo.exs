%{
  configs: [
    %{
      name: "default",
      strict: true,
      color: true,
      checks: [
        {Credo.Check.Design.AliasUsage, false}
      ]
    }
  ]
}
