open Constraints
open SymbolicInterpreter__Semantics
open Semantics__Buffers

type utility = state -> (state * bool) list

let return result : utility =
  function sta -> [sta, result]

let apply_to_list l u =
  (* apply utility [u] to a list [l] of states *)
  List.concat (List.map u l)

let separate_states l =
  (* split a list of pairs state*bool into the list of states with flag
     [true] and the list of pairs with flag [false]
   *)
  let rec separate_aux posacc negacc = function
    | [] -> (posacc,negacc)
    | (s,true)::l -> separate_aux (s::posacc) negacc l
    | (s,false)::l -> separate_aux posacc (s::negacc) l
  in separate_aux [] [] l

let choice u1 u2 =
  (* non-deterministic choice *)
  function state -> (u1 state) @ (u2 state)

let if_then_else (cond:utility) (posbranch:utility) (negbranch:utility) =
  function sta ->
    let (posstates,negstates) = separate_states (cond sta)
    in
    (apply_to_list posstates posbranch)
    @ (apply_to_list negstates negbranch)
let if_then (cond:utility) (posbranch:utility) =
  function sta ->
    let (posstates,negstates) = separate_states (cond sta)
    in
    (apply_to_list posstates posbranch)
    @ (List.map (function sta -> (sta,true)) negstates)

let uneg (u:utility) : utility = fun st ->
  List.map (fun (s,b) -> (s, not b)) (u st)

let uand (u1:utility) (u2:utility) : utility = fun st ->
  List.flatten
    (List.map
       (fun (s1,b1) ->
         List.map (fun (s2,b2) -> (s2, b1 && b2)) (u2 s1))
       (u1 st))

let uor (u1:utility) (u2:utility) : utility = fun st ->
  List.flatten
    (List.map
       (fun (s1,b1) ->
         List.map (fun (s2,b2) -> (s2, b1 || b2)) (u2 s1))
       (u1 st))

let compose_non_strict (u1:utility) (u2:utility) =
  function sta ->
    apply_to_list (List.map fst (u1 sta)) u2

let compose_strict (u1:utility) (u2:utility) =
  function sta ->
    let (success1,failure1) = separate_states (u1 sta)
    in (apply_to_list success1 u2) @
         (List.map (function sta -> (sta,false)) failure1)

let print_line msg state =
  let open Semantics__Buffers in
  let stdout = Stdout.(output msg state.stdout |> newline) in
  {state with stdout}

let print_utility_trace msg state =
  if String.equal msg "" then
    state
  else
    let msg = "[UTL] "^msg in
    print_line msg state

let print_error msg state =
  match msg with
  | Some msg ->
    let msg = "[ERR] "^msg in
    print_line msg state
  | None ->
    state

type case = {
  result : bool;
  spec : Clause.t;
  descr : string;
  stdout : Stdout.t ;
  error_message: string option;
}

let success_case ~descr ?(stdout=Stdout.empty) spec =
  { result = true ; error_message = None ; stdout ; descr; spec }

let error_case ~descr ?(stdout=Stdout.empty) ?error_message spec =
  { result = false ; error_message ; stdout ; descr ; spec }

let failure ?error_message () =
  [{ result = false ;
     descr = "" ;
     stdout = Stdout.empty ;
     error_message ;
     spec = Clause.true_ }]

let quantify_over_intermediate_root state conj =
  match state.filesystem.root0 with
  | Some root0 when Var.equal root0 state.filesystem.root -> [conj]
  | _ -> Clause.quantify_over state.filesystem.root conj

let apply_output_to_state (state : state) stdout =
  { state with stdout = Stdout.concat state.stdout stdout }

(* Create the corresponding filesystem, update the state and create corresponding
    result **)
let apply_clause_to_state state case root clause =
  let filesystem = {state.filesystem with clause; root} in
  let state' =
    { state with filesystem }
    |> print_error case.error_message
  in
  state', case.result

let apply_case_to_state state root case : (state * bool) list =
  let state = print_utility_trace case.descr state in
  let state = apply_output_to_state state case.stdout in
  (* Add the case specification to the current clause *)
  Clause.add_to_sat_conj case.spec state.filesystem.clause
  |> List.map (quantify_over_intermediate_root state)
  |> List.flatten
  |> List.map (apply_clause_to_state state case root)


type specifications = root:Var.t -> root':Var.t -> case list

let under_specifications : specifications -> state -> (state * bool) list =
  fun spec state ->
    let new_root = Var.fresh ~hint:(Var.hint state.filesystem.root) () in
    let cases = spec ~root:state.filesystem.root ~root':new_root in
    List.map (apply_case_to_state state new_root) cases |> List.flatten

(******************************************************************************)
(*                                  Auxiliaries                               *)
(******************************************************************************)

let last_comp_as_hint: root:Var.t -> Path.t -> string option =
  fun ~root path ->
    match Path.split_last path with
    | Some (_, Down f) ->
      Some (Feat.to_string f)
    | None -> (* Empty parent path => root *)
      Some (Var.hint root)
    | Some (_, (Here|Up)) ->
      None (* We can’t know (if last component in parent path is a symbolic link) *)

let error ?msg () : utility =
  fun sta ->
    let sta' =
      match msg with
      | Some msg ->
        let str = "[ERR] "^msg in
        let stdout = Stdout.(output str sta.stdout |> newline) in
        {sta with stdout}
      | None -> sta
    in
    [ sta', false ]

let unknown_utility ?(msg="Unknown utility") ~name () =
  if !Options.fail_on_unknown_utilities then
    raise (Errors.UnsupportedUtility (name, msg))
  else
    error ~msg:(msg ^ ": " ^ name) ()

let unknown_argument ?(msg="Unknown argument") ~name ~arg () =
  if !Options.fail_on_unknown_utilities then
    raise (Errors.UnsupportedArgument (name, msg, arg))
  else
    error ~msg:(msg ^ ": " ^ arg) ()

module IdMap = Env.IdMap

type context = {
  args: string list;
  cwd: Path.normal;
  env: string IdMap.t;
}

module type SYMBOLIC_UTILITY = sig
  val name : string
  val interprete : context -> utility
end

let table = Hashtbl.create 10

let register (module M:SYMBOLIC_UTILITY) =
  Hashtbl.replace table M.name M.interprete

let register' (name, f) =
  register (module struct let name = name let interprete = f end)

let dispatch ~name =
  try Hashtbl.find table name
  with Not_found -> fun _ -> unknown_utility ~name ()

let call name ctx args =
  dispatch ~name {ctx with args}

let dispatch' (cwd, env, args) name sta =
  Collection.of_list (dispatch ~name {cwd; args; env} sta)
