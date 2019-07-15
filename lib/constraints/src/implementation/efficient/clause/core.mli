(** {1 Core} *)

open Constraints_common

(** {2 Main Structure} *)

type var
(** Type of the variables. *)

type info
(** Type of the information we have on a variable. *)

type t
(** Type of an irreducible existential clause. *)

val empty : t
(** Empty existential clause. That is, "true". *)

(** {2 Variables and information} *)

val fresh_var : unit -> var

val equal : var -> var -> t -> bool

val internalise : Constraints_common.Var.t -> t -> (var * t)

val get_info : var -> t -> info

val set_info : var -> t -> info -> t

val update_info : var -> t -> (info -> info) -> t

(** {2 Local Helpers} *)

(** {3 kinds} *)

type kind = Any | Neg of Kind.t list | Pos of Kind.t

val get_kind : info -> kind

val set_kind : kind -> info -> info

(** {3 feats} *)

type feat = DontKnow | Absent | Present of var | Maybe of var list

val get_feat : Feat.t -> info -> feat option

val fold_feats : (Feat.t -> feat -> 'a -> 'a) -> 'a -> info -> 'a

val for_all_feats : (Feat.t -> feat -> bool) -> info -> bool

val set_feat : Feat.t -> feat -> info -> info

val set_feat_if_none : Feat.t -> feat -> info -> info

val remove_feat : Feat.t -> info -> info

val remove_feats : (Feat.t -> bool) -> info -> info

val remove_all_feats : info -> info

(** {3 fens} *)

val has_fen : info -> bool

val set_fen : info -> info

(** {3 sims} *)

val update_sim : var -> (Feat.Set.t option -> Feat.Set.t) -> info -> info
(** [update_sim y f info] updates the sims in [info] by calling [f None] is
    there is no sim for [y] or [Some gs] if there is a sim [~gs y]. *)

val fold_sims : (Feat.Set.t -> var -> 'a -> 'a) -> 'a -> info -> 'a

(** {3 nfens} *)

val remove_nfens : info -> info
(** Remove all nfens in the given [info]. *)

val not_implemented_nfens : info -> unit
(* Raise [NotImplemented "nfens"] if there are nfens in the given [info].

   FIXME: should not be required if everything is correctly implemented. They
   are here to denote places where work has to be done to support nfens. *)

(** {3 nsims} *)

val remove_nsims : var -> t -> t
(** Remove all nsims in the given [info]. *)

val not_implemented_nsims : info -> unit
(* Raise [NotImplemented "nsims"] if there are nsims in the given [info].

   FIXME: should not be required if everything is correctly implemented. They
   are here to denote places where work has to be done to support nsims. *)

(** {2 Global Helpers} *)

val update_info_for_all_similarities :
  (Feat.Set.t -> info -> info) ->
  var -> info -> t -> t
(** [update_info_for_all_similarities upd x info] takes a clause and
    applies the [upd] function to all the info records of variables that are
    similar to the given info (including it). *)
