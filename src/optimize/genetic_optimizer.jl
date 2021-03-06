#
# OPTIMIZE - GENETIC OPTIMIZER
#

type GeneticOptimizer
  population::Vector{AbstractGenerator}   # vector of generators, all different genotypes

  fitness::Function     # maps AbstractGenerator       → AbstractRating
  compare::Function     # maps AbstractGenerator², RNG → bool,
                        # returns true if first arg is better than second

  env::AbstractEnvironment # the environment that the optimizer has to work in
  generation::Int       # counts the number of generations that have been simulated
  recorder::Recorder    # records genotype information
  rng::AbstractRNG      # an own rng for deterministic results

  # Constructor
  function GeneticOptimizer( fitness::Function, compare::Function;
                             population::Vector{AbstractGenerator}=AbstractGenerator[],
                             env::AbstractEnvironment=Environment(),
                             seed::Integer = randseed() )
      new( population, fitness, compare, env, 0, Recorder(), MersenneTwister(seed) )
  end
end

# function to calculate the success values as fast as possible in parallel
# ATTENTION: Usage of this function makes it necessary to start julia appropriately
# for several processes
function rate_population_parallel( opt::GeneticOptimizer; seed::Integer=randseed(),
                                   samples = 10, pop = opt.population )
  rng = MersenneTwister(seed)
  gene_tuples = [ (gene, randseed(rng)) for gene in pop ]
  return AbstractRating[ succ for succ in pmap( x -> opt.fitness(x[1],
                                                            rng=MersenneTwister(x[2]),
                                                            samples=samples,
                                                            env=opt.env),
                                                       gene_tuples ) ]
end

function init_population!( opt::GeneticOptimizer, base_element::AbstractGenerator, N::Integer )
  # provde defaults to be mutated later
  opt.population = AbstractGenerator[ deepcopy(base_element) for i in 1:N ]
  # load parameters
  params = export_params( base_element ) # Vector of AbstractParameters
  valid = filter( i -> get_name(params[i]) ∉ opt.env.blacklist, 1:length(params) )
  # randomize the generators in the population (genome-pool)
  for gen in opt.population
    # damn, thats one big list comprehension. for valid (i.e. not blacklisted) indices, use random_params, and copy the others.
    # deepcopy probably is overkill, but does not hurt either.
    import_params!( gen, AbstractParameter[i ∈ valid ? random_param(params[i], opt.rng, s = 0.5 ) :
                                                       deepcopy(params[i])
                                           for i in 1:length(params)]
                   )
  end
end


function init_population!( opt::GeneticOptimizer, base_elements::AbstractVector, N::Integer; fracs=ones(length(base_elements)) )
  # normalize the fractions
  cumratios = cumsum(fracs/sum(fracs))
  cumsizes = Int[ round(r*N) for r in cumratios ] # e.g. [2, 5, 9]
  prepend!(cumsizes, Int[0] )
  sizes = cumsizes[2:end] - cumsizes[1:end-1]
  f(ele) = typeof(ele) <: AbstractGenerator ? (ele, 0.5) : ele
  base_elements = (AbstractGenerator, Float64)[ f(ele) for ele in base_elements  ]
  opt.population = AbstractGenerator[]
  for i in 1:length(sizes)
      pop = AbstractGenerator[ deepcopy(base_elements[i][1]) for j in 1:sizes[i] ]
      params = export_params( base_elements[i][1] )
      valid = filter( j -> get_name(params[j]) ∉ opt.env.blacklist, 1:length(params))
      for gen in pop
          import_params!( gen, AbstractParameter[j ∈ valid ? random_param(params[j], opt.rng, s = base_elements[i][2]) :
                                                             deepcopy(params[j])
                                                 for j in 1:length(params)]
                        )
      end
          append!( opt.population, pop )
  end
end

function step!( opt::GeneticOptimizer ) ## TO BE GENERALIZED
  # provide the impatient programmer with some information
  println("processing generation $(opt.generation)")

  #
  #mean_success, variance = record_population(opt.recorder, opt.population, opt.success, opt.generation)

  # collection of all generators that survive
  survivors = fight_till_death(opt, opt.population)

  # two stage population generation:
  #newborns = calculate_next_generation(opt, survivors, 2*length(opt.population) )
  #opt.population = infancy_death(opt, newborns, length(opt.population))

  opt.population = calculate_next_generation(opt, survivors, length(opt.population) )
  opt.generation += 1
end

# lets the members of a population fight
function fight_till_death( opt::GeneticOptimizer, population::Vector{AbstractGenerator};
                          rng::AbstractRNG = opt.rng, compare::Function = opt.compare,
                          reduction_rate::Float64 = 0.5, max_samples::Integer = 100,
                          samples::Integer = 40
                          )
   # collection of all generators that survive
  success = rate_population_parallel(opt, seed=randseed(rng), pop = population, samples = samples)
  mean, stddev = mean_success(success)
  while(samples < max_samples)
    req1 = ceil(4*(mean * (1-mean) / stddev)^2) # first criterion: error
    req2 = 0
    if mean > 0.5
      # second criterion: possible results
      # if we have N samples, distributed symetrically around mean up to 1, we get B = 2(1-mean)⋅N usefull bins for our results
      # distributing population P, we get K = S/B entries per bin. The chance of comparing two entities of the same bin thus is
      # p = K/S ≤! 0.1. Pluggin in yield 1/B ≤! 0.1 ⇒ 2(1-mean)⋅N ≥ 10
      # thus N ≥ 5 / (1-mean)   □
      req2 = ceil(5/(1-mean))
    end
    if samples < max(req1, req2)
      println("mean $(mean)±$(stddev) → $(samples + 10) samples, estimating $(req1) / $(req2) total")
      success += rate_population_parallel(opt, seed=randseed(rng), pop = population, samples = 10)
      mean, stddev = mean_success(success)
      samples += 10
    else
      break
    end
  end

  wins = zeros(length(population))
  NUM_FIGHTS = 100
  for i = 1:NUM_FIGHTS
    # random order for comparison
    order = shuffle( rng, collect(1:length(population)) )

    # fight: just compare the old fitnesses
    for i = 2:2:length(population)
      if compare( success[order[i-1]], success[order[i]], rng )
        wins[order[i-1]] += 1
      else
        wins[order[i]] += 1
      end
    end
  end

  num_survivors = ceil(length(population) * (1.0 - reduction_rate) )
  survived = zeros( length(population) )
  survivors = AbstractGenerator[]
  for i = 1:num_survivors
    index = indmax(wins)
    push!(survivors, population[index]  )
    wins[index] = 0 # prevent double selection
    survived[index] = 1
  end

  # record the population, includin who survived
  record_population(opt.recorder, population, success, survived, opt.generation)

  return shuffle(rng, survivors) # make sure they are not ordered in any particular way
end


# calculate mean and stddev of success
function mean_success(suc::Vector{AbstractRating})
  # collect info about all gens
  mean = 0.0
  squared_success = 0.0
  @inbounds for i = 1:length(suc)
    mean += suc[i].quota
    squared_success += suc[i].quota * suc[i].quota
  end
  mean /= length(suc)
  squared_success /= length(suc)
  variance = squared_success - mean*mean
  return mean::Float64, sqrt(variance)::Float64
end

function record_population(rec::Recorder, pop::Vector{AbstractGenerator}, suc::Vector{AbstractRating}, surv::Vector, generation::Integer)
  # get all parameters that occur for the generators
  #
  for i = 1:length(pop)
    record(rec, "G",  generation)
    record(rec, "QT", suc[i].quota)
    record(rec, "QL", suc[i].quality)
    record(rec, "TS", suc[i].timeshift)
    record(rec, "SV", surv[i])
    for p in export_params(pop[i])
      record(rec, p.name, p.val)
    end
  end
end


# performs recombination and mutation / currently mutually exclusive
function calculate_next_generation( opt::GeneticOptimizer, parents::Vector{AbstractGenerator}, N::Integer)
  rng = opt.rng
  offspring = AbstractGenerator[]
  lidx = 1
  for p in parents
    push!(offspring, p)
  end
  for t in 1:N-length(parents)
    if randbool(rng)
      push!(offspring, mutate(rng, parents[lidx], lock=opt.env.blacklist, rate=opt.env.contamination))
    else
      push!(offspring, recombine(rng, parents[lidx], parents[lidx % length(parents) + 1]))
    end

    # make lidx round-trip, so this works even if we require no relation between parents and targets sizes
    lidx = lidx % length(parents) + 1
  end

  return offspring
end

function infancy_death(opt::GeneticOptimizer, infants::Vector{AbstractGenerator}, N::Integer)
  survivors = infants
  survivor_rating = AbstractRating[]
  NUM_SAMPLES = 0

  while true
    # do another sample and mix with previous results
    nb_rating = rate_population_parallel(opt, seed=randseed(opt.rng), samples = 1, pop=survivors) # only do a few samples
    if length(survivor_rating) != 0
      nb_rating .+= survivor_rating
    end
    NUM_SAMPLES += 1

    # reset survivors and their ratings, initialise linearized score
    infants = deepcopy(survivors)
    survivors = AbstractGenerator[]
    survivor_rating = AbstractRating[]
    linear_scores = [s.quota * NUM_SAMPLES + s.quality for s in nb_rating]

    # take the N best networks
    while length(survivors) < N
      best = indmax(linear_scores)
      linear_scores[best] = -1 # this one is used
      push!(survivors, infants[best])
      push!(survivor_rating, nb_rating[best])
    end

    # take a look at the last survivors rating. if it includes failed trials, we are finished
    if survivor_rating[end].quota < 1
      return survivors # would be cool if we could reuse the samples we did here
    end
  end
end

function recombine( rng::AbstractRNG, A::AbstractGenerator, B::AbstractGenerator )
  # combine A and B as parents for a new Generator target
  # load parameters
  ap = export_params( A )
  bp = export_params( B )
  # randomize networks
  for i = 1:length(ap)
    if( randbool(rng) )
      @assert ap[i].name == bp[i].name "parameters do not match $(ap[i]) != $(bp[i])"
      ap[i] = bp[i] #should be safe, because export_params creates deep copies
    end
  end

  new_gen = deepcopy(A) # this assumes that A and B are equivalent!
  import_params!( new_gen, ap )
  return new_gen
end

function save_evolution(file, opt::GeneticOptimizer)
  names = Param.get_parameter_names(opt.population[1])
  output = [opt.recorder["G"] opt.recorder["QT"] opt.recorder["QL"] opt.recorder["TS"] opt.recorder["SV"]]
  names2 = UTF8String[]
  for name in names
    output = hcat(output, hcat(opt.recorder[name]...)')
    if typeof(opt.recorder[name][1]) <: AbstractArray
      for i in 1:length(opt.recorder[name][1])
        push!(names2, name*string(i))
      end
    else
      push!(names2, name)
    end
  end
  i = 5
  names = UTF8String[ name*"($(i+=1))" for name in names2 ]
  f = open(file, "w")
  write(f, "#"*"G(1) | QT(2) | QL(3) | TS(4) | SV(5) | "*join(names, " | ")*"\n")
  writedlm(f, output, )
  close(f)
#  writedlm(join(("mean_",file)), hcat(opt.recorder[2]...)')
end


function mutate( rng::AbstractRNG, source::AbstractParametricObject; lock=[], rate=0.1 )
  # load parameters
  params = export_params( source )
  # remove blacklisted ones
  valid = filter( i -> get_name(params[i]) ∉ lock, 1:length(params) )
  # choose parameter-index to mutate
  id = rand( rng, valid )
  # make the mutation
  params[id] = random_param( params[id], rng, s = rate )
  # and reimport them
  target = deepcopy(source) # this assumes that A and B are equivalent!
  import_params!( target, params )
  return target
end
