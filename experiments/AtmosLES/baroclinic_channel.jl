using ClimateMachine
ClimateMachine.init(parse_clargs = true)

using ClimateMachine.Atmos
using ClimateMachine.ConfigTypes
using ClimateMachine.DGMethods
using ClimateMachine.DGMethods.NumericalFluxes
using ClimateMachine.Diagnostics
using ClimateMachine.GenericCallbacks
using ClimateMachine.Mesh.Filters
using ClimateMachine.Mesh.Grids
using ClimateMachine.ODESolvers
using ClimateMachine.SystemSolvers: ManyColumnLU, SingleColumnLU
using ClimateMachine.Thermodynamics
using ClimateMachine.TurbulenceClosures
using ClimateMachine.VariableTemplates

using CLIMAParameters
using CLIMAParameters.Planet: e_int_v0, grav, day, cp_d, cv_d, R_d, grav, planet_radius
struct EarthParameterSet <: AbstractEarthParameterSet end
const param_set = EarthParameterSet()


using Distributions
using Random
using StaticArrays
using Test
using DocStringExtensions
using LinearAlgebra
using Logging

"""
    baroclinic_instability_cube(...)
Initialisation helper for baroclinic-wave (channel flow) test case for iterative
determination of η = p/pₛ coordinate for given z-altitude. 
"""

function baroclinic_instability_cube!(eta, temp, tolerance, (x,y,z),f0,beta0,u0,T0,gamma_lapse,gravity, R_gas, cp)
  for niter = 1:200
    FT    = eltype(y)
    b     = FT(2)
    Ly    = FT(6e6)  
    y0    = FT(Ly/2)
    b2    = b*b
    #Get Mean Temperature
    exp1  = R_gas*gamma_lapse/gravity
    Tmean = T0*eta^exp1
    phimean = T0*gravity/gamma_lapse * (FT(1) - eta^exp1)
    logeta = log(eta)
    fac1   = (f0-beta0*y0)*(y - FT(1/2)*Ly - Ly/2π * sin(2π*y/Ly))  
    fac2   = FT(1/2)*beta0*(y^2 - Ly*y/π*sin(2π*y/Ly) - 
                          FT(1/2)*(Ly/π)^2*cos(2π*y/Ly) - 
                          Ly^2/3 - FT(1/2)*(Ly/π)^2)
    fac3 = exp(-logeta*logeta/b2)
    fac4 = exp(-logeta/b) 
    ## fac4 applies a correction based on the required temp profile from Ullrich's paper
    ## TODO: Verify if paper contains TYPO, use fac3 or fac4
    ## Check for consistency 
    phi_prime=FT(1/2)*u0*(fac1 + fac2)
    geo_phi = phimean + phi_prime*fac3*logeta
    temp = Tmean + phi_prime/R_gas*fac3*(2/b2*logeta*logeta - 1)
    num  = -gravity*z + geo_phi
    den  = -R_gas/(eta)*temp
    deta = num/den
    eta  = eta - deta
    if (abs(deta) <= FT(tolerance))
      break
    elseif (abs(deta) > FT(tolerance)) && niter==200
      @error "Initialisation: η convergence failure."
      @show deta
      break
    end
  end
  return (eta, temp)
end 


function init_baroclinicwave!(problem, bl, state, aux, localgeo, t)

  (x,y,z) = localgeo.coord
  ### Problem float-type
  FT = eltype(state)
  param_set = bl.param_set
  
  ### Unpack CLIMAParameters
  _planet_radius = FT(planet_radius(param_set))
  gravity        = FT(grav(param_set))
  cp             = FT(cp_d(param_set))
  R_gas          = FT(R_d(param_set))

  ### Global Variables
  up    = FT(1)                ## See paper: Perturbation peak value
  Lp    = FT(6e5)              ## Perturbation parameter (radius)
  Lp2   = Lp*Lp              
  xc    = FT(2e6)              ## Streamwise center of perturbation
  yc    = FT(2.5e6)            ## Spanwise center of perturbation
  gamma_lapse = FT(5/1000)     ## Γ Lapse Rate
  Ω     = FT(7.292e-5)         ## Rotation rate [rad/s]
  f0    = 2Ω/sqrt(2)           ## 
  beta0 = f0/_planet_radius    ##  
  beta0 = -zero(FT)
  b     = FT(2)
  b2    = b*b
  u0    = FT(35)
  Ly    = FT(6e6)
  T0    = FT(288)
  T_ref = T0                   
  x0    = FT(2e7)
  p00   = FT(1e5)              ## Surface pressure

  ## Step 1: Get current coordinate value by unpacking nodal coordinates from aux state
  eta = FT(1e-7)
  temp = FT(300)
  ## Step 2: Define functions for initial condition temperature and geopotential distributions
  ## These are written in terms of the pressure coordinate η = p/pₛ

  ### Unpack initial conditions (solved by iterating for η)
  tolerance = FT(1e-10)
  eta, temp = baroclinic_instability_cube!(eta, 
                                           temp, 
                                           tolerance, 
                                           (x,y,z),
                                           f0, 
                                           beta0, 
                                           u0, 
                                           T0, 
                                           gamma_lapse, 
                                           gravity, 
                                           R_gas, 
                                           cp)
  eta = min(eta,FT(1))
  eta = max(eta,FT(0))
  ### η = p/p_s
  logeta = log(eta)
  T=FT(temp)
  press = p00*eta
  theta = T *(p00/press)^(R_gas/cp)
  rho = press/(R_gas*T)
  thetaref = T_ref * (1 - gamma_lapse*z/T0)^(-gravity/(cp*gamma_lapse))
  rhoref = p00/(T0*R_gas) * (1 - gamma_lapse*z/T0)^(gravity/(R_gas*gamma_lapse) - 1)

  ### Balanced Flow
  u = -u0*(sinpi(y/Ly))^2  * logeta * exp(-logeta*logeta/b2)

  ### Perturbation of the balanced flow
  rc2 = (x-xc)^2 + (y-yc)^2
  du = up*exp(-rc2/Lp2)
    
  ### Primitive variables
  u⃗ = SVector{3,FT}(u+du,0,0)
  e_kin = FT(1/2)*sum(abs2.(u⃗))
  e_pot = gravity * z

  ### Assign state variables for initial condition
  state.ρ = rho
  state.ρu = rho .* u⃗
  state.energy.ρe = rho * total_energy(param_set, e_kin, e_pot, T)
end

function config_baroclinicwave(FT, N, resolution, xmax, ymax, zmax)

    ics = init_baroclinicwave!     # Initial conditions
        
    # Assemble source components
    source = (
        Gravity(),
    )

    # Choose default IMEX solver
    #ode_solver_type = ClimateMachine.ExplicitSolverType();
    # Set up experiment
    ode_solver_type = ClimateMachine.IMEXSolverType(
        implicit_model = AtmosAcousticGravityLinearModel,
        implicit_solver = SingleColumnLU,
        solver_method = ARK2GiraldoKellyConstantinescu,
        split_explicit_implicit = true,
        discrete_splitting = false,
    )
    
    #ode_solver_type = ClimateMachine.HEVISolverType(FT);
#                                                    linear_max_subspace_size = Int(10),
#                                                    linear_rtol = FT(5e-3),
#                                                    nonlinear_ϵ = FT(1.e-7),
#                                                    );
    #ode_solver_type = ClimateMachine.HEVISplitting();
    
    problem = AtmosProblem(
        boundaryconditions = (
            AtmosBC(),
            AtmosBC(),
        ),
        init_state_prognostic = ics,
    )

    # Assemble model components
    model = AtmosModel{FT}(
        AtmosLESConfigType,
        param_set;
        problem=problem,
        #ref_state=NoReferenceState(), #use this when you do not need a linear model to be used.
        turbulence = SmagorinskyLilly(0.21),
        #hyperdiffusion = DryBiharmonic{FT}(10),
        moisture = DryModel(),
        source = source,
    )

    # Assemble configuration
    config = ClimateMachine.AtmosLESConfiguration(
        "Baroclinic Wave",
        N,
        resolution,
        xmax,
        ymax,
        zmax,
        param_set,
        init_baroclinicwave!,
        solver_type = ode_solver_type,
        model = model,
    )
    return config
end

function config_diagnostics(driver_config, FT, xmax, ymax, zmax)
    
    boundaries = [
        FT(0.0) FT(0.0) FT(0.0)
        FT(xmax) FT(ymax) FT(zmax)
    ]
    resolution = (FT(100e3), FT(75e3), FT(1250)) 
    interpol = ClimateMachine.InterpolationConfiguration(
        driver_config,
        boundaries,
        resolution,
    )

    default_dgngrp = setup_atmos_default_diagnostics(
        AtmosLESConfigType(),
        "1shours",
        driver_config.name,
    )
    core_dgngrp = setup_atmos_core_diagnostics(
        AtmosLESConfigType(),
        "1shours",
        driver_config.name,
    )
    state_dgngrp = setup_dump_state_diagnostics(
        AtmosLESConfigType(),
        "1shours",
        driver_config.name,
        interpol = interpol,
    )
    aux_dgngrp = setup_dump_aux_diagnostics(
        AtmosLESConfigType(),
        "1shours",
        driver_config.name,
        interpol = interpol,
    )
    return ClimateMachine.DiagnosticsConfiguration([
        default_dgngrp,
    ])
end

function main()
    FT = Float64

    # DG polynomial order
    N = 3
    # Domain resolution and size
    Δx = FT(100e3) 
    Δy = FT(100e3)
    Δz = FT(1.25e3)

    resolution = (Δx, Δy, Δz)

    # Prescribe domain parameters
    xmax = FT(40000e3) 
    ymax = FT(6000e3)
    zmax = FT(30e3)

    t0 = FT(0)

    # For a full-run, please set the timeend to 3600*6 seconds
    # For the test we set this to == 30 minutes
    days = FT(86400)
    timeend = FT(15days)
    CFLmax = FT(0.075)

    driver_config = config_baroclinicwave(FT, N, resolution, xmax, ymax, zmax)
    solver_config = ClimateMachine.SolverConfiguration(
        t0,
        timeend,
        driver_config,
        init_on_cpu = true,
        Courant_number = CFLmax,
        ### Diffusion Direction Keyword for Horizontal Dimension
        diffdir=HorizontalDirection(),
        CFL_direction = HorizontalDirection(), 
    )
    dgn_config = config_diagnostics(driver_config, FT, xmax, ymax, zmax)

    filterorder = 16
    filter = ExponentialFilter(solver_config.dg.grid, 0, filterorder)
    cbfilter = GenericCallbacks.EveryXSimulationSteps(1) do
        Filters.apply!(
            solver_config.Q,
            AtmosFilterPerturbations(driver_config.bl),
            solver_config.dg.grid,
            filter,
            state_auxiliary = solver_config.dg.state_auxiliary,
        )
        nothing
    end

    check_cons = (
        ClimateMachine.ConservationCheck("ρ", "3000steps", FT(0.0001)),
        ClimateMachine.ConservationCheck("energy.ρe", "3000steps", FT(0.0025)),
    )

    result = ClimateMachine.invoke!(
        solver_config;
        diagnostics_config = dgn_config,
        user_callbacks = (cbfilter,),
        check_cons = check_cons,
        check_euclidean_distance = true,
    )
end

main()

