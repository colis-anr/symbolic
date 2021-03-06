open SymbolicUtility.ConstraintsCompatibility

module True = struct
  let name = "true"

  let interprete : utility_context -> utility =
    fun _ -> return true
end

module Colon = struct
  include True
  let name = ":"
end

module False = struct
  let name = "false"

  let interprete : utility_context -> utility =
    fun _ -> return false
end

module Echo = struct
  let name = "echo"

  let interprete : utility_context -> utility =
    fun ctx sta ->
    let str = String.concat " " ctx.args in
    let sta = print_stdout ~newline:true str sta in
    [sta, Ok true]
end
