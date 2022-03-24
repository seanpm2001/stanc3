open Core_kernel
open Common
open Helpers

(** Fixed-point of statements *)
module Fixed = struct
  module First = Expr.Fixed

  module Pattern = struct
    type ('a, 'b) t =
      | Assignment of 'a lvalue * UnsizedType.t * 'a
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

    and 'e lvalue =
      | LVariable of string
      | LIndexed of 'e lvalue * 'e Index.t list
      | LTupleProjection of 'e lvalue * int
    [@@deriving sexp, hash, map, compare, fold]

    let pp pp_e pp_s ppf = function
      | Assignment (lvalue, _, rhs) ->
          let rec pp_lvalue ppf = function
            | LVariable v -> Fmt.string ppf v
            | LIndexed (lv, idcs) ->
                Fmt.pf ppf {|%a%a|} pp_lvalue lv (Index.pp_indices pp_e) idcs
            | LTupleProjection (lv, ix) -> Fmt.pf ppf {|%a.%d|} pp_lvalue lv ix
          in
          Fmt.pf ppf {|@[<h>%a =@ %a;@]|} pp_lvalue lvalue pp_e rhs
      | TargetPE expr ->
          Fmt.pf ppf {|@[<h>%a +=@ %a;@]|} pp_keyword "target" pp_e expr
      | NRFunApp (kind, args) ->
          Fmt.pf ppf {|@[%a%a;@]|} (Fun_kind.pp pp_e) kind
            Fmt.(list pp_e ~sep:comma |> parens)
            args
      | Break -> pp_keyword ppf "break;"
      | Continue -> pp_keyword ppf "continue;"
      | Skip -> pp_keyword ppf ";"
      | Return (Some expr) ->
          Fmt.pf ppf {|%a %a;|} pp_keyword "return" pp_e expr
      | Return _ -> pp_keyword ppf "return;"
      | IfElse (pred, s_true, Some s_false) ->
          Fmt.pf ppf {|%a(%a) %a %a %a|} pp_builtin_syntax "if" pp_e pred pp_s
            s_true pp_builtin_syntax "else" pp_s s_false
      | IfElse (pred, s_true, _) ->
          Fmt.pf ppf {|%a(%a) %a|} pp_builtin_syntax "if" pp_e pred pp_s s_true
      | While (pred, stmt) ->
          Fmt.pf ppf {|%a(%a) %a|} pp_builtin_syntax "while" pp_e pred pp_s stmt
      | For {loopvar; lower; upper; body} ->
          Fmt.pf ppf {|%a(%s in %a:%a) %a|} pp_builtin_syntax "for" loopvar pp_e
            lower pp_e upper pp_s body
      | Profile (_, stmts) ->
          Fmt.pf ppf {|{@;<1 2>@[<v>%a@]@;}|} Fmt.(list pp_s ~sep:Fmt.cut) stmts
      | Block stmts ->
          Fmt.pf ppf {|{@;<1 2>@[<v>%a@]@;}|} Fmt.(list pp_s ~sep:Fmt.cut) stmts
      | SList stmts -> Fmt.(list pp_s ~sep:Fmt.cut |> vbox) ppf stmts
      | Decl {decl_adtype; decl_id; decl_type; _} ->
          Fmt.pf ppf {|%a%a %s;|} UnsizedType.pp_autodifftype decl_adtype
            (Type.pp pp_e) decl_type decl_id

    include Foldable.Make2 (struct
      type nonrec ('a, 'b) t = ('a, 'b) t

      let fold = fold
    end)
  end

  include Fixed.Make2 (First) (Pattern)
end

(** Statements with no meta-data *)
module NoMeta = struct
  module Meta = struct
    type t = unit [@@deriving compare, sexp, hash]

    let empty = ()
    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.NoMeta) (Meta)

  let remove_meta stmt = Fixed.map (fun _ -> ()) (fun _ -> ()) stmt
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

(** Statements with location information and labels. Contained expressions have
both are typed and labelled. *)
module Labelled = struct
  module Meta = struct
    type t =
      { loc: (Location_span.t[@sexp.opaque] [@compare.ignore])
      ; label: Label.Int_label.t [@compare.ignore] }
    [@@deriving compare, create, sexp, hash]

    let empty =
      create ~loc:Location_span.empty ~label:Label.Int_label.(prev init) ()

    let pp _ _ = ()
  end

  include Specialized.Make2 (Fixed) (Expr.Labelled) (Meta)

  let label_of Fixed.{meta= Meta.{label; _}; _} = label
  let loc_of Fixed.{meta= Meta.{loc; _}; _} = loc

  let label ?(init = Label.Int_label.init) (stmt : Located.t) : t =
    let lbl = ref init in
    let f Expr.Typed.Meta.{adlevel; type_; loc} =
      let cur_lbl = !lbl in
      lbl := Label.Int_label.next cur_lbl ;
      Expr.Labelled.Meta.create ~type_ ~loc ~adlevel ~label:cur_lbl ()
    and g loc =
      let cur_lbl = !lbl in
      lbl := Label.Int_label.next cur_lbl ;
      Meta.create ~loc ~label:cur_lbl () in
    Fixed.map f g stmt

  type associations =
    { exprs: Expr.Labelled.t Label.Int_label.Map.t
    ; stmts: t Label.Int_label.Map.t }

  let empty =
    {exprs= Label.Int_label.Map.empty; stmts= Label.Int_label.Map.empty}

  let rec associate ?init:(assocs = empty) ({pattern; _} as stmt : t) =
    associate_pattern
      { assocs with
        stmts=
          Label.Int_label.Map.add_exn assocs.stmts ~key:(label_of stmt)
            ~data:stmt }
      pattern

  and associate_pattern assocs = function
    | Fixed.Pattern.Break | Skip | Continue | Return None -> assocs
    | Return (Some e) | TargetPE e ->
        {assocs with exprs= Expr.Labelled.associate ~init:assocs.exprs e}
    | NRFunApp (_, args) ->
        { assocs with
          exprs=
            List.fold args ~init:assocs.exprs ~f:(fun accu x ->
                Expr.Labelled.associate ~init:accu x ) }
    | Assignment (lv, _, rhs) ->
        let rec lvalue_exprs ~init = function
          | Fixed.Pattern.LIndexed (lv, idxs) ->
              List.fold ~f:Expr.Labelled.associate_index
                ~init:(lvalue_exprs lv ~init) idxs
          | _ -> init in
        let exprs =
          Expr.Labelled.(
            associate rhs ~init:(lvalue_exprs ~init:assocs.exprs lv)) in
        {assocs with exprs}
    | IfElse (pred, body, None) | While (pred, body) ->
        let exprs = Expr.Labelled.associate ~init:assocs.exprs pred in
        associate ~init:{assocs with exprs} body
    | IfElse (pred, ts, Some fs) ->
        let exprs = Expr.Labelled.associate ~init:assocs.exprs pred in
        let assocs' = {assocs with exprs} in
        associate ~init:(associate ~init:assocs' ts) fs
    | Decl {decl_type; _} -> associate_possibly_sized_type assocs decl_type
    | For {lower; upper; body; _} ->
        let exprs =
          Expr.Labelled.(
            associate ~init:(associate ~init:assocs.exprs lower) upper) in
        let assocs' = {assocs with exprs} in
        associate ~init:assocs' body
    | Profile (_, xs) | Block xs | SList xs ->
        List.fold ~f:(fun accu x -> associate ~init:accu x) ~init:assocs xs

  and associate_possibly_sized_type assocs = function
    | Type.Sized st ->
        {assocs with exprs= SizedType.associate ~init:assocs.exprs st}
    | Unsized _ -> assocs
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
  let ensure_var bodyfn (expr : Expr.Typed.t) meta =
    match expr with
    | {pattern= Var _; _} -> bodyfn expr meta
    | _ ->
        let symbol, reset = Gensym.enter () in
        let body = bodyfn {expr with pattern= Var symbol} meta in
        let decl =
          { body with
            Fixed.pattern=
              Decl
                { decl_adtype= Expr.Typed.adlevel_of expr
                ; decl_id= symbol
                ; decl_type= Unsized (Expr.Typed.type_of expr)
                ; initialize= true } } in
        let assign =
          { body with
            Fixed.pattern=
              Assignment (LVariable symbol, Expr.Typed.type_of expr, expr) }
        in
        reset () ;
        {body with Fixed.pattern= Block [decl; assign; body]}

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

  let for_each_tuple bodyfn iteratee ts meta =
    let stmt =
      Fixed.Pattern.SList
        (List.mapi ts ~f:(fun tuple_ix t ->
             let e = Expr.Helpers.add_tuple_index iteratee (tuple_ix + 1) in
             bodyfn t e ) ) in
    Fixed.{meta; pattern= stmt}

  let rec for_each bodyfn iteratee smeta =
    let len (e : Expr.Typed.t) =
      let emeta = e.meta in
      let emeta' = {emeta with Expr.Typed.Meta.type_= UInt} in
      Expr.Helpers.internal_funapp FnLength [e] emeta' in
    match Expr.Typed.type_of iteratee with
    | UInt | UReal | UComplex -> bodyfn iteratee
    | UVector | URowVector ->
        mk_for_iteratee (len iteratee) bodyfn iteratee smeta
    | UMatrix ->
        let emeta = iteratee.meta in
        let emeta' = {emeta with Expr.Typed.Meta.type_= UInt} in
        let rows =
          Expr.Fixed.
            { meta= emeta'
            ; pattern= FunApp (StanLib ("rows", FnPlain, AoS), [iteratee]) }
        in
        mk_for_iteratee rows (fun e -> for_each bodyfn e smeta) iteratee smeta
    | UArray _ -> mk_for_iteratee (len iteratee) bodyfn iteratee smeta
    (* TUPLE MAYBE It's not clear that this should ever be called: *)
    | UTuple ts -> for_each_tuple (const bodyfn) iteratee ts smeta
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
      ->
        bodyfn st var
    | SArray (t, d) ->
        mk_for_iteratee d (fun e -> for_eigen t bodyfn e smeta) var smeta
    | STuple ts ->
        for_each_tuple (fun t e -> for_eigen t bodyfn e smeta) var ts smeta

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
    | SizedType.SInt | SReal | SComplex -> bodyfn st var
    | SVector (_, d) | SRowVector (_, d) ->
        mk_for_iteratee d (bodyfn st) var smeta
    | SMatrix (mem_pattern, d1, d2) ->
        mk_for_iteratee d1
          (fun e -> for_scalar (SRowVector (mem_pattern, d2)) bodyfn e smeta)
          var smeta
    | SArray (t, d) ->
        mk_for_iteratee d (fun e -> for_scalar t bodyfn e smeta) var smeta
    | STuple ts ->
        for_each_tuple (fun t e -> for_scalar t bodyfn e smeta) var ts smeta

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
          let bodyfn' _ var = mk_for_iteratee d (bodyfn st) var smeta in
          go t bodyfn' var smeta
      | SMatrix (mem_pattern, d1, d2) ->
          let bodyfn' _ var = mk_for_iteratee d1 (bodyfn st) var smeta in
          go (SRowVector (mem_pattern, d2)) bodyfn' var smeta
      | _ -> for_scalar st bodyfn var smeta in
    go st (fun st var -> bodyfn st (invert_index_order var)) var smeta

  let assign_indexed decl_type vident meta varfn var =
    let indices = Expr.Helpers.collect_indices var in
    Fixed.
      { meta
      ; pattern=
          Assignment (LIndexed (LVariable vident, indices), decl_type, varfn var)
      }
  
  let rec get_name (lval : 'a Fixed.Pattern.lvalue) = 
    match lval with 
    | LVariable name -> name
    | LIndexed (sub_lval, _) -> get_name sub_lval
    | LTupleProjection (sub_lval, num) -> (get_name sub_lval)^"."^(string_of_int num)
end
