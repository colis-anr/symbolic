open SymbolicUtility
   
module IdMap = Env.IdMap

let name = "dpkg-maintscript-helpers"

let call myname myctx myargs =
  dispatch ~name:myname {myctx with args=myargs}
  
let supports args =
  match args with
  |["rm_conffile"]|["mv_conffile"]|["symlink_to_dir"]|["dir_to_symlink"]
   -> return true
  | _ -> return false
       
exception NoDashDash
let split_at_dashdash l =
  (* split a list into the part before "--" and the part after *)
  let rec split_aux acc = function
    | "--"::rest -> (List.rev acc, rest)
    | head::rest -> split_aux (head::acc) rest
    | [] -> raise NoDashDash
  in split_aux [] l
   
let (||>>) = compose_non_strict
let starts_on_slash s = String.length s > 0 && s.[0]='/'
let ends_on_slash s = let n = String.length s in n > 0 && s.[n-1]='/'
let empty_string s = (String.length s = 0)
let dpkg_compare_versions_le_nl s1 s2 = assert false (* FIXME *)
let dpkg_validate_version s = true (* FIXME *)
let validate_optional_version s =
  empty_string s || dpkg_validate_version s
let ensure_package_owns_file package file = true (* FIXME *)
let conffiles package = [] (* FIXME *)
let contents package = [] (* FIXME *)
let is_pathprefix p1 p2 =
  (* check whether [p1^'/'] is a prefix of [p2] *)
  let rec forall_from_to lower upper pred =
    (* check [(pred lower) && .... && (pred upper)] *)
    if lower > upper then true
    else pred lower && forall_from_to (lower+1) upper pred
  in
  let n1 = String.length p1
  and n2 = String.length p2
  in
  if n1+1 >= n2
  then
    false
  else
    p2.[n1]='/' && forall_from_to 0 (n1-1) (function i -> p1.[i]=p2.[i])
  
let interp_test_fence pathname arity = return true (* FIXME *)
                                     
exception Error of string
exception NumberOfArguments
exception MaintainerScriptArguments
        
let prepare_rm_conffile ctx conffile package =
  if ensure_package_owns_file package conffile
  then choice
         (let args = ["-f"; conffile; conffile^".dpkg-backup"] in
          dispatch ~name:"mv" {ctx with args})
         (let args = ["-f"; conffile; conffile^".dpkg-remove"] in
          dispatch ~name:"mv" {ctx with args})
  else return true
  
let finish_rm_conffile ctx conffile =
  (if_then
     (call "test" ctx ["-e"; conffile^".dpkg-backup"])
     (* TODO: echo .... in positive case *)
     (call "mv" ctx ["-f"; conffile^".dpkg-backup"; conffile^".dpkg-bak"]))
  ||>>
    (if_then
       (call "test" ctx ["-e"; conffile^".dpkg-remove"])
       (* TODO echo ... in positive case *)
       (call "rm" ctx ["-f"; conffile^".dpkg-remove"])
    )
  
let abort_rm_conffile ctx conffile package =
  if ensure_package_owns_file package conffile
  then
    (if_then
       (call "test" ctx ["-e"; conffile^".dpkg-remove"])
       (* TODO echo ... in positive case *)
       (call "mv" ctx [conffile^".dpkg-remove"; conffile]))
    ||>>
      (if_then
         (call "test" ctx ["-e"; conffile^".dpkg-backup"])
         (* TODO echo ... in positive case *)
         (let args = [conffile^".dpkg-backup"; conffile] in
          (dispatch ~name:"mv" {ctx with args})))
  else
    return true
  
let rm_conffile ctx scriptarg1 scriptarg2 =
  let dpkg_package =
    try IdMap.find "DPKG_MAINTSCRIPT_PACKAGE" ctx.env
    with Not_found ->
      raise (Error
               "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let default_package =
    try
      let dpkg_arch = IdMap.find "DPKG_MAINTSCRIPT_ARCH" ctx.env
      in dpkg_package^":"^dpkg_arch
    with Not_found -> dpkg_package
  in
  let dpkg_maintscript_name =
    try IdMap.find "DPKG_MAINTSCRIPT_NAME" ctx.env
    with
    | Not_found ->
       raise (Error
                "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let (conffile,lastversion,package) =
    match ctx.args with
    | [x;y;z] -> (x,y,if empty_string z then default_package else z)
    | [x;y] -> (x,y,default_package)
    | [x] -> (x,"",default_package)
    | _ -> raise NumberOfArguments
  in
  if empty_string package then
    raise (Error "couldn't identify the package");
  (* checking scriptarg1 done by [interprete] *)
  (* checking DPKG_MAINTSCRIPTNAME done above *)
  (* checking DPKG_MAINTSCRIPT_PACKAGE done above *)
  if not (starts_on_slash conffile) then
    raise (Error "conffile '$CONFFILE' is not an absolute path");
  if not (validate_optional_version lastversion) then
    raise (Error ("wrong version "^lastversion));
  match dpkg_maintscript_name with
  | "preinst" ->
     if (scriptarg1 = "install" || scriptarg1 = "upgrade")
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion
     then prepare_rm_conffile ctx conffile package
     else return true
  | "postinst" ->
     if scriptarg1 = "configure"
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion
     then finish_rm_conffile ctx conffile
     else return true
  | "postrm" ->
     if scriptarg1 = "purge"
     then
       call "rm" ctx
         [ "-f";
           conffile^".dpkg-bak";
           conffile^".dpkg-remove";
           conffile^".dpkg-backup"]
     else
       if (scriptarg1 = "abort-install" || scriptarg1 = "abort-upgrade")
          && not (empty_string scriptarg2)
          && dpkg_compare_versions_le_nl scriptarg2 lastversion
       then abort_rm_conffile ctx conffile package
       else return true
  | _ -> return true
       
let prepare_mv_conffile ctx conffile package =
  if_then
    (call "test" ctx ["-e"; conffile])
    (if ensure_package_owns_file package conffile
     then
       choice
         (let args = ["-f"; conffile; conffile^".dpkg-remove"] in
          dispatch ~name:"mv" {ctx with args})
         (return true)
     else return true)
  
let finish_mv_conffile ctx oldconffile newconffile package =
  (call "rm" ctx ["-f"; oldconffile^".dpkg-remove"])
  ||>>
    (if_then
       (call "test" ctx ["-e"; oldconffile])
       (if ensure_package_owns_file package oldconffile
        then
          (* TODO echo bla bla *)
          compose_non_strict
            (if_then_else
               (call "test" ctx ["-e"; newconffile])
               (call "mv" ctx ["-f";newconffile; newconffile^".dpkg-new"])
               (return true))
            (call "mv" ctx ["-f"; oldconffile; newconffile])
        else return true
       )
    )
  
let abort_mv_conffile ctx conffile package =
  if ensure_package_owns_file package conffile
  then
    if_then
      (call "test" ctx ["-e"; conffile^".dpkg-remove"])
      (* TODO echo bla bla *)
      (let args = [conffile^".dpkg-remove"; conffile] in
       dispatch ~name:"mv" {ctx with args})
  else return true
  
let mv_conffile ctx scriptarg1 scriptarg2 =
  let dpkg_package =
    try IdMap.find "DPKG_MAINTSCRIPT_PACKAGE" ctx.env
    with Not_found ->
      raise (Error
               "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let default_package =
    try
      let dpkg_arch = IdMap.find "DPKG_MAINTSCRIPT_ARCH" ctx.env
      in dpkg_package^":"^dpkg_arch
    with Not_found -> dpkg_package
  in
  let dpkg_maintscript_name =
    try IdMap.find "DPKG_MAINTSCRIPT_NAME" ctx.env
    with
    | Not_found ->
       raise (Error
                "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let (oldconffile,newconffile,lastversion,package) =
    match ctx.args with
    | [w;x;y;z] -> (w,x,y,if empty_string z then default_package else z)
    | [w;x;y] -> (w,x,y,default_package)
    | [w;x] -> (w,x,"",default_package)
    | _ -> raise NumberOfArguments
  in
  if empty_string package then
    raise (Error "couldn't identify the package");
  (* checking scriptarg1 done by [interprete] *)
  (* checking DPKG_MAINTSCRIPT_NAME done above *)
  (* checking DPKG_MAINTSCRIPT_PACKAGE done above *)
  if not (starts_on_slash oldconffile) then
    raise (Error "conffile '$OLDCONFFILE' is not an absolute path");
  if not (starts_on_slash newconffile) then
    raise (Error "conffile '$NEWCONFFILE' is not an absolute path");
  if not (validate_optional_version lastversion) then
    raise (Error ("wrong version "^lastversion));
  match dpkg_maintscript_name with
  | "preinst" ->
     if (scriptarg1 = "install" || scriptarg1 = "upgrade")
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion
     then prepare_mv_conffile ctx oldconffile package
     else return true
  | "postinst" ->
     if scriptarg1 = "configure"
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion
     then finish_mv_conffile ctx oldconffile newconffile package
     else return true
  | "postrm" ->
     if (scriptarg1 = "abort-install" || scriptarg1 = "abort-upgrade")
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion
     then abort_mv_conffile ctx oldconffile package
     else return true
  | _ -> return true
       
let symlink_match link target = assert false (* FIXME *)
                              
let symlink_to_dir ctx scriptarg1 scriptarg2 =
  let dpkg_package =
    try IdMap.find "DPKG_MAINTSCRIPT_PACKAGE" ctx.env
    with Not_found ->
      raise (Error "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let default_package =
    try
      let dpkg_arch = IdMap.find "DPKG_MAINTSCRIPT_ARCH" ctx.env
      in dpkg_package^":"^dpkg_arch
    with Not_found -> dpkg_package
  in
  let dpkg_maintscript_name =
    try IdMap.find "DPKG_MAINTSCRIPT_NAME" ctx.env
    with
    | Not_found ->
       raise (Error
                "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let (symlink,symlink_target,lastversion,package) =
    match ctx.args with
    | [w;x;y;z] -> (w,x,y,if empty_string z then default_package else z)
    | [w;x;y] -> (w,x,y,default_package)
    | [w;x] -> (w,x,"",default_package)
    | _ -> raise NumberOfArguments
  in
  if empty_string package then
    raise (Error "couldn't identify the package");
  if empty_string symlink then
    raise (Error "symlink parameter is missing");
  if not (starts_on_slash symlink) then
    raise (Error "symlink pathname is not an absolute path");
  if ends_on_slash symlink then
    raise (Error "symlink pathname ends with a slash");
  if empty_string symlink_target then
    raise (Error "original symlink target is missing");
  (* checking scriptarg1 done by [interprete] *)
  (* checking DPKG_MAINTSCRIPT_NAME done above *)
  (* checking DPKG_MAINTSCRIPT_PACKAGE done above *)
  if not (validate_optional_version lastversion) then
    raise (Error ("wrong version "^lastversion));
  match dpkg_maintscript_name with
  | "preinst" ->
     if (scriptarg1 = "install" || scriptarg1 = "upgrade" )
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion
     then
       if_then
         (call "test" ctx ["-h"; symlink])
         (if_then_else
            (symlink_match symlink symlink_target)
            (call "mv" ctx [symlink; symlink^".dpkg-backup"] )
            (return true))
     else return true
  | "postinst" ->
     if scriptarg1 = "configure"
     then
       if_then
         (call "test" ctx ["-h"; symlink^".dpkg-backup"])
         (if_then_else
            (symlink_match (symlink^".dpkg-backup") symlink_target)
            (call "rm" ctx ["-f"; symlink^".dpkg-backup"])
            (return true))
     else return true
  | "postrm" ->
     (if scriptarg1 = "purge"
      then
        if_then
          (call "test" ctx ["-h"; symlink^".dpkg-backup"])
          (call "rm" ctx ["-f"; symlink^".dpkg-backup"])
      else return true)
     ||>>
       (if (scriptarg1 = "abort-install" || scriptarg1 = "abort-upgrade")
           && not (empty_string scriptarg2)
           && dpkg_compare_versions_le_nl scriptarg2 lastversion
        then
          if_then_else
            (call "test" ctx ["-e"; symlink])
            (return true)
            (if_then
               (call "test" ctx ["-h"; symlink^".dpkg-backup"])
               (if_then
                  (symlink_match (symlink^".dpkg-backup") symlink_target)
                  (* FIXME echo Restoring ... *)
                  (let args = [symlink^".dpkg-backup"; symlink] in
                   dispatch ~name:"mv" {ctx with args})))
        else return true)
  | _ -> return true
       
let prepare_dir_to_symlink ctx package pathname =
  (if List.exists
        (function filename -> is_pathprefix pathname filename)
        (conffiles package)
   then raise (Error
                 ("directory '"^pathname^
                    "' contains conffiles, cannot swithc to directory"))
   else return true)
  ||>>
    (if_then
       (interp_test_fence
          pathname
          (List.filter
             (function filename -> is_pathprefix pathname filename)
             (* FIXME we also need to remove the pathprefix *)
             (contents package)))
       (raise (Error
                 ("directory '" ^ pathname
                  ^ "' contains files not owned by '" ^ package
                  ^ "', cannot switch to symlink"))))
  ||>>
    (let args = ["-f"; pathname; pathname^".dpkg-staging-dir"] in
     dispatch ~name:"mv" {ctx with args})
  ||>>
    (call "mkdir" ctx [pathname])
  ||>>
    (call "touch" ctx [pathname^"/.dpkg-staging-dir"])
  
let finish_dir_to_symlink _ctx pathname symlink_target = assert false
                                                       
let abort_dir_to_symlink _ctx pathname = assert false
                                       
let dir_to_symlink ctx scriptarg1 scriptarg2 =
  let dpkg_package =
    try IdMap.find "DPKG_MAINTSCRIPT_PACKAGE" ctx.env
    with Not_found ->
      raise (Error
               "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let default_package =
    try
      let dpkg_arch = IdMap.find "DPKG_MAINTSCRIPT_ARCH" ctx.env
      in dpkg_package^":"^dpkg_arch
    with Not_found -> dpkg_package
  in
  let dpkg_maintscript_name =
    try IdMap.find "DPKG_MAINTSCRIPT_NAME" ctx.env
    with
    | Not_found ->
       raise (Error
                "environment variable DPKG_MAINTSCRIPT_PACKAGE is required")
  in
  let (pathname,symlink_target,lastversion,package) =
    match ctx.args with
    | [w;x;y;z] -> (w,x,y,if empty_string z then default_package else z)
    | [w;x;y] -> (w,x,y,default_package)
    | [w;x] -> (w,x,"",default_package)
    | _ -> raise NumberOfArguments
  in
  (* checking DPKG_MAINTSCRIPT_NAME done above *)
  (* checking DPKG_MAINTSCRIPT_PACKAGE done above *)
  if empty_string package then
    raise (Error "cannot identify the package");
  if empty_string pathname then
    raise (Error "directory parameter is missing");
  if not (starts_on_slash pathname) then
    raise (Error "directory parameter is not an absolute path");
  if empty_string symlink_target then
    raise (Error "new symlink target is missing");
  (* checking scriptarg1 done by [interprete] *)
  if not (validate_optional_version lastversion) then
    raise (Error ("wrong version "^lastversion));
  match dpkg_maintscript_name with
  | "preinst" ->
     if (scriptarg1 = "install" || scriptarg1 = "upgrade" )
        && not (empty_string scriptarg2)
        && dpkg_compare_versions_le_nl scriptarg2 lastversion then
       if_then
         (call "test" ctx ["-h"; pathname])
         (if_then_else
            (call "test" ctx ["-d"; pathname])
            (prepare_dir_to_symlink ctx package pathname)
            (return true))
     else return true
  | "postinst" ->
     if scriptarg1 = "configure" then
       if_then
         (call "test" ctx ["-d"; pathname^".dpkg-backup"])
         (if_then_else
            (call "test" ctx ["-h"; pathname])
            (return true)
            (if_then
               (call "test" ctx ["-d"; pathname])
               (if_then
                  (call "test" ctx ["-f"; pathname^".dpkg-staging-dir"])
                  (finish_dir_to_symlink ctx pathname symlink_target)
               )
            )
         )
     else return true
  | "postrm" ->
     (if scriptarg1 = "purge"
      then if_then
             (call "test" ctx ["-d"; pathname^".dpkg-backup"])
             (call "rm" ctx ["-rf"; pathname^".dpkg-backup"])
      else return true
     )
     ||>>
       (if (scriptarg1 = "abort-install" || scriptarg1 = "abort-upgrade")
           && not (empty_string scriptarg2)
           && dpkg_compare_versions_le_nl scriptarg2 lastversion then
          (if_then
             (call "test" ctx ["-d"; pathname^".dpkg-backup"])
             (if_then_else
                (call "test" ctx ["-h"; pathname])
                (if_then
                   (symlink_match pathname symlink_target)
                   (abort_dir_to_symlink ctx pathname))
                (if_then
                   (call "test" ctx
                      ["-d"; pathname;"-a";"-f";pathname^".dpkg-staging-dir"])
                   (abort_dir_to_symlink ctx pathname))))
        else return true)
  | _ -> return true
       
let interprete ctx =
  match ctx.args with
  | subcmd::restargs ->
     begin
       if subcmd = "supports" then
         supports restargs
       else
         try
           let (args,scriptargs) = split_at_dashdash ctx.args in
           let (scriptarg1,scriptarg2) =
             match scriptargs with
             | [x;y] -> (x,y)
             | [x] -> (x,"")
             | _ -> raise MaintainerScriptArguments
           in
           match subcmd with
           | "rm_conffile"->
              rm_conffile ctx scriptarg1 scriptarg2
           | "mv_conffile" ->
              mv_conffile ctx scriptarg1 scriptarg2
           | "symlink_to_dir" ->
              symlink_to_dir ctx scriptarg1 scriptarg2
           | "dir_to_symlink" ->
              dir_to_symlink {ctx with args} scriptarg1 scriptarg2
           | _ -> unknown_argument
                    ~msg:"unknown subcommand"
                    ~name:"dpkg_maintscript_helper"
                    ~arg:subcmd
                    ()
         with
         | NoDashDash ->
            unknown_argument
              ~msg:"missing -- separator"
              ~name:("dpkg-maintscript-helper "^subcmd)
              ~arg:"" (* FIXME *)
              ()
         | MaintainerScriptArguments ->
            unknown_argument
              ~msg:"maintainer script arguments are missing"
              ~name:("dpkg-maintscript-helper "^subcmd)
              ~arg: "" (* FIXME *)
              ()
         | Error s ->
            error ~msg:s ()
     end
  | [] -> unknown_argument
            ~msg:"no arguments"
            ~name: "dpkg_maintscript_helper"
            ~arg:"" (* FIXME *)
            ()
            