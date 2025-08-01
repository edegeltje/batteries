/-
Copyright (c) 2022 Siddhartha Gadgil. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Siddhartha Gadgil, Mario Carneiro
-/
import Lean.Elab.Tactic.ElabTerm

/-!
# `trans` tactic

This implements the `trans` tactic, which can apply transitivity theorems with an optional middle
variable argument.
-/

/-- Compose using transitivity, homogeneous case. -/
def Trans.simple {r : α → α → Sort _} [Trans r r r] : r a b → r b c → r a c := trans

namespace Batteries.Tactic
open Lean Meta Elab

initialize registerTraceClass `Tactic.trans

/-- Environment extension storing transitivity lemmas -/
initialize transExt :
    SimpleScopedEnvExtension (Name × Array DiscrTree.Key) (DiscrTree Name) ←
  registerSimpleScopedEnvExtension {
    addEntry := fun dt (n, ks) => dt.insertCore ks n
    initial := {}
  }

initialize registerBuiltinAttribute {
  name := `trans
  descr := "transitive relation"
  add := fun decl _ kind => MetaM.run' do
    let declTy := (← getConstInfo decl).type
    let (xs, _, targetTy) ← withReducible <| forallMetaTelescopeReducing declTy
    let fail := throwError
      "@[trans] attribute only applies to lemmas proving
      x ∼ y → y ∼ z → x ∼ z, got {indentExpr declTy} with target {indentExpr targetTy}"
    let .app (.app rel _) _ := targetTy | fail
    let some yzHyp := xs.back? | fail
    let some xyHyp := xs.pop.back? | fail
    let .app (.app _ _) _ ← inferType yzHyp | fail
    let .app (.app _ _) _ ← inferType xyHyp | fail
    let key ← withReducible <| DiscrTree.mkPath rel
    transExt.add (decl, key) kind
}

open Lean.Elab.Tactic

/-- solving `e ← mkAppM' f #[x]` -/
def getExplicitFuncArg? (e : Expr) : MetaM (Option <| Expr × Expr) := do
  match e with
  | Expr.app f a => do
    if ← isDefEq (← mkAppM' f #[a]) e then
      return some (f, a)
    else
      getExplicitFuncArg? f
  | _ => return none

/-- solving `tgt ← mkAppM' rel #[x, z]` given `tgt = f z` -/
def getExplicitRelArg? (tgt f z : Expr) : MetaM (Option <| Expr × Expr) := do
  match f with
  | Expr.app rel x => do
    let check: Bool ← do
      try
        let folded ← mkAppM' rel #[x, z]
        isDefEq folded tgt
      catch _ =>
        pure false
    if check then
      return some (rel, x)
    else
      getExplicitRelArg? tgt rel z
  | _ => return none

/-- refining `tgt ← mkAppM' rel #[x, z]` dropping more arguments if possible -/
def getExplicitRelArgCore (tgt rel x z : Expr) : MetaM (Expr × Expr) := do
  match rel with
  | Expr.app rel' _ => do
    let check: Bool ← do
      try
        let folded ← mkAppM' rel' #[x, z]
        isDefEq folded tgt
      catch _ =>
        pure false
    if !check then
      return (rel, x)
    else
      getExplicitRelArgCore tgt rel' x z
  | _ => return (rel ,x)

/-- Internal definition for `trans` tactic. Either a binary relation or a non-dependent
arrow. -/
inductive TransRelation
  /-- Expression for transitive relation. -/
  | app (rel : Expr)
  /-- Constant name for transitive relation. -/
  | implies (name : Name) (bi : BinderInfo)

/-- Finds an explicit binary relation in the argument, if possible. -/
def getRel (tgt : Expr) : MetaM (Option (TransRelation × Expr × Expr)) := do
  match tgt with
  | .forallE name binderType body info => return .some (.implies name info, binderType, body)
  | .app f z =>
    match (← getExplicitRelArg? tgt f z) with
    | some (rel, x) =>
      let (rel, x) ← getExplicitRelArgCore tgt rel x z
      return some (.app rel, x, z)
    | none =>
      return none
  | _ => return none

/--
`trans` applies to a goal whose target has the form `t ~ u` where `~` is a transitive relation,
that is, a relation which has a transitivity lemma tagged with the attribute [trans].

* `trans s` replaces the goal with the two subgoals `t ~ s` and `s ~ u`.
* If `s` is omitted, then a metavariable is used instead.

Additionally, `trans` also applies to a goal whose target has the form `t → u`,
in which case it replaces the goal with `t → s` and `s → u`.
-/
elab "trans" t?:(ppSpace colGt term)? : tactic => withMainContext do
  let tgt := (← instantiateMVars (← (← getMainGoal).getType)).cleanupAnnotations
  let .some (rel, x, z) ← getRel tgt |
    throwError (m!"transitivity lemmas only apply to binary relations and " ++
                m!"non-dependent arrows, not {indentExpr tgt}")
  match rel with
  | .implies name info =>
    -- only consider non-dependent arrows
    if z.hasLooseBVars then
      throwError "`trans` is not implemented for dependent arrows{indentExpr tgt}"
    -- parse the intermeditate term
    let middleType ← mkFreshExprMVar none
    let t'? ← t?.mapM (elabTermWithHoles · middleType (← getMainTag))
    let middle ← (t'?.map (pure ·.1)).getD (mkFreshExprMVar middleType)
    liftMetaTactic fun goal => do
      -- create two new goals
      let g₁ ← mkFreshExprMVar (some <| .forallE name x middle info) .synthetic
      let g₂ ← mkFreshExprMVar (some <| .forallE name middle z info) .synthetic
      -- close the original goal with `fun x => g₂ (g₁ x)`
      goal.assign (.lam name x (.app g₂ (.app g₁ (.bvar 0))) .default)
      pure <| [g₁.mvarId!, g₂.mvarId!] ++ if let some (_, gs') := t'? then gs' else [middle.mvarId!]
    return
  | .app rel =>
    trace[Tactic.trans]"goal decomposed"
    trace[Tactic.trans]"rel: {indentExpr rel}"
    trace[Tactic.trans]"x: {indentExpr x}"
    trace[Tactic.trans]"z: {indentExpr z}"
    -- first trying the homogeneous case
    try
      let ty ← inferType x
      let t'? ← t?.mapM (elabTermWithHoles · ty (← getMainTag))
      let s ← saveState
      trace[Tactic.trans]"trying homogeneous case"
      let lemmas :=
        (← (transExt.getState (← getEnv)).getUnify rel).push ``Trans.simple
      for lem in lemmas do
        trace[Tactic.trans]"trying lemma {lem}"
        try
          liftMetaTactic fun g => do
            let lemTy ← inferType (← mkConstWithLevelParams lem)
            let arity ← withReducible <| forallTelescopeReducing lemTy fun es _ => pure es.size
            let y ← (t'?.map (pure ·.1)).getD (mkFreshExprMVar ty)
            let g₁ ← mkFreshExprMVar (some <| ← mkAppM' rel #[x, y]) .synthetic
            let g₂ ← mkFreshExprMVar (some <| ← mkAppM' rel #[y, z]) .synthetic
            g.assign (← mkAppOptM lem (.replicate (arity - 2) none ++ #[some g₁, some g₂]))
            pure <| [g₁.mvarId!, g₂.mvarId!] ++
              if let some (_, gs') := t'? then gs' else [y.mvarId!]
          return
        catch _ => s.restore
      pure ()
    catch _ =>
    trace[Tactic.trans]"trying heterogeneous case"
    let t'? ← t?.mapM (elabTermWithHoles · none (← getMainTag))
    let s ← saveState
    for lem in (← (transExt.getState (← getEnv)).getUnify rel).push
        ``HEq.trans |>.push ``Trans.trans do
      try
        liftMetaTactic fun g => do
          trace[Tactic.trans]"trying lemma {lem}"
          let lemTy ← inferType (← mkConstWithLevelParams lem)
          let arity ← withReducible <| forallTelescopeReducing lemTy fun es _ => pure es.size
          trace[Tactic.trans]"arity: {arity}"
          trace[Tactic.trans]"lemma-type: {lemTy}"
          let y ← (t'?.map (pure ·.1)).getD (mkFreshExprMVar none)
          trace[Tactic.trans]"obtained y: {y}"
          trace[Tactic.trans]"rel: {indentExpr rel}"
          trace[Tactic.trans]"x:{indentExpr x}"
          trace[Tactic.trans]"z:  {indentExpr z}"
          let g₂ ← mkFreshExprMVar (some <| ← mkAppM' rel #[y, z]) .synthetic
          trace[Tactic.trans]"obtained g₂: {g₂}"
          let g₁ ← mkFreshExprMVar (some <| ← mkAppM' rel #[x, y]) .synthetic
          trace[Tactic.trans]"obtained g₁: {g₁}"
          g.assign (← mkAppOptM lem (.replicate (arity - 2) none ++ #[some g₁, some g₂]))
          pure <| [g₁.mvarId!, g₂.mvarId!] ++ if let some (_, gs') := t'? then gs' else [y.mvarId!]
        return
      catch e =>
        trace[Tactic.trans]"failed: {e.toMessageData}"
        s.restore
    throwError m!"no applicable transitivity lemma found for {indentExpr tgt}"

/-- Synonym for `trans` tactic. -/
syntax "transitivity" (ppSpace colGt term)? : tactic
set_option hygiene false in
macro_rules
  | `(tactic| transitivity) => `(tactic| trans)
  | `(tactic| transitivity $e) => `(tactic| trans $e)

end Batteries.Tactic
