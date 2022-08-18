open Core_kernel
open Core_kernel.Poly
open Middle
open Mangle

let use_opencl = ref false

let translate_funapps_and_kwrds e =
  let open Expr.Fixed in
  let f ({pattern; _} as expr) =
    match pattern with
    | FunApp (UserDefined (fname, suffix), args) ->
        { expr with
          pattern= FunApp (UserDefined (add_prefix_to_kwrds fname, suffix), args)
        }
    | Var s -> {expr with pattern= Var (add_prefix_to_kwrds s)}
    | _ -> expr in
  rewrite_bottom_up ~f e

let rec change_kwrds_stmts s =
  let open Stmt.Fixed.Pattern in
  let pattern =
    match s.Stmt.Fixed.pattern with
    | Decl e -> Decl {e with decl_id= add_prefix_to_kwrds e.decl_id}
    | NRFunApp (UserDefined (s, sfx), e) ->
        NRFunApp (UserDefined (add_prefix_to_kwrds s, sfx), e)
    | Assignment (lhs, t, e2) ->
        Assignment
          (Stmt.Helpers.map_lhs_variable ~f:add_prefix_to_kwrds lhs, t, e2)
    | For e -> For {e with loopvar= add_prefix_to_kwrds e.loopvar}
    | x -> map Fn.id change_kwrds_stmts x in
  {s with pattern}

(** A list of functions which return an Eigen block expression *)
let eigen_block_expr_fns =
  ["head"; "tail"; "segment"; "col"; "row"; "block"; "sub_row"; "sub_col"]
  |> String.Set.of_list

let eval_eigen_blocks e =
  let open Expr.Fixed in
  let f ({pattern; meta} as expr) =
    match (pattern, UnsizedType.is_eigen_type (Expr.Typed.type_of expr)) with
    | Indexed _, true ->
        {meta; pattern= FunApp (StanLib ("eval", FnPlain, AoS), [expr])}
    | FunApp (StanLib (fname, _, _), _), true
      when Set.mem eigen_block_expr_fns fname ->
        {meta; pattern= FunApp (StanLib ("eval", FnPlain, AoS), [expr])}
    | _ -> expr in
  rewrite_bottom_up ~f e

let eval_udf_indexed_calls e =
  let open Expr.Fixed in
  let f ({pattern; _} as expr) =
    match pattern with
    | FunApp ((UserDefined (_, _) as kind), args) ->
        {expr with pattern= FunApp (kind, List.map ~f:eval_eigen_blocks args)}
    | _ -> expr in
  rewrite_bottom_up ~f e

let opencl_trigger_restrictions =
  String.Map.of_alist_exn
    [ ( "bernoulli_lpmf"
      , [ [ (0, UnsizedType.DataOnly, UnsizedType.UArray UnsizedType.UInt)
          ; (1, UnsizedType.DataOnly, UnsizedType.UReal) ] ] )
    ; ( "bernoulli_logit_glm_lpmf"
      , [ (* Array of conditions under which we do not want to move to OpenCL *)
          [(1, UnsizedType.DataOnly, UnsizedType.URowVector)]
          (* Argument 1 (0-based indexing) is a row vector *) ] )
    ; ( "categorical_logit_glm_lpmf"
      , [[(1, UnsizedType.DataOnly, UnsizedType.URowVector)]] )
    ; ( "exponential_lpdf"
      , [ [ (0, UnsizedType.AutoDiffable, UnsizedType.UVector)
          ; (1, UnsizedType.DataOnly, UnsizedType.UReal) ] ] )
    ; ( "neg_binomial_2_log_glm_lpmf"
      , [[(1, UnsizedType.DataOnly, UnsizedType.URowVector)]] )
    ; ( "normal_id_glm_lpdf"
      , [[(1, UnsizedType.DataOnly, UnsizedType.URowVector)]] )
    ; ( "ordered_logistic_glm_lpmf"
      , [[(1, UnsizedType.DataOnly, UnsizedType.URowVector)]] )
    ; ( "poisson_log_glm_lpmf"
      , [[(1, UnsizedType.DataOnly, UnsizedType.URowVector)]] )
    ; ("std_normal_lpdf", [[(0, UnsizedType.AutoDiffable, UnsizedType.UVector)]])
    ; ( "uniform_lpdf"
      , [ [ (0, UnsizedType.AutoDiffable, UnsizedType.UVector)
          ; (1, UnsizedType.DataOnly, UnsizedType.UReal)
          ; (1, UnsizedType.DataOnly, UnsizedType.UReal) ] ] ) ]

let opencl_supported_functions =
  [ "bernoulli_lpmf"; "bernoulli_logit_lpmf"; "bernoulli_logit_glm_lpmf"
  ; "beta_lpdf"; "beta_proportion_lpdf"; "binomial_lpmf"
  ; "categorical_logit_glm_lpmf"; "cauchy_lpdf"; "chi_square_lpdf"
  ; "double_exponential_lpdf"; "exp_mod_normal_lpdf"; "exponential_lpdf"
  ; "frechet_lpdf"; "gamma_lpdf"; "gumbel_lpdf"; "inv_chi_square_lpdf"
  ; "inv_gamma_lpdf"; "logistic_lpdf"; "lognormal_lpdf"; "neg_binomial_lpmf"
  ; "neg_binomial_2_lpmf"; "neg_binomial_2_log_lpmf"
  ; "neg_binomial_2_log_glm_lpmf"; "normal_lpdf"; "normal_id_glm_lpdf"
  ; "ordered_logistic_glm_lpmf"; "pareto_lpdf"; "pareto_type_2_lpdf"
  ; "poisson_lpmf"; "poisson_log_lpmf"; "poisson_log_glm_lpmf"; "rayleigh_lpdf"
  ; "scaled_inv_chi_square_lpdf"; "skew_normal_lpdf"; "std_normal_lpdf"
  ; "student_t_lpdf"; "uniform_lpdf"; "weibull_lpdf" ]
  |> String.Set.of_list

let opencl_suffix = "_opencl__"

let to_matrix_cl e =
  Expr.Fixed.
    {e with pattern= FunApp (StanLib ("to_matrix_cl", FnPlain, AoS), [e])}

let rec switch_expr_to_opencl available_cl_vars (Expr.Fixed.{pattern; _} as e) =
  let is_avail = List.mem available_cl_vars ~equal:( = ) in
  let to_cl (Expr.Fixed.{pattern; meta= {Expr.Typed.Meta.type_; _}} as e) =
    match (pattern, type_) with
    | Var s, _ when is_avail s ->
        Expr.Fixed.{e with pattern= Var (s ^ opencl_suffix)}
    | _, UnsizedType.(UInt | UReal) -> e
    | _, _ -> to_matrix_cl e in
  let check_type args (i, ad, t) =
    let arg = List.nth_exn args i in
    Expr.Typed.type_of arg = t
    && UnsizedType.autodifftype_can_convert (Expr.Typed.adlevel_of arg) ad in
  let is_restricted args = List.exists ~f:(List.for_all ~f:(check_type args)) in
  let maybe_map_args args req_args =
    match req_args with
    | Some x when is_restricted args x -> args
    | None | Some _ -> List.map args ~f:to_cl in
  let is_fn_opencl_supported f = Set.mem opencl_supported_functions f in
  match pattern with
  | FunApp (StanLib (f, sfx, mem_pattern), args) when is_fn_opencl_supported f
    ->
      let trigger = Map.find opencl_trigger_restrictions f in
      { e with
        pattern=
          FunApp (StanLib (f, sfx, mem_pattern), maybe_map_args args trigger) }
  | x ->
      { e with
        pattern=
          Expr.Fixed.Pattern.map (switch_expr_to_opencl available_cl_vars) x }

let rec base_type = function
  | SizedType.SArray (t, _) -> base_type t
  | SVector _ | SRowVector _ | SMatrix _ -> UnsizedType.UReal
  | SComplexVector _ | SComplexRowVector _ | SComplexMatrix _ -> UComplex
  | x -> SizedType.to_unsized x

let pos = "pos__"

let munge_tuple_name name =
  Str.global_replace (Str.regexp_string ".") "_dot_" name

let make_tuple_temp name = munge_tuple_name name ^ "_temp__"

(** This function is essentially copied from [data_read],
    but rather than calling ReadDataFn, this indexes
    into the flattened versions of the tuple data
    created by [data_read] when it encounters an array of tuples

    @param enclosing_tuple_name The name (in the sense of [Stmt.Helpers.get_lhs_name])
      of the element of the tuple this recursive call is handling. This is
      used to generate the appropriate [_flat__] variable to pull from
    @param origin_type The type of the flat variable for this call, if one exists.
      In situations where this is an array of tuples still, this type is unused.
  *)
let rec data_read_inside_tuple enclosing_tuple_name origin_type smeta
    ((decl_id_lval : 'a Stmt.Fixed.Pattern.lvalue), st) =
  let unsized = SizedType.to_unsized st in
  let scalar = base_type st in
  let flat_type = UnsizedType.UArray scalar in
  let decl_id = Stmt.Helpers.get_lhs_name decl_id_lval in
  let decl_var =
    { Expr.Fixed.pattern= Var decl_id
    ; meta= Expr.Typed.Meta.{loc= smeta; type_= unsized; adlevel= DataOnly} }
  in
  let swrap stmt = {Stmt.Fixed.pattern= stmt; meta= smeta} in
  let pos_var = {Expr.Fixed.pattern= Var pos; meta= Expr.Typed.Meta.empty} in
  let flat_name decl_id = munge_tuple_name decl_id ^ "_flat__" in
  let enclosing_tuple_flat, enclosing_tuple_pos =
    let name = munge_tuple_name enclosing_tuple_name in
    (name ^ "_flat__", name ^ "_flat__pos__") in
  let origin_name =
    let var = Expr.Helpers.variable enclosing_tuple_flat in
    { var with
      meta=
        { var.meta with
          type_= origin_type
        ; adlevel= UnsizedType.fill_adtype_for_type DataOnly origin_type } }
  in
  let end_position =
    Expr.Helpers.(
      binop (variable enclosing_tuple_pos) Plus (SizedType.io_size st)) in
  let origin =
    match unsized with
    | UInt | UReal | UComplex ->
        (* Scalars get one index *)
        Expr.Helpers.add_int_index origin_name
          (Index.Single (Expr.Helpers.variable enclosing_tuple_pos))
    | _ ->
        Expr.Helpers.add_int_index origin_name
          (Index.Between
             (Expr.Helpers.variable enclosing_tuple_pos, end_position) ) in
  let incr_tuple_pos =
    Stmt.Fixed.Pattern.Assignment
      (LVariable enclosing_tuple_pos, UInt, end_position)
    |> swrap in
  match unsized with
  | UInt | UReal | UComplex ->
      [Assignment (decl_id_lval, unsized, origin) |> swrap; incr_tuple_pos]
  | UArray UInt | UArray UReal ->
      [Assignment (decl_id_lval, flat_type, origin) |> swrap; incr_tuple_pos]
  | UTuple _ ->
      let get_subtypes = match st with STuple subs -> subs | _ -> [] in
      let sub_sts =
        List.mapi
          ~f:(fun iter x ->
            (Stmt.Fixed.Pattern.LTupleProjection (decl_id_lval, iter + 1), x) )
          get_subtypes in
      let enclosing_names =
        List.mapi
          ~f:(fun i _ -> enclosing_tuple_name ^ "." ^ string_of_int (i + 1))
          get_subtypes in
      List.map2_exn
      (* TUPLE MAYBE : might need to also map over new names, types *)
        ~f:(fun name sts -> data_read_inside_tuple name origin_type smeta sts)
        enclosing_names sub_sts
      |> List.concat
  | UArray _ when UnsizedType.contains_tuple unsized ->
      let nonarray_st, dims = SizedType.get_container_dims st in
      let tuple_component_names, tuple_types =
        match nonarray_st with
        | STuple sts ->
            ( List.mapi
                ~f:(fun i _ ->
                  enclosing_tuple_name ^ "." ^ string_of_int (i + 1) )
                sts
            , sts )
        | _ -> ([], []) in
      let temps =
        List.map2_exn
          ~f:(fun name t ->
            Stmt.Fixed.Pattern.Decl
              { decl_adtype=
                  UnsizedType.fill_adtype_for_type DataOnly
                    (SizedType.to_unsized t)
              ; decl_id= make_tuple_temp name
              ; decl_type= Sized t
              ; initialize= false }
            |> swrap )
          tuple_component_names tuple_types in
      let loop =
        let final_assignment loopvars =
          [ Stmt.Fixed.Pattern.Assignment
              ( LIndexed
                  ( decl_id_lval
                  , List.map ~f:(fun e -> Index.Single e) (List.rev loopvars) )
              , unsized
              , Expr.Helpers.tuple_expr
                  (List.map2_exn
                     ~f:(fun n st ->
                       Expr.Fixed.
                         { pattern= Var (make_tuple_temp n)
                         ; meta=
                             { Expr.Typed.Meta.empty with
                               type_= SizedType.to_unsized st } } )
                     tuple_component_names tuple_types ) )
            |> swrap ] in
        [ Stmt.Helpers.mk_nested_for (List.rev dims)
            (fun loopvars ->
              Stmt.Fixed.
                { meta= smeta
                ; pattern=
                    SList
                      ( ( List.map2_exn
                            ~f:(fun io_name st ->
                              let temp_name = make_tuple_temp io_name in
                              data_read_inside_tuple io_name
                                (UnsizedType.wind_array_type
                                   (SizedType.to_unsized st, List.length dims) )
                                smeta
                                (Pattern.LVariable temp_name, st) )
                            tuple_component_names tuple_types
                        |> List.concat )
                      @ final_assignment loopvars ) } )
            smeta ] in
      [Block (temps @ loop) |> swrap]
  | UFun _ | UMathLibraryFunction ->
      Common.FatalError.fatal_error_msg
        [%message "Cannot read a function type."]
  | UVector | URowVector | UMatrix | UComplexMatrix | UComplexRowVector
   |UComplexVector | UArray _ ->
      let decl, assign, flat_var =
        let decl_id_flat = flat_name decl_id in
        ( Stmt.Fixed.Pattern.Decl
            { decl_adtype= AutoDiffable
            ; decl_id= decl_id_flat
            ; decl_type= Unsized flat_type
            ; initialize= false }
          |> swrap
        , Assignment
            (Stmt.Fixed.Pattern.LVariable decl_id_flat, flat_type, origin)
          |> swrap
        , { Expr.Fixed.pattern= Var decl_id_flat
          ; meta=
              Expr.Typed.Meta.{loc= smeta; type_= flat_type; adlevel= DataOnly}
          } ) in
      let bodyfn _ var =
        let pos_increment =
          [ Assignment
              (LVariable pos, UInt, Expr.Helpers.(binop pos_var Plus one))
            |> swrap ] in
        let read_indexed _ =
          { Expr.Fixed.pattern= Indexed (flat_var, [Single pos_var])
          ; meta= Expr.Typed.Meta.{flat_var.meta with type_= scalar} } in
        SList
          ( Stmt.Helpers.assign_indexed (SizedType.to_unsized st) decl_id_lval
              smeta read_indexed var
          :: pos_increment )
        |> swrap in
      let pos_reset =
        Stmt.Fixed.Pattern.Assignment
          (LVariable pos, UInt, Expr.Helpers.loop_bottom)
        |> swrap in
      [ Block
          [ decl; assign; pos_reset
          ; Stmt.Helpers.for_scalar_inv st bodyfn decl_var smeta; incr_tuple_pos
          ]
        |> swrap ]

let rec data_read ?origin ?name smeta
    ((decl_id_lval : 'a Stmt.Fixed.Pattern.lvalue), st) =
  let unsized = SizedType.to_unsized st in
  let scalar = base_type st in
  let flat_type = UnsizedType.UArray scalar in
  let decl_id = Stmt.Helpers.get_lhs_name decl_id_lval in
  let decl_var =
    { Expr.Fixed.pattern= Var decl_id
    ; meta= Expr.Typed.Meta.{loc= smeta; type_= unsized; adlevel= DataOnly} }
  in
  let swrap stmt = {Stmt.Fixed.pattern= stmt; meta= smeta} in
  let pos_var = {Expr.Fixed.pattern= Var pos; meta= Expr.Typed.Meta.empty} in
  let flat_name decl_id = munge_tuple_name decl_id ^ "_flat__" in
  let readfnapp decl_id flat_type =
    match origin with
    | Some expr -> expr
    | None ->
        Expr.Helpers.internal_funapp FnReadData
          [ { decl_var with
              pattern=
                Lit (Str, remove_prefix (Option.value name ~default:decl_id)) }
          ]
          Expr.Typed.Meta.{decl_var.meta with type_= flat_type} in
  match unsized with
  | UInt | UReal | UComplex ->
      let e =
        match origin with
        | Some expr -> expr
        | None ->
            { Expr.Fixed.pattern=
                Indexed
                  ( readfnapp decl_id flat_type
                  , [Single Expr.Helpers.loop_bottom] )
            ; meta= {decl_var.meta with type_= unsized} } in
      [Assignment (decl_id_lval, unsized, e) |> swrap]
  | UArray UInt | UArray UReal ->
      [ Assignment (decl_id_lval, flat_type, readfnapp decl_id flat_type)
        |> swrap ]
  | UTuple _ ->
      let get_subtypes = match st with STuple subs -> subs | _ -> [] in
      let sub_sts =
        List.mapi
          ~f:(fun iter x ->
            (Stmt.Fixed.Pattern.LTupleProjection (decl_id_lval, iter + 1), x) )
          get_subtypes in
      List.concat_map ~f:(data_read smeta) sub_sts
  | UArray _ when UnsizedType.contains_tuple unsized ->
      (* The IO format for tuples is complicated in this case.
         Therefore, we need to do the following
         1. Make "_flat__" decls for everything
         2. Declare a temp for each item of this tuple
         3. in a loop:
           i. call [data_read_inside_tuple] with the temp variable as the destination
             this function does essentially the same things recursively, but it doesn't create
             more "_flat__" variables for deeper nested arrays-of-tuples.
           ii. assign those temps (forwarding as tuple) to this variable, properly indexed.
      *)
      let nonarray_st, dims = SizedType.get_container_dims st in
      let flat_decls =
        (* Here we need to go recursively all the way down the tuple *)
        let flat_io_names =
          UnsizedType.enumerate_tuple_names_io decl_id
            (SizedType.to_unsized nonarray_st) in
        let flat_vars = List.map ~f:flat_name flat_io_names in
        let flat_types = SizedType.flatten_tuple_io nonarray_st in
        List.map3_exn
          ~f:(fun variable_name io_name st ->
            let typ = SizedType.to_unsized st in
            let scalar_type = UnsizedType.internal_scalar typ in
            let array_type =
              UnsizedType.wind_array_type (scalar_type, List.length dims) in
            [ Stmt.Fixed.Pattern.Decl
                { decl_adtype= AutoDiffable
                ; decl_id= variable_name
                ; decl_type= Unsized array_type
                ; initialize= false }
              |> swrap
            ; Assignment
                ( Stmt.Fixed.Pattern.LVariable variable_name
                , typ
                , readfnapp io_name array_type )
              |> swrap
            ; Stmt.Fixed.Pattern.Decl
                { decl_adtype= DataOnly
                ; decl_id= variable_name ^ "pos__"
                ; decl_type= Unsized UInt
                ; initialize= false }
              |> swrap
            ; Stmt.Fixed.Pattern.Assignment
                ( LVariable (variable_name ^ "pos__")
                , UInt
                , Expr.Helpers.loop_bottom )
              |> swrap ] )
          flat_vars flat_io_names flat_types
        |> List.concat in
      (* from now on, we only care about things at this level,
         calling [data_read_inside_tuple] *)
      let tuple_component_names, tuple_types =
        match nonarray_st with
        | STuple sts ->
            ( List.mapi ~f:(fun i _ -> decl_id ^ "." ^ string_of_int (i + 1)) sts
            , sts )
        | _ -> ([], []) in
      let temps =
        List.map2_exn
          ~f:(fun name t ->
            Stmt.Fixed.Pattern.Decl
              { decl_adtype=
                  UnsizedType.fill_adtype_for_type DataOnly
                    (SizedType.to_unsized t)
              ; decl_id= make_tuple_temp name
              ; decl_type= Sized t
              ; initialize= false }
            |> swrap )
          tuple_component_names tuple_types in
      let loop =
        let final_assignment loopvars =
          [ Stmt.Fixed.Pattern.Assignment
              ( LIndexed
                  ( decl_id_lval
                  , List.map ~f:(fun e -> Index.Single e) (List.rev loopvars) )
              , unsized
              , Expr.Helpers.tuple_expr
                  (List.map2_exn
                     ~f:(fun n st ->
                       Expr.Fixed.
                         { pattern= Var (make_tuple_temp n)
                         ; meta=
                             { Expr.Typed.Meta.empty with
                               type_= SizedType.to_unsized st } } )
                     tuple_component_names tuple_types ) )
            |> swrap ] in
        [ Stmt.Helpers.mk_nested_for (List.rev dims)
            (fun loopvars ->
              Stmt.Fixed.
                { meta= smeta
                ; pattern=
                    SList
                      ( ( List.map2_exn
                            ~f:(fun io_name st ->
                              let temp_name = make_tuple_temp io_name in
                              data_read_inside_tuple io_name
                                (UnsizedType.wind_array_type
                                   (SizedType.to_unsized st, List.length dims) )
                                smeta
                                (Pattern.LVariable temp_name, st) )
                            tuple_component_names tuple_types
                        |> List.concat )
                      @ final_assignment loopvars ) } )
            smeta ] in
      [Block (flat_decls @ temps @ loop) |> swrap]
  | UFun _ | UMathLibraryFunction ->
      Common.FatalError.fatal_error_msg
        [%message "Cannot read a function type."]
  | UVector | URowVector | UMatrix | UComplexMatrix | UComplexRowVector
   |UComplexVector | UArray _ ->
      let decl, assign, flat_var =
        let decl_id_flat = flat_name decl_id in
        ( Stmt.Fixed.Pattern.Decl
            { decl_adtype= AutoDiffable
            ; decl_id= decl_id_flat
            ; decl_type= Unsized flat_type
            ; initialize= false }
          |> swrap
        , Assignment
            ( Stmt.Fixed.Pattern.LVariable decl_id_flat
            , flat_type
            , readfnapp decl_id flat_type )
          |> swrap
        , { Expr.Fixed.pattern= Var decl_id_flat
          ; meta=
              Expr.Typed.Meta.{loc= smeta; type_= flat_type; adlevel= DataOnly}
          } ) in
      let bodyfn _ var =
        let pos_increment =
          [ Assignment
              (LVariable pos, UInt, Expr.Helpers.(binop pos_var Plus one))
            |> swrap ] in
        let read_indexed _ =
          { Expr.Fixed.pattern= Indexed (flat_var, [Single pos_var])
          ; meta= Expr.Typed.Meta.{flat_var.meta with type_= scalar} } in
        SList
          ( Stmt.Helpers.assign_indexed (SizedType.to_unsized st) decl_id_lval
              smeta read_indexed var
          :: pos_increment )
        |> swrap in
      let pos_reset =
        Stmt.Fixed.Pattern.Assignment
          (LVariable pos, UInt, Expr.Helpers.loop_bottom)
        |> swrap in
      [ Block
          [ decl; assign; pos_reset
          ; Stmt.Helpers.for_scalar_inv st bodyfn decl_var smeta ]
        |> swrap ]

(*
  Get the dimension expressions that are expected by constrain/unconstrain
  functions for a sized type.

  For constrains that return square / lower triangular matrices the C++
  only wants one of the matrix dimensions.
*)
let read_constrain_dims constrain_transform st =
  let rec constrain_get_dims st =
    match st with
    | SizedType.SInt | SReal | SComplex | STuple _ -> []
    | SArray (t, dim) -> dim :: constrain_get_dims t
    | SVector (_, d)
     |SRowVector (_, d)
     |SComplexVector d
     |SComplexRowVector d ->
        [d]
    | SMatrix (_, _, dim2) | SComplexMatrix (_, dim2) -> [dim2] in
  match constrain_transform with
  | Transformation.CholeskyCorr | Correlation | Covariance ->
      constrain_get_dims st
  | _ -> SizedType.get_dims st

let data_serializer_read loc out_constrained_st =
  let ut = SizedType.to_unsized out_constrained_st in
  let dims = SizedType.get_dims_io out_constrained_st in
  let emeta = Expr.Typed.Meta.create ~loc ~type_:ut ~adlevel:AutoDiffable () in
  Expr.(
    Helpers.(
      internal_funapp FnReadDataSerializer dims Typed.Meta.{emeta with type_= ut}))

let param_read smeta
    (decl_id_lval, Program.{out_constrained_st= cst; out_block; out_trans; _}) =
  if not (out_block = Parameters) then []
  else
    let rec read_expr (cst, out_trans) =
      let ut = SizedType.to_unsized cst in
      let emeta =
        Expr.Typed.Meta.create ~loc:smeta ~type_:ut
          ~adlevel:(UnsizedType.fill_adtype_for_type AutoDiffable ut)
          () in
      match cst with
      | STuple _ ->
          Expr.Helpers.internal_funapp FnMakeTuple
            (List.map ~f:read_expr @@ Utils.zip_stuple_trans_exn cst out_trans)
            emeta
      | _ ->
          let dims = read_constrain_dims out_trans cst in
          let read =
            Expr.Helpers.internal_funapp
              (FnReadParam
                 { constrain= out_trans
                 ; dims
                 ; mem_pattern= SizedType.get_mem_pattern cst } )
              [] emeta in
          read in
    let rec read_stmt (lval, cst, out_trans) =
      let rec contains_nested_tuple_arr st =
        match st with
        | SizedType.SArray _ -> SizedType.contains_tuple st
        | STuple ts -> List.exists ~f:contains_nested_tuple_arr ts
        | _ -> false in
      match cst with
      | SizedType.SArray _ when SizedType.contains_tuple cst ->
          let nonarray_st, array_dims = SizedType.get_container_dims cst in
          [ Stmt.Helpers.mk_nested_for (List.rev array_dims)
              (fun loopvars ->
                Stmt.Fixed.
                  { meta= smeta
                  ; pattern=
                      SList
                        (read_stmt
                           ( Stmt.Fixed.Pattern.LIndexed
                               ( lval
                               , List.map
                                   ~f:(fun e -> Index.Single e)
                                   (List.rev loopvars) )
                           , nonarray_st
                           , out_trans ) ) } )
              smeta ]
      | SizedType.STuple _ when contains_nested_tuple_arr cst ->
          let subtys = Utils.zip_stuple_trans_exn cst out_trans in
          let sub_sts =
            List.mapi
              ~f:(fun iter (st, trans) ->
                (Stmt.Fixed.Pattern.LTupleProjection (lval, iter + 1), st, trans)
                )
              subtys in
          List.concat_map ~f:read_stmt sub_sts
      | _ ->
          let read = read_expr (cst, out_trans) in
          [ Stmt.Fixed.
              { pattern=
                  Pattern.Assignment (lval, SizedType.to_unsized cst, read)
              ; meta= smeta } ] in
    read_stmt (decl_id_lval, cst, out_trans)

let escape_name str =
  str
  |> String.substr_replace_all ~pattern:"." ~with_:"_"
  |> String.substr_replace_all ~pattern:"-" ~with_:"_"

(** Make sure that all if-while-and-for bodies are safely wrapped in a block in
  such a way that we can insert a location update before. The blocks make sure
  that the program with the inserted location update is still well-formed C++ though.
*)
let rec ensure_body_in_block (Stmt.Fixed.{pattern; _} as stmt) =
  let in_block stmt =
    let pattern =
      Stmt.Fixed.(
        match stmt.pattern with
        | Block l | SList l -> Pattern.Block l
        | _ -> Block [stmt]) in
    {stmt with pattern} in
  let ensure_body_in_block_base pattern =
    Stmt.Fixed.Pattern.(
      match pattern with
      | IfElse (_, _, _) | While (_, _) | For _ -> map Fn.id in_block pattern
      | _ -> pattern) in
  let pattern =
    ensure_body_in_block_base
      Stmt.Fixed.(Pattern.map Fn.id ensure_body_in_block pattern) in
  {stmt with pattern}

let rec flatten_slists_list ls =
  let flatten_slist stmt =
    Stmt.Fixed.(match stmt.pattern with SList ls -> ls | _ -> [stmt]) in
  let rec flatten_slists_stmt stmt =
    let pattern =
      Stmt.Fixed.(
        match stmt.pattern with
        | Block ls ->
            Pattern.Block
              (List.concat_map
                 ~f:(Fn.compose flatten_slist flatten_slists_stmt)
                 ls )
        | pattern -> Pattern.map Fn.id flatten_slists_stmt pattern) in
    {stmt with pattern} in
  List.concat_map ls ~f:(fun stmt ->
      Stmt.Fixed.(
        match stmt.pattern with
        | SList ls -> flatten_slists_list ls
        | _ -> [stmt]) )
  |> List.map ~f:flatten_slists_stmt

let%expect_test "Flatten slists" =
  let e pattern = Expr.Fixed.{meta= (); pattern} in
  let s pattern = Stmt.Fixed.{meta= (); pattern} in
  let stmt =
    Stmt.Fixed.Pattern.(
      [ SList
          [ Block
              [ SList
                  [ While (e (Var "hi"), Block [SList [Break |> s] |> s] |> s)
                    |> s ]
                |> s ]
            |> s ]
        |> s ]
      |> flatten_slists_list) in
  print_s [%sexp (stmt : (unit, unit) Stmt.Fixed.t list)] ;
  [%expect
    {|
    (((pattern
       (Block
        (((pattern
           (While ((pattern (Var hi)) (meta ()))
            ((pattern (Block (((pattern Break) (meta ()))))) (meta ()))))
          (meta ())))))
      (meta ()))) |}]

let add_reads vars mkread stmts =
  let var_names = String.Map.of_alist_exn vars in
  let add_read_to_decl (Stmt.Fixed.{pattern; meta} as stmt) =
    match pattern with
    | Decl {decl_id; _} when Map.mem var_names decl_id ->
        stmt
        :: mkread meta
             ( Stmt.Fixed.Pattern.LVariable decl_id
             , Map.find_exn var_names decl_id )
    | _ -> [stmt] in
  List.concat_map ~f:add_read_to_decl stmts

let gen_write ?(unconstrain = false)
    (decl_id, Program.{out_constrained_st; out_trans; _}) =
  let rec write (var, st, trans) =
    match (unconstrain, st, trans) with
    | true, SizedType.STuple sts, Transformation.TupleTransformation ts ->
        let sub_sts =
          sts
          |> List.mapi ~f:(fun iter x ->
                 (Expr.Helpers.add_tuple_index var (iter + 1), x) )
          |> List.map2_exn ~f:(fun t (v, st) -> (v, st, t)) ts in
        List.concat_map ~f:write sub_sts
    | true, SArray _, TupleTransformation _ ->
        let nonarray_st, array_dims = SizedType.get_container_dims st in
        [ Stmt.Helpers.mk_nested_for (List.rev array_dims)
            (fun loopvars ->
              Stmt.Fixed.
                { meta= Stmt.Located.Meta.empty
                ; pattern=
                    SList
                      (write
                         ( List.fold ~f:Expr.Helpers.add_int_index ~init:var
                             (List.map
                                ~f:(fun e -> Index.Single e)
                                (List.rev loopvars) )
                         , nonarray_st
                         , trans ) ) } )
            Stmt.Located.Meta.empty ]
    | true, _, _ ->
        [ Stmt.Helpers.internal_nrfunapp
            (FnWriteParam {unconstrain_opt= Some trans; var})
            [] Location_span.empty ]
    | false, _, _ ->
        [ Stmt.Helpers.internal_nrfunapp
            (FnWriteParam {unconstrain_opt= None; var})
            [] Location_span.empty ] in
  let decl_var =
    { Expr.Fixed.pattern= Var decl_id
    ; meta=
        Expr.Typed.Meta.
          { loc= Location_span.empty
          ; type_= SizedType.to_unsized out_constrained_st
          ; adlevel= DataOnly } } in
  write (decl_var, out_constrained_st, out_trans)

(**
  Generate write instructions for unconstrained types. For scalars,
  matrices, vectors, and arrays with one dimension we can write
  these directly, but for arrays of arrays/vectors/matrices we
  need to write them in "column major order"
 *)
let gen_unconstrained_write (decl_id, Program.{out_constrained_st; _}) =
  let smeta = Stmt.Located.Meta.empty in
  let rec write (var, st) =
    match st with
    | SizedType.STuple sts ->
        let sub_sts =
          List.mapi
            ~f:(fun iter x -> (Expr.Helpers.add_tuple_index var (iter + 1), x))
            sts in
        List.concat_map ~f:write sub_sts
    | _ when SizedType.is_recursive_container st ->
        let nonarray_st, array_dims = SizedType.get_container_dims st in
        [ Stmt.Helpers.mk_nested_for (List.rev array_dims)
            (fun loopvars ->
              Stmt.Fixed.
                { meta= smeta
                ; pattern=
                    SList
                      (write
                         ( List.fold ~f:Expr.Helpers.add_int_index ~init:var
                             (List.map
                                ~f:(fun e -> Index.Single e)
                                (List.rev loopvars) )
                         , nonarray_st ) ) } )
            smeta ]
    | _ ->
        [ Stmt.Helpers.internal_nrfunapp
            (FnWriteParam {unconstrain_opt= None; var})
            [] Location_span.empty ] in
  let var =
    { Expr.Fixed.pattern= Var decl_id
    ; meta=
        Expr.Typed.Meta.
          { loc= Location_span.empty
          ; type_= SizedType.to_unsized out_constrained_st
          ; adlevel= DataOnly } } in
  write (var, out_constrained_st)

(** Statements to read, unconstrain and assign a parameter then write it back *)
let data_unconstrain_transform smeta (decl_id, outvar) : Stmt.Located.t list =
  let decl =
    Stmt.Fixed.
      { pattern=
          Decl
            { decl_adtype=
                UnsizedType.fill_adtype_for_type AutoDiffable
                  (SizedType.to_unsized outvar.Program.out_constrained_st)
            ; decl_id
            ; decl_type= Type.Sized outvar.Program.out_constrained_st
            ; initialize= true }
      ; meta= smeta } in
  let rec read (lval, st) =
    match st with
    | SizedType.SInt | SReal | SComplex ->
        [ Stmt.Fixed.
            { meta= smeta
            ; pattern=
                Assignment
                  ( lval
                  , outvar.Program.out_constrained_st |> SizedType.inner_type
                    |> SizedType.to_unsized
                  , data_serializer_read smeta st ) } ]
    | STuple sts ->
        let sub_sts =
          List.mapi
            ~f:(fun iter x ->
              (Stmt.Fixed.Pattern.LTupleProjection (lval, iter + 1), x) )
            sts in
        List.concat_map ~f:read sub_sts
    | _ ->
        let nonarray_st, array_dims = SizedType.get_container_dims st in
        [ Stmt.Helpers.mk_nested_for (List.rev array_dims)
            (fun loopvars ->
              Stmt.Fixed.
                { meta= smeta
                ; pattern=
                    SList
                      (read
                         ( LIndexed
                             ( lval
                             , List.map
                                 ~f:(fun e -> Index.Single e)
                                 (List.rev loopvars) )
                         , nonarray_st ) ) } )
            smeta ] in
  (decl :: read (LVariable decl_id, outvar.Program.out_constrained_st))
  @ gen_write ~unconstrain:true (decl_id, outvar)

(* let%expect_test "data unconstrain transform" =
   let mkoutvar (name, st, t) =
     ( name
     , Program.
         { out_unconstrained_st= st
         ; out_constrained_st= st
         ; out_block= Parameters
         ; out_trans= t } ) in
   let outs =
     List.map ~f:mkoutvar
       [ ( "y"
         , SizedType.SArray (STuple [SReal; SReal], Expr.Helpers.int 3)
         , Transformation.TupleTransformation [Identity; Identity] ) ] in
   outs
   |> List.concat_map ~f:(data_unconstrain_transform Location_span.empty)
   |> List.sexp_of_t Stmt.Located.sexp_of_t
   |> print_s ;
   [%expect {| |}] *)

let rec contains_var_expr is_vident accum Expr.Fixed.{pattern; _} =
  accum
  ||
  match pattern with
  | Var v when is_vident v -> true
  | pattern ->
      Expr.Fixed.Pattern.fold (contains_var_expr is_vident) false pattern

let fn_name_map =
  String.Map.of_alist_exn [("integrate_ode", "integrate_ode_rk45")]

let rec map_fn_names s =
  let rec map_fn_names_expr e =
    let pattern =
      Expr.Fixed.(
        match e.pattern with
        | FunApp (StanLib (f, sfx, mem_pattern), a) when Map.mem fn_name_map f
          ->
            Pattern.FunApp
              (StanLib (Map.find_exn fn_name_map f, sfx, mem_pattern), a)
        | expr -> Pattern.map map_fn_names_expr expr) in
    {e with pattern} in
  let stmt =
    Stmt.Fixed.(
      match s.pattern with
      | NRFunApp (StanLib (f, sfx, mem_pattern), a) when Map.mem fn_name_map f
        ->
          Pattern.NRFunApp
            (StanLib (Map.find_exn fn_name_map f, sfx, mem_pattern), a)
      | stmt -> Pattern.map map_fn_names_expr map_fn_names stmt) in
  {s with pattern= stmt}

let rec insert_before f to_insert = function
  | [] -> to_insert
  | hd :: tl ->
      if f hd then to_insert @ (hd :: tl)
      else hd :: insert_before f to_insert tl

let is_opencl_var = String.is_suffix ~suffix:opencl_suffix

let rec collect_vars_expr is_target accum Expr.Fixed.{pattern; _} =
  Set.union accum
    ( match pattern with
    | Var s when is_target s -> String.Set.of_list [s]
    | x ->
        Expr.Fixed.Pattern.fold (collect_vars_expr is_target) String.Set.empty x
    )

let collect_opencl_vars s =
  let rec go accum s =
    Stmt.Fixed.(
      Pattern.fold (collect_vars_expr is_opencl_var) go accum s.pattern) in
  go String.Set.empty s

let%expect_test "collect vars expr" =
  let mkvar s = Expr.{Fixed.pattern= Var s; meta= Typed.Meta.empty} in
  let args = List.map ~f:mkvar ["y"; "x_opencl__"; "z"; "w_opencl__"] in
  let fnapp =
    Expr.
      { Fixed.pattern= FunApp (StanLib ("print", FnPlain, AoS), args)
      ; meta= Typed.Meta.empty } in
  Stmt.Fixed.{pattern= TargetPE fnapp; meta= Location_span.empty}
  |> collect_opencl_vars |> String.Set.sexp_of_t |> print_s ;
  [%expect {| (w_opencl__ x_opencl__) |}]

let%expect_test "insert before" =
  let l = [1; 2; 3; 4; 5; 6] |> insert_before (( = ) 6) [999] in
  [%sexp (l : int list)] |> print_s ;
  [%expect {| (1 2 3 4 5 999 6) |}]

let map_prog_stmt_lists f (p : ('a, 'b) Program.t) =
  { p with
    Program.prepare_data= f p.prepare_data
  ; log_prob= f p.log_prob
  ; generate_quantities= f p.generate_quantities
  ; transform_inits= f p.transform_inits }

let trans_prog (p : Program.Typed.t) =
  (* name mangling of c++ keywords*)
  let rec map_stmt {Stmt.Fixed.pattern; meta} =
    { Stmt.Fixed.pattern=
        Stmt.Fixed.Pattern.map translate_funapps_and_kwrds map_stmt pattern
    ; meta } in
  let rename_kwrds (s, e) = (add_prefix_to_kwrds s, e) in
  let rename_fdarg (e1, s, e2) = (e1, add_prefix_to_kwrds s, e2) in
  let rename_func (s : 'a Program.fun_def) =
    { s with
      fdname= add_prefix_to_kwrds s.fdname
    ; fdargs= List.map ~f:rename_fdarg s.fdargs } in
  let p =
    Program.(
      { p with
        output_vars= List.map ~f:rename_kwrds p.output_vars
      ; input_vars= List.map ~f:rename_kwrds p.input_vars
      ; functions_block= List.map ~f:rename_func p.functions_block }
      |> map translate_funapps_and_kwrds map_stmt
      |> map Fn.id change_kwrds_stmts) in
  let p = Program.map Fn.id map_fn_names p in
  (* Eval indexed eigen types in UDF calls to prevent
     infinite template expansion if the call is recursive
  *)
  let possibly_recursive_fns =
    List.filter_map
      ~f:(function
        | {fdname; fdargs; fdbody= None; _} -> Some (fdname, fdargs) | _ -> None
        )
      p.functions_block
    |> Set.Poly.of_list in
  let rec map_stmt {Stmt.Fixed.pattern; meta} =
    match pattern with
    | NRFunApp ((UserDefined _ as kind), args) ->
        { Stmt.Fixed.meta
        ; pattern= NRFunApp (kind, List.map ~f:eval_eigen_blocks args) }
    | _ ->
        { Stmt.Fixed.pattern=
            Stmt.Fixed.Pattern.map eval_udf_indexed_calls map_stmt pattern
        ; meta } in
  let eval_udf_indexed_stmts (s : 'a Program.fun_def) =
    if Set.mem possibly_recursive_fns (s.fdname, s.fdargs) then
      {s with fdbody= Option.map ~f:map_stmt s.fdbody}
    else s in
  let p =
    { p with
      functions_block= List.map ~f:eval_udf_indexed_stmts p.functions_block }
  in
  let init_pos =
    [ Stmt.Fixed.Pattern.Decl
        { decl_adtype= DataOnly
        ; decl_id= pos
        ; decl_type= Sized SInt
        ; initialize= true }
    ; Assignment (LVariable pos, UInt, Expr.Helpers.loop_bottom) ]
    |> List.map ~f:(fun pattern ->
           Stmt.Fixed.{pattern; meta= Location_span.empty} ) in
  let param_writes, tparam_writes, gq_writes =
    List.map p.output_vars ~f:gen_unconstrained_write
    |> List.map2_exn p.output_vars ~f:(fun (_, outvar) writes ->
           ( outvar.Program.out_block
           , Stmt.Fixed.{pattern= SList writes; meta= Location_span.empty} ) )
    |> List.partition3_map ~f:(fun (b, x) ->
           match b with
           | Parameters -> `Fst x
           | TransformedParameters -> `Snd x
           | GeneratedQuantities -> `Trd x ) in
  let tparam_start stmt =
    Stmt.Fixed.(
      match stmt.pattern with
      | IfElse (cond, _, _)
        when contains_var_expr
               (( = ) "emit_transformed_parameters__")
               false cond ->
          true
      | _ -> false) in
  let gq_start Stmt.Fixed.{pattern; _} =
    match pattern with
    | IfElse
        ( { pattern=
              FunApp (_, [{pattern= Var "emit_generated_quantities__"; _}])
          ; _ }
        , _
        , _ ) ->
        true
    | _ -> false in
  let translate_to_open_cl stmts =
    if !use_opencl then
      let decl Stmt.Fixed.{pattern; _} =
        match pattern with
        | Decl {decl_type= Sized (SInt | SReal); _} -> None
        | Decl {decl_id; _} -> Some decl_id
        | _ -> None in
      let data_var_idents = List.filter_map ~f:decl p.prepare_data in
      let switch_expr = switch_expr_to_opencl data_var_idents in
      let rec trans_stmt_to_opencl s =
        Stmt.Fixed.
          { s with
            pattern= Pattern.map switch_expr trans_stmt_to_opencl s.pattern }
      in
      List.map stmts ~f:trans_stmt_to_opencl
    else stmts in
  let tparam_writes_cond =
    match tparam_writes with
    | [] -> []
    | _ ->
        [ Stmt.Fixed.
            { pattern=
                IfElse
                  ( Expr.
                      { Fixed.pattern= Var "emit_transformed_parameters__"
                      ; meta= Typed.Meta.empty }
                  , {pattern= SList tparam_writes; meta= Location_span.empty}
                  , None )
            ; meta= Location_span.empty } ] in
  let generate_quantities =
    ( p.generate_quantities
    |> add_reads p.output_vars param_read
    |> translate_to_open_cl
    |> insert_before tparam_start param_writes
    |> insert_before gq_start tparam_writes_cond )
    @ gq_writes in
  let log_prob =
    p.log_prob |> add_reads p.output_vars param_read |> translate_to_open_cl
  in
  let opencl_vars =
    String.Set.union_list
      (List.concat_map
         ~f:(List.map ~f:collect_opencl_vars)
         [log_prob; generate_quantities] )
    |> String.Set.to_list in
  let maybe_add_opencl_events_clear =
    let event_clear_stmt x =
      Stmt.Fixed.
        { pattern= NRFunApp (CompilerInternal (FnReadWriteEventsOpenCL x), [])
        ; meta= Location_span.empty } in
    List.map ~f:event_clear_stmt opencl_vars in
  let to_matrix_cl_stmts =
    List.concat_map opencl_vars ~f:(fun vident ->
        let vident_sans_opencl =
          String.chop_suffix_exn ~suffix:opencl_suffix vident in
        let type_of_input_var =
          match
            List.Assoc.find p.input_vars vident_sans_opencl ~equal:String.equal
          with
          | Some st -> SizedType.to_unsized st
          | None -> UnsizedType.UMatrix in
        [ Stmt.Fixed.
            { pattern=
                Decl
                  { decl_adtype= DataOnly
                  ; decl_id= vident
                  ; decl_type= Type.Unsized type_of_input_var
                  ; initialize= true }
            ; meta= Location_span.empty }
        ; { pattern=
              Assignment
                ( LVariable vident
                , type_of_input_var
                , to_matrix_cl
                    { pattern= Var vident_sans_opencl
                    ; meta= Expr.Typed.Meta.empty } )
          ; meta= Location_span.empty } ] ) in
  let p =
    { p with
      log_prob= log_prob @ maybe_add_opencl_events_clear
    ; prog_name= escape_name p.prog_name
    ; prepare_data=
        init_pos
        @ (p.prepare_data |> add_reads p.input_vars data_read)
        @ to_matrix_cl_stmts
    ; transform_inits=
        init_pos
        @ List.concat_map
            ~f:(data_unconstrain_transform Location_span.empty)
            (List.filter
               ~f:(fun (_, ov) -> ov.Program.out_block = Parameters)
               p.output_vars )
    ; generate_quantities } in
  Program.(
    p
    |> map Fn.id ensure_body_in_block
    |> map_prog_stmt_lists flatten_slists_list)
