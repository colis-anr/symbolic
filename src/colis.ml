open Format

module Errors = Errors
module Options = Options

module Language = struct
  module Nat = Syntax__Nat
  module Syntax = Syntax__Syntax
  module Parser = ColisParser
  module Lexer = ColisLexer
  module FromShell = FromShell
end

module Concrete = struct
  module Arguments = Semantics__Arguments
  module Behaviour = Semantics__Behaviour
  module Stdin = Semantics__Buffers.Stdin
  module Stdout = Semantics__Buffers.Stdout
  module Context = Semantics__Context
  module Env = Semantics__Env
  module Input = Semantics__Input
  module Semantics = Semantics__Semantics
  module Filesystem = Interpreter__Filesystem
  module Interpreter = Interpreter__Interpreter
end

module Symbolic = struct
  module Context = SymbolicInterpreter__Context
  module Filesystem = SymbolicInterpreter__Filesystem
  module FilesystemSpec = FilesystemSpec
  module State = SymbolicInterpreter__State
  module SymState = SymbolicInterpreter__SymState
  module Results = SymbolicInterpreter__Results
  module Interpreter = SymbolicInterpreter__Interpreter
  module Utilities = SymbolicUtilities
end

(* Parsers *)

type colis = Language.Syntax.program

let parse_colis_lexbuf ?(filename="-") lexbuf =
  lexbuf.Lexing.lex_curr_p <-
    { lexbuf.Lexing.lex_curr_p
      with Lexing.pos_fname = filename };
  try
    ColisParser.program ColisLexer.token lexbuf
  with
  | ColisLexer.LexerError s ->
    let pos = lexbuf.Lexing.lex_curr_p in
    raise (Errors.ParseError (s, pos))
  | ColisParser.Error ->
    let pos = lexbuf.Lexing.lex_curr_p in
    raise (Errors.ParseError ("", pos))

let parse_colis_channel ?(filename="-") channel =
  let lexbuf = Lexing.from_channel channel in
  parse_colis_lexbuf ~filename lexbuf

let parse_colis_file filename =
  let ic =
    try
      open_in filename
    with
      Sys_error msg -> raise (Errors.FileError msg)
  in
  try
    let colis = parse_colis_channel ~filename ic in
    close_in ic;
    colis
  with
    exn -> close_in ic; raise exn

let parse_colis_string string =
  let lexbuf = Lexing.from_string string in
  parse_colis_lexbuf lexbuf

let parse_shell_file = FromShell.parse_file

(* Printers *)

let pp_print_colis = ToColis.program

let print_colis =
  pp_print_colis Format.std_formatter

let colis_to_string colis =
  let buf = Buffer.create 8 in
  let fmt = Format.formatter_of_buffer buf in
  pp_print_colis fmt colis;
  Buffer.contents buf

let colis_to_file filename colis =
  let ochan = open_out filename in
  let fmt = Format.formatter_of_out_channel ochan in
  pp_print_colis fmt colis;
  close_out ochan

(* Interpret *)

let run ~argument0 ?(arguments=[]) colis =
  let open Concrete in
  let input = { Input.empty with argument0 } in
  let state = Interpreter.empty_state () in
  state.arguments := arguments;
  try
    let cnf = Z.minus_one in (* Don’t break while loops *)
    Interpreter.interp_program cnf input state colis;
    print_string (Stdout.all_lines !(state.stdout) |> List.rev |> String.concat "\n");
    exit (if !(state.result) then 0 else 1)
  with Interpreter.EFailure ->
    assert false (* The counter in the interpretation of while loops decreases and will never hit zero *)

let print_symbolic_filesystem fmt fs =
  let open Constraints in
  let open Symbolic.Filesystem in
  fprintf fmt "root: %a@\n" Var.pp fs.root;
  fprintf fmt "cwd: %a@\n" Path.pp fs.cwd;
  fprintf fmt "clause: %a@\n" Clause.pp_sat_conj fs.clause

let _print_dot filename id clause =
  let ch = open_out filename in
  try
    let fmt = formatter_of_out_channel ch in
    Constraints.Conj.pp_as_dot ~name:id fmt clause;
    close_out ch
  with e ->
    close_out ch;
    raise e

let print_symbolic_state fmt ?id sta =
  let open Symbolic.State in
  begin match id with
    | Some id ->
      fprintf fmt "id: %s@\n" id;
      (* print_dot (sprintf "/tmp/%s.dot" id) id sta.filesystem.clause; *)
    | None -> ()
  end;
  print_symbolic_filesystem fmt sta.filesystem;
  (* Print stdin *)
  if sta.stdin <> [] then begin
    fprintf fmt "stdin: |@\n";
    List.iter (fprintf fmt "  %s@\n")
      (List.rev sta.stdin)
  end;
  (* Print stdout *)
  if not (Concrete.Stdout.is_empty sta.stdout) then begin
    fprintf fmt "stdout: |@\n";
    List.iter (fprintf fmt "  %s@\n")
      (List.rev @@ sta.stdout.lines);
    fprintf fmt "  %s" sta.stdout.line
  end

let run_symbolic ~prune_init_state ~while_loop_boundary fs_spec ~argument0 ?(arguments=[]) colis =
  let open Symbolic in
  let cnf = while_loop_boundary in
  let clause_to_state root clause =
    let cwd = Constraints.Path.Abs [] in
    let root0 = if prune_init_state then None else Some root in
    let filesystem = {Filesystem.clause; cwd; root; root0} in
    let stdin = Concrete.Stdin.empty in
    let stdout = Concrete.Stdout.empty in
    {State.filesystem; stdin; stdout}
  in
  let run_in_state state =
    let input = { Concrete.Input.empty with argument0 } in
    let context = { Context.empty_context with arguments } in
    let normals, errors, failures = Interpreter.interp_program input context state colis in
    state, normals, errors, failures
  in
  let res =
    let open Constraints in
    let root = Constraints.Var.fresh ~hint:"r" () in
    let clause = FilesystemSpec.compile ~root fs_spec in
    Clause.(add_to_sat_conj clause true_) |>
    List.map (clause_to_state root) |>
    List.map run_in_state
  in
  let print_symbolic_state label ctr fmt sta =
    let id = sprintf "%s-%d" label !ctr in
    incr ctr;
    fprintf fmt "- @[%a@]@\n" (print_symbolic_state ~id) sta
  in
  List.iter
    (fun (init, normals, errors, failures) ->
       printf "* Initial state@\n";
       printf "%a@\n" (print_symbolic_state "init" (ref 0)) init;
       printf "* Success states@\n";
       List.iter (print_symbolic_state "success" (ref 1) Format.std_formatter) (BatSet.to_list normals);
       printf "@\n";
       printf "* Error states@\n";
       List.iter (print_state_record (ref 1) "error" Format.std_formatter) (BatSet.to_list errors);
       printf "@\n";
       printf "* Failure states@\n";
       List.iter (print_symbolic_state "failure" (ref 1) Format.std_formatter) (BatSet.to_list errors);
       printf "@\n";
       printf "* Summary@\n@\n";
       printf "- Success cases: %d@\n" (BatSet.cardinal normals);
       printf "- Error cases: %d@\n" (BatSet.cardinal errors))
    res;
  let allright = List.forall BatSet.(fun (_, _, errs, fails) -> is_empty errs && is_empty fails) res in
  exit (if allright then 0 else 1)
