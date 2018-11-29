open Constraints
open SymbolicInterpreter__Filesystem
open SymbolicInterpreter__State

type utility =
  string list -> state -> (state * bool) list

let print_line msg state =
  let open Semantics__Buffers in
  let stdout = Stdout.(output msg state.stdout |> newline) in
  {state with stdout}

let print_debug msg state =
  if String.equal msg "" then
    state
  else
    let msg = "[DBG] "^msg in
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
  error_message: string option;
}

let success_case ~descr spec = {
  result = true;
  error_message = None;
  descr; spec
}

let error_case ~descr ?error_message spec = {
  result = false;
  error_message; descr; spec;
}

let failure ?error_message () = [{
    result = false;
    descr = "";
    error_message;
    spec = Clause.(exists @@ fun v -> eq v v); (* is there a better way to write `true' ? *)
  }]

(* Create the corresponding filesystem, update the state and create corresponding
    result **)
let apply_clause_to_state state case root clause =
  let filesystem = {clause; root; cwd=state.filesystem.cwd} in
  let state' =
    { state with filesystem }
    |> print_error case.error_message
    |> print_debug case.descr
  in
  state', case.result

let apply_case_to_state state root case : (state * bool) list =
  (* Add the spec to the current clause *)
  Clause.add_to_sat_conj case.spec state.filesystem.clause
  (* Quantify over the old state root *)
  |> List.map (Clause.quantify_over state.filesystem.root)
  |> List.flatten
  |> List.map (apply_clause_to_state state case root)

type specifications = cwd:Path.t -> root:Var.t -> root':Var.t -> case list

let under_specifications : specifications -> state -> (state * bool) list =
  fun spec state ->
    let new_root = Var.fresh ~hint:(Var.to_string state.filesystem.root) () in
    spec ~cwd:state.filesystem.cwd ~root:state.filesystem.root ~root':new_root
    |> List.map (apply_case_to_state state new_root)
    |> List.flatten
