open Constraints_common
open Dnf.Syntax

let do_nothing x = x (* fancy name for identity *)

let implied_by_ndir info c cont =
  (* This function is made to be used by constructs that have the {S-*-Kind} and
     {S-*-NDir} rules, that is the constructs that are known to be implied by
     a kind different from [dir] or by [¬dir]. It simply returns the clause when
     we know that this is not a directory. Or calls the continuation. *)
  match Core.get_kind info with
  | Pos k when k <> Kind.Dir -> Dnf.single c (* S-*-Kind *)
  | Neg ks when List.mem Kind.Dir ks -> Dnf.single c (* S-*-NDir *)
  | _ -> cont ()

(* {2 Absence} *)

let abs x f c =
  let info = Core.get_info x c in
  implied_by_ndir info c @@ fun () -> (* S-Abs-Kind, S-Abs-NDir *)
  match Core.get_feat f info with
  | None when Core.has_fen info ->
    Core.(
      update_info_for_all_similarities
        (fun fs -> if Feat.Set.mem f fs
          then do_nothing
          else remove_feat f (* P-Abs + S-Abs-Fen *))
        x info c
    ) |> Dnf.single

  | None | Some DontKnow | Some (Maybe _) | Some Absent -> (* S-Maybe-Abs *)
    Core.(
      update_info_for_all_similarities
        (fun fs -> if Feat.Set.mem f fs
          then do_nothing
          else set_feat f Absent (* P-Abs *))
        x info c
    ) |> Dnf.single

  | Some (Present _) -> Dnf.empty (* C-Abs-Feat *)

(** {2 Kind} *)

let unsafe_kind_not_dir x info k c =
  Core.(
    info
    |> remove_all_feats  (* S-Abs-NDir, S-Maybe-NDir *)
    |> remove_nfens      (* S-NFen-NDir *)
    |> set_kind k
    |> set_info x c
    |> remove_nsims x    (* S-NSim-NDir *)
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
  (* Looks in a sorted list of kinds for the first one that isn't there by
     comparing to [Kind.all] (sorted as well). *)
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
  | Pos l when k = l -> Dnf.empty (* C-Kind-NKind *)
  | Pos _ -> Dnf.single c (* S-NKind-Kind *)
  | Neg ls when List.mem k ls -> Dnf.single c

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
  if
    Core.for_all_feats
      (fun f t ->
         Feat.Set.mem f fs ||
         match t with
         | DontKnow | Absent | Maybe _ -> true
         | Present _ -> false (* C-Feat-Fen *))
      info
  then
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
  else
    Dnf.empty

(* {2 Similarity} *)

let unsafe_sim x fs y c =
  Core.update_info x c @@ fun info ->
  Core.update_sim y
    (function
      | None -> fs
      | Some gs -> Feat.Set.inter fs gs)
    info

let sim x fs y c =
  if Core.equal x y c then
    Dnf.single c (* S-Sim-Relf *)
  else
    (
      let transfer_info x info_x y c =
        (* This function defines the transfer of info from x to y. It will need
           to be called both ways. *)

        (* Fail in case of nfens or nsims. FIXME. *)
        Core.not_implemented_nfens info_x;
        Core.not_implemented_nsims info_x;

        (* Transfer all feats by calling the appropriate function
           (feat, abs or maybe). *)
        Core.(
          fold_feats
            (fun f t c ->
               c >>= fun c ->
               match t with
               | DontKnow -> Dnf.single c
               | Absent -> abs x f c
               | Present z -> feat x f z c
               | Maybe zs -> List.fold_left (fun c z -> maybe x f z c) (Dnf.single c) zs
            )
            (Dnf.single c)
            info_x
        ) >>= fun c ->

        ( (* Transfer the fen if there is one. *)
          if Core.has_fen info_x then
            let gs = Core.fold_feats (fun f _ fs -> Feat.Set.add f fs) Feat.Set.empty info_x in
            let hs = Feat.Set.union fs gs in
            fen y hs c
          else
            Dnf.single c
        ) >>= fun c ->

        (* Transfer the sims. We don't do that by calling ourselves but
           manually. *)
        Core.(
          fold_sims
            (fun gs z c ->
               let hs = Feat.Set.union fs gs in
               c >>= fun c ->
               c
               |> unsafe_sim y hs z
               |> unsafe_sim z hs y
               |> Dnf.single)
            (Dnf.single c)
            info_x
        ) >>= fun c ->

        (* Add our similarity. *)
        unsafe_sim x fs y c
      |> Dnf.single
      in
      dir x c >>= fun c -> (* D-Sim *)
      dir y c >>= fun c -> (* D-Sim *)
      let info_x = Core.get_info x c in
      let info_y = Core.get_info y c in
      transfer_info x info_x y c >>= fun c ->
      transfer_info x info_y x c
    )
