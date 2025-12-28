# Virtual Places and Borrow Checker Integration

Jump to [*The Table*](#the-table).

In this blog post, I present an idea on how we can specify the borrow checker behavior in the context of the field projection design effort. This work builds upon the blog post [The Algebra of Loans in Rust] by Nadrieril. I will give a more field projection focused proposal, whereas that blog post looked at the general way the borrow checker works.

The main proposal for field projection is focused on virtual places, which were [introduced by Nadrieril](https://nadrieril.github.io/blog/2025/11/11/truly-first-class-custom-smart-pointers.html). Similarly now, I will give a way to specify the borrow checker behavior of the built-in reference types as well as custom types with *places* at the focal point.

Additionally, I will present an idea on how to better include the borrow checker's lifetime into our proposal.

There are several issues/open questions with the current design[^current]:
- What does the lifetime on `PlaceBorrow` mean when we have `BORROW_KIND = Untracked`?
- How does lifetime shortening fit into the picture here, we only have one lifetime?
- What are the actual semantics of `BorrowKind`?

I hope to answer all of these with this blog post. And additionally provide a simpler explanation of borrowing in Rust.

[^current]: By *current design* I mean the design introduced by [Truly First-Class Custom Smart Pointers](https://nadrieril.github.io/blog/2025/11/11/truly-first-class-custom-smart-pointers.html) and developed further through discussions on Zulip.

[The Algebra of Loans in Rust]: https://nadrieril.github.io/blog/2025/12/21/the-algebra-of-loans-in-rust.html

## Informal Writeup

[The Algebra of Loans in Rust] is a prerequisite of this post, it gives a good overview of the basic concepts, such as what a *place* is, *taking a borrow* and *loans*. The post also gives three tables, which specify what kind of operations each reference has available. In this post I will replicate the latter two tables[^tables]; not via specifying them directly, but rather by specifying an underlying mechanism.

[^tables]: The first table is encoded by implementing `PlaceBorrow` for the right types.

This *underlying mechanism* consists of two concepts:
1. What *kind* of access are we granting to the place. For example, `&mut` requires *exclusive* access, `&` only needs *shared* access and `*const` doesn't need any kind of access[^untracked].
2. What *state* should the place be in when the borrow starts and should it be changed when the borrow ends? For example, `&` requires the place to be initialized. `&mut` requires that the place is *not* pinned. `*const` doesn't require anything. As a last important example there is `&own`, which requires the state to be initialized, not pinned *and* transform that state on expiry to uninitialized.

These concepts also explain how all place operations interact with the borrow checker:
- `PlaceDrop` requires exclusive access & changes the state from initialized to uninitialized.
- `PlaceRead` requires shared access to the place and expects it to be initialized.
- `PlaceMove` additionally requires the place to be not pinned and changes the state to uninitialized.
- `PlaceWrite` requires exclusive access; if the state is initialized, it performs `PlaceDrop` first, so it requires an uninitialized state, otherwise it expects the place to be uninitialized.
- `PlaceDeref` requires the same kind of access that the following operation on the derefed pointer needs.
- `PlaceBorrow` specifies its access & expected state + state change.

[^untracked]: Raw pointers can obviously be used to read or write their pointee, but that operation is not governed by the borrow checker, which is what we're interested in here. So from the borrow checker's perspective, `*const` does not ask for any kind of access.

## Formal Explanation

This part essentially is like the "reference-level explanation" section of an RFC. We model the access kind and place state using enums:

```rust
// also called `BorrowKind` in previous proposals
pub enum PlaceAccess {
    Shared,
    Exclusive,
    Untracked,
}

pub enum PlaceState {
    Initialized(PinnedState),
    Uninitialized,
}

pub enum PinnedState {
    NotPinned,
    Pinned,
}
```

We can now add two constants on `PlaceBorrow` or even on `HasPlace`:

```rust
pub trait HasPlace {
    const ACCESS: PlaceAccess;

    const STATE: PlaceState;

    type Target: ?Sized;
}
```

(Note that to properly support places that allow several states, we'd probably need a set or another enum instead of `PlaceState`.)

We then also need a constant `AFTER: PlaceState` in `PlaceBorrow`, which specifies the state the place should be in after the borrow ends.

To obtain the second table ["If a loan was taken and is live, what can I still do to the place"](https://nadrieril.github.io/blog/2025/12/21/the-algebra-of-loans-in-rust.html#table-2-if-a-loan-was-taken-and-is-live-what-can-i-still-do-to-the-place), we only need to consider the `ACCESS` constants of the two custom pointers (types that implement `HasPlace`). If one of them is `Untracked` or both are `Shared`, they may coexist; otherwise, a borrow check error is thrown.

Examples:
- `&mut T` and `&own T` cannot coexist, as they both want `Exclusive`.
- `&T` and `ArcMap<T, U>` can coexist, as both only need `Shared` access.
- `UniqueArcMap<T, U>` and `*const T` can coexist, as raw pointers have `Untracked` access.

For the [third table](https://nadrieril.github.io/blog/2025/12/21/the-algebra-of-loans-in-rust.html#table-3-if-a-loan-was-taken-and-expired-what-can-i-now-do-to-the-place), one only needs to consider the state of the place after the borrow expires. In this model, it is useful to make `Untracked` borrows expire immediately.

Examples:
- `&own T` changes the state to `Uninitialized`, so a subsequent `&mut T` borrow is not allowed, as that expects an initialized state. A borrow using `&uninit T` is allowed, since that expects uninitialized memory.
- `&mut T` doesn't change the state, so a subsequent `&T` borrow is allowed.

#### The Table

| (Smart) pointer or operation | `PlaceAccess` | `PlaceState` before[^pat] | `PlaceState` after       |
|------------------------------|---------------|---------------------------|--------------------------|
| `&T`                         | `Shared`      | `Initialized(_)`          | unchanged                |
| `&mut T`                     | `Exclusive`   | `Initialized(NotPinned)`  | unchanged                |
| `&own T`                     | `Exclusive`   | `Initialized(NotPinned)`  | `Uninitialized`          |
| `&uninit T`                  | `Exclusive`   | `Uninitialized`           | ???                      |
| `*const T`                   | `Untracked`   | `_`                       | unchanged                |
| `&pin T`                     | `Shared`      | `Initialized(Pinned)`     | unchanged                |
| `&pin mut T`                 | `Exclusive`   | `Initialized(Pinned)`     | unchanged                |
| `&pin own T`                 | `Exclusive`   | `Initialized(Pinned)`     | `Uninitialized`          |
| `ArcMap<T, U>`               | `Untracked`   | `Initialized(_)`          | unchanged                |
| `UniqueArcMap<T, U>`         | `Untracked`   | `Initialized(_)`          | `Uninitialized`          |
| `PlaceDrop`                  | `Exclusive`   | `Initialized(_)`          | `Uninitialized`          |
| `PlaceRead`                  | `Shared`      | `Initialized(NotPinned)`  | unchanged                |
| `PlaceMove`                  | `Exclusive`   | `Initialized(NotPinned)`  | `Uninitialized`[^mov]    |
| `PlaceWrite`                 | `Exclusive`   | `Uninitialized`           | `Initialized(NotPinned)` |
| `PlaceInit`                  | `Exclusive`   | `Uninitialized`           | `Initialized(NotPinned)` |
| `PlacePinInit`               | `Exclusive`   | `Uninitialized`           | `Initialized(Pinned)`    |
| `PlaceBorrow`                | custom        | custom                    | custom                   |
| `PlaceDeref`                 | ???           | ???                       | ???                      |

A couple of notes:
- `&uninit` overlaps heavily with in-place init. The borrow checker needs to understand control flow here, as the error path leaves the memory uninitialized, but the happy path initializes it. Not really sure how we would track this using `PlaceState`. Since in-place init has not settled on a design, we do not need to support it right away.
- `PlaceWrite` expects the place to be uninitialized. This matches the current behavior of Rust, where a `drop_in_place` is inserted before a write is performed. This behavior would of course be kept for custom pointers as well.
- `PlaceDeref` is pretty special, we need more time to iron out its design anyways. From this posts perspective, we probably want to copy the borrow checker behavior from the operation that is performed afterwards on the returned pointer.
- The last column could also be encoded via a `PlaceAction` enum:
  ```rust
  pub enum PlaceAction {
      Nothing,
      Initialize(PinnedState),
      Uninitialize,
  }
  ```
  This would allow us to better specify the "unchanged" semantics.

[^mov]: For `Copy` types, we'd of course not change the state to `Uninitialized`. But in my mind, we are not using `PlaceMove` for `Copy` types in the first place, so this only applies for types for which `PlaceRead` is insufficient.
[^pat]: We use a pattern to specify the before state, since we can potentially accept multiple.

## Conclusion

I believe that this idea is very much on the right track, since it has many great properties at the same time:
- It overall is a simple explanation, we only have two small enums to keep track of and combine.
- Interactions between references are defined immediately through specifying just three properties of both references and there is no room for ambiguity.
- It covers the existing `Place*` operations.
- It matches my intuitive understanding of how the borrow checker works very well.

If we had a `Move` trait instead of making pin a place state, we'd have an even simpler picture. Another piece of evidence in favor of making `Move` a reality.

## Open Questions

- What is the best way to accommodate multiple `PlaceState` in the same borrow?
- How do we support different changes to the `PlaceState` depending on various things? Do we even want to support that?
- Should we specify a `PlaceAction` (which encodes a state change) instead of giving the state after the borrow ends?
- How does `PlaceDeref` work?
- Does it make sense for `Untracked` access to "immediately end" the borrow?

# Bonus: Lifetime in `PlaceAccess`

Taking inspiration from Nadrieril[^lifetime], we can try to make the lifetime available depending on whether the access kind is untracked. My idea is to just use the type system instead of an enum:

```rust
#[sealed]
pub trait PlaceAccess {}

pub struct Owned;
impl PlaceAccess for Owned {}

pub struct Shared<'a>(PhantomData<&'a ()>);
impl PlaceAccess for Shared<'_> {}

pub struct Exclusive<'a>(PhantomData<&'a mut ()>);
impl PlaceAccess for Exclusive<'_> {}
```

When we now implement `HasPlace`, we must give a lifetime in shared and exclusive cases:

```rust
impl<'a, T> HasPlace for &'a mut T {
    type Access = Exclusive<'a>;
    const STATE: PlaceState = PlaceState::Initialized { pinned: false };
    type Target = T;
}
```

But in the untracked case, we now do not have a lifetime at all:

```rust
impl<T> HasPlace for *const T {
    type Access = Untracked;
    const STATE: PlaceState = PlaceState::Any;
    type Target = T;
}

impl<P: Projection> PlaceBorrow<P, *const P::Target> for *const P::Source {
    // ...
}
```

This conditional binding of the lifetime to `PlaceAccess` also allows us to allow the borrow checker to choose that lifetime. It essentially acts as a marker of the borrow-checker-controlled lifetime. This way, we get lifetime shortening, since we can now write the following impl:

```rust
impl<'a, 'b: 'a, P: Projection> PlaceBorrow<P, &'a mut P::Target> for &'b mut P::Source {
    // ...
}
```

And since `&'a mut P::Target` has `Access = Exclusive<'a>`, the borrow checker can shorten that lifetime as is appropriate.

[^lifetime]: Nadrieril [had the idea](https://rust-lang.zulipchat.com/#narrow/channel/522311-t-lang.2Fcustom-refs/topic/The.20PlaceBorrow.20lifetime.2C.20and.20reborrows/near/565092669) to use the existing reference types to specify the behavior for new ones.


---

---
