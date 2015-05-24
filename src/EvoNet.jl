
module EvoNet

# Basic integration step for the network dynamic
const dt = 0.1

include("types.jl")
include("interface.jl")

include("learning_rule.jl")
include("task.jl")
include("network.jl")
include("teacher.jl")

# extra convenience stuff
include("recorder.jl")


end # module EvoNet
