/-
  Lean wrapper for CSDP's `easy_sdp` interface.

  CSDP solves the standard-form semidefinite program

      maximise     tr(C · X)
      subject to   tr(Aᵢ · X) = bᵢ   for i = 1, …, k
                   X ⪰ 0  with block-diagonal structure

  All matrices are block-diagonal with a uniform block layout. Each block is
  either a symmetric SDP block (size n, the upper triangle of an n×n matrix)
  or an LP-style diagonal block (size n, just the n diagonal entries).
-/

module

public section

namespace CSDP

/--
A nonzero entry in a block-diagonal symmetric matrix. Indices are 1-based,
matching CSDP's conventions. `block` is the 1-based block index; `row` and
`col` index within that block. For SDP blocks, only the upper triangle
(`row ≤ col`) need be supplied; CSDP assumes symmetry.
-/
structure Triple where
  block : UInt32
  row   : UInt32
  col   : UInt32
  value : Float
deriving Repr

/--
A nonzero entry in a constraint matrix `Aᵢ`. Identifies the constraint
(1-based), the block, and the (row, col) within that block.
-/
structure ConstraintTriple where
  constraint : UInt32
  block      : UInt32
  row        : UInt32
  col        : UInt32
  value      : Float
deriving Repr

/--
SDP problem in CSDP's native form.

* `blockSizes`: one entry per block. Positive `n` denotes a symmetric SDP
  block of order `n`; negative `n` denotes a diagonal (LP) block of order
  `|n|`.
* `b`: right-hand side, of length `k = numConstraints`.
* `c`: nonzero entries of the cost matrix `C` (upper triangle).
* `a`: nonzero entries of the constraint matrices `A₁, …, Aₖ` (upper
  triangle).
* `constantOffset`: optional constant added to the objective value.
-/
structure Problem where
  blockSizes     : Array Int32
  b              : Array Float
  c              : Array Triple
  a              : Array ConstraintTriple
  constantOffset : Float := 0.0
deriving Repr

/-- Number of constraints (equal to `b.size`). -/
def Problem.numConstraints (p : Problem) : Nat := p.b.size

/-- Number of blocks (equal to `blockSizes.size`). -/
def Problem.numBlocks (p : Problem) : Nat := p.blockSizes.size

/-- Total ambient dimension `n = Σ |blockSizes[i]|`. -/
def Problem.totalDim (p : Problem) : Nat :=
  p.blockSizes.foldl (init := 0) fun acc s =>
    acc + (if s < 0 then (-s).toNatClampNeg else s.toNatClampNeg)

/--
Internal raw solution returned from FFI. Field order is fixed and must
match the C bridge in `ffi/lean_csdp_bridge.c`.
-/
structure RawSolution where
  ret  : Nat
  pobj : Float
  dobj : Float
  X    : FloatArray
  y    : FloatArray
  Z    : FloatArray
deriving Nonempty

@[extern "lean_csdp_solve_ffi"]
private opaque solveImpl
    (blockSizes : @& ByteArray) (b : @& FloatArray)
    (cBlocks : @& ByteArray) (cI : @& ByteArray) (cJ : @& ByteArray)
    (cVals : @& FloatArray)
    (aConstraints : @& ByteArray) (aBlocks : @& ByteArray)
    (aI : @& ByteArray) (aJ : @& ByteArray) (aVals : @& FloatArray)
    (constantOffset : Float) : RawSolution

/-- Pack a `UInt32` little-endian onto a `ByteArray`. -/
@[inline] private def pushU32LE (bs : ByteArray) (u : UInt32) : ByteArray :=
  bs.push (u &&& 0xff).toUInt8
    |>.push ((u >>> 8) &&& 0xff).toUInt8
    |>.push ((u >>> 16) &&& 0xff).toUInt8
    |>.push ((u >>> 24) &&& 0xff).toUInt8

/-- Pack an `Array Int32` into a little-endian `ByteArray`. -/
private def packInt32Array (xs : Array Int32) : ByteArray := Id.run do
  let mut bs := ByteArray.empty
  for x in xs do bs := pushU32LE bs x.toUInt32
  return bs

private def packUInt32Array (xs : Array UInt32) : ByteArray := Id.run do
  let mut bs := ByteArray.empty
  for x in xs do bs := pushU32LE bs x
  return bs

private def floatArrayOfArray (xs : Array Float) : FloatArray := Id.run do
  let mut a := FloatArray.empty
  for x in xs do a := a.push x
  return a

/--
Block within a flat output buffer. Either a square SDP block of side `n`
stored column-major, or a diagonal block of side `n` storing just the
diagonal entries.
-/
inductive Block where
  /-- Symmetric `n × n` block stored column-major (`n^2` entries). -/
  | sdp  (n : Nat) (entries : FloatArray)
  /-- Diagonal block of order `n` (just the `n` diagonal entries). -/
  | diag (n : Nat) (entries : FloatArray)

/--
Solution returned by `solve`. `ret = 0` indicates success per CSDP
conventions; nonzero values correspond to CSDP failure codes (with `99`
reserved for an internal allocation failure in the bridge).
-/
structure Solution where
  /-- CSDP return code; `0` means success. -/
  ret  : Nat
  /-- Primal objective value. -/
  pobj : Float
  /-- Dual objective value. -/
  dobj : Float
  /-- Primal variable `X`, split into its blocks. -/
  X    : Array Block
  /-- Dual variable `y` (length `k`). -/
  y    : FloatArray
  /-- Dual slack `Z`, split into its blocks. -/
  Z    : Array Block

/-- Slice a flat blockmatrix buffer into per-block `Block` values. -/
private def splitBlocks (blockSizes : Array Int32) (flat : FloatArray) :
    Array Block := Id.run do
  let mut out : Array Block := Array.mkEmpty blockSizes.size
  let mut off : Nat := 0
  for s in blockSizes do
    if s < 0 then
      let n := (-s).toNatClampNeg
      let mut e : FloatArray := FloatArray.empty
      for i in [0 : n] do e := e.push flat[off + i]!
      out := out.push (.diag n e)
      off := off + n
    else
      let n := s.toNatClampNeg
      let total := n * n
      let mut e : FloatArray := FloatArray.empty
      for i in [0 : total] do e := e.push flat[off + i]!
      out := out.push (.sdp n e)
      off := off + total
  return out

/-- Solve `p` via CSDP's `easy_sdp`. -/
def solve (p : Problem) : Solution :=
  let nb := p.numBlocks
  let nc := p.numConstraints
  let _ := (nb, nc) -- consume to avoid unused-variable warning in v0
  let blockSizes := packInt32Array p.blockSizes
  let bArr := floatArrayOfArray p.b
  let cBlocks := packUInt32Array (p.c.map (·.block))
  let cI      := packUInt32Array (p.c.map (·.row))
  let cJ      := packUInt32Array (p.c.map (·.col))
  let cVals   := floatArrayOfArray (p.c.map (·.value))
  let aCs     := packUInt32Array (p.a.map (·.constraint))
  let aBs     := packUInt32Array (p.a.map (·.block))
  let aI      := packUInt32Array (p.a.map (·.row))
  let aJ      := packUInt32Array (p.a.map (·.col))
  let aVals   := floatArrayOfArray (p.a.map (·.value))
  let raw := solveImpl blockSizes bArr cBlocks cI cJ cVals
                       aCs aBs aI aJ aVals p.constantOffset
  { ret  := raw.ret
    pobj := raw.pobj
    dobj := raw.dobj
    X    := splitBlocks p.blockSizes raw.X
    y    := raw.y
    Z    := splitBlocks p.blockSizes raw.Z }

end CSDP
