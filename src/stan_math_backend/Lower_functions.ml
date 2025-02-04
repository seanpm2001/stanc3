open Core_kernel
open Core_kernel.Poly
open Middle
open Lower_expr
open Lower_stmt
open Cpp

(** Detect if argument requires C++ template *)
let is_data_matrix_or_not_int_type = function
  | UnsizedType.DataOnly, _, ut -> UnsizedType.is_eigen_type ut
  | _, _, t when UnsizedType.is_int_type t -> false
  | _ -> true

(** Print template arguments for C++ functions that need templates
@param args A pack of [Program.fun_arg_decl] containing functions to detect templates.
@return A list of arguments with template parameter names added.
*)
let template_parameter_names (args : Program.fun_arg_decl) =
  List.mapi args ~f:(fun i arg ->
      match is_data_matrix_or_not_int_type arg with
      | true -> Some (sprintf "T%d__" i)
      | false -> None )

let requires (_, _, ut) t =
  match ut with
  | UnsizedType.URowVector ->
      [ RequireIs ("stan::is_row_vector", t)
      ; RequireIs ("stan::is_vt_not_complex", t) ]
  | UComplexRowVector ->
      [ RequireIs ("stan::is_row_vector", t)
      ; RequireIs ("stan::is_vt_complex", t) ]
  | UVector ->
      [ RequireIs ("stan::is_col_vector", t)
      ; RequireIs ("stan::is_vt_not_complex", t) ]
  | UComplexVector ->
      [ RequireIs ("stan::is_col_vector", t)
      ; RequireIs ("stan::is_vt_complex", t) ]
  | UMatrix ->
      [ RequireIs ("stan::is_eigen_matrix_dynamic", t)
      ; RequireIs ("stan::is_vt_not_complex", t) ]
  | UComplexMatrix ->
      [ RequireIs ("stan::is_eigen_matrix_dynamic", t)
      ; RequireIs ("stan::is_vt_complex", t) ]
      (* NB: Not unwinding array types due to the way arrays of eigens are printed *)
  | _ -> [RequireIs ("stan::is_stan_scalar", t)]

let optional_require_templates (name_ops : string option list)
    (args : Program.fun_arg_decl) =
  List.map2_exn name_ops args ~f:(fun name_op fun_arg ->
      match name_op with
      | Some param_name -> requires fun_arg param_name
      | None -> [] )

let return_optional_arg_types (args : Program.fun_arg_decl) =
  List.mapi args ~f:(fun i ((_, _, ut) as arg) ->
      if UnsizedType.is_eigen_type ut && is_data_matrix_or_not_int_type arg then
        Some (sprintf "stan::base_type_t<T%d__>" i)
      else if is_data_matrix_or_not_int_type arg then Some (sprintf "T%d__" i)
      else None )

let%expect_test "arg types templated correctly" =
  [(AutoDiffable, "xreal", UReal); (DataOnly, "yint", UInt)]
  |> template_parameter_names |> List.filter_opt |> String.concat ~sep:","
  |> print_endline ;
  [%expect {| T0__ |}]

let lower_promoted_scalar args =
  match args with
  | [] -> Double
  | _ ->
      let rec promote_args_chunked args =
        let chunk_till_empty list_tail =
          match list_tail with [] -> [] | _ -> [promote_args_chunked list_tail]
        in
        match args with
        | [] -> Double
        | hd :: list_tail ->
            TypeTrait ("stan::promote_args_t", hd @ chunk_till_empty list_tail)
      in
      promote_args_chunked
        List.(
          chunks_of ~length:5
            (List.map
               ~f:(fun t -> TemplateType t)
               (filter_opt (return_optional_arg_types args)) ))

(** Pretty-prints a function's return-type, taking into account templated argument
promotion.*)
let lower_returntype arg_types rt =
  let scalar = lower_promoted_scalar arg_types in
  match rt with
  | Some ut when UnsizedType.is_int_type ut -> lower_type ut Int
  | Some ut -> lower_type ut scalar
  | None -> Void

let lower_eigen_args_to_ref arg_types =
  let lower_ref name =
    VariableDefn
      (make_variable_defn ~type_:(Types.const_ref Auto) ~name
         ~init:
           (Assignment
              (Exprs.fun_call "stan::math::to_ref" [Var (name ^ "_arg__")]) )
         () ) in
  List.map ~f:lower_ref
    (List.filter_map
       ~f:(fun (_, name, ut) ->
         if UnsizedType.is_eigen_type ut then Some name else None )
       arg_types )

let lower_arg ~is_possibly_eigen_expr custom_scalar_opt (_, name, ut) =
  let scalar =
    match custom_scalar_opt with
    | Some scalar -> TemplateType scalar
    | None -> stantype_prim ut in
  (* we add the _arg suffix for any Eigen types *)
  let opt_arg_suffix =
    if is_possibly_eigen_expr && UnsizedType.is_eigen_type ut then
      name ^ "_arg__"
    else name in
  (Types.const_ref (lower_type_eigen_expr ut scalar), opt_arg_suffix)

let typename parameter_name = Typename parameter_name

(** Construct an object with it's needed templates for function signatures.
@param is_possibly_eigen_expr if true, argument can possibly be an unevaluated eigen expression.
@param fdargs A sexp list of strings representing C++ types.
*)
let templates_and_args (is_possibly_eigen_expr : bool)
    (fdargs : Program.fun_arg_decl) :
    string list * template_parameter list * (type_ * string) list =
  let arg_templates = template_parameter_names fdargs in
  let require_arg_templates = optional_require_templates arg_templates fdargs in
  ( List.filter_opt arg_templates
  , List.concat require_arg_templates
  , List.map2_exn ~f:(lower_arg ~is_possibly_eigen_expr) arg_templates fdargs )

(**
Prints boilerplate at start of function. Body of function wrapped in a `try` block.
*)
let lower_fun_body fdargs fdsuffix fdbody =
  let local_scalar =
    Using ("local_scalar_t__", Some (lower_promoted_scalar fdargs)) in
  let to_refs = lower_eigen_args_to_ref fdargs in
  let propto =
    match fdsuffix with
    | Fun_kind.FnLpdf _ | FnTarget -> []
    | FnPlain | FnRng ->
        VariableDefn
          (make_variable_defn ~static:true ~constexpr:true ~type_:Types.bool
             ~name:"propto__" ~init:(Assignment (Literal "true")) () )
        :: Stmts.unused "propto__" in
  let body = lower_statement fdbody in
  (local_scalar :: Decls.current_statement :: to_refs)
  @ propto @ Decls.dummy_var
  @ [Stmts.rethrow_located body]

let mk_extra_args templates args =
  List.map
    ~f:(fun (t, v) -> (Ref (TemplateType t), v))
    (List.zip_exn templates args)

let lower_args extra_templates extra args variadic =
  let args, variadic_args =
    match variadic with
    | `ReduceSum -> List.split_n args 3
    | `VariadicHOF x -> List.split_n args x
    | `None -> (args, []) in
  let arg_strs =
    args
    @ mk_extra_args extra_templates extra
    @ [(Pointer (TypeLiteral "std::ostream"), "pstream__")]
    @ variadic_args in
  arg_strs

let add_functor_decl functors (name : string)
    (param : template_parameter option) (f : fun_defn) =
  let f existing =
    match existing with
    | None -> make_struct_defn ~param ~name ~body:[FunDef f] ()
    | Some sd -> {sd with body= sd.body @ [FunDef f]} in
  Hashtbl.update functors name ~f

let extra_suffix_args fdsuffix =
  match fdsuffix with
  | Fun_kind.FnTarget -> (["lp__"; "lp_accum__"], ["T_lp__"; "T_lp_accum__"])
  | FnRng -> (["base_rng__"], ["RNG"])
  | FnLpdf _ | FnPlain -> ([], [])

(** This function produces the function and any functor definitions.
    Functor {b declarations} need to be collated, and are therefore stored in the
    functors hashtable *)
let lower_fun_def (functors : (string, struct_defn) Hashtbl.t)
    (forward_decls :
      (string * (UnsizedType.autodifftype * string * UnsizedType.t) list)
      Hash_set.t ) (funs_used_in_reduce_sum : String.Set.t)
    (variadic_fns : int list String.Map.t)
    Program.{fdrt; fdname; fdsuffix; fdargs; fdbody; _} : fun_defn list =
  let extra_arg_names, extra_template_names = extra_suffix_args fdsuffix in
  let template_parameter_and_arg_names is_possibly_eigen_expr variadic_fun_type
      =
    let template_param_names, template_require_checks, args =
      templates_and_args is_possibly_eigen_expr fdargs in
    let template_params =
      List.(map ~f:typename (template_param_names @ extra_template_names))
      @ template_require_checks in
    match (fdsuffix, variadic_fun_type) with
    | (FnLpdf _ | FnTarget), `None -> (Bool "propto__" :: template_params, args)
    | _ -> (template_params, args) in
  let template_params, templated_args =
    template_parameter_and_arg_names true `None in
  let cpp_arg_gen = lower_args extra_template_names extra_arg_names in
  let cpp_args = cpp_arg_gen templated_args `None in
  (* We want to print the [* = nullptr] at most once, and preferrably on a forward decl *)
  let init_template_requires =
    Option.is_none fdbody || not (Hash_set.mem forward_decls (fdname, fdargs))
  in
  let almost_fn =
    make_fun_defn
      ~templates_init:([template_params], init_template_requires)
      ~name:fdname
      ~return_type:(lower_returntype fdargs fdrt)
      ~args:cpp_args in
  match fdbody with
  | None ->
      (* Side Effect: *)
      Hash_set.add forward_decls (fdname, fdargs) ;
      [almost_fn ()]
  | Some fdbody ->
      let register_functor variadic_fun_type =
        let suffix =
          match variadic_fun_type with
          | `None -> functor_suffix
          | `ReduceSum -> reduce_sum_functor_suffix
          | `VariadicHOF x -> variadic_functor_suffix x in
        let functor_name = fdname ^ suffix in
        let struct_template =
          match (fdsuffix, variadic_fun_type) with
          | FnLpdf _, `ReduceSum -> Some (Bool "propto__")
          | _ -> None in
        let arg_templates, templated_args =
          template_parameter_and_arg_names false variadic_fun_type in
        let cpp_args = cpp_arg_gen templated_args variadic_fun_type in
        let functor_decl =
          make_fun_defn
            ~templates_init:([arg_templates], true)
            ~name:"operator()"
            ~return_type:(lower_returntype fdargs fdrt)
            ~args:cpp_args ~cv_qualifiers:[Const] () in
        (* Side Effect: *)
        add_functor_decl functors functor_name struct_template functor_decl ;
        let defn_template =
          match fdsuffix with
          | FnLpdf _ | FnTarget -> [TemplateType "propto__"]
          | _ -> [] in
        let defn_args =
          List.map ~f:Exprs.to_var
            (List.map ~f:snd templated_args @ extra_arg_names @ ["pstream__"])
        in
        let defn_args =
          match (variadic_fun_type, defn_args) with
          | `ReduceSum, slice :: start :: end_ :: rest ->
              slice :: plus_one start :: plus_one end_ :: rest
          | _ -> defn_args in
        let defn_body =
          [ Return
              (Some (Exprs.templated_fun_call fdname defn_template defn_args))
          ] in
        make_fun_defn
          ~templates_init:
            ([struct_template |> Option.to_list; arg_templates], false)
          ~name:
            ( functor_name
            ^ (if struct_template <> None then "<propto__>" else "")
            ^ "::operator()" )
          ~return_type:(lower_returntype fdargs fdrt)
          ~args:cpp_args ~cv_qualifiers:[Const] ~body:defn_body () in
      let out_body = lower_fun_body fdargs fdsuffix fdbody in
      [almost_fn ~body:out_body (); register_functor `None]
      @ ( if String.Set.mem funs_used_in_reduce_sum fdname then
          [register_functor `ReduceSum]
        else [] )
      @ (* Produces the variadic functors that has the pstream argument
           as not the last argument. For DAEs this is the 4th, for ODEs the 3rd *)
      List.map
        (List.stable_dedup @@ Map.find_multi variadic_fns fdname)
        ~f:(fun i -> register_functor (`VariadicHOF i))

let is_fun_used_with_reduce_sum (p : Program.Numbered.t) =
  let rec find_functors_expr accum Expr.Fixed.{pattern; _} =
    String.Set.union accum
      ( match pattern with
      | FunApp (StanLib (x, FnPlain, _), {pattern= Var f; _} :: _)
        when Stan_math_signatures.is_reduce_sum_fn x ->
          String.Set.of_list [Utils.stdlib_distribution_name f]
      | x -> Expr.Fixed.Pattern.fold find_functors_expr accum x ) in
  let rec find_functors_stmt accum stmt =
    Stmt.Fixed.(
      Pattern.fold find_functors_expr find_functors_stmt accum stmt.pattern)
  in
  Program.fold find_functors_expr find_functors_stmt String.Set.empty p

let get_variadic_requirements (p : Program.Numbered.t) =
  let rec find_functors_expr accum Expr.Fixed.{pattern; _} =
    match pattern with
    | FunApp (StanLib (x, FnPlain, _), {pattern= Var f; _} :: _) -> (
      match
        Hashtbl.find Stan_math_signatures.stan_math_variadic_signatures x
      with
      | Some {required_fn_args; _} ->
          Map.add_multi accum
            ~key:(Utils.stdlib_distribution_name f)
            ~data:(List.length required_fn_args)
      | _ -> Expr.Fixed.Pattern.fold find_functors_expr accum pattern )
    | _ -> Expr.Fixed.Pattern.fold find_functors_expr accum pattern in
  let rec find_functors_stmt accum stmt =
    Stmt.Fixed.(
      Pattern.fold find_functors_expr find_functors_stmt accum stmt.pattern)
  in
  Program.fold find_functors_expr find_functors_stmt String.Map.empty p

(** We need to do a fair bit of bookkeeping to handle the functors necessary for the various
    higher order functions.

    Each functor needs a forward decl struct before the function,
    then the function definition,
    then the actual functor definitions
  *)
let collect_functors_functions (p : Program.Numbered.t) : defn list =
  let (functors : (string, Cpp.struct_defn) Hashtbl.t) =
    String.Table.create () in
  let forward_decls = Hash_set.Poly.create () in
  let reduce_sum_fns = is_fun_used_with_reduce_sum p in
  let variadic_fns = get_variadic_requirements p in
  let fun_and_functor_defs =
    p.functions_block
    |> List.concat_map
         ~f:(lower_fun_def functors forward_decls reduce_sum_fns variadic_fns)
    |> List.map ~f:(fun f -> FunDef f) in
  let functor_struct_decls =
    functors |> Hashtbl.data |> List.map ~f:(fun s -> Struct s) in
  functor_struct_decls @ fun_and_functor_defs

let lower_standalone_fun_def namespace_fun
    Program.{fdname; fdsuffix; fdargs; fdbody; fdrt; _} =
  let extra, extra_templates =
    match fdsuffix with
    | Fun_kind.FnTarget ->
        (["lp__"; "lp_accum__"], ["double"; "stan::math::accumulator<double>"])
    | FnRng -> (["base_rng__"], ["boost::ecuyer1988"])
    | FnLpdf _ | FnPlain -> ([], []) in
  let args =
    List.map
      ~f:(fun (_, name, ut) ->
        (Types.const_ref (lower_type ut (stantype_prim ut)), name) )
      fdargs in
  let all_args =
    args
    @ mk_extra_args extra_templates extra
    @ [(Pointer (TypeLiteral "std::ostream"), "pstream__ = nullptr")] in
  let mark_function_comment = GlobalComment "[[stan::function]]" in
  let return_type, return_stmt =
    match fdrt with
    | None -> (Void, fun e -> Expression e)
    | _ -> (Auto, fun e -> Return (Some e)) in
  let fn_sig = make_fun_defn ~name:fdname ~return_type ~args:all_args in
  match fdbody with
  | None -> [FunDef (fn_sig ())]
  | Some _ ->
      let internal_fname = namespace_fun ^ "::" ^ fdname in
      let template =
        match fdsuffix with
        | FnLpdf _ | FnTarget -> [TypeLiteral "false"]
        | FnRng | FnPlain -> [] in
      let call_args =
        List.map ~f:(fun (_, name, _) -> name) fdargs @ extra @ ["pstream__"]
        |> List.map ~f:Exprs.to_var in
      let ret =
        return_stmt (Exprs.templated_fun_call internal_fname template call_args)
      in
      [mark_function_comment; FunDef (fn_sig ~body:[ret] ())]

module Testing = struct
  (* Testing code *)
  open Middle
  open Fmt

  let pp_fun_def_test ppf a =
    (list ~sep:cut Cpp.Printing.pp_fun_defn)
      ppf
      (lower_fun_def (String.Table.create ()) (Hash_set.Poly.create ())
         String.Set.empty String.Map.empty a )

  let%expect_test "udf" =
    let with_no_loc stmt =
      Stmt.Fixed.{pattern= stmt; meta= Numbering.no_span_num} in
    let w e = Expr.{Fixed.pattern= e; meta= Typed.Meta.empty} in
    { fdrt= None
    ; fdname= "sars"
    ; fdsuffix= FnPlain
    ; fdargs= [(DataOnly, "x", UMatrix); (AutoDiffable, "y", URowVector)]
    ; fdbody=
        Stmt.Fixed.Pattern.Return
          (Some
             ( w
             @@ FunApp
                  ( StanLib ("add", FnPlain, AoS)
                  , [w @@ Var "x"; w @@ Lit (Int, "1")] ) ) )
        |> with_no_loc |> List.return |> Stmt.Fixed.Pattern.Block |> with_no_loc
        |> Some
    ; fdloc= Location_span.empty }
    |> str "@[<v>%a" pp_fun_def_test
    |> print_endline ;
    [%expect
      {|
    template <typename T0__, typename T1__,
              stan::require_all_t<stan::is_eigen_matrix_dynamic<T0__>,
                                  stan::is_vt_not_complex<T0__>,
                                  stan::is_row_vector<T1__>,
                                  stan::is_vt_not_complex<T1__>>* = nullptr>
    void sars(const T0__& x_arg__, const T1__& y_arg__, std::ostream* pstream__) {
      using local_scalar_t__ = stan::promote_args_t<stan::base_type_t<T0__>,
                                 stan::base_type_t<T1__>>;
      int current_statement__ = 0;
      const auto& x = stan::math::to_ref(x_arg__);
      const auto& y = stan::math::to_ref(y_arg__);
      static constexpr bool propto__ = true;
      // suppress unused var warning
      (void) propto__;
      local_scalar_t__ DUMMY_VAR__(std::numeric_limits<double>::quiet_NaN());
      // suppress unused var warning
      (void) DUMMY_VAR__;
      try {
        return stan::math::add(x, 1);
      } catch (const std::exception& e) {
        stan::lang::rethrow_located(e, locations_array__[current_statement__]);
      }
    }
    template <typename T0__, typename T1__,
              stan::require_all_t<stan::is_eigen_matrix_dynamic<T0__>,
                                  stan::is_vt_not_complex<T0__>,
                                  stan::is_row_vector<T1__>,
                                  stan::is_vt_not_complex<T1__>>*>
    void
    sars_functor__::operator()(const T0__& x, const T1__& y, std::ostream*
                               pstream__) const {
      return sars(x, y, pstream__);
    } |}]

  let%expect_test "udf-expressions" =
    let with_no_loc stmt =
      Stmt.Fixed.{pattern= stmt; meta= Numbering.no_span_num} in
    let w e = Expr.{Fixed.pattern= e; meta= Typed.Meta.empty} in
    { fdrt= Some UMatrix
    ; fdname= "sars"
    ; fdsuffix= FnPlain
    ; fdargs=
        [ (DataOnly, "x", UMatrix); (AutoDiffable, "y", URowVector)
        ; (AutoDiffable, "z", URowVector); (AutoDiffable, "w", UArray UMatrix)
        ]
    ; fdbody=
        Stmt.Fixed.Pattern.Return
          (Some
             ( w
             @@ FunApp
                  ( StanLib ("add", FnPlain, AoS)
                  , [w @@ Var "x"; w @@ Lit (Int, "1")] ) ) )
        |> with_no_loc |> List.return |> Stmt.Fixed.Pattern.Block |> with_no_loc
        |> Some
    ; fdloc= Location_span.empty }
    |> str "@[<v>%a" pp_fun_def_test
    |> print_endline ;
    [%expect
      {|
    template <typename T0__, typename T1__, typename T2__, typename T3__,
              stan::require_all_t<stan::is_eigen_matrix_dynamic<T0__>,
                                  stan::is_vt_not_complex<T0__>,
                                  stan::is_row_vector<T1__>,
                                  stan::is_vt_not_complex<T1__>,
                                  stan::is_row_vector<T2__>,
                                  stan::is_vt_not_complex<T2__>,
                                  stan::is_stan_scalar<T3__>>* = nullptr>
    Eigen::Matrix<stan::promote_args_t<stan::base_type_t<T0__>,
                    stan::base_type_t<T1__>, stan::base_type_t<T2__>, T3__>,-1,-1>
    sars(const T0__& x_arg__, const T1__& y_arg__, const T2__& z_arg__,
         const std::vector<Eigen::Matrix<T3__,-1,-1>>& w, std::ostream* pstream__) {
      using local_scalar_t__ = stan::promote_args_t<stan::base_type_t<T0__>,
                                 stan::base_type_t<T1__>,
                                 stan::base_type_t<T2__>, T3__>;
      int current_statement__ = 0;
      const auto& x = stan::math::to_ref(x_arg__);
      const auto& y = stan::math::to_ref(y_arg__);
      const auto& z = stan::math::to_ref(z_arg__);
      static constexpr bool propto__ = true;
      // suppress unused var warning
      (void) propto__;
      local_scalar_t__ DUMMY_VAR__(std::numeric_limits<double>::quiet_NaN());
      // suppress unused var warning
      (void) DUMMY_VAR__;
      try {
        return stan::math::add(x, 1);
      } catch (const std::exception& e) {
        stan::lang::rethrow_located(e, locations_array__[current_statement__]);
      }
    }
    template <typename T0__, typename T1__, typename T2__, typename T3__,
              stan::require_all_t<stan::is_eigen_matrix_dynamic<T0__>,
                                  stan::is_vt_not_complex<T0__>,
                                  stan::is_row_vector<T1__>,
                                  stan::is_vt_not_complex<T1__>,
                                  stan::is_row_vector<T2__>,
                                  stan::is_vt_not_complex<T2__>,
                                  stan::is_stan_scalar<T3__>>*>
    Eigen::Matrix<stan::promote_args_t<stan::base_type_t<T0__>,
                    stan::base_type_t<T1__>, stan::base_type_t<T2__>, T3__>,-1,-1>
    sars_functor__::operator()(const T0__& x, const T1__& y, const T2__& z,
                               const std::vector<Eigen::Matrix<T3__,-1,-1>>& w,
                               std::ostream* pstream__) const {
      return sars(x, y, z, w, pstream__);
    } |}]
end
