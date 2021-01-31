using Test
using MPI

using ClimateMachine

# To test coupling
using ClimateMachine.Coupling

# To create meshes (borrowed from Ocean for now!)
using ClimateMachine.Ocean.Domains

# To setup some callbacks
using ClimateMachine.GenericCallbacks

# To invoke timestepper
using ClimateMachine.ODESolvers

import ClimateMachine.Mesh.Grids: _x3

ClimateMachine.init()

# Use toy balance law for now
include("CplTestingBL.jl")

# Make some meshes covering same space laterally.
domainA = RectangularDomain(
    Ne = (10, 10, 5),
    Np = 4,
    x = (0, 1e6),
    y = (0, 1e6),
    z = (0, 1e5),
    periodicity = (true, true, true),
)
domainO = RectangularDomain(
    Ne = (10, 10, 4),
    Np = 4,
    x = (0, 1e6),
    y = (0, 1e6),
    z = (-4e3, 0),
    periodicity = (true, true, true),
)
domainL = RectangularDomain(
    Ne = (10, 10, 1),
    Np = 4,
    x = (0, 1e6),
    y = (0, 1e6),
    z = (0, 1),
    periodicity = (true, true, true),
)

# Set some paramters
#  Haney like relaxation 60-day time scale.
τ_airsea=60*86400


# Create 3 components - one on each domain, for now all are instances
# of the same balance law

# Atmos component
## Set atmosphere initial state function
function atmos_init_theta(xc,yc,zc,npt,el)
  return 30.
end
## Set atmosphere shadow boundary flux function
function atmos_theta_shadow_boundary_flux(θᵃ,θᵒ,npt,el,xc,yc,zc)
 if zc == 0.
  tflux=1. / ( τ_airsea*(θᵃ-θᵒ) )
 else
  tflux=0.
 end
 return tflux
end
## Create atmos component
bl_prop=CplTestingBL.prop_defaults()
bl_prop=(bl_prop..., init_theta=atmos_init_theta)
bl_prop=(bl_prop..., theta_shadow_boundary_flux=atmos_theta_shadow_boundary_flux)
btags=( (0,0), (0,0), (CplTestingBL.CoupledBoundaryCondition, CplTestingBL.ExteriorBoundaryCondition) )
mA=Coupling.CplTestModel(;domain=domainA,BL_module=CplTestingBL, nsteps=5, btags=btags, bl_prop=bl_prop)

# Ocean component
## Set source from atmos export
## S.θ=bl.bl_prop.source_theta(S.θ,A.npt,A.elnum,A.xc,A.yc,A.zc,A.boundary_in)
function ocean_init_theta(xc,yc,zc,npt,el)
  return 20.
end
function ocean_source_theta(θ,npt,el,xc,yc,zc,air_sea_flux_import)
  sval=0.
  if zc == 0.
   sval=air_sea_flux_import
  end
  return sval
end
## Create ocean component
bl_prop=CplTestingBL.prop_defaults()
bl_prop=(bl_prop..., init_theta=ocean_init_theta)
bl_prop=(bl_prop..., source_theta=ocean_source_theta)
btags=( (0,0), (0,0), (CplTestingBL.ExteriorBoundaryCondition, CplTestingBL.CoupledBoundaryCondition) )
mO=Coupling.CplTestModel(;domain=domainO,BL_module=CplTestingBL, nsteps=2, btags=btags, bl_prop=bl_prop)

# No Land for now
#mL=Coupling.CplTestModel(;domain=domainL,BL_module=CplTestingBL)
 
# Create a Coupler State object for holding imort/export fields.
# Try using Dict here - not sure if that will be OK with GPU
cState=CplState( Dict(:Atmos_MeanAirSeaθFlux=>[ ], :Ocean_SST=>[ ] ) )

# I think each BL can have a pre- and post- couple function?
function postatmos(_)
    println(" Ocean component finished stepping...")
    println("Atmos export fill callback")
    # Pass atmos exports to "coupler" namespace
    # For now we use deepcopy here.
    # 1. Save mean θ flux at the Atmos boundary during the couling period
    cState.CplStateBlob[:Atmos_MeanAirSeaθFlux]=deepcopy(mA.state.θ_boundary_export[mA.discretization.grid.vgeo[:,_x3:_x3,:] .== 0] )
end

function postocean(_)
    println(" Ocean component finished stepping...")
    println("Ocean export fill callback")
    # Pass ocean exports to "coupler" namespace
    #  1. Ocean SST (value of θ at z=0)
    cState.CplStateBlob[:Ocean_SST]=deepcopy( mO.state.θ[mO.discretization.grid.vgeo[:,_x3:_x3,:] .== 0] )
end

function preatmos(_)
        println("Atmos import fill callback")
        # Set boundary SST used in atmos to SST of ocean surface at start of coupling cycle.
        mA.discretization.state_auxiliary.boundary_in[mA.discretization.grid.vgeo[:,_x3:_x3,:] .== 0] .= cState.CplStateBlob[:Ocean_SST]
        # Set atmos boundary flux accumulator to 0.
        mA.state.θ_boundary_export.=0
        println(" Atmos component start stepping...")
        nothing
end
function preocean(_)
        println("Ocean import fill callback")
        # Set mean air-sea theta flux
        mO.discretization.state_auxiliary.boundary_in[mO.discretization.grid.vgeo[:,_x3:_x3,:] .== 0] .= cState.CplStateBlob[:Atmos_MeanAirSeaθFlux]
        # Set ocean boundary flux accumulator to 0. (this isn't used)
        mO.state.θ_boundary_export.=0
        println(" Ocean component start stepping...")
        nothing
end

# Instantiate a coupled timestepper that steps forward the components and
# implements mapings between components export bondary states and
# other components imports.

compA=(pre_step=preatmos,component_model=mA,post_step=postatmos)
compO=(pre_step=preocean,component_model=mO,post_step=postocean)
component_list=( atmosphere=compA,ocean=compO,)
cC=Coupling.CplSolver(component_list=component_list,
                      coupling_dt=5.,t0=0.)

# We also need to initialize the imports so they can be read.
cState.CplStateBlob[:Ocean_SST]=deepcopy( mO.discretization.state_auxiliary.boundary_out[mO.discretization.grid.vgeo[:,_x3:_x3,:] .== 0] )
cState.CplStateBlob[:Atmos_MeanAirSeaθFlux]=deepcopy(mA.discretization.state_auxiliary.boundary_out[mA.discretization.grid.vgeo[:,_x3:_x3,:] .== 0] )

# Invoke solve! with coupled timestepper and callback list.
solve!(nothing,cC;numberofsteps=2)
