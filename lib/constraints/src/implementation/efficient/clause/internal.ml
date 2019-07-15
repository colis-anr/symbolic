open Constraints_common
open Dnf.Syntax

exception NotImplemented of string
let not_implemented s = raise (NotImplemented s)

let do_nothing x = x (* fancy name for identity *)

(* {2 Absence} *)

let abs x f c =
  let info = Core.get_info x c in

  match Core.get_kind info with
  | Pos k when k <> Kind.Dir ->
    (* S-Abs-Kind *)
    Dnf.single c

  | Neg ks when List.mem Kind.Dir ks ->
    (* S-Abs-NDir *)
    Dnf.single c

  | _ ->
    match Core.get_feat f info with

    | None when Core.has_fen info ->
      (* P-Abs + S-Abs-Fen*)
      Core.(
        update_info_for_all_similarities
          (fun fs -> if Feat.Set.mem f fs
            then do_nothing
            else remove_feat f)
          x info c
      ) |> Dnf.single

    | None | Some DontKnow | Some (Maybe _) | Some Absent ->
      (* (S-Maybe-Abs) + P-Abs *)
      Core.(
        update_info_for_all_similarities
          (fun fs -> if Feat.Set.mem f fs
            then do_nothing
            else set_feat f Absent)
          x info c
      ) |> Dnf.single

    | Some (Present _) ->
      (* C-Abs-Feat *)
      Dnf.empty

(** {2 Kind} *)

let unsafe_kind_not_dir x info k c =
  Core.(
    info
    |> remove_all_feats     (* S-Abs-NDir, S-Maybe-NDir *)
    |> remove_nfens     (* S-NFen-NDir *)
    |> set_kind k
    |> set_info x c
    |> remove_nsims x   (* S-NSim-NDir *)
    |> Dnf.single
  )

let kind x k c =
  let info = Core.get_info x c in

  match Core.get_kind info with
  | Pos l when k = l ->
    Dnf.single c

  | Pos _ ->
    Dnf.empty (* C-Kind-Kind *)

  | Neg ls when List.mem k ls ->
    Dnf.empty (* C-Kind-NKind *)

  | _ -> (* (S-NKind-Kind) *)
    match k with
    | Dir ->
      Core.(
        info
        |> set_kind (Pos Dir)
        |> set_info x c
        |> Dnf.single
      )

    | _ ->
      unsafe_kind_not_dir x info (Pos k) c

let dir x = kind x Kind.Dir

let missing_kind ls =
  let rec missing_kind = function
    | l :: ls, k :: ks when Kind.equal l k ->
      missing_kind (ls, ks)
    | _, k :: _ ->
      k
    | _ ->
      assert false
  in
  missing_kind (ls, Kind.all)

let nkind x k c =
  let info = Core.get_info x c in

  match Core.get_kind info with
  | Pos l when k = l ->
    Dnf.empty (* C-Kind-NKind *)

  | Pos _ ->
    Dnf.single c (* S-NKind-Kind *)

  | Neg ls when List.mem k ls ->
    Dnf.single c

  | Neg ls ->
    (
      let ls = ExtList.insert_uniq_sorted Kind.compare k ls in

      if List.length ls = Kind.nb_all - 1 then
        kind x (missing_kind ls) c

      else
        match k with
        | Kind.Dir ->
          unsafe_kind_not_dir x info (Neg ls) c

        | _ ->
          Core.(
            info
            |> set_kind (Neg ls)
            |> set_info x c
            |> Dnf.single
          )
    )

  | Any ->
    (
      match k with
      | Kind.Dir ->
        unsafe_kind_not_dir x info (Neg [Dir]) c

      | _ ->
        Core.(
          info
          |> set_kind (Neg [k])
          |> set_info x c
          |> Dnf.single
        )
    )

(* {2 Fence} *)

let fen x fs c =
  dir x c >>= fun c -> (* D-Fen *)
  let info = Core.get_info x c in
  (* Check that feats are either in the fence or outside but compatible. *)
  let ok =
    Core.for_all_feats
      (fun f t ->
         Feat.Set.mem f fs ||
         match t with
         | DontKnow | Absent | Maybe _ -> true
         | Present _ -> false (* C-Feat-Fen *))
      info
  in
  if not ok then
    Dnf.empty
  else
    Core.(
      update_info_for_all_similarities
        (fun gs info ->
           let hs = Feat.Set.union fs gs in
           info
           |> remove_feats (fun f -> not (Feat.Set.mem f hs)) (* S-Abs-Fen, S-Maybe-Fen *)
           |> Feat.Set.fold (fun f -> Core.set_feat_if_none f DontKnow) hs
           |> set_fen)
        x info c
    ) |> Dnf.single
