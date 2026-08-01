import CSDP

private def problem : CSDP.Problem := {
  blockSizes := #[1]
  b := #[1.0]
  c := #[⟨1, 1, 1, 1.0⟩]
  a := #[⟨1, 1, 1, 1, 1.0⟩]
}

def checkCSDP : IO Unit := do
  let solution := CSDP.solve problem
  unless solution.ret == 0 do
    throw <| IO.userError s!"CSDP failed with code {solution.ret}"
  let error := (solution.pobj - 1.0).abs
  unless error ≤ 1e-4 do
    throw <| IO.userError
      s!"expected objective 1.0, got {solution.pobj} (error {error})"

#eval checkCSDP
