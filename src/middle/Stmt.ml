open Core_kernel
open Common

(** Fixed-point of statements *)
module Fixed = struct
  module First = Expr.Fixed

  module Pattern = struct
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
    [@@deriving sexp, hash, map, fold, compare]

    and 'a lvalue = string * UnsizedType.t * 'a Index.t list
    [@@deriving sexp, hash, map, compare, fold]

    let pp pp_e pp_s ppf = function
      | Assignment ((assignee, _, idcs), rhs) ->
          Fmt.pf ppf "@[<h>%a =@ %a;@]" (Index.pp_indexed pp_e) (assignee, idcs)
            pp_e rhs
      | TargetPE expr -> Fmt.pf ppf "@[<h>target +=@ %a;@]" pp_e expr
      | NRFunApp (kind, args) ->
          Fmt.pf ppf "@[%a%a;@]" (Fun_kind.pp pp_e) kind
            Fmt.(list pp_e ~sep:comma |> parens)
            args
      | Break -> Fmt.string ppf "break;"
      | Continue -> Fmt.string ppf "continue;"
      | Skip -> Fmt.string ppf ";"
      | Return (Some expr) -> Fmt.pf ppf "return %a;" pp_e expr
      | Return _ -> Fmt.string ppf "return;"
      | IfElse (pred, s_true, Some s_false) ->
          Fmt.pf ppf "if(%a) %a else %a" pp_e pred pp_s s_true pp_s s_false
      | IfElse (pred, s_true, _) -> Fmt.pf ppf "if(%a) %a" pp_e pred pp_s s_true
      | While (pred, stmt) -> Fmt.pf ppf "while(%a) %a" pp_e pred pp_s stmt
      | For {loopvar; lower; upper; body} ->
          Fmt.pf ppf "for(%s in %a:%a) %a" loopvar pp_e lower pp_e upper pp_s
            body
      | Profile (_, stmts) ->
          Fmt.pf ppf "{@;<1 2>@[<v>%a@]@;}" Fmt.(list pp_s ~sep:cut) stmts
      | Block stmts ->
          Fmt.pf ppf "{@;<1 2>@[<v>%a@]@;}" Fmt.(list pp_s ~sep:cut) stmts
      | SList stmts -> Fmt.(list pp_s ~sep:cut |> vbox) ppf stmts
      | Decl {decl_adtype; decl_id; decl_type; _} ->
          Fmt.pf ppf "%a%a %s;" UnsizedType.pp_autodifftype decl_adtype
            (Type.pp pp_e) decl_type decl_id

    include Foldable.Make2 (struct
      type nonrec ('a, 'b) t = ('a, 'b) t

      let fold = fold
    end)
  end

  include Fixed.Make2 (First) (Pattern)
end

(** Statements with location information and types for contained expressions *)
module Located = struct
  module Meta = struct
    type t = (Location_span.t[@sexp.opaque] [@compare.ignore])
    [@@deriving compare, sexp, hash]

    let empty = Location_span.empty
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.Typed) (Meta)

  let loc_of Fixed.{meta; _} = meta

  (** This module acts as a temporary replace for the [stmt_loc_num] type that
  is currently used within [analysis_and_optimization].

  The original intent of the type was to provide explicit sharing of subterms.
  My feeling is that ultimately we either want to:
  - use the recursive type directly and rely on OCaml for sharing
  - provide the same interface as other [Specialized] modules so that
    the analysis code isn't aware of the particular representation we are using.
  *)
  module Non_recursive = struct
    type t =
      { pattern: (Expr.Typed.t, int) Fixed.Pattern.t
      ; meta: (Meta.t[@sexp.opaque] [@compare.ignore]) }
    [@@deriving compare, sexp, hash]
  end
end

module Numbered = struct
  module Meta = struct
    type t = (int[@sexp.opaque] [@compare.ignore])
    [@@deriving compare, sexp, hash]

    let empty = 0
    let from_int (i : int) : t = i
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.Typed) (Meta)
end

module Helpers = struct
  let temp_vars exprs : Located.t list * Expr.Typed.t list * (unit -> unit) =
    let sym, reset = Gensym.enter () in
    let rec loop es sym inits vars =
      match es with
      | [] -> (inits, vars)
      | (Expr.{Fixed.pattern= Var _; _} as e) :: es ->
          loop es sym inits (e :: vars)
      | e :: es ->
          let decl =
            { Fixed.pattern=
                Decl
                  { decl_adtype= Expr.Typed.adlevel_of e
                  ; decl_id= sym
                  ; decl_type= Unsized (Expr.Typed.type_of e)
                  ; initialize= true }
            ; meta= e.meta.loc } in
          let assign =
            { decl with
              Fixed.pattern= Assignment ((sym, Expr.Typed.type_of e, []), e) }
          in
          loop es (Gensym.generate ()) (decl :: assign :: inits)
            ({e with pattern= Var sym} :: vars) in
    let setups, exprs = loop (List.rev exprs) sym [] [] in
    (setups, exprs, reset)

  let ensure_var bodyfn (expr : Expr.Typed.t) meta =
    match expr with
    | {pattern= Var _; _} -> bodyfn expr meta
    | _ ->
        let preamble, temp, reset = temp_vars [expr] in
        let body = bodyfn (List.hd_exn temp) meta in
        reset () ;
        {body with Fixed.pattern= Block (preamble @ [body])}

  let internal_nrfunapp fn args meta =
    {Fixed.pattern= NRFunApp (CompilerInternal fn, args); meta}

  (** [mk_for] returns a MIR For statement from 0 to [upper] that calls the [bodyfn] with the loop
      variable inside the loop. *)
  let mk_for upper bodyfn meta =
    let loopvar, reset = Gensym.enter () in
    let loopvar_expr =
      Expr.Fixed.
        { meta= Expr.Typed.Meta.create ~type_:UInt ~loc:meta ~adlevel:DataOnly ()
        ; pattern= Var loopvar } in
    let lower = Expr.Helpers.loop_bottom in
    let body = Fixed.{meta; pattern= Pattern.Block [bodyfn loopvar_expr]} in
    reset () ;
    let pattern = Fixed.Pattern.For {loopvar; lower; upper; body} in
    Fixed.{meta; pattern}

  (** [mk_nested_for] returns nested MIR For statements with ranges from 0 to each element of
      [uppers], and calls the [bodyfn] in the innermost loop with the list of loop variables. *)
  let rec mk_nested_for uppers bodyfn meta =
    match uppers with
    | [] -> bodyfn []
    | upper :: uppers' ->
        mk_for upper
          (fun loopvar ->
            mk_nested_for uppers'
              (fun loopvars -> bodyfn (loopvar :: loopvars))
              meta )
          meta

  (** [mk_for_iteratee] returns a MIR For statement that iterates over the given expression
    [iteratee]. *)
  let mk_for_iteratee upper iteratee_bodyfn iteratee meta =
    let bodyfn loopvar =
      iteratee_bodyfn
        (Expr.Helpers.add_int_index iteratee (Index.Single loopvar)) in
    mk_for upper bodyfn meta

  let rec for_each bodyfn iteratee smeta =
    let len (e : Expr.Typed.t) =
      let emeta = e.meta in
      let emeta' = {emeta with Expr.Typed.Meta.type_= UInt} in
      Expr.Helpers.internal_funapp FnLength [e] emeta' in
    match Expr.Typed.type_of iteratee with
    | UInt | UReal | UComplex -> bodyfn iteratee
    | UVector | URowVector | UComplexVector | UComplexRowVector ->
        mk_for_iteratee (len iteratee) bodyfn iteratee smeta
    | UMatrix | UComplexMatrix ->
        let emeta = iteratee.meta in
        let emeta' = {emeta with Expr.Typed.Meta.type_= UInt} in
        let rows =
          Expr.Fixed.
            { meta= emeta'
            ; pattern= FunApp (StanLib ("rows", FnPlain, AoS), [iteratee]) }
        in
        mk_for_iteratee rows (fun e -> for_each bodyfn e smeta) iteratee smeta
    | UArray _ -> mk_for_iteratee (len iteratee) bodyfn iteratee smeta
    | UMathLibraryFunction | UFun _ ->
        FatalError.fatal_error_msg
          [%message "Can't iterate over " (iteratee : Expr.Typed.t)]

  let contains_fn_kind is_fn_kind ?(init = false) stmt =
    let rec aux accu Fixed.{pattern; _} =
      match pattern with
      | NRFunApp (kind, _) when is_fn_kind kind -> true
      | stmt_pattern ->
          Fixed.Pattern.fold_left ~init:accu stmt_pattern
            ~f:(fun accu expr ->
              Expr.Helpers.contains_fn_kind is_fn_kind ~init:accu expr )
            ~g:aux in
    aux init stmt

  (** [for_eigen unsizedtype...] generates a For statement that loops
    over the eigen types in the underlying [unsizedtype]; i.e. just iterating
    overarrays and running bodyfn on any eign types found within.

    We can call [bodyfn] directly on scalars and Eigen types;
    for Arrays we call mk_for_iteratee but insert a
    recursive call into the [bodyfn] that will operate on the nested
    type. In this way we recursively create for loops that loop over
    the outermost layers first.
*)
  let rec for_eigen st bodyfn var smeta =
    match st with
    | SizedType.SInt | SReal | SComplex | SVector _ | SRowVector _ | SMatrix _
     |SComplexVector _ | SComplexRowVector _ | SComplexMatrix _ ->
        bodyfn var
    | SArray (t, d) ->
        mk_for_iteratee d (fun e -> for_eigen t bodyfn e smeta) var smeta

  (** [for_scalar unsizedtype...] generates a For statement that loops
    over the scalars in the underlying [unsizedtype].

    We can call [bodyfn] directly on scalars, make a direct For loop
    around Eigen types, or for Arrays we call mk_for_iteratee but inserting a
    recursive call into the [bodyfn] that will operate on the nested
    type. In this way we recursively create for loops that loop over
    the outermost layers first.
*)
  let rec for_scalar st bodyfn var smeta =
    match st with
    | SizedType.SInt | SReal | SComplex -> bodyfn var
    | SVector (_, d)
     |SRowVector (_, d)
     |SComplexVector d
     |SComplexRowVector d ->
        mk_for_iteratee d bodyfn var smeta
    | SMatrix (mem_pattern, d1, d2) ->
        mk_for_iteratee d1
          (fun e -> for_scalar (SRowVector (mem_pattern, d2)) bodyfn e smeta)
          var smeta
    | SComplexMatrix (d1, d2) ->
        mk_for_iteratee d1
          (fun e -> for_scalar (SComplexRowVector d2) bodyfn e smeta)
          var smeta
    | SArray (t, d) ->
        mk_for_iteratee d (fun e -> for_scalar t bodyfn e smeta) var smeta

  (** Exactly like for_scalar, but iterating through array dimensions in the
  inverted order.*)
  let for_scalar_inv st bodyfn (var : Expr.Typed.t) smeta =
    let var = {var with pattern= Indexed (var, [])} in
    let invert_index_order (Expr.Fixed.{pattern; _} as e) =
      match pattern with
      | Indexed (obj, []) -> obj
      | Indexed (obj, idxs) -> {e with pattern= Indexed (obj, List.rev idxs)}
      | _ -> e in
    let rec go st bodyfn var smeta =
      match st with
      | SizedType.SArray (t, d) ->
          let bodyfn' var = mk_for_iteratee d bodyfn var smeta in
          go t bodyfn' var smeta
      | SMatrix (mem_pattern, d1, d2) ->
          let bodyfn' var = mk_for_iteratee d1 bodyfn var smeta in
          go (SRowVector (mem_pattern, d2)) bodyfn' var smeta
      | SComplexMatrix (d1, d2) ->
          let bodyfn' var = mk_for_iteratee d1 bodyfn var smeta in
          go (SComplexRowVector d2) bodyfn' var smeta
      | _ -> for_scalar st bodyfn var smeta in
    go st (Fn.compose bodyfn invert_index_order) var smeta

  let assign_indexed decl_type vident meta varfn var =
    let indices = Expr.Helpers.collect_indices var in
    Fixed.{meta; pattern= Assignment ((vident, decl_type, indices), varfn var)}
end
