/-
Copyright (c) 2018 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/

namespace Batteries
/--
A difference List is a Function that, given a List, returns the original
contents of the difference List prepended to the given List.
This structure supports `O(1)` `append` and `push` operations on lists, making it
useful for append-heavy uses such as logging and pretty printing.
-/
structure DList (α : Type u) where
  /-- "Run" a `DList` by appending it on the right by a `List α` to get another `List α`. -/
  apply     : List α → List α
  /-- The `apply` function of a `DList` is completely determined by the list `apply []`. -/
  invariant : ∀ l, apply l = apply [] ++ l

attribute [simp] DList.apply

namespace DList
variable {α : Type u}
open List

/-- `O(1)` (`apply` is `O(|l|)`). Convert a `List α` into a `DList α`. -/
def ofList (l : List α) : DList α :=
  ⟨(l ++ ·), fun t => by simp⟩

/-- `O(1)` (`apply` is `O(1)`). Return an empty `DList α`. -/
def empty : DList α :=
  ⟨id, fun _ => rfl⟩

instance : EmptyCollection (DList α) := ⟨DList.empty⟩

instance : Inhabited (DList α) := ⟨DList.empty⟩

/-- `O(apply())`. Convert a `DList α` into a `List α` by running the `apply` function. -/
@[simp] def toList : DList α → List α
  | ⟨f, _⟩ => f []

/-- `O(1)` (`apply` is `O(1)`). A `DList α` corresponding to the list `[a]`. -/
def singleton (a : α) : DList α where
  apply     := fun t => a :: t
  invariant := fun _ => rfl

/-- `O(1)` (`apply` is `O(1)`). Prepend `a` on a `DList α`. -/
def cons : α → DList α → DList α
  | a, ⟨f, h⟩ => {
    apply     := fun t => a :: f t
    invariant := by intro t; simp; rw [h]
  }

/-- `O(1)` (`apply` is `O(1)`). Append two `DList α`. -/
def append : DList α → DList α → DList α
  | ⟨f, h₁⟩, ⟨g, h₂⟩ => {
    apply     := f ∘ g
    invariant := by
      intro t
      show f (g t) = (f (g [])) ++ t
      rw [h₁ (g t), h₂ t, ← append_assoc (f []) (g []) t, ← h₁ (g [])]
    }

/-- `O(1)` (`apply` is `O(1)`). Append an element at the end of a `DList α`. -/
def push : DList α → α → DList α
  | ⟨f, h⟩, a => {
    apply     := fun t => f (a :: t)
    invariant := by
      intro t
      show f (a :: t) = f (a :: nil) ++ t
      rw [h [a], h (a::t), append_assoc (f []) [a] t]
      rfl
  }

instance : Append (DList α) := ⟨DList.append⟩

/-- Convert a lazily-evaluated `List` to a `DList` -/
def ofThunk (l : Thunk (List α)) : DList α :=
  ⟨fun xs => l.get ++ xs, fun t => by simp⟩

/-- Concatenates a list of difference lists to form a single difference list. Similar to
`List.join`. -/
def join {α : Type _} : List (DList α) → DList α
  | [] => DList.empty
  | x :: xs => x ++ DList.join xs
