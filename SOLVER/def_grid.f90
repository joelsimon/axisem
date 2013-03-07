!========================
module def_grid
!========================

use global_parameters
use data_mesh
use data_mesh_preloop
use data_spec
use data_io
use data_proc

use utlity

implicit none

public :: init_grid, mesh_tests, deallocate_preloop_arrays
public :: massmatrix, massmatrix_dble
private

contains

!@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!-----------------------------------------------------------------------------
subroutine init_grid
!
! This routine defines the arrays related to the chosen spectral-element 
! discretization. In particular, it computes the reference coordinates of 
! the collocation points,the global coordinates of these points mapped in 
! any element ielem, weights associated with the chosen quadrature, 
! the axis and north booleans, elemental arrays for the mean radius/colatitude,
! and some short-hand parameters for the time loop.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use data_numbering, ONLY : igloc_solid,nglob_solid
use data_comm
use commun
use splib

include 'mesh_params.h'

integer :: iel,ipol,jpol,idest,ipt,icount,iicount,ipg,ip

! Axial elements, s-direction: Gauss-Lobatto-Jacobi (0,1) quadrature
  call zemngl2(npol,xi_k)                   
  call get_welegl_axial(npol,xi_k,wt_axial_k,2) 

! All elements, z-direction & s-direction non-axial elements: 
! Gauss-Lobatto-Legendre quadrature
  call ZELEGL(npol,eta,dxi)                  
  call get_welegl(npol,eta,wt)        

! Define logical arrays to determine whether element is on the axis or not.
! We safely use "zero" here since coordinates have been "masked" to eliminate 
! round-off errors above in read_db (the choice to use jpol=npol is random)
   axis=.false.

! define elemental logical array north
  north(:)=.true.

   do iel=1,nelem
      if (scoord(0,npol,iel)==zero) axis(iel)=.true.
     if ( zcoord(int(npol/2),int(npol/2),iel) < zero ) north(iel)=.false.
   enddo

   axis_solid=.false.
   do iel=1,nel_solid
      if (scoord(0,npol,ielsolid(iel))==zero) axis_solid(iel)=.true.
   enddo

   axis_fluid=.false.
   do iel=1,nel_fluid
      if (scoord(0,npol,ielfluid(iel))==zero) axis_fluid(iel)=.true.
   enddo

! define array that gives average radius and colatitude given an element number
  do iel=1,nel_solid
    mean_rad_colat_solid(iel,1)=rcoord(npol/2,npol/2,ielsolid(iel))/1.d3
    mean_rad_colat_solid(iel,2)=thetacoord(npol/2,npol/2,ielsolid(iel))/pi*180.
  enddo

  do iel=1,nel_fluid
    mean_rad_colat_fluid(iel,1)=rcoord(npol/2,npol/2,ielfluid(iel))/1.d3
    mean_rad_colat_fluid(iel,2)=thetacoord(npol/2,npol/2,ielfluid(iel))/pi*180.
  enddo

! Set some misc. parameters for faster access in time loop
  nsize=(npol+1)**2
  npoint_solid3=npoint_solid*3 ! for three-component arrays

! Initialize the solid global number array needed for the assembly
  allocate(gvec_solid(nglob_solid))

! Initialize solid array that maps global numbers into elemental numbers for 
! processor boundaries

  if (nproc>1) then
     if (sizesend_solid>0) then
        allocate(glob2el_send(2*maxval(sizemsgsend_solid),3))
        glob2el_send=0
     endif
     if (sizerecv_solid>0) then
        allocate(glob2el_recv(2*maxval(sizemsgrecv_solid),3))
        glob2el_recv=0
     endif
     
     icount=0; iicount=0
     
     open(unit=8978,file=infopath(1:lfinfo)//'/mpi_gll_send.dat'//appmynum)
     open(unit=8979,file=infopath(1:lfinfo)//'/mpi_gll_recv.dat'//appmynum)
     do iel=1,nel_solid
        do jpol=0,npol
           do ipol=0,npol
              ipt = (iel-1)*(npol+1)**2 + jpol*(npol+1) + ipol + 1
              idest = igloc_solid(ipt)
              if (sizesend_solid>0) then
                 do ip = 1, sizemsgsend_solid(1)
                    ipg = glocal_index_msg_send_solid(ip,1)
                    if (idest==ipg) then 
                       icount=icount+1
                       glob2el_send(icount,1)=ipol
                       glob2el_send(icount,2)=jpol
                       glob2el_send(icount,3)=iel
                       write(8978,*)icount,iel,ipol,jpol
                    endif
                 enddo
              endif
              if (sizerecv_solid>0) then
                 do ip = 1, sizemsgrecv_solid(1)
                    ipg = glocal_index_msg_recv_solid(ip,1)
                    if (idest==ipg) then 
                       iicount=iicount+1
                       glob2el_recv(iicount,1)=ipol
                       glob2el_recv(iicount,2)=jpol
                       glob2el_recv(iicount,3)=iel
                       write(8979,*)iicount,iel,ipol,jpol
                    endif
                 enddo
              endif
           end do
        end do
     end do
     close(8978); close(8979)
     
     num_send_gll=icount; num_recv_gll=iicount
     
     do iel=0,nproc-1
        call barrier
        if (mynum==iel) then 
           write(6,12)procstrg,'counted sent/received GLL points:',&
                num_send_gll,num_recv_gll
        endif
     enddo
     
     call barrier
     if (lpr) write(6,*)
     
  end if ! nproc>1

12 format('   ',a8,a33,2(i6))

end subroutine init_grid
!=============================================================================

!-----------------------------------------------------------------------------
subroutine deallocate_preloop_arrays
!
! These memory-pricey arrays are not needed in the time loop and therefore 
! dynamically allocated and dropped at this point. 
! Any inevitable larger arrays are defined in data_matr or data_mesh.
! The decision process here is highly dependant on the amount and type of 
! on-the-fly dumpsters of wavefields. One should consider these issues here
! when trading off run-time memory with disk space occupancy.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
 
use data_pointwise

  if (lpr) write(6,*)'  deallocating large mesh arrays...'; call flush(6)
  deallocate(lnods)
  deallocate(crd_nodes)
  deallocate(eltype,coarsing,north,axis)

  if (allocated(ielsolid)) deallocate(ielsolid)
  if (allocated(ielfluid)) deallocate(ielfluid)
  if (allocated(spher_radii)) deallocate(spher_radii)

! Deallocate redundant arrays if memory-efficient dumping strategy is applied
  if (.not. need_fluid_displ) then
     if (lpr) write(6,*)'  deallocating pointwise fluid arrays...'
     deallocate(DsDeta_over_J_flu)
     deallocate(DzDeta_over_J_flu)
     deallocate(DsDxi_over_J_flu)
     deallocate(DzDxi_over_J_flu)

     deallocate(inv_rho_fluid)
     deallocate(inv_s_rho_fluid)
     deallocate(inv_s_fluid)
  endif

  ! These terms are needed to compute the gradient!
  if (.not. dump_wavefields .or. dump_type/='fullfields') then
     if (.not. anel_true) then
        if (lpr) write(6,*)'  deallocating pointwise solid arrays...'
        deallocate(DsDeta_over_J_sol)
        deallocate(DzDeta_over_J_sol)
        deallocate(DsDxi_over_J_sol)
        deallocate(DzDxi_over_J_sol)
        deallocate(inv_s_solid)
     endif
  endif

  if (lpr) write(6,*)'  Done deallocating mesh arrays.'; call flush(6)

end subroutine deallocate_preloop_arrays
!=============================================================================

!-----------------------------------------------------------------------------
subroutine massmatrix(masstmp,nel,domain)
!  
! Computes the UNASSEMLED global mass matrix, i.e. spanning solid AND 
! fluid domains.
! (as opposed to routine def_mass_matrix_k which only computes those terms 
! that are needed in the time loop.
! As of Sept 2006 (date of creation...) only needed for computing the volume.
! Feb 2007: Also needed for computing discontinuity surfaces in get_model.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use geom_transf
use get_mesh, ONLY : compute_coordinates_mesh

include "mesh_params.h"

integer,intent(in)               :: nel
character(len=5), intent(in)     :: domain
real(kind=realkind), intent(out) :: masstmp(0:npol,0:npol,nel)

double precision                 :: mass2
double precision                 :: local_crd_nodes(8,2)
integer                          :: iel,ielem, inode,ipol,jpol

  masstmp(:,:,:) = zero
  do ielem = 1, nel

     if (domain=='solid') iel=ielsolid(ielem)
     if (domain=='fluid') iel=ielfluid(ielem)
     if (domain=='total') iel=ielem

     do inode = 1, 8
        call compute_coordinates_mesh(local_crd_nodes(inode,1),&
             local_crd_nodes(inode,2),iel,inode)
     end do

! ::::::::::::::::non-axial elements::::::::::::::::
     if (.not. axis(iel)) then
        do ipol  = 0, npol
           do jpol = 0, npol
              mass2 = &
                   jacobian(eta(ipol),eta(jpol),local_crd_nodes,iel) &
                   *scoord(ipol,jpol,iel)*wt(ipol)*wt(jpol)
              masstmp(ipol,jpol,ielem) = mass2
           end do
        end do

! ::::::::::::::::axial elements::::::::::::::::
     elseif (axis(iel)) then
        do ipol  = 0, npol ! Be careful here !!!!
           do jpol = 0, npol
              mass2 = &
                    jacobian(xi_k(ipol),eta(jpol),local_crd_nodes,iel) &
                    *s_over_oneplusxi_axis(xi_k(ipol),eta(jpol),&
                    local_crd_nodes,iel)*wt_axial_k(ipol)*wt(jpol)
              masstmp(ipol,jpol,ielem) = mass2
           end do
        end do
      end if
  end do

end subroutine massmatrix
!=============================================================================

!-----------------------------------------------------------------------------
subroutine massmatrix_dble(masstmp,nel,domain)
!
! Same as routine massmatrix above but in double precision.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use geom_transf
use get_mesh, ONLY : compute_coordinates_mesh

include "mesh_params.h"

integer,intent(in)               :: nel
character(len=5), intent(in)     :: domain
double precision, intent(out)    :: masstmp(0:npol,0:npol,nel)

double precision                 :: local_crd_nodes(8,2)
integer                          :: iel,ielem, inode,ipol,jpol

  masstmp(:,:,:) = zero
  do ielem = 1, nel

     if (domain=='solid') iel=ielsolid(ielem)
     if (domain=='fluid') iel=ielfluid(ielem)
     if (domain=='total') iel=ielem

     do inode = 1, 8
        call compute_coordinates_mesh(local_crd_nodes(inode,1),&
             local_crd_nodes(inode,2),iel,inode)
     end do

! ::::::::::::::::non-axial elements::::::::::::::::
     if (.not. axis(iel)) then
        do ipol  = 0, npol
           do jpol = 0, npol
              masstmp(ipol,jpol,ielem) = &
                   jacobian(eta(ipol),eta(jpol),local_crd_nodes,iel) &
                   *scoord(ipol,jpol,iel)*wt(ipol)*wt(jpol)
           end do
        end do

! ::::::::::::::::axial elements::::::::::::::::
     elseif (axis(iel)) then
        do ipol  = 0, npol ! Be careful here !!!!
           do jpol = 0, npol
              masstmp(ipol,jpol,ielem) = &
                    jacobian(xi_k(ipol),eta(jpol),local_crd_nodes,iel) &
                    *s_over_oneplusxi_axis(xi_k(ipol),eta(jpol),&
                    local_crd_nodes,iel)*wt_axial_k(ipol)*wt(jpol)
           end do
        end do
      end if
  end do

end subroutine massmatrix_dble
!=============================================================================

!-----------------------------------------------------------------------------
subroutine mesh_tests
!
! A wrapper for a multitude of tests related to various aspects of the mesh 
! (that is, prior to adding elastic properties) such as volume, surfaces, 
! valence & global numbering, solid-fluid boundary indexing, axial arrays, 
! global coordinates, north-south issues.
! If there is an (isolated) issue with any of these, in *most* cases this 
! routine shall find it and exit with a descriptive error message. 
! Yet again, maybe not...
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use commun, ONLY: mpi_asynch_messaging_test_solid
use commun, ONLY: mpi_asynch_messaging_test_fluid

! Checking coordinate conformity 
  if (lpr) write(6,*)'  dumping element information...'
  call dump_coarsing_element_info

! Checking coordinate conformity <><><><><><><><><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  checking physical coordinates...'
  call check_physical_coordinates

! Dumping the respective serendipity meshes<><><><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  dumping control-node meshes...'
  call dump_serendipity_meshes

! Axial elements & masking <><><><><><><><><><><><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  Checking out axial stuff...'
  call check_axial_stuff

! Check all radii by computing surface areas <><><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  Computing spherical surface integrals...'
  call compute_spherical_surfaces

! compute the volume of the spheres/shells <><><><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  Computing volumes...'
  call compute_volume

! Solid-fluid boundary <><><><><><><><><><><><><><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  Checking out solid-fluid boundaries...'
  call check_solid_fluid_boundaries

! Check message passing <><><><><><><><><><><><><><>><><><><><><><><><><><>
  if (nproc>1) then
     if (lpr) write(6,*)'  Checking message-passing for solid...'
     call mpi_asynch_messaging_test_solid
     if (lpr) write(6,*)'  Checking message-passing for fluid...'
     call mpi_asynch_messaging_test_fluid
  endif

! Valence for all (global/solid/fluid) domains <><><><><><><><><><><><><><>
  if (lpr) write(6,*)'  Computing valences...'
  if (save_large_tests) call compute_valence

  if (lpr) write(6,*)
  if (lpr) write(6,*)'  >>> FINISHED mesh tests.'
  if (lpr) write(6,*)

end subroutine mesh_tests
!=============================================================================

!-----------------------------------------------------------------------------
subroutine dump_coarsing_element_info
!
! Coarsing elements are all those that have any role in the non-spheroidal
! coarsening levels (i.e., contain some non-spheroidal edge), i.e. include
! "two entire depth levels" around the coarsening level.
!
! Element information: number, location, type, whether north, and axis.
! ...also written to processor output.
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use commun, ONLY: barrier

include 'mesh_params.h'

integer          :: iel
double precision :: s,z,r,theta
character(len=4) :: axischar
character(len=1) :: northchar
integer          :: ncoars,naxis,naxis_solid,naxis_fluid,ncurve
integer          :: nsemino,nsemiso,nlinear

!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
  open(444+mynum,file=infopath(1:lfinfo)//'/element_info.dat'//appmynum) 
  write(69,*)'  Dumping element information into element_info.dat'//appmynum
  do iel = 1, nelem
!    check for central point in element
     call compute_coordinates(s,z,r,theta,iel,int(npol/2),int(npol/2)) 

!    dump element location, type, etc
     northchar = 'S';    if ( north(iel) ) northchar = 'N'
     axischar = 'noax';  if ( axis(iel) ) axischar = 'axis'
     write(444+mynum,14)iel,r,theta*180./pi,eltype(iel),northchar,axischar
14   format(i6,2(1pe13.5),a8,a3,a6)
  enddo
  close(444+mynum)

  write(69,*)'  Dumping coarsening elements into coarsing_els.dat'//appmynum
  open(unit=1577,file=infopath(1:lfinfo)//'/coarsing_els.dat'//appmynum)
  do iel = 1, nelem
     if (coarsing(iel)) then 
        write(1577,15)iel,rcoord(npol/2,npol/2,iel)/1000., &
                      thetacoord(npol/2,npol/2,iel)*180./pi, &
                      scoord(npol/2,npol/2,iel)/1000., &
                      zcoord(npol/2,npol/2,iel)/1000.
     endif
  enddo
  close(1577)
15 format(i8,1pe15.5,1pe13.3,2(1pe15.5))
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

! write element info to processor output
  ncoars=0
  naxis=0
  naxis_solid=0
  naxis_fluid=0
  ncurve=0
  nsemino=0
  nsemiso=0
  nlinear=0
  do iel = 1, nelem
     if ( axis(iel) ) naxis=naxis+1
     if ( coarsing(iel) ) ncoars=ncoars+1
     if (eltype(iel)=='curved') ncurve=ncurve+1
     if (eltype(iel)=='semino') nsemino=nsemino+1
     if (eltype(iel)=='semiso') nsemiso=nsemiso+1
     if (eltype(iel)=='linear') nlinear=nlinear+1
  enddo
  do iel = 1, nel_solid
     if (axis_solid(iel)) naxis_solid = naxis_solid+1
  enddo
  do iel = 1, nel_fluid
     if (axis_fluid(iel)) naxis_fluid = naxis_fluid+1
  enddo

  write(69,*)
  write(69,16)procstrg,nelem,'total'
  write(69,16)procstrg,nel_solid,'solid'
  write(69,16)procstrg,nel_fluid,'fluid'
  write(69,16)procstrg,naxis,'axial'
  write(69,16)procstrg,naxis_solid,'solid axial' 
  write(69,16)procstrg,naxis_fluid,'fluid axial' 
  write(69,16)procstrg,ncoars,'coarsing'
  write(69,16)procstrg,ncurve,'spheroidal'
  write(69,16)procstrg,nlinear,'rectangular'
  write(69,16)procstrg,nsemino,'north mixed'
  write(69,16)procstrg,nsemiso,'south mixed'
  write(69,*)

16 format('   ',a8,'has ',i6,a12,' elements')

end subroutine dump_coarsing_element_info
!=============================================================================

!-----------------------------------------------------------------------------
subroutine check_physical_coordinates
!
! Check whether s,z,theta, and r conform. Just here as a debugging relict,
! but lingering well since not exactly pricey...
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

include 'mesh_params.h'

integer :: iel,ipol,jpol
double precision :: s,z,r,theta

  do iel = 1,nelem
     do ipol=0,npol
        do jpol=0,npol
           call compute_coordinates(s,z,r,theta,iel,ipol,jpol)
 ! test if s,z conform with r   
           if ( abs(sqrt(s**2+z**2)-r)> min_distance_dim) then
              write(6,*)
              write(6,*)procstrg,&
                   'PROBLEM: in compute_coordinates, s,z,r are inconsistent'
              write(6,*)procstrg,'sqrt(s^2+z^2),r [km]:',sqrt(s**2+z**2),r
              stop
           endif

           if ( abs(z) > zero ) then ! off the equator
! test if s,z conform with theta   
              if ( s == zero .and. z < zero ) then ! south axis 
                 if ( (theta-pi)*r > min_distance_dim) then
                    write(6,*)
                    write(6,*)procstrg,'PROBLEM: in compute_coordinates,', &
                         'antipode inconsistent'
                    write(6,*)procstrg,'theta [deg],s,z [km]:',&
                         theta*180.d0/pi,s,z
                    stop
                 endif

              else ! not south axis
                 if ( datan(s/z) >= zero) then ! north
                    if ( abs(datan(s/z)-theta)*r > min_distance_dim) then
                       write(6,*)
                       write(6,*)procstrg,'PROBLEM: in compute_coordinates',&
                            's,z,theta inconsistent'
                       write(6,*)procstrg,'atan(s/z),theta [deg]:', &
                            datan(s/z)*180/pi,theta*180.d0/pi
                       stop
                    endif
                 else 
                    if ( abs(datan(s/z)+pi-theta)*r > min_distance_dim) then
                       write(6,*)
                       write(6,*)procstrg,'PROBLEM: in compute_coordinates,',&
                            's,z,theta inconsistent'
                       write(6,*)procstrg,'atan(s/z),theta [deg]:',&
                            datan(s/z)*180.d0/pi+180.,theta*180.d0/pi
                       stop
                    endif
                 endif
              endif
           else
              if ( abs(theta-pi/two)*r > min_distance_dim) then
                 write(6,*)
                 write(6,*)procstrg,'PROBLEM: equatorial coordinates: ',&
                      'z,theta inconsistent'
                 write(6,*)procstrg,'sqrt(s^2+z^2),r [km]:',datan(s/z),r
                 stop
              endif
           endif
        enddo
     enddo
  enddo

end subroutine check_physical_coordinates
!=============================================================================

!-----------------------------------------------------------------------------
subroutine dump_serendipity_meshes
!
! Dumping the respective serendipity meshes for global, solid, fluid domains.
!
! Serendipity refers to the 8 fundamental control nodes, i.e. the pillars to 
! define any physical coordinates s,z or reference GLL/GLJ(0,1) points xi,eta).
! The numbering inode for an element is defined as follows (both hemispheres):
!
!          North
!         7--6--5
!         |     |
! z       8     4   
! ^       |     |   
! |       1--2--3   
! |-->s    South   
!
! See analytical mapping routines for details.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

include 'mesh_params.h'

integer :: inode,iel

!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
   if (save_large_tests) then

! Gnuplot serendipity solid mesh dump
      open(unit=1577,file=infopath(1:lfinfo)//&
                          '/serend_mesh_solid.dat'//appmynum)
      do iel = 1, nel_solid
         do inode=1,8
            write(1577,*)crd_nodes(lnods(ielsolid(iel),inode),1), & ! s 
                 crd_nodes(lnods(ielsolid(iel),inode),2)    ! z 
         enddo
         write(1577,*)crd_nodes(lnods(ielsolid(iel),1),1), &
              crd_nodes(lnods(ielsolid(iel),1),2) 
         write(1577,*)
      enddo
      close(1577)

! Gnuplot serendipity fluid mesh dump
      if (have_fluid) then 
         open(unit=1577,file=infopath(1:lfinfo)//&
                             '/serend_mesh_fluid.dat'//appmynum)
         do iel = 1, nel_fluid
            do inode=1,8
               write(1577,*)crd_nodes(lnods(ielfluid(iel),inode),1), & ! s 
                    crd_nodes(lnods(ielfluid(iel),inode),2)    ! z 
            enddo
            write(1577,*)crd_nodes(lnods(ielfluid(iel),1),1), &
                 crd_nodes(lnods(ielfluid(iel),1),2) 
            write(1577,*)
         enddo
         close(1577)
      endif

   endif !save_large_tests
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

end subroutine dump_serendipity_meshes
!=============================================================================

!-----------------------------------------------------------------------------
subroutine check_axial_stuff
!
! Checks the various arrays related to the axis globally and in solid/fluid 
! subdomains; and runs test fields through the actual routines 
! used to mask those fields that vanish on the axis during the time loop.
! 
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use apply_masks

include 'mesh_params.h'

integer                          ::  iel,jpol
integer                          :: count_ax,count2_ax,count3_ax,i
real(kind=realkind), allocatable :: tmpsolfieldcomp(:,:,:,:)
real(kind=realkind), allocatable :: tmpflufield(:,:,:)

  allocate(tmpsolfieldcomp(0:npol,0:npol,1:nel_solid,1:3))
  allocate(tmpflufield(0:npol,0:npol,1:nel_fluid))

! checking if any non-axial elements sneaked into this...
  do iel = 1,nelem
     if (axis(iel) .and. scoord(0,npol,iel) > zero) then 
        write(6,*)procstrg,'PROBLEM: Non-axial element is coined axis=true!'
        write(6,*)procstrg,'iel,s  :',iel,scoord(0,npol,iel)
        write(6,*)procstrg,'r,theta:',rcoord(0,npol,iel),thetacoord(0,npol,iel)
        stop
     endif
  enddo
  do iel = 1,nel_solid
     if (axis_solid(iel) .and. scoord(0,npol,ielsolid(iel)) > zero) then 
        write(6,*)procstrg,&
                  'PROBLEM: Non-axial solid element is coined axis_solid=true!'
        write(6,*)procstrg,'iel,iels,s:',iel,ielsolid(iel),scoord(0,npol,&
                                         ielsolid(iel))
        write(6,*)procstrg,'r,theta   :',rcoord(0,npol,ielsolid(iel)), &
                                         thetacoord(0,npol,ielsolid(iel))
        stop
     endif
  enddo
  if (have_fluid) then
  do iel = 1,nel_fluid
     if (axis_fluid(iel) .and. scoord(0,npol,ielfluid(iel)) > zero) then 
        write(6,*)procstrg,&
                  'PROBLEM: Non-axial fluid element is coined axis_fluid=true!'
        write(6,*)procstrg,'iel,ielf,s:',iel,ielfluid(iel),scoord(0,npol,&
                  ielfluid(iel))
        write(6,*)procstrg,'r,theta   :',rcoord(0,npol,ielfluid(iel)), &
                                         thetacoord(0,npol,ielfluid(iel))
        stop
     endif
  enddo
  endif

! check consistency between e.g. axis_solid(iel) and axis(ielsolid(iel))
  do iel = 1,nel_solid
     if (axis_solid(iel) .and. .not. axis(ielsolid(iel)) .or. &
         axis(ielsolid(iel)) .and. .not. axis_solid(iel)        ) then 
        write(6,*)procstrg,'PROBLEM:inconsistency between axis and axis_solid!'
        write(6,*)procstrg,'axis,axis_solid:',axis(ielsolid(iel)),&
                                              axis_solid(iel) 
        write(6,*)procstrg,'iel,iels,s:',iel,ielsolid(iel),scoord(0,npol,&
                                         ielsolid(iel))
        write(6,*)procstrg,'r,theta   :',rcoord(0,npol,ielsolid(iel)), &
                                         thetacoord(0,npol,ielsolid(iel))
        stop
     endif
  enddo
  if (have_fluid) then
  do iel = 1,nel_fluid
     if (axis_fluid(iel) .and. .not. axis(ielfluid(iel)) .or. &
         axis(ielfluid(iel)) .and. .not. axis_fluid(iel)        ) then 
        write(6,*)procstrg,&
                  'PROBLEM: inconsistency between axis and axis_fluid!'
        write(6,*)procstrg,'axis,axis_fluid:',axis(ielfluid(iel)), &
                                              axis_fluid(iel) 
        write(6,*)procstrg,'iel,ielf,s:',iel,ielfluid(iel),&
                                         scoord(0,npol,ielfluid(iel))
        write(6,*)procstrg,'r,theta   :',rcoord(0,npol,ielfluid(iel)), &
                                         thetacoord(0,npol,ielfluid(iel))
        stop
     endif
  enddo
  endif

!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
! write out all s- and r-coords of axial elements
   open(unit=13,file=infopath(1:lfinfo)//'/masking_scomp_solid.dat'//appmynum)
   do iel = 1,naxel_solid
      do jpol = 0,npol
      write(13,*)iel,rcoord(0,jpol,ielsolid(ax_el_solid(iel))), &
                     scoord(0,jpol,ielsolid(ax_el_solid(iel)) ) 
      if (scoord(0,jpol,ielsolid(ax_el_solid(iel)) ) > zero) then 
        write(6,*)procstrg,'PROBLEM: element with axis_solid=true has s>0'
        write(6,*)procstrg,'iel,ielaxsol,ielglob:',iel,ax_el_solid(iel), &
                                          ielsolid(ax_el_solid(iel))
        write(6,*)procstrg,'s,r,theta:',scoord(0,jpol,&
                                        ielsolid(ax_el_solid(iel))),&
                                  rcoord(0,jpol,ielsolid(ax_el_solid(iel))), &
                                  thetacoord(0,jpol,ielsolid(ax_el_solid(iel)))
        stop
      endif
      enddo
   enddo
   close(13)
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/


!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
  if (have_fluid) then
   open(unit=13,file=infopath(1:lfinfo)//'/masking_scomp_fluid.dat'//appmynum)
   do iel = 1,naxel_fluid
      do jpol = 0,npol
      write(13,*)iel,rcoord(0,jpol,ielfluid(ax_el_fluid(iel))), &
                     scoord(0,jpol,ielfluid(ax_el_fluid(iel)) )
      if (scoord(0,jpol,ielfluid(ax_el_fluid(iel)) ) > zero) then 
        write(6,*)procstrg,'PROBLEM: element with axis_fluid=true has s>0'
        write(6,*)procstrg,'iel,ielaxsol,ielglob:',iel,ax_el_fluid(iel), &
                                                   ielfluid(ax_el_fluid(iel))
        write(6,*)procstrg,'s,r,theta:',&
                               scoord(0,jpol,ielfluid(ax_el_fluid(iel))),&
                               rcoord(0,jpol,ielfluid(ax_el_fluid(iel))), &
                               thetacoord(0,jpol,ielfluid(ax_el_fluid(iel)))
        stop
      endif
      enddo
   enddo
   close(13)
   endif
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

!  compare naxel_fluid/solid to s/flobal number of axial elements
   count_ax=0; count2_ax=0; count3_ax=0
   do iel=1,nel_solid
      if (axis(ielsolid(iel))) count_ax=count_ax+1
      if (axis_solid(iel))  count3_ax=count3_ax+1
      do jpol=0,npol
      if ( scoord(0,jpol,ielsolid(iel)) == zero ) count2_ax=count2_ax+1
      enddo
   enddo  
   if (count_ax .ne. naxel_solid ) then 
      write(6,*)procstrg,&
                'PROBLEM: counting solid axial elements via axis /= naxel!'
      write(6,*)procstrg,'naxel,count axis==T:',naxel_solid,count_ax
      stop
   endif
   if (count2_ax .ne. (npol+1)*naxel_solid ) then 
      write(6,*)procstrg,&
          'PROBLEM: counting solid axial points via s-coord /= (npol+1)*naxel!'
      write(6,*)procstrg,'naxel,count s-coorc=0:',&
                                (npol+1)*naxel_solid,count2_ax
      stop
   endif
   if (count3_ax .ne. naxel_solid ) then 
      write(6,*)procstrg,&
                'PROBLEM: counting axial elemets via axis_solid /= naxel!'
      write(6,*)procstrg,'naxel,count s-coorc=0:',naxel_solid,count3_ax
      stop
   endif

   if (have_fluid) then
   count_ax=0; count2_ax=0; count3_ax=0
   do iel=1,nel_fluid
      if (axis(ielfluid(iel))) count_ax=count_ax+1
      if (axis_fluid(iel)) count3_ax=count3_ax+1
      do jpol=0,npol
      if ( scoord(0,jpol,ielfluid(iel)) == zero ) count2_ax=count2_ax+1
      enddo
   enddo  
   if (count_ax .ne. naxel_fluid ) then 
      write(6,*)procstrg,&
                'PROBLEM: counting fluid axial elements via axis /= naxel!'
      write(6,*)procstrg,'naxel,count axis==T:',naxel_fluid,count_ax
      stop
   endif
   if (count2_ax .ne. (npol+1)*naxel_fluid ) then 
      write(6,*)procstrg,&
          'PROBLEM: counting fluid axial points via s-coord /= (npol+1)*naxel!'
      write(6,*)procstrg,'naxel,count s-coorc=0:',&
                (npol+1)*naxel_fluid,count2_ax
      stop
   endif
   if (count3_ax .ne. naxel_fluid ) then 
      write(6,*)procstrg,&
             'PROBLEM: counting fluid axial elemets via axis_fluid /= naxel!'
      write(6,*)procstrg,'naxel,count s-coorc=0:',naxel_fluid,count3_ax
      stop
   endif
   endif

! Test axial masking routines -----------------------------------
  if (have_fluid) then
! fluid one-comp
   tmpflufield = one
   call apply_axis_mask_scal(tmpflufield,nel_fluid,ax_el_fluid,naxel_fluid)

   if ( minval(tmpflufield(1:npol,:,:)) .ne. one) then
      write(6,*)procstrg,&
                'PROBLEM: Fluid one-comp masking: point with xi>0 set to zero!'
      stop
   endif
   do iel=1,nel_fluid
   if ( .not. axis(ielfluid(iel)) .and. &
        minval(tmpflufield(:,:,iel)) .ne. one) then
      write(6,*)procstrg,&
                'PROBLEM: Fluid one-comp masking: non-ax element set to zero!'
      write(6,*)procstrg,&
           'el num, r,s:',iel,rcoord(int(npol/2),int(npol/2),ielfluid(iel)), &
                                  scoord(int(npol/2),int(npol/2),ielfluid(iel))
      stop
   endif
   if (axis(ielfluid(iel)) .and. maxval(tmpflufield(0,:,iel))==one) then 
      write(6,*)procstrg, &
                'PROBLEM: Fluid one-comp masking:ax element not set to zero!'
      write(6,*)procstrg,& 
           'el num, r,s:',iel,rcoord(int(npol/2),int(npol/2),ielfluid(iel)), &
                              scoord(int(npol/2),int(npol/2),ielfluid(iel))
      stop
   endif
   do jpol=0,npol
   if ( scoord(0,jpol,ielfluid(iel) ) < min_distance_dim .and. &
        tmpflufield(0,jpol,iel)==one) then 
      write(6,*)procstrg, &
                'PROBLEM: Fluid one-comp masking: ax element not set to zero!'
      write(6,*)procstrg, &
                'el ,jpol r,s:',iel,jpol,rcoord(0,jpol,ielfluid(iel)), &
                                         scoord(0,jpol,ielfluid(iel)) 
      stop
   endif
   enddo

   enddo
  endif

! solid one-comp
   tmpsolfieldcomp = one
   call apply_axis_mask_onecomp(tmpsolfieldcomp,nel_solid, &
                                       ax_el_solid,naxel_solid)
   
   do i=2,3
   if (minval(tmpsolfieldcomp(:,:,:,i)) .ne. one) then
      write(6,*)procstrg,'PROBLEM: Solid one-comp masking: comp',i,&
                         '  set to zero'
      write(6,*)procstrg,'min value, min loc:',&
                minval(tmpsolfieldcomp(:,:,:,i)), &
                minloc(tmpsolfieldcomp(:,:,:,i))
      stop
   endif
   enddo

   if ( minval(tmpsolfieldcomp(1:npol,:,:,1)) .ne. one) then
      write(6,*)procstrg,&
                'PROBLEM: Solid one-comp masking: point with xi>0 set to zero!'
      stop
   endif

   do iel=1,nel_solid
   if ( .not. axis(ielsolid(iel)) .and. &
        minval(tmpsolfieldcomp(:,:,iel,1)) .ne. one) then
      write(6,*)procstrg, &
               'PROBLEM: Solid one-comp masking: non-ax element set to zero!'
      write(6,*)procstrg,&
                'el num, r,s:',&
                iel,rcoord(int(npol/2),int(npol/2),ielsolid(iel)), &
                    scoord(int(npol/2),int(npol/2),ielsolid(iel))
      stop
   endif
   if (axis(ielsolid(iel)) .and. maxval(tmpsolfieldcomp(0,:,iel,1))==one) then 
      write(6,*)procstrg,&
               'PROBLEM: Solid one-comp masking:ax element not set to zero!'
      write(6,*)procstrg,&
                'el num, r:',iel,rcoord(int(npol/2),int(npol/2),ielsolid(iel))
      stop
   endif

   do jpol=0,npol
   if ( scoord(0,jpol,ielsolid(iel)) < min_distance_dim .and. &
        tmpsolfieldcomp(0,jpol,iel,1)==one) then 
      write(6,*)procstrg,&
                'PROBLEM: Solid one-comp masking: ax element not set to zero!'
      write(6,*)procstrg,&
                'el,jpol, r:',iel,jpol,rcoord(0,jpol,ielsolid(iel))
      stop
   endif
   enddo
   enddo

! solid two-comp
   tmpsolfieldcomp = one
   call apply_axis_mask_twocomp(tmpsolfieldcomp,nel_solid, &
                                                 ax_el_solid, naxel_solid)
   if ( minval(tmpsolfieldcomp(:,:,:,1)) .ne. one ) then
      write(6,*)procstrg,&
                'PROBLEM: Solid two-comp masking: comp 1 set to zero'
      stop
   endif

   if ( minval(tmpsolfieldcomp(1:npol,:,:,2:3)) .ne. one) then
      write(6,*)procstrg,&
                'PROBLEM: Solid two-comp masking: point with xi>0 set to zero!'
      stop
   endif

   do iel=1,nel_solid
   if ( .not. axis(ielsolid(iel)) .and. &
        minval(tmpsolfieldcomp(:,:,iel,2:3)) .ne. one) then
      write(6,*)procstrg,&
                'PROBLEM: Solid two-comp masking: non-ax element set to zero!'
      write(6,*)procstrg,&
           'el num, r,s:',iel,rcoord(int(npol/2),int(npol/2),ielsolid(iel)),&
                              scoord(int(npol/2),int(npol/2),ielsolid(iel))
      stop
   endif
   if (axis(ielsolid(iel)) .and. maxval(tmpsolfieldcomp(0,:,iel,2:3))==one)then
      write(6,*)procstrg,&
                'PROBLEM: Solid two-comp masking:ax element not set to zero!'
      write(6,*)procstrg,&
                'el num, r:',iel,rcoord(int(npol/2),int(npol/2),ielsolid(iel))
      stop
   endif

   do jpol=0,npol
   if ( scoord(0,jpol,ielsolid(iel)) < min_distance_dim .and. &
        tmpsolfieldcomp(0,jpol,iel,2)==one) then 
      write(6,*)procstrg,&
                'PROBLEM: Solid two-comp masking:', &
                'ax element comp 2 not set to zero!'
      write(6,*)procstrg,&
                'el,jpol, r:',iel,jpol,rcoord(0,jpol,ielsolid(iel))
      stop
   endif

   if ( scoord(0,jpol,ielsolid(iel)) < min_distance_dim .and. &
        tmpsolfieldcomp(0,jpol,iel,3)==one) then 
      write(6,*)procstrg,&
                'PROBLEM: Solid two-comp masking:', &
                'ax element comp 3 not set to zero!'
      write(6,*)procstrg,&
                'el,jpol, r:',iel,jpol,rcoord(0,jpol,ielsolid(iel))
      stop
   endif

   enddo
   enddo

! solid three-comp 
   tmpsolfieldcomp = one
    call apply_axis_mask_threecomp(tmpsolfieldcomp,nel_solid, &
                                                   ax_el_solid,naxel_solid)
   if ( minval(tmpsolfieldcomp(1:npol,:,:,:)) .ne. one) then
      write(6,*)procstrg,&
              'PROBLEM: Solid three-comp masking: point with xi>0 set to zero!'
      stop
   endif

   do iel=1,nel_solid
   if ( .not. axis(ielsolid(iel)) .and. &
        minval(tmpsolfieldcomp(:,:,iel,:)) .ne. one) then
      write(6,*)procstrg,&
               'PROBLEM: Solid three-comp masking: non-ax element set to zero!'
      write(6,*)procstrg,'el num, r,s:',&
                          iel,rcoord(int(npol/2),int(npol/2),ielsolid(iel)), &
                              scoord(int(npol/2),int(npol/2),ielsolid(iel))
      stop
   endif
   if (axis(ielsolid(iel)) .and. maxval(tmpsolfieldcomp(0,:,iel,:))==one) then 
      write(6,*)procstrg,&
              'PROBLEM: Solid three-comp masking:ax element not set to zero!'
      write(6,*)procstrg,&
              'el num, r:',iel,rcoord(int(npol/2),int(npol/2),ielsolid(iel))
      stop
   endif

   do jpol=0,npol

   if ( scoord(0,jpol,ielsolid(iel)) < min_distance_dim .and. &
        tmpsolfieldcomp(0,jpol,iel,1)==one) then 
      write(6,*)procstrg,&
                'PROBLEM: Solid three-comp masking:', &
                'ax element  comp 1 not set to zero!'
      write(6,*)procstrg,&
                'el,jpol, r:',iel,jpol,rcoord(0,jpol,ielsolid(iel))
      stop
   endif

   if ( scoord(0,jpol,ielsolid(iel)) < min_distance_dim .and. &
        tmpsolfieldcomp(0,jpol,iel,2)==one) then 
      write(6,*)procstrg,'PROBLEM: Solid three-comp masking:', &
                'ax element  comp 2 not set to zero!'
      write(6,*)procstrg,'el,jpol, r:',iel,jpol,rcoord(0,jpol,ielsolid(iel))
      stop
   endif

   if ( scoord(0,jpol,ielsolid(iel)) < min_distance_dim .and. &
        tmpsolfieldcomp(0,jpol,iel,3)==one) then 
      write(6,*)procstrg,&
                'PROBLEM: Solid three-comp masking:', &
                'ax element comp 3 not set to zero!'
      write(6,*)procstrg,'el,jpol, r:',iel,jpol,rcoord(0,jpol,ielsolid(iel))
      stop
   endif

   enddo
   enddo

  deallocate(tmpsolfieldcomp)
  deallocate(tmpflufield)

end subroutine check_axial_stuff
!=============================================================================

!-----------------------------------------------------------------------------
subroutine compute_spherical_surfaces
!
! Compute surface area of all radii in the spherical part of the domain 
! numerically and compare to analytical values.
! Constitutes an accuracy test of the GLL and GLJ(0,1) integration
! as well as a qualitative test on the sphericity over the whole domain 
! (Note that this test includes all spherical element edges, i.e. all 
! potential locations of elastic discontinuities).
! Also defines array spher_radii which will be used to compute & dump
! time step, period, characteristic lead times etc in get_model.f90
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use commun, ONLY : broadcast_int, broadcast_dble, psum_dble

include 'mesh_params.h'

integer                      :: irad,ipol,iel,ielabove,ielbelow
double precision,allocatable :: tmpradii(:,:),radsurf(:,:),radii2(:,:)
double precision             :: s,z,r1,r2,theta1,theta2,delta_th
double precision             :: tmpdble1,tmpdble2,deltacosth

  allocate(tmpradii(1:naxel,1:2))
  tmpradii(:,:)=zero

  write(69,*) &
         '  Computing surface areas for all spherical radii (sans coarsing)...'

! define radii via axial loop (only consider purely spheroidal shapes)
! assuming here that mynum=0 touches the northern axis
  if (mynum==0) then
     irad = 0
     do iel = 1, naxel
        if ( eltype(ax_el(iel))=='curved' .and. north(ax_el(iel)) .and. & 
             .not. coarsing(ax_el(iel)) ) then 
           irad = irad +1
           tmpradii(irad,1) = rcoord(0,npol,ax_el(iel)) ! upper edge,below
           tmpradii(irad,2) = rcoord(0,0,ax_el(iel))    ! lower edge,above
        endif
     enddo
  endif

! Broadcasting these radii to all processors
  call broadcast_int(irad,0)
  if (lpr) write(6,133) irad
133  format('   ==> found ',i4,' appropriate radii (along northern axis)')
  allocate(radii2(irad,2),radsurf(1:irad,1:2))
  radsurf(1:irad,1:2) = zero
  if (mynum==0) then 
     radii2(1:irad,1:2) = tmpradii(1:irad,1:2)
  endif
  deallocate(tmpradii)
  do iel=1,irad    
     tmpdble1=radii2(iel,1)
     call broadcast_dble(tmpdble1,0)
     radii2(iel,1)=tmpdble1
     tmpdble2=radii2(iel,2)
     call broadcast_dble(tmpdble2,0)
     radii2(iel,2)=tmpdble2
  enddo

! compute numerical surface areas by summing over respective radii
  do iel = 1,nelem
     if ( eltype(iel)=='curved' .and. .not. coarsing(iel)) then      
        if (north(iel)) then
           call compute_coordinates(s,z,r1,theta1,iel,0,npol) ! closest to axis
           call compute_coordinates(s,z,r2,theta2,iel,npol,npol) ! furthest
           delta_th=half*abs(theta2-theta1)

           ielbelow=minloc(abs(rcoord(0,npol,iel)-radii2(:,1)),DIM=1)
           ielabove=minloc(abs(rcoord(0,0,iel)-radii2(:,2)),DIM=1)

           if (axis(iel)) then
              do ipol = 1, npol
                 radsurf(ielbelow,1) = radsurf(ielbelow,1) + &
                    delta_th*wt_axial_k(ipol)*dsin(thetacoord(ipol,npol,iel))/&
                      (one+xi_k(ipol))
                 radsurf(ielabove,2) = radsurf(ielabove,2) + &
                    delta_th*wt_axial_k(ipol)*dsin(thetacoord(ipol,0,iel))/&
                      (one+xi_k(ipol))
              enddo
!             axial point ipol=0
              radsurf(ielbelow,1)=radsurf(ielbelow,1)+delta_th**2*wt_axial_k(0)
              radsurf(ielabove,2)=radsurf(ielabove,2)+delta_th**2*wt_axial_k(0)

           else ! non-axial elements
              do ipol = 0, npol
                 radsurf(ielbelow,1) = radsurf(ielbelow,1) + &
                      delta_th*wt(ipol)*dsin(thetacoord(ipol,npol,iel))
                 radsurf(ielabove,2) = radsurf(ielabove,2) + &
                      delta_th*wt(ipol)*dsin(thetacoord(ipol,0,iel))
              enddo
           endif ! axial/nonaxial

        else !south
           call compute_coordinates(s,z,r2,theta2,iel,0,npol) ! closest to axis
           call compute_coordinates(s,z,r1,theta1,iel,npol,npol) ! furthest
           delta_th=half*abs(theta2-theta1)

           ielbelow=minloc(abs(rcoord(0,0,iel)-radii2(:,1)),DIM=1)
           ielabove=minloc(abs(rcoord(0,npol,iel)-radii2(:,2)),DIM=1)

           if (axis(iel)) then 
              do ipol = 1, npol
                 radsurf(ielbelow,1) = radsurf(ielbelow,1) + &
                    delta_th*wt_axial_k(ipol)*dsin(thetacoord(ipol,0,iel))/&
                      (one+xi_k(ipol))
                 radsurf(ielabove,2) = radsurf(ielabove,2) + &
                    delta_th*wt_axial_k(ipol)*dsin(thetacoord(ipol,npol,iel))/&
                      (one+xi_k(ipol))
              enddo

!             axial point ipol=0
              radsurf(ielbelow,1)=radsurf(ielbelow,1)+delta_th**2*wt_axial_k(0)
              radsurf(ielabove,2)=radsurf(ielabove,2)+delta_th**2*wt_axial_k(0)

           else 
              do ipol = 0, npol
                 radsurf(ielbelow,1) = radsurf(ielbelow,1) + &
                      delta_th*wt(ipol)*dsin(thetacoord(ipol,0,iel))
                 radsurf(ielabove,2) = radsurf(ielabove,2) + &
                      delta_th*wt(ipol)*dsin(thetacoord(ipol,npol,iel))
              enddo
           endif ! axial/nonaxial

        endif ! north/south
     endif    ! curved elements only
  enddo

  deltacosth = dcos(pi*dble(mynum)/dble(nproc)) - &
               dcos(pi*dble(mynum+1)/dble(nproc))

  write(69,1233)'(below):',maxval(dabs(radsurf(1:irad,1)-deltacosth)),&
              radii2(maxloc(dabs(radsurf(1:irad,1)-deltacosth)),1)/1.d3
  write(69,1233)'(above):',maxval(dabs(radsurf(1:irad,2)-deltacosth)),&
              radii2(maxloc(dabs(radsurf(1:irad,2)-deltacosth)),2)/1.d3
1233 format('   ==> Largest surface area error ',a8,1pe11.4, &
                ' at r=',1pe11.4,' km')
  write(69,*)

!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
! write out comparison numerical/analytical surfaces
  open(unit=109,file=infopath(1:lfinfo)//&
                     '/surface_areas_all_radii.dat'//appmynum)
    do iel = 1, irad
       write(109,122)radii2(iel,1),deltacosth*two*pi*radii2(iel,1)**2, &
            two*pi*radsurf(iel,1)*radii2(iel,1)**2, &
            dbleabsreldiff(deltacosth,radsurf(iel,1))
       write(109,122)radii2(iel,2),deltacosth*two*pi*radii2(iel,2)**2, &
            two*pi*radsurf(iel,2)*radii2(iel,2)**2, &
            dbleabsreldiff(deltacosth,radsurf(iel,2))
    enddo
  close(109); call flush(109)
122 format(1pe14.5,2(1pe17.8),1pe13.3)
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

! sum up all processor contributions:
  do iel=1,irad
     radsurf(iel,1) = psum_dble(radsurf(iel,1))
     radsurf(iel,2) = psum_dble(radsurf(iel,2))
  enddo

  if (lpr) then
     write(6,1234)'(below):',maxval(dabs(radsurf(1:irad,1)/two-one)),&
          radii2(maxloc(abs(radsurf(1:irad,1)/two-one)),1)/1.d3
     write(6,1234)'(above):',maxval(dabs(radsurf(1:irad,2)/two-one)),&
          radii2(maxloc(dabs(radsurf(1:irad,2)/two-one)),2)/1.d3
1234 format('   ==> Largest global surface area error ',a8,1pe11.4, &
          ' at r=',1pe11.4,' km')
     write(6,*)

!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
! write out comparison numerical/analytical surfaces
     open(unit=109,file=infopath(1:lfinfo)//'/surface_areas_all_radii.dat')
     do iel = 1, irad
        write(109,122)radii2(iel,1),four*pi*radii2(iel,1)**2, &
             two*pi*radsurf(iel,1)*radii2(iel,1)**2, &
             dbleabsreldiff(two,radsurf(iel,1))
        write(109,122)radii2(iel,2),four*pi*radii2(iel,2)**2, &
             two*pi*radsurf(iel,2)*radii2(iel,2)**2, &
             dbleabsreldiff(two,radsurf(iel,2))
     enddo
     close(109); call flush(109)
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

  endif

  num_spher_radii = irad + 1
  allocate(spher_radii(1:num_spher_radii))
  spher_radii(1)=router
  spher_radii(2:num_spher_radii) = radii2(1:irad,2) ! take the ones below 

! sort spher_radii by inverse bubble sort
  call BSORT2(spher_radii,num_spher_radii)

  deallocate(radii2)
  deallocate(radsurf)

end subroutine compute_spherical_surfaces
!=============================================================================

!-----------------------------------------------------------------------------
subroutine compute_volume
!
! A straight computation of the spherical volume of the sphere and its 
! solid and fluid sub-shells. 
! Accuracy for realkind=4 is typically O(1E-8) and for realkind=8 O(1E-12).
! The comparison for processor-specific volumes is not implemented as the 
! volume is non-analytical due to the (deformed) central cube decomposition.
!
! This validates the mass matrix ingredients (integration weights, Jacobian, 
! s coordinate) as represented through their mesh point locations. 
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use commun, ONLY : psum,assembmass_sum_solid,assembmass_sum_fluid

include 'mesh_params.h'

integer             :: iel,ipol,jpol
double precision    :: vol_glob,vol_solid,vol_fluid
double precision    :: vol_glob_num,vol_solid_num,vol_fluid_num
double precision    :: vol_solid_numass,vol_fluid_numass
double precision    :: router_fluid, rinner_fluid

real(kind=realkind), dimension(:,:,:), allocatable :: mass
real(kind=realkind), dimension(:,:,:), allocatable :: mass_solid,mass_fluid

  allocate(mass(0:npol,0:npol,1:nelem))
  allocate(mass_solid(0:npol,0:npol,1:nel_solid))
  allocate(mass_fluid(0:npol,0:npol,1:nel_fluid))

  if (bkgrdmodel(1:4)=='prem') then 
     router_fluid=3480000.d0 ! CMB
     rinner_fluid=1221500.d0 ! ICB
  elseif (bkgrdmodel(1:4)=='iasp') then
     router_fluid=3482000.d0 ! CMB
     rinner_fluid=1217000.d0 ! ICB
  elseif (bkgrdmodel(1:4)=='homo') then 
     rinner_fluid= 3000.d0
     router_fluid = rinner_fluid
  else
     write(6,*)'  !!WARNING!! Do not know the fluid for model',bkgrdmodel
     write(6,*)'             ....setting outer/inner equal -> assuming no fluid'
     rinner_fluid= 3000.d0
     router_fluid = rinner_fluid      
  endif

  if (.not. have_fluid) rinner_fluid=router_fluid

! actual volumes
  vol_glob  = 4.d0/3.d0*pi*router**3
  vol_fluid = 4.d0/3.d0*pi*( router_fluid**3 - rinner_fluid**3 )
  vol_solid = vol_glob - vol_fluid

  vol_glob_num=zero; vol_solid_num=zero; vol_fluid_num=zero

! numerically computed volumes
  call massmatrix(mass,nelem,'total')
  call massmatrix(mass_solid,nel_solid,'solid')
  call massmatrix(mass_fluid,nel_fluid,'fluid')

  do iel = 1, nelem
     do ipol = 0, npol
        do jpol = 0, npol
           vol_glob_num = vol_glob_num + mass(ipol,jpol,iel)
        end do
     end do
  end do
  vol_glob_num=2.d0*pi*vol_glob_num
  vol_glob_num=psum(real(vol_glob_num,kind=realkind))

  do iel = 1, nel_solid
     do ipol = 0, npol
        do jpol = 0, npol
           vol_solid_num = vol_solid_num + mass_solid(ipol,jpol,iel)
        end do
     end do
  end do
  vol_solid_num=2.d0*pi*vol_solid_num
  vol_solid_num=psum(real(vol_solid_num,kind=realkind))

  do iel = 1, nel_fluid
     do ipol = 0, npol
        do jpol = 0, npol
           vol_fluid_num = vol_fluid_num + mass_fluid(ipol,jpol,iel)
        end do
     end do
  end do
  vol_fluid_num=2.d0*pi*vol_fluid_num
  vol_fluid_num=psum(real(vol_fluid_num,kind=realkind))

! Alternative numerical calculation: Compute assembled mass matrix, 
! and sum global numbers. This one does a simple psum at the end, 
! next incarnation should do comm2d and then just sum to test message-passing.
  call assembmass_sum_solid(mass_solid,vol_solid_numass)
  call assembmass_sum_fluid(mass_fluid,vol_fluid_numass)
  vol_solid_numass=2.d0*pi*vol_solid_numass
  vol_fluid_numass=2.d0*pi*vol_fluid_numass

  if (lpr) then
     write(6,*)'  Accuracy for 3-D spheres and shells [m^3]:'
     write(6,9)'Volume','analytical','global num','direct sum',&
                'ana-dirsum','ana-globnum'
     write(6,10)'Total:',vol_glob,vol_solid_numass+vol_fluid_numass, &
                         vol_glob_num,(vol_glob-vol_glob_num)/vol_glob,&
                         (vol_glob-vol_solid_numass-vol_fluid_numass)/vol_glob
     write(6,10)'Solid:',vol_solid,vol_solid_numass,vol_solid_num, &
                         (vol_solid-vol_solid_num)/vol_solid, &
                         (vol_solid-vol_solid_numass)/vol_solid
     if (vol_fluid > zero) then 
     write(6,10)'Fluid:',vol_fluid,vol_fluid_numass,vol_fluid_num, &
                         (vol_fluid-vol_fluid_num)/vol_fluid, &
                         (vol_fluid-vol_fluid_numass)/vol_fluid
     else
     write(6,10)'Fluid:',vol_fluid,vol_fluid_numass
     endif

     write(6,*)
9    format(a10,3(a14),2(a13))
10   format(a10,3(1pe14.5),2(1pe13.3))
  endif

  if ( .not. reldiff_small(real(vol_glob,kind=realkind), &
       real(vol_glob_num,kind=realkind)) ) then
     write(6,*)''
     write(6,*)procstrg,'PROBLEM computing global volume!!'
     write(6,*)procstrg, &
          '...exact and numerical volume differ by (relatively):', &
          (vol_glob-vol_glob_num)/vol_glob
     stop
  endif

  if ( .not. reldiff_small(real(vol_solid,kind=realkind), &
       real(vol_solid_num,kind=realkind)) ) then
     write(6,*)''
     write(6,*)procstrg,'PROBLEM computing solid volume!!'
     write(6,*)procstrg,&
          '...exact and numerical volume differ by (relatively):', &
          (vol_solid-vol_solid_num)/vol_solid
     stop
  endif

  if ( .not. reldiff_small(real(vol_fluid,kind=realkind), &
       real(vol_fluid_num,kind=realkind)) ) then
     write(6,*)''
     write(6,*)procstrg,'PROBLEM computing fluid volume!!'
     write(6,*)procstrg,&
          '...exact and numerical volume differ by (relatively):', &
          (vol_fluid-vol_fluid_num)/vol_fluid
     stop
  endif

  deallocate(mass)
  deallocate(mass_solid)
  deallocate(mass_fluid)

end subroutine compute_volume
!=============================================================================

!-----------------------------------------------------------------------------
subroutine check_solid_fluid_boundaries
!
! S/F boundary tests
! define field on fluid side, copy to solid, check difference
! This routine does not "check" as in exiting (except for counting boundary 
! points), but merely dumps the results of these checks into files. 
! Could well be fixed some day.
! Note that the routine computing the boundary term in def_precomp_matrices.f90
! contains more critical checks and actual terminating decisions....
! 
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

include 'mesh_params.h'

real(kind=realkind), allocatable :: tmpsolfield(:,:,:),tmpflufield(:,:,:)
integer                          :: bdrycount,ipol,jpol,iel
double precision                 :: s,z,r,theta

  allocate(tmpsolfield(0:npol,0:npol,1:nel_solid))
  allocate(tmpflufield(0:npol,0:npol,1:nel_fluid))
     do iel=1,nel_fluid
        do ipol=0,npol
           do jpol=0,npol
              ! make tmpflufield equal to theta
              call compute_coordinates(s,z,r,theta,ielfluid(iel),ipol,jpol)
              tmpflufield(ipol,jpol,iel)= asin(s/r)*180./pi
           enddo
        enddo
     enddo
 
!  write(6,*)'Test bdry: maxval/loc fluid [deg]:', &
!            maxval(tmpflufield),maxloc(tmpflufield); call flush(6)

  ! Now copy the S/F boundary values to the solid domain
  tmpsolfield(0:npol,0:npol,1:nel_solid)=-45.
  do iel=1,nel_bdry
!     write(6,*)iel,bdry_solid_el(iel),bdry_jpol_solid(iel),bdry_fluid_el(iel)
    tmpsolfield(0:npol,bdry_jpol_solid(iel),bdry_solid_el(iel))= &
         tmpflufield(0:npol,bdry_jpol_fluid(iel),bdry_fluid_el(iel))
  enddo

!  write(6,*)'Test bdry: maxval/loc solid [deg/indices]:', &
!             maxval(tmpsolfield),maxloc(tmpsolfield); call flush(6)

  ! Write out the radii at which the solid field takes values >1 
  ! (i.e., if other than S/F boundary radii, something's wrong....)

  if (lpr) write(6,*)'  Testing S/F boundary copying...'
!  write(6,*)'File: bdrytest_solflubdry.dat contains:'
!  write(6,*)'iel_solid, rad,latitude, value at which things have been copied:'
!  open(unit=109,file=infopath(1:lfinfo)//'/bdrytest_solflubdry.dat'//appmynum)
  bdrycount=0
     do iel=1,nel_solid
        do ipol=0,npol
           do jpol=0,npol
              call compute_coordinates(s,z,r,theta,ielsolid(iel),ipol,jpol)
              if ( tmpsolfield(ipol,jpol,iel) >= 0.) then 
              bdrycount=bdrycount+1
!              write(109,110)iel,r,asin(s/r)*180./pi,tmpsolfield(iel,ipol,jpol)
              endif
           enddo
        enddo
     enddo
!  call flush(109)
!  close(109)

!110 format(i4,3(1pe14.3))

!\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\
if (save_large_tests) then
! write out both fields (elementally)
! whole fluid
  open(unit=111,file=infopath(1:lfinfo)//'/bdrytest_flufield.dat'//appmynum)
  do iel=1,nel_fluid
    call compute_coordinates(s,z,r,theta,ielfluid(iel),int(npol/2),int(npol/2))
    write(111,*)s, z,tmpflufield(int(npol/2),int(npol/2),iel)
  enddo
  close(111)

! whole solid
  open(unit=112,file=infopath(1:lfinfo)//'/bdrytest_solfield.dat'//appmynum)
  do iel=1,nel_solid
    call compute_coordinates(s,z,r,theta,ielsolid(iel),int(npol/2),int(npol/2))
    write(112,*)s,z,tmpsolfield(int(npol/2),int(npol/2),iel)
  enddo
  close(112)
endif !save_large_tests

! fluid boundary elements
  open(unit=111,file=infopath(1:lfinfo)//'/bdrytest_bdryflufield.dat'//appmynum)
  do iel=1,nel_bdry
     do ipol=0,npol
     call compute_coordinates(s,z,r,theta,ielfluid(bdry_fluid_el(iel)), &
                              ipol,int(npol/2))
     write(111,*)s,z,tmpflufield(ipol,bdry_jpol_fluid(iel),bdry_fluid_el(iel))
     enddo
  enddo
  close(111)

! solid boundary elements
  open(unit=112,file=infopath(1:lfinfo)//'/bdrytest_bdrysolfield.dat'//appmynum)
  do iel=1,nel_bdry
     do ipol=0,npol
     call compute_coordinates(s,z,r,theta,ielsolid(bdry_solid_el(iel)), &
                             ipol,int(npol/2))
     write(112,*)s,z,tmpsolfield(ipol,bdry_jpol_solid(iel),bdry_solid_el(iel))
     enddo
  enddo
  close(112)
!/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/_/

  if (bdrycount .ne. nel_bdry*(npol+1) ) then
     write(6,*)
     write(6,*)procstrg,'!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
     write(6,*)procstrg,'E R R O R at S/F boundary copying!'
     write(6,*)procstrg,'expected # bdry points        :',nel_bdry*(npol+1)
     write(6,*)procstrg,'actually copied # bdry points :',bdrycount
     write(6,*)procstrg,'...see file bdrytest_solflubdry.dat for details...'
     stop
  endif

  deallocate(tmpsolfield)
  deallocate(tmpflufield)

end subroutine check_solid_fluid_boundaries
!=============================================================================

!-----------------------------------------------------------------------------
subroutine compute_valence
!
! Valence: a global field that assumes those values that denote the number 
!          of elements that share that point. All interior points 
!          0<ipol<npol have valence 1, and the maximum value for our mesh is 6.
! This routines does not "check" as in exiting in any sense but merely dumps 
! the fields for the solid & fluid subdomains. If visually reasonable, it 
! indicates that global numbering and associated mapping is done properly.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

use commun
use meshes_io
include "mesh_params.h"

real(kind=realkind), dimension(:,:,:), allocatable :: val_solid
real(kind=realkind), dimension(:,:,:), allocatable :: val_fluid
character(len=80) :: fname

  allocate(val_solid(0:npol,0:npol,1:nel_solid))
  allocate(val_fluid(0:npol,0:npol,1:nel_fluid))

  fname = 'valence_solid'
  val_solid(:,:,:) = 1.0;
  call comm2d(val_solid,nel_solid,1,'solid')
  call fldout_cyl2(fname,nel_solid,val_solid,0,npol,0,npol,0,'solid')

  fname = 'valence_fluid'
  val_fluid(:,:,:) = 1.0;
  call comm2d(val_fluid,nel_fluid,1,'fluid')
  call fldout_cyl2(fname,nel_fluid,val_fluid,0,npol,0,npol,0,'fluid')

  deallocate(val_solid)
  deallocate(val_fluid)

end subroutine compute_valence
!=============================================================================

!-----------------------------------------------------------------------------
subroutine compute_hmin_meri(hmin)
!
! This routine returns the smallest grid-spacing
! between two neighbouring points in the meridional plane.
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

include 'mesh_params.h'

double precision :: hmin
real(kind=realkind),dimension(:,:,:),allocatable :: dis1,dis2
integer :: ielem,ipol,jpol

  allocate(dis1(0:npol-1,0:npol-1,1:nelem))
  allocate(dis2(0:npol-1,0:npol-1,1:nelem))

  hmin = router 

  do ielem=1,nelem
     do ipol=0,npol-1
        do jpol=0,npol-1
           dis1(ipol,jpol,ielem) = dsqrt(&
                (scoord(ipol,jpol,ielem)-scoord(ipol+1,jpol,ielem))**2&
                +(zcoord(ipol,jpol,ielem)-zcoord(ipol+1,jpol,ielem))**2)

           dis2(ipol,jpol,ielem) = dsqrt(&
                (scoord(ipol,jpol,ielem)-scoord(ipol,jpol+1,ielem))**2&
                +(zcoord(ipol,jpol,ielem)-zcoord(ipol,jpol+1,ielem))**2)
        enddo
     enddo
  enddo

  hmin=min(hmin,minval(dble(dis1)),minval(dble(dis2)))

  deallocate(dis1)
  deallocate(dis2)

end subroutine compute_hmin_meri
!=============================================================================

!-----------------------------------------------------------------------------
SUBROUTINE BSORT2(LIST,N)
!
! Inverse bubble sort routine adapted from Ratzer's F90,C and Algorithms:
! http://www.cs.mcgill.ca/~ratzer/progs15_3.html
!
!-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

IMPLICIT NONE
INTEGER :: K,I,LAST,TEMP1
double precision, INTENT(IN OUT) :: LIST(:)
INTEGER, INTENT(IN) :: N
INTEGER:: NSWAP
INTEGER:: NCOMP

  NCOMP=0
  NSWAP=0
  LAST=N-1
  L1:   DO
     K=0
     L2:      DO I=1,LAST
        NCOMP=NCOMP+1
!        IF(LIST(I) > LIST(I+1))THEN
        IF(LIST(I) < LIST(I+1))THEN
           TEMP1=LIST(I)
           LIST(I)=LIST(I+1)
           LIST(I+1)=TEMP1
           NSWAP=NSWAP+1
           K=I  ! Remember swap location
        END IF
     END DO L2
     LAST=K
     IF(K == 0) EXIT  ! No more swaps
  END DO L1

END SUBROUTINE BSORT2
!=============================================================================



!@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

!========================
end module def_grid
!========================
