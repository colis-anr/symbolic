(** Identifier environments with default value. *)

type 'a env
val empty : 'a -> 'a env
val get : 'a env -> string -> 'a
val set : 'a env -> string -> 'a -> 'a env
val filter : (string -> 'a -> bool) -> 'a env -> 'a env
val map : ('a -> 'b) -> 'b -> 'a env -> 'b env
val elements : 'a env -> (string * 'a) list

module IdMap : Map.S with type key = string

(** Conversion to a normal map without default value *)
val to_map : 'a env -> 'a IdMap.t

val filter_var_env : ('a -> bool) -> ('a -> string option) -> 'a env -> string IdMap.t
