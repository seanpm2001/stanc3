(** MIR types and modules corresponding to the statements of the language *)

open Common

module Fixed : sig
  module Pattern : sig
    type ('a, 'b) t =
      | Assignment of 'a lvalue * 'a
      | TargetPE of 'a
      | NRFunApp of 'a Fun_kind.t * 'a list
      | Break
      | Continue
      | Return of 'a option
      | Skip
      | IfElse of 'a * 'b * 'b option
      | While of 'a * 'b
      | For of {loopvar: string; lower: 'a; upper: 'a; body: 'b}
      | Profile of string * 'b list
      | Block of 'b list
      | SList of 'b list
      | Decl of
          { decl_adtype: UnsizedType.autodifftype
          ; decl_id: string
          ; decl_type: 'a Type.t
          ; initialize: bool }
    [@@deriving sexp, hash, compare]

    and 'a lvalue = string * UnsizedType.t * 'a Index.t list
    [@@deriving sexp, hash, map, compare, fold]

    include Pattern.S2 with type ('a, 'b) t := ('a, 'b) t
  end

  include Fixed.S2 with module First = Expr.Fixed and module Pattern := Pattern
end

module Located : sig
  module Meta : sig
    type t = (Location_span.t[@sexp.opaque] [@compare.ignore])
    [@@deriving compare, sexp, hash]

    include Specialized.Meta with type t := t
  end

  include
    Specialized.S
      with module Meta := Meta
       and type t =
            ( Expr.Typed.Meta.t
            , (Meta.t[@sexp.opaque] [@compare.ignore]) )
            Fixed.t

  val loc_of : t -> Location_span.t

  module Non_recursive : sig
    type t =
      { pattern: (Expr.Typed.t, int) Fixed.Pattern.t
      ; meta: (Meta.t[@sexp.opaque] [@compare.ignore]) }
    [@@deriving compare, sexp, hash]
  end
end

module Numbered : sig
  module Meta : sig
    type t = (int[@sexp.opaque] [@compare.ignore])
    [@@deriving compare, sexp, hash]

    include Specialized.Meta with type t := t

    val from_int : int -> t
  end

  include
    Specialized.S
      with module Meta := Meta
       and type t = (Expr.Typed.Meta.t, Meta.t) Fixed.t
end

module Helpers : sig
  val temp_vars :
    Expr.Typed.t list -> Located.t list * Expr.Typed.t list * (unit -> unit)

  val ensure_var :
    (Expr.Typed.t -> 'a -> Located.t) -> Expr.Typed.t -> 'a -> Located.t

  val internal_nrfunapp :
       'a Fixed.First.t Internal_fun.t
    -> 'a Fixed.First.t list
    -> 'b
    -> ('a, 'b) Fixed.t

  val contains_fn_kind :
       ('a Fixed.First.t Fun_kind.t -> bool)
    -> ?init:bool
    -> ('a, 'b) Fixed.t
    -> bool

  val mk_for :
    Expr.Typed.t -> (Expr.Typed.t -> Located.t) -> Location_span.t -> Located.t

  val mk_nested_for :
       Expr.Typed.t list
    -> (Expr.Typed.t list -> Located.t)
    -> Location_span.t
    -> Located.t

  val mk_for_iteratee :
       Expr.Typed.t
    -> (Expr.Typed.t -> Located.t)
    -> Expr.Typed.t
    -> Location_span.t
    -> Located.t

  val for_each :
    (Expr.Typed.t -> Located.t) -> Expr.Typed.t -> Location_span.t -> Located.t

  val for_scalar :
       Expr.Typed.t SizedType.t
    -> (Expr.Typed.t -> Located.t)
    -> Expr.Typed.t
    -> Location_span.t
    -> Located.t

  val for_scalar_inv :
       Expr.Typed.t SizedType.t
    -> (Expr.Typed.t -> Located.t)
    -> Expr.Typed.t
    -> Location_span.t
    -> Located.t

  val for_eigen :
       Expr.Typed.t SizedType.t
    -> (Expr.Typed.t -> Located.t)
    -> Expr.Typed.t
    -> Location_span.t
    -> Located.t

  val assign_indexed :
       UnsizedType.t
    -> string
    -> 'a
    -> ('b Expr.Fixed.t -> 'b Expr.Fixed.t)
    -> 'b Expr.Fixed.t
    -> ('b, 'a) Fixed.t
end
