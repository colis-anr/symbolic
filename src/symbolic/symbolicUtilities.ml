open Constraints
open Clause
open UtilitiesSpecification
open Semantics__Buffers
open SymbolicInterpreter__State

let path_split_last str =
  Path.split_last
    (Path.from_string str)

let error ?msg () : state -> (state * bool) list =
  fun sta ->
    let sta' =
      match msg with
      | Some msg ->
        let str = "[ERR] "^msg in
        let stdout = Stdout.(output str sta.stdout |> newline) in
        {sta with stdout}
      | None -> sta
    in
    [sta', false]

let return result : utility =
  fun _args sta ->
    [sta, result]

let interp_echo : utility =
  fun args sta ->
    let open Semantics__Buffers in
    let open SymbolicInterpreter__State in
    let str = String.concat " " args in
    let stdout = Stdout.(output str sta.stdout |> newline) in
    [ {sta with stdout}, true ]

let last_comp_as_hint p =
  match Path.split_last p with
  | Some (_, Down f) -> Some (Feat.to_string f)
  | _ -> None

let interp_touch : utility =
  function
  | [path_str] -> begin
      let path = Path.from_string path_str in
      match Path.split_last path with
      | Some (q, Down f) ->
        let hintx = last_comp_as_hint q in (* TODO if None extract from root *)
        under_specs @@ fun cwd root root' -> [
          (* The dir "path" exists but does not have "feat". *)
          { outcome = Success;
            spec =
              exists ?hint:hintx @@ fun x ->
              exists ?hint:hintx @@ fun x' ->
              exists ~hint:(Feat.to_string f) @@ fun y ->
              resolve root cwd q x &
              dir x &
              abs x f &
              similar root root' cwd q x x' &
              feat x f x' &
              dir x' &
              feat x' f y &
              reg y };
          (* The dir "path" exists and has "feat". *)
          { outcome = Success ;
            spec =
              exists ~hint:(Feat.to_string f) @@ fun y ->
              resolve root cwd path y &
              eq root root' };
          (* The dir "path" does not exist. *)
          { outcome = Error;
            spec =
              noresolve root cwd q &
              eq root root' }
        ]
      | None ->
        (* `touch ''` *)
        error ~msg:"cannot touch '': No such file or directory" ()
      | Some (_, (Up|Here)) ->
        failwith "interp_touch: no specification"
    end
  | _ ->
    error ~msg:"touch: not exactly one argument" ()

let interp_mkdir : utility =
  function
  | [path_str] -> begin
      match path_split_last path_str with
      | None ->
        error ()
      | Some (q, (Here|Up)) ->
        error ~msg:"mkdir: file exists" () (* TODO *)
      | Some (q, Down f) ->
        let hintx = last_comp_as_hint q in
        under_specs @@ fun cwd root root' ->
        [ (* The dir "path" exists but does not have "feat". *)
          { outcome = Success;
            spec =
              exists ?hint:hintx @@ fun x ->
              exists ?hint:hintx @@ fun x' ->
              exists ~hint:(Feat.to_string f) @@ fun y ->
              resolve root cwd q x &
              dir x &
              abs x f &
              similar root root' cwd q x x' &
              sim x (Feat.Set.singleton f) x' &
              dir x' &
              feat x' f y &
              dir y &
              fen y Feat.Set.empty };
          (* The dir "path" does not exist. *)
          { outcome = Error;
            spec =
              exists @@ fun x ->
              resolve root cwd q x &
              dir x &
              nabs x f &
              eq root root' };
          (* The dir "path" exists and has "feat". *)
          { outcome = Error;
            spec =
              exists @@ fun x ->
              resolve root cwd q x &
              ndir x &
              eq root root' };
          { outcome = Error;
            spec =
              noresolve root cwd q &
              eq root root'} ]
    end
  | _ ->
    error ~msg:"mkdir: not exactly one argument" ()

let interp_test_e : utility =
  function
  | [path_str] -> begin
      match path_split_last path_str with
      | None ->
        error ()
      | Some (q, Down f) ->
        let hintx = last_comp_as_hint q in
        under_specs @@ fun cwd root root' -> [
          { outcome = Success;
            spec =
              exists ?hint:hintx @@ fun x ->
              resolve root cwd q x &
              eq root root' };
          { outcome = Error;
            spec =
              noresolve root cwd q &
              eq root root' }
        ]
      | Some (q, (Here|Up)) ->
        failwith "interp_test_e: no specification"
    end
  | _ ->
    error ~msg:"test -e: not exactly one argument" ()

(* Dispatch interpretation of utilities *)

let interp (name: string) : utility =
  match name with
  | "true" -> return true
  | "false" -> return false
  | "echo" -> interp_echo
  | "test-e" -> interp_test_e
  | "touch" -> interp_touch
  | "mkdir" -> interp_mkdir
  | _ -> fun _ -> error ~msg:("Unknown builtin: "^name) ()
