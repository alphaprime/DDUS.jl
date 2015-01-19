####
# Helpers
###
# Contains statistical and other routines used by data-driven sets
using Distributions, Roots, JuMP #VG Can these be moved above?

export boot, calcMeansT, calcSigsBoot
export boot_mu, boot_sigma, bootDY_mu, bootDY_sigma, calc_ab_thresh

###Bootstrapping code
# ideally this should all be moved to some base level function
function boot(data::Vector, fun::Function, prob::Float64, numBoots::Int, f_args...)
	const N = size(data, 1)
	dist = DiscreteUniform(1, N)
	out = zeros(Float64, numBoots)
	indices = [1:N]::Vector{Int}
	for i = 1:numBoots
		rand!(dist, indices)
		out[i] = fun(data[indices], f_args...)
	end
	quantile(out, prob)
end

function boot(data::Matrix, fun::Function, prob::Float64, numBoots::Int, f_args...)
	const N = size(data, 1)
	dist = DiscreteUniform(1, N)
	out = zeros(Float64, numBoots)
	indices = [1:N]::Vector{Int}
	for i = 1:numBoots
		rand!(dist, indices)
		out[i] = fun(data[indices, :], f_args...)
	end
	quantile(out, prob)
end

#search for a valid bracket multiplicatively
#primarily used to prep for root-finding
function bracket(fun, guess; max_iter=32, ratio=2., trace=false)
    low = guess/ratio
    hi  = guess * ratio

    f_low  = fun(low)
    f_hi = fun(hi)
    iter = 0
    trace && println("Bracketing:")
    while((f_low * f_hi >= 0) && (iter < max_iter))
        trace && println("$iter \t $low \t $hi \t $f_low \t $f_hi")
        low /= ratio
        hi  *= ratio
        f_low  = fun(low)
        f_hi = fun(hi)
        iter += 1
    end
    iter == max_iter && error("Bracketing Failed")

    if f_hi * fun(hi/ratio) <= 0
        return hi/ratio, hi
    elseif f_low * fun(low*ratio) <= 0
        return low, low*ratio
    else
        error("iter $iter \t $f_low \t $f_hi")
    end
end

#Assumes both, joint
function calcSigsBoot(data, delta, numBoots)
    sigf = calcSigsBoot(data, delta/2., numBoots, :Fwd)
    sigb = calcSigsBoot(data, delta/2., numBoots, :Back)
    sigf, sigb
end

#####
# b = maximum(data) if x > 0, b= minimum(data) otherwse
function f_sig(x, mu_adj, data_b, b)
    expdata = exp(x*data_b)
    logmeanexp = log(mean(expdata))
    sqrt(-2mu_adj/x + 2/x^2 * logmeanexp)
end

#approximate deriv or rootfinding
#muadj and data_b are already adjusted for numerical stability
function df_sig(x, mu_adj, data_b) 
    expdata = exp(x*data_b)
    logmeanexp = log(mean(expdata))
    wght_mean = dot(expdata, data_b) / sum(expdata)
    (x*(wght_mean + mu_adj) -2logmeanexp)/x^3
end

######

#Sgn of guess encodes whether we are looking at Fwd or Backwd
function sigFwdBack(data, guess, trace=false)
    # #check if its degenerate
    # third_moment = mean(data.^3)
    # if (guess > 0) && (third_moment < 0)
    #     return mean(data.^2)
    # elseif (guess < 0) && (third_moment > 0)
    #     return mean(data.^2)
    # end

    #adjust things for stability
    const b = guess > 0 ? maximum(data) : minimum(data)
    const mu_adj = mean(data)-b
    data_b = data-b

    df_sig_(x) = df_sig(x, mu_adj, data_b)
    #repair bracket if necessary
    low, hi = bracket(df_sig_, guess, trace=trace)

    trace && println("Bracketing Success:\t $low \t $hi")

    #rootfind
    xstar = fzero(df_sig_, low, hi)
    #use root to calc sig
    f_sig(xstar, mu_adj, data_b, b)
end

#Takes a Case Specification
function calcSigsBoot(data, delta, numBoots, CASE)
    if CASE == :Fwd
        sigFwdBack_(data_) = sigFwdBack(data_, 1.)
    elseif CASE == :Back
        sigFwdBack_(data_) = sigFwdBack(data_, -1.)
    else
        error("Case must be either :Fwd or :Back $CASE")
    end
    boot(data, sigFwdBack_, 1-delta, numBoots)
end


#calculates the means via t approx
# if joint, bounds hold (jointly) simultaneously at level 1-delta_
# o.w. bounds hold individually at level 1-delta_
function calcMeansT(data, delta_; joint=true)
    const N   = length(data)
    const sig_rt_N = std(data)/sqrt(N)
    dist      = TDist(N-1)
    delta = joint ? delta_/2 : delta_
    mean(data) + quantile(dist, delta)*sig_rt_N, mean(data) + quantile(dist, 1-delta)*sig_rt_N
end

# #Safer versions of log-sum-exp
# function logMeanExp(x::Float64, data_shift::Vector, b::Float64)
#     x*b + log(mean(exp(x * data_shift)))
# end
# logMeanExp(x::Float64, data::Vector) = (const b = x > 0 ? maximum(data) : minimum(data); logMeanExp(x, data-b, b))

# #overwrites hint
# function calcSigSampleHint!(boot_sample::Vector{Float64}, CASE::Symbol, hint::Float64, 
# 						min_u::Float64, max_u::Float64; factor = 10.)
#     const mu = mean(boot_sample)
#     if CASE == :Fwd
#         f(x) = 2mu/x - 2/x^2 * logMeanExp(x, boot_sample-max_u, max_u)  #include a negative bc we minimize

#     elseif CASE == :Back
#         f(x) = -2mu/x - 2/x^2 * logMeanExp(-x, boot_sample-min_u, min_u)  #include a negative bc we minimize
#     else
#         error("CASE must be one of :Fwd or :Back")
#     end

#     res = Optim.optimize(f, hint/factor, factor*hint)

#     !res.converged && error("Bootstrapping Opt did not converge")
#     res.f_minimum >=0 && error("Minimum is positive: \t", res.f_minimum)

#     @assert res.f_minimum < 0
#     hint = res.minimum
#     return sqrt(-res.f_minimum)
# end

# ######
# ###This is the preferred method
# function calcSigsBoot(data::Vector{Float64}, delta_::Float64, numBoots::Int; 
#                       CASE=:Both, joint=CASE==:Both)
#     const delta  = joint ? delta_/2. : delta_
#     sigfwd = 0.; sigback = 0.;
#     const min_u::Float64 = minimum(data)
#     const max_u::Float64 = maximum(data)

#     #Determine an appropriate hint by calling with large params first
#     #parameter choices equiv to searching [1e-10, 9std(data)]
#     if CASE == :Fwd || CASE == :Both
#         hint = 3e-5*std(data)
#         calcSigSampleHint!(data, :Fwd, hint, min_u, max_u, factor=3e5*std(data))
#         sigfwd = boot(data, calcSigSampleHint!, 1-delta, numBoots, :Fwd, hint, min_u, max_u)
#     end
#     if CASE == :Back || CASE == :Both
#         hint = 3e-5*std(data)
#         calcSigSampleHint!(data, :Back, hint, min_u, max_u, factor=3e5*std(data))
#         sigback = boot(data, calcSigSampleHint!, 1-delta, numBoots, :Back, hint, min_u, max_u)
#     end
#     sigfwd, sigback 
# end


#Currently computed using Stephens Approximation 
#Journaly of Royal Statistical Society 1970
function KSGamma(delta, N) 
       const sqrt_N = sqrt(N)
       const num = sqrt(.5 * log(2/delta))
       const denom = sqrt_N + .12 + .11/sqrt_N
       num/denom
end

kappa(eps_) = sqrt(1./eps_ - 1.)

function boot_mu(data, delta, numBoots)
    const muhat = mean(data, 1)
    myfun(data_b) = norm(mean(data_b, 1) - muhat)
    boot(data, myfun, 1-delta, numBoots)
end

function boot_sigma(data, delta, numBoots)
    const covhat = cov(data)
    myfun(data_b) = vecnorm(cov(data_b) - covhat)
    boot(data, myfun, 1-delta, numBoots)
end

function bootDY_mu(data, delta, numBoots)
    muhat = mean(data, 1)
    myfun(data_b) = (mu = mean(data_b, 1); ((mu-muhat) * inv(cov(data)) * (mu-muhat)')[1])
    boot(data, myfun, 1-delta, numBoots)
end 

function bootDY_sigma(data, delta, numBoots)
    mu0  = mean(data, 1)
    sig0 = cov(data)
   
    function myfun(data_b)
        muhat = mean(data_b, 1)
        sighat = cov(data_b)
        mudiff = (mu0 - muhat)'*(mu0-muhat)
        f(g2) = eigmin(g2*sighat - sig0 -mudiff)

        #If the dist of sighat is degenerate, return Inf
        if eigmin(sighat) <= 0 
            println("Infinite 2nd moment matrix")
            return Inf
        end

        #solve
        try       
            Roots.fzero(f, [.01, 500])
        catch e
            show(e); println()
            println("Using Manual Bracketing: f(1) $(f(1))  f(2) $(f(2))")
            #do your own bracketing
            if f(1) < 0
                lb = 1; ub = 2
                iter = 0
                const MAX_ITER = 100
                while f(ub) < 0 && iter < MAX_ITER
                    println("$iter \t $(f(ub))")
                    lb = ub
                    ub = ub * 2
                    iter = iter + 1
                end
            else
                lb = .5; ub = 1
                iter = 0
                const MAX_ITER = 100
                while f(lb) > 0 && iter < MAX_ITER
                    ub = lb
                    lb = lb * .5
                    iter = iter + 1
                end
            end
            try
                fzero(f, [lb, ub])
            catch e2
                println("Manual bracketing failed")
                println("Debug Sequence")
                for i = 10.0.^[-2:5]
                    println(f(i))
                end
            end
        end

   end
   boot(data, myfun, 1-delta, numBoots)
end

### Used by UM and UIOracle
function sort_data_cols(data)
    data_sort = zeros(eltype(data), size(data))
    const d = size(data, 2)
    for i = 1:d
        data_sort[:, i] = sort(data[:, i])
    end
    data_sort
end


########
# LCX Stuff
####

########################
# Bootstrapping computation

#Returns indx of last instance of val, 0 if not found
#Assumes sorted_list, and sort_list[start] >= val
function findlast_sort(val::Float64, sort_list::Vector; TOL::Float64=1e-10, start::Int64=1)
    i::Int64 = 1
    for i = int(start):length(sort_list)
        if abs(val - sort_list[i]) > TOL
            break
        end
    end
    i-1
end

## Makes a single pass through zetas/zetahats to solve
# 1/N * max_b { sum_i [zeta_i - b] ^+ - sum_i[zetahat_i - b]^+ }
function singlepass!(zetas::Vector, zetahats::Vector)
    sort!(zetas)  
    sort!(zetahats)

    vstar::Float64 = mean(zetas) - zetas[1] 
    vb::Float64    = mean(zetahats) - zetas[1]

    Gamma::Float64 = vstar - vb
    const N::Int64 = length(zetas)
    pbar::Float64    = 1.0 
    hat_indx::Int64  = 1
    hat_indx_::Int64 = 0
    
    for k = 2:length(zetas)
        vstar += (zetas[k-1] - zetas[k]) * (N-k+1)/N
        hat_indx = findlast_sort(zetas[k-1], zetahats, start=hat_indx_ + 1)
        pbar -=  (hat_indx - hat_indx_)/N
        hat_indx_ = hat_indx
        vb  += (zetas[k-1] - zetas[k]) * pbar
        Gamma = max(Gamma, vstar - vb)
    end
    Gamma
end

#a::Vector, sgns::Vector is used as storage between bootstraps
function f2(boot_sample::Matrix, data::Matrix, numSamples::Int, a::Vector, sgns::Vector)
    Gamma::Float64 = 0.
    for i = 1:numSamples
        randL1!(a, sgns)
        Gamma_ = singlepass!(data*a, boot_sample*a)
        Gamma = max(Gamma, Gamma_)
    end
    Gamma
end

function randL1!(a, sgns)
    a = rand!(a) 
    a = a/ sum(a)
    rand!(Bernoulli(), sgns)
    a = a .* (2*sgns-1)
end

#Approximates the threshold by sampling a bunch of abs for each bootstrap rep
function calc_ab_thresh(data::Matrix, delta::Float64, numBoots::Int, numSamples::Int)
    const N = size(data, 1)
    const d = size(data, 2)
    a::Vector{Float64} = zeros(Float64, d)
    sgns::Vector{Int}  = zeros(Int64, d)
    boot(data, f2, 1-delta, numBoots, data, numSamples, a, sgns)
end

function compute_cs(boot_indx)
    cs = ones(length(boot_indx))
    for i = boot_indx
        cs[i] = cs[i] - 1
    end
    return cs/length(boot_indx)
end