module fire_routines

    use precision_parameters

    use opening_fractions, only: get_vent_opening
    use utility_routines, only: tanhsmooth, xerror, interp

    use cenviro
    use ramp_data
    use room_data
    use target_data
    use cparams
    use fire_data
    use option_data
    use setup_data
    use smkview_data
    use vent_data

    implicit none

    private

    public door_jet, fire, flame_height, get_gas_temp_velocity, integrate_mass, remap_fires, update_fire_objects, update_species

    contains
! --------------------------- fires -------------------------------------------

    subroutine fire (tsec,flows_fires)

    !     routine: fire
    !     purpose: physical interface routine to calculate the current rates of mass and energy flows into the layers from
    !              all fires in the building.
    !     revision: $Revision$
    !     revision date: $Date$
    !     arguments: tsec   current simulation time (s)
    !                flows_fires   mass and energy flows into layers due to fires.
    !                       standard source routine data structure.
    !                nfire  total number of fires
    !                ifroom room numbers for each of the fires

    real(eb), intent(in) :: tsec
    real(eb), intent(out) :: flows_fires(mxrooms,ns+2,2)

    real(eb) :: xntms(2,ns), stmass(2,ns), n_C, n_H, n_O, n_N, n_Cl
    real(eb) :: omasst, oareat, ohight, oqdott, objhct, y_soot, y_co, y_trace, xtl, q_firemass, q_entrained, xqfr, xqfc
    real(eb) :: y_soot_flaming, y_soot_smolder
    integer iroom, i, nfire
    type(room_type), pointer :: roomptr
    type(fire_type), pointer :: fireptr

    flows_fires(1:nr,1:ns+2,u) = 0.0_eb
    flows_fires(1:nr,1:ns+2,l) = 0.0_eb
    nfire = 0

    if (option(ffire)==off) return

    do i = 1, n_fires
        fireptr => fireinfo(i)
        iroom = fireptr%room
        roomptr => roominfo(iroom)
        call interpolate_pyrolysis(i,tsec,iroom,omasst,oareat,ohight,oqdott,objhct,n_C,n_H,n_O,n_N,n_Cl,y_soot,y_soot_flaming, &
            y_soot_smolder,y_co,y_trace)

        fireptr%mdot_pyrolysis = omasst
        fireptr%z_offset = ohight
        stmass(u,1:ns) = roomptr%species_mass(u,1:ns)
        stmass(l,1:ns) = roomptr%species_mass(l,1:ns)

        call do_fire(i, iroom, fireptr%mdot_pyrolysis, roomptr%cheight, roomptr%cwidth, roomptr%cdepth, objhct, y_soot, &
            y_soot_flaming, y_soot_smolder, y_co, y_trace, n_C, n_H, n_O, n_N, n_Cl, fireptr%molar_mass, stmass, &
            fireptr%x_position, fireptr%y_position, fireptr%z_position+fireptr%z_offset, oareat, fireptr%mdot_entrained, &
            fireptr%mdot_plume, oqdott, xntms, xqfc, xqfr, fireptr%qdot_layers(l), fireptr%qdot_layers(u))
        
        fireptr%firearea = oareat
        fireptr%mdot_trace = fireptr%mdot_pyrolysis*y_trace
        fireptr%qdot_actual = fireptr%qdot_layers(l) + fireptr%qdot_layers(u)
        fireptr%qdot_convective = xqfc
        fireptr%qdot_radiative = xqfr

        ! sum the flows for return to the source routine
        xtl = roomptr%temp(l)
        flows_fires(iroom,m,u) = flows_fires(iroom,m,u) + fireptr%mdot_plume
        flows_fires(iroom,m,l) = flows_fires(iroom,m,l) - fireptr%mdot_entrained
        q_firemass = cp*fireptr%mdot_pyrolysis*interior_ambient_temperature
        q_entrained = cp*fireptr%mdot_entrained*xtl
        flows_fires(iroom,q,u) = flows_fires(iroom,q,u) + xqfc + q_firemass + q_entrained
        flows_fires(iroom,q,l) = flows_fires(iroom,q,l) - q_entrained
        flows_fires(iroom,3:ns+2,u) = flows_fires(iroom,3:ns+2,u) + xntms(u,1:ns)
        flows_fires(iroom,3:ns+2,l) = flows_fires(iroom,3:ns+2,l) + xntms(l,1:ns)
    end do

    return
    end subroutine fire

! --------------------------- do_fire -------------------------------------------

    subroutine do_fire(ifire,iroom,xemp,xhr,xbr,xdr,hcombt,y_soot,y_soot_flaming, y_soot_smolder,y_co,y_trace,n_C,n_H,n_O,n_N,n_Cl,&
       mol_mass,stmass,xfx,xfy,xfz,object_area,xeme,xems,xqpyrl,xntms,xqfc,xqfr,xqlp,xqup)

    !     routine: do_fire
    !     purpose: do heat release and species from a fire
    !     arguments:  ifire: fire number (ifire=0 is the main fire)
    !                 iroom: room containing the fire
    !                 xemp: pyrolysis rate of the fire (kg/s)
    !                 xhr: height of the room (m)
    !                 xbr: breadth of the room (m)
    !                 xdr: Depth of the room (m)
    !                 hcombt: current heat of combustion (j/kg)
    !                 y_soot, y_soot_flaming, y_soot_smolder, y_co, y_trace: species yields for soot, CO, and trace species;
    !                       others are calculated from the molecular formula of the fuel (kg species produced/kg fuel pyrolyzed)
    !                 n_C, n_H, n_O, n_N, n_Cl: molecular formula for the fuel; these can be fractional; yields
    !                 of O2, HCl, and HCN are determined from this
    !                 molar_mass: molar mass of the fuel (kg/mol)
    !                 stmass: mass of a species in a layer in the room (kg)
    !                 xfx: position of the fire in x direction
    !                 xfy: position of the fire in y direction
    !                 xfz: position of the fire in z direction
    !                 object_area: characteristic object diameter for plume models
    !                 xeme (output): plume entrainment rate (kg/s)
    !                 xems (output): plume flow rate into the upper layer (kg/s)
    !                 xqpyrl (output): actual heat release rate of the fire (w)
    !                 xntms (output): net change in mass of a species in a layer
    !                 xqfc (output): net convection into upper layer (w)
    !                 xqfr (output): net radiation from fire (w)
    !                 xqlp (output): heat release in the lower plume (w)
    !                 xqup (output): heat release rate in the upper plume (w)

    integer, intent(in) :: ifire, iroom
    real(eb), intent(in) :: xemp, xhr, xbr, xdr, hcombt, y_soot, y_soot_flaming, y_soot_smolder, y_co, y_trace
    real(eb), intent(in) :: n_C ,n_H, n_O, n_N, n_Cl
    real(eb), intent(in) :: mol_mass, stmass(2,ns), xfx, xfy, xfz, object_area
    real(eb), intent(out) :: xeme, xems, xntms(2,ns), xqfc, xqfr, xqlp, xqup

    real(eb) :: xmass(ns), xz, xtl, xtu, xxfirel, xxfireu, xntfl, qheatl, qheatl_c, qheatu, qheatu_c
    real(eb) :: chirad, xqpyrl, source_o2, xtemp, uplmep, uplmes, uplmee, height
    real(eb) :: firex, firey
    integer :: ipass, lsp
    type(room_type), pointer :: roomptr
    type(fire_type), pointer :: fireptr

    roomptr => roominfo(iroom)
    fireptr => fireinfo(ifire)

    xz = roomptr%depth(u)
    xtl = roomptr%temp(l)
    xtu = roomptr%temp(u)
    xqfc = 0.0_eb
    xqlp = 0.0_eb
    xeme = 0.0_eb

    ! these are the lengths ("heights") in the upper and lower layers respectively
    ! if it is negative, then the fire is not in that layer
    xxfirel = xhr - xz - xfz
    xxfireu = xhr - xfz
    xntfl = 0.0_eb
    qheatl_c = 0.0_eb
    qheatu_c = 0.0_eb
    xqfr = 0.0_eb
    xems = 0.0_eb

    xntms(u,1:ns) = 0.0_eb
    xntms(l,1:ns) = 0.0_eb
    xmass(1:ns) = 0.0_eb

    ! the trace species is assumed to be released by the pyrolysis of the burning object regardless of
    ! whether the fuel actually combusts here. this is consistent with the earlier chemistry routine.
    ! release it here and deposit it in the upper layer
    xntms(u,ts) = xemp*y_trace
    
    ! fuel released by pyrolysis is put into the upper layer. The fuel that burns in the plume is calculated
    ! in the chemistry routine and then removed from the upper layer
    xntms(u,fuel) = xemp

    ! now do the kinetics scheme

    ! divvy up the plume output into radiation and convective energy.
    ! convection drives the plume entrainment

    xqpyrl = xemp*hcombt
    chirad = max(min(fireptr%chirad,1.0_eb),0.0_eb)
    qheatl = xqpyrl
    qheatl_c = max(xqpyrl*(1.0_eb-chirad),0.0_eb)
    
    ! set wall or corner fire
    firex = min(xfx,xbr-xfx)
    firey = min(xfy,xdr-xfy)
    fireptr%modified_plume = 1
    if (firex<=sqrt(fireptr%firearea)/2.or.firey<=sqrt(fireptr%firearea)/2) fireptr%modified_plume = 2
    if (firex<=sqrt(fireptr%firearea)/2.and.firey<=sqrt(fireptr%firearea)/2) fireptr%modified_plume = 3

    ! note that the combination of fire_plume and chemistry can be called twice
    ! in a single iteration to make sure that the plume entrainment is
    ! consistent with the actual fire size for oxygen limited fires
    ! this is done by "re-passing" the actual fire size to fire_plume in the
    ! second pass
    ipass = 1
    do while (ipass<=2)

        ! calculate the entrainment rate but constrain the actual amount
        ! of air entrained to that required to produce stable stratification
        call fire_plume(object_area, qheatl, qheatl_c, xxfirel, interior_ambient_temperature, xemp, xems, xeme, &
           min(xfx,xbr-xfx), min(xfy,xdr-xfy))
        
        if (roomptr%mass(l)-xeme <= roomptr%vmin*roomptr%rho(l)) then
            xeme = max(0.0_eb,roomptr%mass(l)-roomptr%vmin*roomptr%rho(l))
        end if 
        
        ! check for an upper only layer fire
        if (xxfirel<=0.0_eb) go to 90
        xeme = min(xeme,qheatl_c/(max((xtu-xtl),1.0_eb)*cp))
        xems = xemp + xeme

        source_o2 = roomptr%species_fraction(l,o2)
        call chemistry (xemp, mol_mass, xeme, hcombt, y_soot, y_soot_flaming, y_soot_smolder, y_co, n_C, n_H, n_O, n_N, &
            n_Cl, source_o2, lower_o2_limit, xqpyrl, xntfl, xmass)

        ! limit the amount entrained to that actually entrained by the fuel burned
        xqpyrl = max(0.0_eb, xqpyrl*(1.0_eb-chirad))

        if (xqpyrl<qheatl_c) then
            xeme = xeme*(xqpyrl/qheatl_c)
            xmass(1:ns) = (xqpyrl/qheatl_c)*xmass(1:ns)
            xqpyrl = xqpyrl/qheatl_c*xqpyrl
            qheatl_c = xqpyrl
            ipass = ipass + 1
            cycle
        end if
        exit
    end do
    xqpyrl = xqpyrl/(1.0_eb-chirad)
    qheatl = xqpyrl
    xems = xemp + xeme
    
    xntms(u,1:ns) = xmass(1:ns) + xntms(u,1:ns)

    xqfr = xqpyrl*chirad
    xqfc = xqpyrl*(1.0_eb-chirad)
    xqlp = xqpyrl

    ! add burning in the upper layer to the fire. the heat which drives entrainment in the upper layer is the sum of the
    ! heat released in the lower layer and what can be released in the upper layer.

    ! start with the fuel removed by lower layer burning, xntfl umplm{ep},{es},and {ee} are equivalent to emp, ems and eme
90  xqup = 0.0_eb
    uplmep = max(0.0_eb,xemp-xntfl)

    if (uplmep>0.0_eb) then
        qheatu_c = hcombt*uplmep*(1.0_eb-chirad) + qheatl_c
        qheatu = qheatu_c/(1.0_eb-chirad)
        height = max (0.0_eb, min(xz,xxfireu))

        call fire_plume (object_area, qheatu, qheatu_c, height, interior_ambient_temperature, uplmep, uplmes, uplmee, &
           min(xfx,xbr-xfx), min(xfy,xdr-xfy))

        source_o2 = roomptr%species_fraction(u,o2)
        call chemistry (uplmep, mol_mass, uplmee, hcombt, y_soot, y_soot_flaming, y_soot_smolder, y_co, &
            n_C, n_H, n_O, n_N, n_Cl, source_o2, lower_o2_limit, xqpyrl, xntfl, xmass)

        xqfr = xqpyrl*chirad + xqfr
        xqfc = xqpyrl*(1.0_eb-chirad) + xqfc
        xqup = xqpyrl
        xntms(u,1:ns) = xmass(1:ns) + xntms(u,1:ns)
    end if
    
    if (xntms(u,fuel)>0.0_eb) then
        uplmep = xntms(u,fuel)
        source_o2 = lower_o2_limit+0.02
        uplmee = 1000.0_eb*(uplmep*hcombt)/(1.31e7_eb*source_o2)
        call chemistry (uplmep, mol_mass, uplmee, hcombt, y_soot, y_soot_flaming, y_soot_smolder, y_co, &
            n_C, n_H, n_O, n_N, n_Cl, source_o2, lower_o2_limit, xqpyrl, xntfl, xmass)
        if (uplmep*hcombt>xqpyrl) then
            write(*,*) 'not enough oxygen'
        end if
        xntms(u,fuel_moles) = uplmep/mol_mass
        xntms(u,fuel_Q) = xqpyrl
        xntms(u,fuel_o2) = -xmass(o2)
        xntms(u,fuel_co2) = xmass(co2)
        xntms(u,fuel_co) = xmass(co)
        xntms(u,fuel_hcn) = xmass(hcn)
        xntms(u,fuel_hcl) = xmass(hcl)
        xntms(u,fuel_h2o) = xmass(h2o)
        xntms(u,fuel_soot) = xmass(soot)
    end if 
    ! add the species flow entrained by the plume to normalize the yields to unity
    xtemp = 0.0_eb
    do lsp = 1, ns_mass
        xtemp = xtemp + stmass(l,lsp)
    end do
    if (xtemp==0.0_eb) xtemp = 1.0_eb
    xntms(u,1:ns) = xntms(u,1:ns) + xeme*stmass(l,1:ns)/xtemp
    xntms(l,1:ns) = xntms(l,1:ns) - xeme*stmass(l,1:ns)/xtemp
    return
    end subroutine do_fire

! --------------------------- chemistry -------------------------------------------

    subroutine chemistry (pyrolysis_rate, molar_mass,entrainment_rate, h_c, y_soot, y_soot_flaming, y_soot_smolder, &
       y_co,n_C, n_H, n_O, n_N, n_Cl, source_o2, lower_o2_limit, hrr_constrained, pyrolysis_rate_constrained, species_rates)

    !     routine: chemistry
    !     purpose: do the combustion chemistry - for plumes in both the upper and lower layers.
    !         note that the kinetics scheme is implemented here.  however, applying it to the
    !         various pieces, namely the lower layer plume, the upper layer plume, and the door jet fires, is
    !         somewhat complex.
    !         care should be exercised in making changes either here or in the source interface routine.
    !     arguments:  pyrolysis_rate: calculated pyrolysis rate of the fuel (kg/s)
    !                 molar_mass: molar mass of the fuel (kg/mol)
    !                 entrainment_rate: calculated entrainment rate (kg/s)
    !                 source_room: compartment that contains this fire
    !                 h_c: heat of combustion of the fuel (W/kg)
    !                 y_soot, y_soot_flaming, y_soot_smolder, y_co: species yields for soot and CO; others are calculated from 
    !                        the molecular formula of the fuel (kg species produced/kg fuel pyrolyzed)
    !                 n_C, n_H, n_O, n_N, n_Cl: molecular formula for the fuel; these can be fractional;
    !                 yields of O2, HCl, and HCN are determined from this
    !                 source_o2, lower_o2_limit: oxygen concentration in the source layer of the compartment;
    !                 lower oxygen limit for combustion (as a fraction)
    !                 hrr_constrained (output): actual HRR of the fire constrained by available oxygen (W)
    !                                           pyrolysis_rate_constrained (output): actual pyrolysis rate of the fuel
    !                                           constrained by available oxygen (kg/s)
    !                 species_rates (output): production rates of species based on calculated yields and constrained
    !                                         pyrolysis rate (kg/s); fuel and oxygen are naturally negative

    real(eb), intent(in) :: pyrolysis_rate, molar_mass, entrainment_rate, h_c, y_soot, y_co, n_C, n_H, n_O, n_N, n_Cl
    real(eb), intent(in) :: y_soot_flaming, y_soot_smolder
    real(eb), intent(in) :: source_o2, lower_o2_limit
    real(eb), intent(out) :: hrr_constrained, pyrolysis_rate_constrained, species_rates(:)

    real(eb) :: o2_entrained, o2_factor, o2_available
    real(eb) :: nu_o2, nu_co2, nu_h2o, nu_co, nu_soot, nu_hcl,nu_hcn, nu_soot_flaming, nu_soot_smolder
    real(eb) :: net_o2, net_co2, net_h2o, net_co, net_soot, net_hcl, net_hcn, net_fuel, net_ct, net_soot_flaming, net_soot_smolder
    real(eb) :: factor
    real(eb), parameter :: o2f = 1.31e7_eb

    ! calculate the actual burning rate constrained by available o2.

    ! note the scaling in the tanh function.  tanh approaches ~2 at
    ! about ~4. the function inside the tanh scales the ordinate to
    ! ~o2range.  the remainder of the function scales the result
    ! to 0-1
    o2_entrained = entrainment_rate*source_o2
    o2_factor = tanhsmooth(source_o2, lower_o2_limit+0.01_eb, lower_o2_limit, 1.0_eb, 0.0_eb)
    o2_available = o2_entrained*o2_factor
    hrr_constrained = max(0.0_eb,min(pyrolysis_rate*h_c,o2_available*o2f))
    pyrolysis_rate_constrained = hrr_constrained/h_c

    ! now do the chemistry balance with supplied inputs.
    nu_soot = molar_mass/0.01201_eb*y_soot
    nu_soot_flaming = molar_mass/0.01201_eb*y_soot_flaming
    nu_soot_smolder = molar_mass/0.01201_eb*y_soot_smolder
    nu_hcn = n_N
    nu_hcl = n_Cl
    nu_co = molar_mass/0.02801_eb*y_co
    nu_h2o = (n_H - nu_hcl - nu_hcn)/2.0_eb
    nu_co2 = n_C  - nu_co - nu_hcn - nu_soot
    nu_o2 = nu_co2 + (nu_h2o + nu_co - n_O)/2.0_eb

    ! chemistry balance is molar-based so convert back to mass rates. fuel and o2 are consumed,
    ! so negative. Others are produced, so positive
    net_fuel = -pyrolysis_rate_constrained
    net_o2 = -pyrolysis_rate_constrained*nu_o2*0.032_eb/molar_mass
    net_co2 = pyrolysis_rate_constrained*nu_co2*0.04401_eb/molar_mass
    net_co = pyrolysis_rate_constrained*nu_co*0.02801_eb/molar_mass
    net_h2o = pyrolysis_rate_constrained*nu_h2o*0.018016_eb/molar_mass
    net_hcl = pyrolysis_rate_constrained*nu_hcl*0.036458_eb/molar_mass
    net_hcn = pyrolysis_rate_constrained*nu_hcn*0.027028_eb/molar_mass
    net_soot = pyrolysis_rate_constrained*nu_soot*0.01201_eb/molar_mass
    net_soot_flaming = pyrolysis_rate_constrained*nu_soot_flaming*0.01201_eb/molar_mass
    net_soot_smolder = pyrolysis_rate_constrained*nu_soot_smolder*0.01201_eb/molar_mass
    net_ct = 0.0_eb
    
    if (-net_o2 > o2_available) then
        factor = -o2_available/net_o2
        pyrolysis_rate_constrained = factor*pyrolysis_rate_constrained
        hrr_constrained = factor*hrr_constrained
        net_fuel = factor*net_fuel
        net_o2 = factor*net_o2
        net_co2 = factor*net_co2
        net_co = factor*net_co
        net_h2o = factor*net_h2o
        net_hcl = factor*net_hcl
        net_hcn = factor*net_hcn
        net_soot = factor*net_soot
        net_soot_flaming = factor*net_soot_flaming
        net_soot_smolder = factor*net_soot_smolder
    end if 

    ! set mass "generation" rates in the cfast structure for species
    species_rates(o2) = net_o2
    species_rates(co2) = net_co2
    species_rates(co) = net_co
    species_rates(hcn) = net_hcn
    species_rates(hcl) = net_hcl
    species_rates(fuel) = net_fuel
    species_rates(h2o) = net_h2o
    species_rates(soot) = net_soot
    species_rates(soot_flaming) = net_soot_flaming
    species_rates(soot_smolder) = net_soot_smolder
    species_rates(ct) = net_ct

    end subroutine chemistry

! --------------------------- interpolate_pyrolysis -------------------------------------------

    subroutine interpolate_pyrolysis (objn,time,iroom,omasst,oareat,ohight,oqdott,objhct,n_C,n_H,n_O,n_N,n_Cl,y_soot, &
                                      y_soot_flaming, y_soot_smolder,y_co,y_trace)

    !     routine: interpolate_pyrolysis
    !     purpose: returns yields for object fires interpolated from user input
    !     arguments:  objn: the object pointer number,
    !                 time: current simulation time (s)
    !                 iroom: room contining the object
    !                 omasst (output): pyrolysis rate of object (returned)
    !                 oareat (output): area of pyrolysis of object (returned)
    !                 ohight (output): height of fire (returned)
    !                 oqdott (output): heat release rate of object
    !                 objhct (output): object heat of combustion
    !                 n_C, n_H, n_O, n_N, n_Cl (output): molecular formula for the fuel; these can be fractional;
    !                 yields of O2, HCl, and HCN are determined from this
    !                 y_soot, y_co, y_trace (output): species yields for soot, CO, and trace species;
    !                 others are calculated from the molecular formula of the fuel (kg species produced/kg fuel pyrolyzed)

    integer, intent(in) :: objn, iroom
    real(eb), intent(in) :: time
    real(eb), intent(out) :: omasst, oareat, ohight, oqdott, objhct, n_C, n_H, n_O, n_N, n_Cl, y_soot, y_soot_flaming 
    real(eb), intent(out) :: y_soot_smolder, y_co, y_trace

    real(eb) :: xxtime, tdrate, xxtimef, qt, qtf, tfact, factor, tfilter_max
    integer :: id, ifact
    
    type(room_type), pointer :: roomptr
    type(detector_type), pointer :: dtectptr
    type(fire_type), pointer :: fireptr

    roomptr => roominfo(iroom)
    fireptr => fireinfo(objn)
    
    if (.not.fireptr%ignited) then
        omasst = 0.0_eb
        oareat = 0.0_eb
        ohight = 0.0_eb
        oqdott = 0.0_eb
        n_C = 1.0_eb
        n_H = 4.0_eb
        n_O = 0.0_eb
        n_N = 0.0_eb
        n_Cl = 0.0_eb
        objhct = 5.0e7_eb
        y_soot = 0.0_eb
        y_soot_flaming = 0.0_eb
        y_soot_smolder = 0.0_eb
        y_co = 0.0_eb
        y_trace = 0.0_eb
        return
    end if

    xxtime = time - fireptr%ignition_time

    id = roomptr%sprinkler_activated

    if (id==0) then
        ! if a sprinkler is not active then interpolate at current time
        ifact = 0
    else
        ! if a sprinkler is active then interpolate at current time
        ! and when sprinkler first activated.  make sure that specified
        ! heat release rate is the smaller of rate at current time
        ! and rate at sprinkler activation time*exp( ...)
        dtectptr => detectorinfo(id)
        tdrate = dtectptr%tau
        xxtimef = dtectptr%activation_time - fireptr%ignition_time
        call interp(fireptr%t_qdot,fireptr%qdot,fireptr%n_qdot,xxtime,1,qt)
        call interp(fireptr%t_qdot,fireptr%qdot,fireptr%n_qdot,xxtimef,1,qtf)
        tfact = exp(-(xxtime-xxtimef)/tdrate)
        if (qt<tfact*qtf) then
            ! current time heat release rate is smaller than sprinklerd value
            ! so use current time and reset ifact to 0 so rates are not
            ! decreased
            ifact = 0
        else
            xxtime = xxtimef
            ifact = 1
        end if
    end if

    call interp(fireptr%t_mdot,fireptr%mdot,fireptr%n_mdot,xxtime,1,omasst)
    call interp(fireptr%t_qdot,fireptr%qdot,fireptr%n_qdot,xxtime,1,oqdott)
    call interp(fireptr%t_hoc,fireptr%hoc,fireptr%n_hoc,xxtime,1,objhct)
    call interp(fireptr%t_soot,fireptr%y_soot,fireptr%n_soot,xxtime,1,y_soot)
    if (xxtime>=fireptr%flaming_transition_time) then
        y_soot_flaming = y_soot
        y_soot_smolder = 0.0_eb
    else
        y_soot_flaming = 0.0_eb
        y_soot_smolder = y_soot
    end if
    call interp(fireptr%t_co,fireptr%y_co,fireptr%n_co,xxtime,1,y_co)
    call interp(fireptr%t_trace,fireptr%y_trace,fireptr%n_trace,xxtime,1,y_trace)
    call interp(fireptr%t_area,fireptr%area,fireptr%n_area,xxtime,1,oareat)
    call interp(fireptr%t_height,fireptr%height,fireptr%n_height,xxtime,1,ohight)

    n_C = fireptr%n_C
    n_H = fireptr%n_H
    n_O = fireptr%n_O
    n_N = fireptr%n_N
    n_Cl = fireptr%n_Cl

    ! attenuate mass and energy release rates if there is an active sprinkler in this room
    if (id/=0.and.ifact==1) then
        omasst = omasst*tfact
        oqdott = oqdott*tfact
    end if

    tfilter_max=1.0_eb
    if (adiabatic_walls.and.time<tfilter_max) then
        factor = time/tfilter_max
        omasst = omasst*factor
        oqdott = oqdott*factor
    end if

    return
    end subroutine interpolate_pyrolysis

! --------------------------- fire_plume -------------------------------------------

    subroutine fire_plume (object_area, qfire, qfire_c, z, t_inf, xemp, xems, xeme, xfx, xfy)

    !     routine: fireplm
    !     purpose: physical interface between do_fire and the plume models

    real(eb), intent(in) :: qfire, qfire_c, z, xemp, xfx, xfy, object_area, t_inf
    real(eb), intent(out) :: xeme, xems

    call heskestad_plume (qfire, qfire_c,z,t_inf,xemp,xems,xeme,object_area,xfx,xfy)
    return

    end subroutine fire_plume

! --------------------------- heskestad -------------------------------------------

    subroutine heskestad_plume (q_t, q_c, z, t_inf, emp, ems, eme, area, xfx, xfy)

    !     purpose: calculates plume entrainment for a fire from heskestad's variant of zukoski's correlation
    !     inputs:    q_t   fire size (w)
    !                z     plume height (m)
    !                t_inf ambient temperature at base of the fire
    !                emp   mass loss rate of the fire (kg/s)
    !                area  is the cross sectional area at the base of the fire
    !                xfx   distance from fire to wall in x direction (m)
    !                xfy   distance from fire to wall in y direction (m)
    !     outputs:   ems   total mass transfer rate up to height z (kg/s)
    !                eme   net entrainment rate up to height z (kg/s)

    real(eb), intent(in) :: q_t, q_c, z, t_inf, emp, area, xfx, xfy
    real(eb), intent(out) :: ems, eme

    real(eb), parameter :: cpg = cp/1000._eb ! correlation uses different units
    real(eb) :: d, qj, z0, z_l, deltaz, xf, factor, qstar, rho_inf
    real(eb) :: c1, c2

    ! determine which entrainment factor to use by fire position.  if we're on the wall or in the corner, entrainment is modified.
    ! by reflection, entrainment on a wall is 1/2 the entrainment of a fire 2 times larger;
    !                            in a corner, 1/4 the entrainment of a fire 4 times larger
    xf = 1.0_eb
    ! V&V experiments show no effect for walls
    if (xfx<=sqrt(area)/2.or.xfy<=sqrt(area)/2) xf = 1.0_eb 
    if (xfx<=sqrt(area)/2.and.xfy<=sqrt(area)/2) xf = 4.0_eb

    ! qstar and virtual origin correlation are based on total HRR
    qj = 0.001_eb*q_t*xf
    if (z>0.0_eb.and.qj>0.0_eb) then
        d = sqrt(area*xf/pio4)
        rho_inf = 352.981915_eb/t_inf
        qstar = qj/(rho_inf*cpg*t_inf*gsqrt*d**(2.5_eb))
        z0 = d*(-1.02_eb + 1.4_eb*qstar**0.4_eb)

        ! entrainment is based on convective HRR and the mean flame height
        qj = 0.001_eb*q_c*xf
        z_l = max(0.0001_eb,d*(-1.02_eb + 3.7*qstar**0.4_eb))
        if (z>z_l) then
            factor = 1.0_eb
            deltaz = max(0.0001_eb, z-z0)
        else
            factor = z/z_l
            deltaz = max(0.0001_eb, z_l-z0)
        end if
        c1 = 0.196*(grav_con*rho_inf**2/(cpg*t_inf))**onethird  ! under normal conditions, 0.071_eb
        c2 = 2.9_eb/((gsqrt*cpg*rho_inf*t_inf)**twothirds)      ! under normal conditions, 0.026_eb
        eme = (c1*qj**onethird*deltaz**(5.0_eb/3.0_eb)*(1.0_eb+c2*qj**twothirds*deltaz**(-5.0_eb/3.0_eb)) * factor)/xf
        ems = emp + eme
    else
        ems = emp
        eme = 0.0_eb
    end if

    end subroutine heskestad_plume

! --------------------------- integrate_mass -------------------------------------------

    subroutine integrate_mass (time, deltt)

    !     routine:  integrate_mass
    !     description: Routine to integrate the pyrolosate of objects
    !         we also integrate the trace species release and total for all fires
    !     Arguments:  time    current simulation time
    !                 deltt   current time step

    real(eb), intent(in) :: time, deltt

    integer ::i
    real(eb) :: fraction
    character(64) :: rampid
    type(fire_type), pointer :: fireptr
    type(vent_type), pointer :: ventptr

    do i = 1, n_fires
        fireptr => fireinfo(i)
        fireptr%total_pyrolysate = fireptr%total_pyrolysate + fireptr%mdot_pyrolysis*deltt
        fireptr%total_trace = fireptr%total_trace + fireptr%mdot_trace*deltt
    end do

    ! sum the trace release from all of the fires
    tradio = 0.0_eb
    do i = 1, n_fires
        fireptr => fireinfo(i)
        tradio = tradio + fireptr%total_trace
    end do

    ! sum the hvac flow
    ! ...%total_trace_flow is the trace species which gets through the vent, ...%total_trace_filtered is the mass stopped.
    do i = 1, n_mvents
        ventptr => mventinfo(i)
        rampid = ventptr%ramp_id
        call get_vent_opening (rampid,'F',ventptr%room1,ventptr%room2,ventptr%counter,i,time,fraction)
        fraction = (1.0_eb-fraction)
        ventptr%total_flow(u) = ventptr%total_flow(u) + ventptr%mv_mflow(u)*deltt
        ventptr%total_flow(l) = ventptr%total_flow(l) + ventptr%mv_mflow(l)*deltt
        ventptr%total_trace_flow(u)  = ventptr%total_trace_flow(u) + &
           ! ventptr%mv_mflow(u)*ventptr%species_fraction(u,11)*fraction*deltt
            ventptr%mv_mflow(u)*ventptr%species_fraction(u,ts)*fraction*deltt
        ventptr%total_trace_flow(l)  = ventptr%total_trace_flow(l) + &
            !ventptr%mv_mflow(l)*ventptr%species_fraction(l,11)*fraction*deltt
            ventptr%mv_mflow(l)*ventptr%species_fraction(l,ts)*fraction*deltt
        ventptr%total_trace_filtered(u)  = ventptr%total_trace_filtered(u) + &
            !ventptr%mv_mflow(u)*ventptr%species_fraction(u,11)*(1.0_eb-fraction)*deltt
            ventptr%mv_mflow(u)*ventptr%species_fraction(u,ts)*(1.0_eb-fraction)*deltt
        ventptr%total_trace_filtered(l)  = ventptr%total_trace_filtered(l) + &
            !ventptr%mv_mflow(l)*ventptr%species_fraction(l,11)*(1.0_eb-fraction)*deltt
            ventptr%mv_mflow(l)*ventptr%species_fraction(l,ts)*(1.0_eb-fraction)*deltt
    end do

    return
    end subroutine integrate_mass

! --------------------------- door_jet -------------------------------------------

    subroutine door_jet (flows_doorjets,djetflg)

    !     routine:  door_jet
    !     description: physical interface routine to calculate the current
    !                  rates of mass and energy flows into the layers from
    !                  all door jet fires in the building.

    !                  note that we presume that this calculation is performed
    !                  after the normal fires and flow through vents so we
    !                  have a heat of combustion to use for the burning fuel.
    !                  at present, this heat of combustion is presumed to be
    !                  that of the main fire.
    !
    !     inputs:   nfire   total number of normal fires
    !     outputs:  flows_doorjets  mass and energy flows into layers due to fires.
    !                       standard source routine data structure.

    logical, intent(out) :: djetflg
    real(eb), intent(out) :: flows_doorjets(mxrooms,ns+2,2)

    real(eb) :: xntms1(2,ns), xntms2(2,ns), flw1to2, flw2to1, qpyrol1, qpyrol2
    integer :: i, iroom1, iroom2

    logical :: dj1flag, dj2flag
    type(vent_type), pointer :: ventptr
    type(room_type), pointer :: roomptr, room1ptr, room2ptr

    ! initialize summations and local data

    flows_doorjets(1:nr,1:ns+2,l) = 0.0_eb
    flows_doorjets(1:nr,1:ns+2,u) = 0.0_eb
    roominfo(1:nr)%qdot_doorjet = 0.0_eb
    djetflg = .false.
    if (option(fdfire)/=on.or.n_fires<=0) return

    ! if no vents have a door jet fire then exit
    do i = 1, n_hvents
        ventptr=>hventinfo(i)

        ! is there a door jet fire into room iroom1
        iroom1 = ventptr%room1
        room1ptr => roominfo(iroom1)
        if (room1ptr%temp(u)>=tgignt) then
            flw1to2 = vss(1,i)+vsa(1,i)
            if (vsas(2,i)>0.0_eb.and.flw1to2>0.0_eb) then
                djetflg = .true.
                exit
            end if
        end if

        !is there a door jet fire into room iroom2
        iroom2 = ventptr%room2
        room2ptr => roominfo(iroom2)
        if (room2ptr%temp(u)>=tgignt) then
            flw2to1 = vss(2,i)+vsa(2,i)
            if (vsas(1,i)>0.0_eb.and.flw2to1>0.0_eb) then
                djetflg = .true.
                exit
            end if
        end if
    end do
    if (.not.djetflg)return

    ! calculate the heat for each of the door jet fires

        do i = 1, n_hvents
            ventptr=>hventinfo(i)
                iroom1 = ventptr%room1
                iroom2 = ventptr%room2
                room1ptr => roominfo(iroom1)
                room2ptr => roominfo(iroom2)
                flw1to2 = room1ptr%species_fraction(u,fuel)*(vss(1,i)+vsa(1,i))
                flw2to1 = room2ptr%species_fraction(u,fuel)*(vss(2,i)+vsa(2,i))
                call door_jet_fire (iroom2,iroom1,flw1to2,vsas(2,i),qpyrol2,xntms2,dj2flag)
                call door_jet_fire (iroom1,iroom2,flw2to1,vsas(1,i),qpyrol1,xntms1,dj1flag)

                ! sum the flows for return to the source routine
                if (dj1flag) then
                    flows_doorjets(iroom1,q,u) = flows_doorjets(iroom1,q,u) + qpyrol1
                    flows_doorjets(iroom1,3:ns+2,u) = flows_doorjets(iroom1,3:ns+2,u) + xntms1(u,1:ns)
                end if
                if (dj2flag) then
                    flows_doorjets(iroom2,q,u) = flows_doorjets(iroom2,q,u) + qpyrol2
                    flows_doorjets(iroom2,3:ns+2,u) = flows_doorjets(iroom2,3:ns+2,u) + xntms2(u,1:ns)
                end if
        end do

    do i = 1, nr
        roomptr => roominfo(i)
        roomptr%qdot_doorjet = flows_doorjets(i,q,u) + flows_doorjets(i,q,l)
    end do
    return
    end subroutine door_jet

! --------------------------- door_jet_fire -------------------------------------------

    subroutine door_jet_fire (ito,ifrom,xxnetfl,sas,qpyrol,xntms,djflowflg)

    !     routine: door_jet_fire
    !     purpose: calculate heat and combustion chemistry for a door jet fire
    !     arguments:  ito: room number door jet is flowing into
    !                 ifrom: room number door jet is flowing from
    !                 xxnetfl: net fuel available to be burned
    !                 sas: mass flow rate of entrained air in door jet
    !                 qpyrol (output): total heat released by door jet fire
    !                 xntms (output): net change in mass of species in door jet

    integer, intent(in) :: ito, ifrom
    real(eb), intent(in) :: xxnetfl, sas
    logical, intent(out) :: djflowflg
    real(eb), intent(out) :: qpyrol, xntms(2,ns)

    real(eb) :: xmass(ns), source_o2, xxmol_mass, xqpyrl, xntfl, tjet, hcombt, flowfrac
    real(eb) :: y_soot, y_flaming_soot, y_smolder_soot, y_co
    real(eb) :: nu_o2, nu_co2, nu_co, nu_hcn, nu_hcl, nu_h2o, nu_soot
    real(eb) :: n_n, n_o, n_c, n_cl,n_h
    type(room_type), pointer :: room1ptr, room2ptr

    qpyrol = 0.0_eb
    djflowflg = .false.
    room1ptr => roominfo(ito)
    room2ptr => roominfo(ifrom)
    tjet = room2ptr%temp(u)

    ! we only want to do the door jet calculation if there is fuel, oxygen, and sufficient temperature in the door jet
    if (xxnetfl>0.0_eb.and.sas>0.0_eb.and.tjet>=tgignt.and.room2ptr%species_mass(u,fuel_Q)>0.0_eb.and. &
        room2ptr%species_mass(u,fuel_moles)>0.0_eb) then

        ! do combustion chemistry assuming complete comversion to co2 & h2o.
        ! although the real chemistry is more complex, for now we don't know
        ! how to handle it.
        djflowflg = .true.
        xmass(1:ns) = 0.0_eb
        
        source_o2 = room1ptr%species_fraction(l,o2)
        hcombt = room2ptr%species_mass(u,fuel_Q)/room2ptr%species_mass(u,fuel)
        xxmol_mass = room2ptr%species_mass(u,fuel)/room2ptr%species_mass(u,fuel_moles)
        y_soot = room2ptr%species_mass(u,fuel_soot)/room2ptr%species_mass(u,fuel)
        y_flaming_soot = y_soot
        y_smolder_soot = 0.0_eb
        y_co = room2ptr%species_mass(u,fuel_co)/room2ptr%species_mass(u,fuel)
        nu_soot = y_soot*xxmol_mass/0.01201_eb
        nu_co = y_co*xxmol_mass/0.02801_eb
        nu_hcn = room2ptr%species_mass(u,fuel_hcn)/room2ptr%species_mass(u,fuel)*xxmol_mass/0.027028_eb
        nu_hcl = room2ptr%species_mass(u,fuel_hcl)/room2ptr%species_mass(u,fuel)*xxmol_mass/0.036458_eb
        nu_co2 = room2ptr%species_mass(u,fuel_co2)/room2ptr%species_mass(u,fuel)*xxmol_mass/0.04401_eb
        nu_h2o = room2ptr%species_mass(u,fuel_h2o)/room2ptr%species_mass(u,fuel)*xxmol_mass/0.018016_eb
        nu_o2 = room2ptr%species_mass(u,fuel_o2)/room2ptr%species_mass(u,fuel)*xxmol_mass/0.032_eb
        
        n_n = nu_hcn
        n_cl = nu_hcl
        n_h = 2.0_eb*nu_h2o + nu_hcn + nu_hcl
        n_c = nu_co2 + nu_hcn + nu_co + nu_soot
        n_o = max(0.0_eb,2.0_eb*nu_co2 - 2.0_eb*nu_o2 + nu_h2o + nu_co)
        
        call chemistry (xxnetfl, xxmol_mass, sas, hcombt, y_soot, y_flaming_soot, y_smolder_soot, y_co, n_c, n_h, n_o, n_n, &
            n_cl, source_o2, lower_o2_limit, xqpyrl, xntfl, xmass)
        qpyrol = xqpyrl
        
        xntms(u,1:ns) = xmass(1:ns)
        xntms(l,1:ns) = 0.0_eb
        flowfrac = xntfl/room2ptr%species_mass(u,fuel)
        xntms(u,fuel_moles) = -flowfrac*room2ptr%species_mass(u,fuel_moles)
        xntms(u,fuel_Q) = -flowfrac*room2ptr%species_mass(u,fuel_Q)
        xntms(u,fuel_o2) = -flowfrac*room2ptr%species_mass(u,fuel_o2)
        xntms(u,fuel_co2) = -flowfrac*room2ptr%species_mass(u,fuel_co2)
        xntms(u,fuel_co) = -flowfrac*room2ptr%species_mass(u,fuel_co)
        xntms(u,fuel_hcn) = -flowfrac*room2ptr%species_mass(u,fuel_hcn)
        xntms(u,fuel_hcl) = -flowfrac*room2ptr%species_mass(u,fuel_hcl)
        xntms(u,fuel_h2o) = -flowfrac*room2ptr%species_mass(u,fuel_h2o)
    end if
    return
    end subroutine door_jet_fire

! --------------------------- flame_height -------------------------------------------

    subroutine flame_height (qdot, area, fheight)

    !     routine: flame_height
    !     purpose: Calculates flame height for a given fire size and area
    !     arguments:  qdot: Fire Size (W)
    !                 area: Area of the base of the fire (m^2)
    !                 fheight (output): Calculated flame height (m)
    !
    !     Source: SFPE handbook, Section 2, Chapter 1

    real(eb), intent(in) :: qdot, area
    real(eb), intent(out) :: fheight

    real(eb) :: d

    if (area<=0._eb) then
        d = pio4*0.2_eb**2
    else
        d = sqrt(4.0_eb*area/pi)
    end if
    fheight = -1.02_eb*d + 0.235_eb*(qdot/1.0e3_eb)**0.4_eb
    fheight = max (0.0_eb, fheight)
    return
    end subroutine flame_height


! --------------------------- get_gas_temp_velocity -------------------------------------------

    subroutine get_gas_temp_velocity(iroom,x,y,z,tg,vg)

    !     routine: get_gas_temp_velocity
    !     purpose: routine to calculate gas temperature nearby a target
    !     arguments: iroom  compartment number
    !                x  x position of target in compartmentnumber
    !                y  y position of target in compartmentnumber
    !                z  z position of target in compartment
    !                tg (output)   calculated gas temperature
    !                vg (output)   calculated gas velocity

    integer, intent(in) :: iroom
    real(eb), intent(in) :: x, y, z

    real(eb), intent(out) :: tg, vg(4)

    real(eb) :: qdot, chirad, area, tu, tl, zfire, zlayer, zceil, r, tplume, vplume, tplume_ceiling, vplume_ceiling, tcj, vcj
    real(eb) :: xdistance, ydistance, distance, hall_width, xf, xfx, xfy
    integer :: i
    type(room_type), pointer :: roomptr
    type(fire_type), pointer :: fireptr

    roomptr => roominfo(iroom)

    ! default is the appropriate layer temperature and a velocity of 0.1 m/s
    if (z>=roomptr%depth(l)) then
        tg = roomptr%temp(u)
    else
        tg = roomptr%temp(l)
    end if
    vg = 0.0_eb
    ! if there is a fire in the room, calculate plume temperature
    do i = 1,n_fires
        fireptr => fireinfo(i)
        if (fireptr%room==iroom) then
            ! determine which entrainment factor to use by fire position.  if we're on the wall or in the corner, entrainment is modified.
            ! by reflection, entrainment on a wall is 1/2 the entrainment of a fire 2 times larger;
            !                            in a corner, 1/4 the entrainment of a fire 4 times larger

            xfx = min(fireptr%x_position, roomptr%cwidth-fireptr%x_position)
            xfy = min(fireptr%y_position, roomptr%cdepth-fireptr%y_position)
            xf = 1.0_eb
            ! V&V experiments show no effect for walls
            if (xfx<=sqrt(fireptr%firearea)/2.or.xfy<=sqrt(fireptr%firearea)/2) xf = 1.0_eb
            if (xfx<=sqrt(fireptr%firearea)/2.and.xfy<=sqrt(fireptr%firearea)/2) xf = 4.0_eb
            qdot = xf*fireptr%qdot_actual
            chirad = fireptr%chirad
            area = xf*fireptr%firearea
            tu = roomptr%temp(u)
            tl = roomptr%temp(l)
            zfire = fireptr%z_position + fireptr%z_offset
            xdistance = x - fireptr%x_position
            if (abs(xdistance)<=mx_hsep) xdistance = 0.0_eb
            ydistance = y - fireptr%y_position
            if (abs(ydistance)<=mx_hsep) ydistance = 0.0_eb
            zlayer = roomptr%depth(l)
            zceil = roomptr%cheight
            r = sqrt(xdistance**2 + ydistance**2)
            if (roomptr%hall) then
                if (roomptr%cdepth>roomptr%cwidth) then
                    distance = ydistance
                    hall_width = roomptr%cwidth
                else
                    distance = xdistance
                    hall_width = roomptr%cdepth
                end if
            else
                hall_width = 0.0_eb
            end if
            ! first calculate plume temperature at desired location
            call get_plume_tempandvelocity (qdot, chirad, area, tu, tl, zfire, zlayer, z, r, tplume, vplume)
            ! include ceiling jet effects if desired location is in the ceiling jet
            call get_plume_tempandvelocity (qdot, chirad, area, tu, tl, zfire, zlayer, zceil, 0.0_eb, &
                tplume_ceiling, vplume_ceiling)
            call get_ceilingjet_tempandvelocity(qdot, tu, tl, tplume_ceiling, zfire, zlayer, zceil, z, distance, r, &
                hall_width, tcj, vcj)
            tg = max(tg,tplume,tcj)
            if (r/=0.0_eb) then
                vg(1) = vg(1) + vcj*xdistance/r
                vg(2) = vg(2) + vcj*ydistance/r
            end if
            vg(3) = vg(3) + vplume
        end if
    end do
    vg(4) = sqrt(vg(1)**2+vg(2)**2+vg(3)**2)
    return

    end subroutine get_gas_temp_velocity

! --------------------------- get_ceilingjet_tempandvelocity --------------------------------------

    subroutine get_ceilingjet_tempandvelocity (qdot, tu, tl, tplume, zfire, zlayer, zceil, zin, xin, r, w, tcj, vcj)

    !     routine: get_ceilingjet_tempandvelocity
    !     purpose: Calculates ceiling jet temperature and velocity at a specified height and distance from the fire.
    !
    !     Uses Alpert / Heskestad's correlation to calculate plume  temperature
    !     arguments:  qdot: total heat release rate of the fire (W)
    !                 tu: upper layer gas temperature (K)
    !                 tl: lower layer gas temperature (K)
    !                 tplume: plume temperature at ceiling (K)
    !                 zfire: height of the base of the fire (m)
    !                 zlayer: height of the hot/cold gas layer interface (m)
    !                 zceil: height of the compartment ceiling (m)
    !                 zin: position to calculate temperature (m)
    !                 xin: distance to calculate temperature (parallel to long wall ... for hallways) (m)
    !                 r: horizontal distance from fire centerline (m)
    !                 w: width of hallway is compartment is designated as a hallway, zero otherwisw
    !                 tcj (output): temperature at height zin and radius r (K)
    !                 vcj (output): velocity at height zin and radius r (m/s)

    real(eb), intent(in) :: qdot, tu, tl, tplume, zfire, zlayer, zceil, zin, xin, r, w
    real(eb), intent(out) :: tcj, vcj

    real(eb), parameter :: cpg = cp/1000._eb ! correlation uses different units
    real(eb), parameter :: deltaT_0star_at_p2 = (0.225_eb+0.27_eb*0.2_eb)**(-4._eb/3._eb)
    real(eb) :: t_inf, t_layer, rho_inf, qstar_h, h, delta_cj

    ! Set default values
    if (zin<=zlayer) then
        ! desired point is in the lower layer
        t_layer = tl
    else
        t_layer = tu
    end if
    tcj = t_layer
    vcj = 0.0

    h = zceil - zfire

    ! for the temperature algorithm to work, there has to be a fire, two layers, and a target point above the fire
    if (qdot>0.0_eb.and.tu>=tl.and.h>=0.0_eb) then
        if (zfire<=zlayer) then
            ! fire is in the lower layer
            t_inf = tl
        else
            t_inf = tu
        end if
        rho_inf = 352.981915_eb/t_inf

        !ceiling jet thickness
        if (r/h>=0.26_eb) then
            delta_cj = h * 0.112_eb*(1.0_eb-exp(-2.24_eb*r/h))
        else
            delta_cj = h * 0.112_eb*(1.0_eb-exp(-2.24_eb*0.26_eb))
        end if

        if (zin>=zceil-delta_cj) then
            ! if compartment is not a hallway or distance is smaller than 1/2 hallway width, use alpert and heskestad

            !ceiling jet temperature
            if (r/h<=0.2_eb) then
                tcj = tplume
            else
                tcj = t_layer + (tplume-t_layer)/deltaT_0star_at_p2 * (0.225_eb+0.27_eb*r/h)**(-4.0_eb/3.0_eb)
            end if
            if (w>0.0_eb.and.xin>w/2) then
                !compartment is a hallway and we've hit the walls, use delichastsios
                tcj = max(tcj,t_layer + (tplume-t_layer)*0.37_eb*(h/w)**onethird*exp(-0.16_eb*xin/h*(w/h)**onethird))
            end if

            ! ceiling jet velocity
            qstar_h = (qdot/1000._eb)/(rho_inf*cpg*t_inf*gsqrt*h**2.5_eb)
            if (r/h<=0.17_eb) then
                vcj = gsqrt*sqrt(h)*qstar_h**onethird*3.61_eb
            else
                vcj = gsqrt*sqrt(h)*qstar_h**onethird*1.06_eb*(r/h)**(-0.69_eb)
            end if
            if (w>0.0_eb.and.xin>w/2) then
                !compartment is a hallway and we've hit the walls, use delichastsios
                vcj = max(vcj,0.114_eb*sqrt(h*(tcj-t_layer))*(h/w)**(1.0_eb/6.0_eb))
            end if
        end if
    end if

    return
    end subroutine get_ceilingjet_tempandvelocity

! --------------------------- get_plume_tempandvelocity -------------------------------------------

    subroutine get_plume_tempandvelocity (qdot, xrad, area, tu, tl, zfire, zlayer, zin, r, tplume, uplume)

    !     routine: get_plume_tempandvelocity
    !     purpose: Calculates plume centerline temperature at a specified height and distance from the fire.
    !
    !     Uses Heskestad's correlation to calculate plume  temperature
    !     with Evan's method to determine virtual fire size and fire origin when fire
    !     is in the lower layer and position is in the upper layer
    !     arguments:  qdot: total heat release rate of the fire (W)
    !                 xrad: fraction of fire HRR released as radiation
    !                 area: fire diamater (m)
    !                 tu: upper layer gas temperature (K)
    !                 tl: lower layer gas temperature (K)
    !                 zfire: height of the base of the fire (m)
    !                 zlayer: height of the hot/cold gas layer interface (m)
    !                 zin: position to calculate plume centerline temperature (m)
    !                 r: horizontal distance from fire centerline (m)
    !                 tplume (output): plume temperature at height zin and radius r (K)
    !                 uplume (output): plume velocity at height zin and radius r (m/s)

    real(eb), intent(in) :: qdot, xrad, area, tu, tl, zfire, zlayer, zin, r
    real(eb), intent(out) :: tplume, uplume

    real(eb), parameter :: cpg = cp/1000._eb ! correlation uses different units
    real(eb) :: t_inf, rho, qdot_c, qstar, z0, z0_prime, z_flame, deltaz, d, t_excess, sigma_deltat, sigma_u, t_max, u_max

    ! default is for temperature to be the layer temperature at the desired location
    if (zin<=zlayer) then
        tplume = tl
    else
        tplume = tu
    end if
    uplume = 0.0_eb

    ! for the algorithm to work, there has to be a fire, two layers, and a target point above the fire
    if (qdot>0.0_eb.and.tu>=tl.and.zin-zfire>=0.0_eb) then
        qdot_c = qdot*(1.0_eb - xrad)/1000.0_eb
        d = sqrt(area/pio4)

        if (zfire<=zlayer) then
            t_inf = tl
        else
            t_inf = tu
        end if

        rho = 352.981915_eb/t_inf
        qstar = (qdot/1000._eb)/(rho*cpg*t_inf*gsqrt*d**2.5_eb)
        z0 = d*(-1.02_eb+1.4_eb*qstar**0.4_eb)
        z_flame = max(0.1_eb,d*(-1.02_eb+3.7_eb*qstar**0.4_eb))

        ! plume temperature
        t_max = 900._eb
        if (zfire<=zlayer.and.zin>zlayer) then
            ! fire is in lower and and target point is in upper layer
            z0_prime = zlayer-(tu/tl)**0.6_eb * (zlayer-z0)
            rho = 352.981915_eb/tu
            deltaz = max(0.1_eb,zin-zfire-z0_prime)
            t_excess = min(t_max,9.1_eb*(tu/(grav_con*cpg**2*rho**2))**onethird * qdot_c**twothirds * deltaz**(-5.0_eb/3.0_eb))
        else
            ! fire and target point are both in the same layer
            deltaz = max(0.1_eb,zin-zfire-z0)
            t_excess = min(t_max,9.1_eb*(t_inf/(grav_con*cpg**2*rho**2))**onethird * qdot_c**twothirds * deltaz**(-5.0_eb/3.0_eb))
        end if

        ! plume velocity
        u_max = 2.2_eb*(grav_con**0.4_eb/(t_inf**0.4_eb*(cpg*rho)**0.2_eb))*(650._eb*qdot_c)**0.2_eb
        uplume = min(u_max,3.4_eb*(grav_con/(cpg*rho*t_inf))**onethird * qdot_c**onethird * deltaz**(-onethird))

        ! if it's within the flame (assumed to be a cone of diameter d and height equal to flame height, it's flame temperature

        sigma_deltat = 0.14_eb * sqrt(1.0_eb + t_excess/t_inf) * deltaz
        if (r>d*(1.0_eb-(zin-zfire)/z_flame)/2.0_eb) then
            t_excess = t_excess*exp(-(r/sigma_deltat)**2)
        end if
        tplume = t_inf + t_excess

        if (r>0.0_eb) then
            sigma_u = 1.1_eb*sigma_deltat
            uplume = uplume*exp(-(r/sigma_u)**2)
        end if
    end if
    return
    end subroutine get_plume_tempandvelocity

! --------------------------- update_species (toxict) -------------------------------------------

    subroutine update_species (deltt)

    !     routine: update_species
    !     purpose: calculate species concentrations (ppm), mass density (kg/m^3), opacity (1/m),
    !              ct (g-min/m^3)
    !     arguments:  deltt  length of the latest time step (s)

    real(eb), intent(in) :: deltt

    ! molar_masses of the species
    real(eb), parameter :: molar_mass(ns_mass) = &
        (/0.02802_eb,0.032_eb,0.04401_eb,0.02801_eb,0.027028_eb,0.036458_eb,0.01201_eb,0.018016_eb,0.01201_eb/)

    ! reciprocal of avagadro's number (so you can't have less than an atom of a species)
    real(eb), parameter :: avagad = 1.0_eb/6.022e23_eb
    
    real(eb) :: air_moles(2), v(2)
    integer i, layer, lsp
    type(room_type), pointer :: roomptr

    do i = 1, nrm1
        roomptr => roominfo(i)
        v(u) = roomptr%volume(u)
        v(l) = roomptr%volume(l)
        do layer = u, l
            air_moles(layer) = 0.0_eb
            do lsp = 1, ns_mass
                if (lsp/=fuel) then
                    air_moles(layer) = air_moles(layer) + roomptr%species_mass(layer,lsp)/molar_mass(lsp)
                else
                    air_moles(layer) = air_moles(layer) + roomptr%species_mass(layer,fuel_moles)
                end if
            end do
            air_moles(layer) = max(avagad,air_moles(layer))
        end do

        ! calculate the mass density in kg/m^3
        do layer = u, l
            roomptr%species_rho(layer,1:ns) = roomptr%species_mass(layer,1:ns)/v(layer)
        end do


        ! calculate the molar fraction (actually in percent)
        do lsp = 1, 8
            do layer = u, l
                if (lsp/=fuel) then
                    roomptr%species_output(layer,lsp) = 100.0_eb*(roomptr%species_mass(layer,lsp)/molar_mass(lsp))/air_moles(layer)
                else
                    roomptr%species_output(layer,fuel) = 100.0_eb*roomptr%species_mass(layer,fuel_moles)/air_moles(layer)
                end if
            end do
        end do

        ! opacity is calculated from seder's work
        ! note: this value was changed 2/15/2 from 3500 to 3778 to reflect the new value as reported by
        ! mulholland in fire and materials, 24, 227(2000) with recommended value of extinction coefficient
        ! of 8700 m^2/kg or 8700/ln(10)=3778 converted to optical density
        do layer = u, l
            roomptr%species_output(layer,soot_flaming) = roomptr%species_rho(layer,soot_flaming)*3778.4_eb
            roomptr%species_output(layer,soot_smolder) = roomptr%species_rho(layer,soot_smolder)*1910.9_eb
            roomptr%species_output(layer,soot) = roomptr%species_output(layer,soot_flaming) + &
                roomptr%species_output(layer,soot_smolder)
        end do

        ! ct is the integration of the total "junk" being transported
        do layer = u, l
            roomptr%species_output(layer,ct) = roomptr%species_output(layer,ct) + &
                roomptr%species_rho(layer,ct)*1000.0_eb*deltt/60.0_eb
        end do

        ! ts (trace species) is the filtered concentration - this is the total mass.
        ! it is converted to fraction of the total generated by all fires.
        ! this step being correct depends on the integratemass routine
        do layer = u, l
            roomptr%species_output(layer,ts) = roomptr%species_mass(layer,ts) !/(tradio+1.0d-10)
        end do
        
        do lsp = fuel_moles, fuel_soot
            do layer = u, l
                roomptr%species_output(layer,lsp) = roomptr%species_mass(layer,lsp)
            end do
        end do

    end do

    return
    end subroutine update_species

! --------------------------- remap_fires -------------------------------------------

    subroutine remap_fires (nfires)

    ! this routine is to combine fire objects into a single list
    ! there does not have to be a fire, so nfires may be zero

    integer, intent(out) :: nfires

    real(eb) :: fheight
    integer :: i
    type(fire_type), pointer :: fireptr

    nfires = n_fires

    do i = 1, n_fires
        fireptr => fireinfo(i)
        smv_xfire(i) = fireptr%x_position
        smv_yfire(i) = fireptr%y_position
        smv_zfire(i) = fireptr%z_position + fireptr%z_offset
        call flame_height (fireptr%qdot_actual,fireptr%firearea,fheight)
        smv_qdot(i) = fireptr%qdot_actual
        smv_height(i) = fheight
        smv_room(i) = fireptr%room
    end do
    return
    end subroutine remap_fires

! --------------------------- update_fire_objects -------------------------------------------

    subroutine update_fire_objects (iflag, told, dt, ifobj, tobj)

    !     routine: update_fire_objects
    !     purpose: check for and set object fire ignition
    !     arguments:  iflag   flags if check, set, or update variables
    !                 told    time previous to this time step
    !                 dt      length of last time step
    !                 ifobj   object number that ignites (return)
    !                 tobj    time object ignites

    integer, intent(in) :: iflag
    integer, intent(out) :: ifobj
    real(eb), intent(in) :: told, dt
    real(eb), intent(out) :: tobj

    real(eb) :: tmpob(2,mxfires), tnobj

    integer :: i, ignflg, itarg

    type(fire_type), pointer :: fireptr
    type(target_type), pointer :: targptr

    ifobj = 0
    tobj = told + 2.0_eb*dt
    tnobj = told + dt

    do i = 1, n_fires
        fireptr => fireinfo(i)
        if (.not.fireptr%ignited) then
            ignflg = fireptr%ignition_type
            itarg = fireptr%ignition_target
            if (ignflg==trigger_by_time) then
                if (fireptr%ignition_time<=tnobj) then
                    tobj = min(fireptr%ignition_time,tobj)
                    ifobj = i
                    tmpob(1,i) = 1.0_eb
                    tmpob(2,i) = fireptr%ignition_time
                else
                    tmpob(1,i) = 0.0_eb
                    tmpob(2,i) = tnobj + dt
                end if
            else if (ignflg==trigger_by_temp) then
                targptr => targetinfo(itarg)
                call check_object_ignition (told,dt,targptr%temperature(idx_tempf_trg),fireptr%ignition_criterion, &
                    fireptr%temperature,i,ifobj,tobj,tmpob(1,i))
            else if (ignflg==trigger_by_flux) then
                targptr => targetinfo(itarg)
                call check_object_ignition (told,dt,targptr%flux_incident_front,fireptr%ignition_criterion, &
                    fireptr%incident_flux,i,ifobj,tobj,tmpob(1,i))
            else
                call xerror('Update_fire_objects-incorrectly defined ignition type in input file',0,1,1)
                stop
            end if
        end if
    end do

    if (iflag/=check_state) then
        do i = 1, n_fires
            fireptr => fireinfo(i)
            if (.not.fireptr%ignited) then
                itarg = fireptr%ignition_target
                if (ignflg/=trigger_by_time) then
                    targptr => targetinfo(itarg)
                    fireptr%temperature = targptr%temperature(idx_tempf_trg)
                    fireptr%incident_flux = targptr%flux_incident_front
                end if
                if (iflag==set_state.and.tmpob(1,i)>0.0_eb) then
                    if (tmpob(2,i)<=tobj) then
                        fireptr%ignited = .true.
                        fireptr%ignition_time = tmpob(2,i)
                        if (.not.fireptr%reported) then
                            write (iofilo,'(/,a,i0,3a,i0,a)') 'Object #',i,' (',trim(fireptr%name),') ignited at ', &
                                int(max(fireptr%ignition_time+0.5_eb,0.0_eb)),' seconds'
                            write (iofill,'(a,i0,3a,i0,a)') 'Object #',i,' (',trim(fireptr%name),') ignited at ', &
                                int(max(fireptr%ignition_time+0.5_eb,0.0_eb)),' seconds'
                            fireptr%reported = .true.
                        end if
                    end if
                end if
            end if
        end do
    end if

    return
    end subroutine update_fire_objects

! --------------------------- check_object_ignition -------------------------------------------

    subroutine check_object_ignition(told, dt, cond, trip, oldcond, iobj, ifobj, tobj, tmpob)

    integer, intent(in) :: iobj
    real(eb), intent(in) :: told, dt, cond, trip, oldcond

    integer, intent(out) :: ifobj
    real(eb), intent(out) :: tmpob(2)
    real(eb), intent(inout) :: tobj

    real(eb) :: delta

    if (cond>trip) then
        delta = (trip-oldcond)/(cond-oldcond)
        tmpob(1) = 1.0_eb
        tmpob(2) = told + dt*delta
        tobj = min(tobj,tmpob(2))
        ifobj = iobj
    else
        tmpob(1) = 0.0_eb
        tmpob(2) = told + 2.0_eb*dt
    end if

    return

    end subroutine check_object_ignition

end module fire_routines
