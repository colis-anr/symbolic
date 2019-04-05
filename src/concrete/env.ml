module IdMap = Map.Make (String)
type 'a env = {map: 'a IdMap.t; default: 'a}
let empty default = {map=IdMap.empty; default}
let get env id = try IdMap.find id env.map with Not_found -> env.default
let set env id value = {env with map=IdMap.add id value env.map}
let filter p env = {env with map=IdMap.filter p env.map}
let map f default env = {map=IdMap.map f env.map; default}
let elements env = IdMap.fold (fun k v t -> (k, v) :: t) env.map []
