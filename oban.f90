!############################# LICENSE ######################################
!
!   Copyright (C) <2010>  <David C. Dowell and Louis J. Wicker, NOAA>
!
!   This library is free software; you can redistribute it and/or
!   modify it under the terms of the GNU Lesser General Public
!   License as published by the Free Software Foundation; either
!   version 2.1 of the License, or (at your option) any later version.
!
!   This library is distributed in the hope that it will be useful,
!   but WITHOUT ANY WARRANTY; without even the implied warranty of
!   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
!   Lesser General Public License for more details.
!
!############################# LICENSE ######################################
!############################################################################
!
!     ##################################################################
!     ##################################################################
!     ######                                                      ######
!     ######                    PROGRAM OBAN                      ######
!     ######                                                      ######
!     ##################################################################
!     ##################################################################
!
!
!############################################################################
!
!     PURPOSE:
!
!     This program interpolates data from radar coordinates to an
!     unstaggered Cartesian coordinate system.  The input files should
!     be in one of the following two formats:
!     * the dorade "sweep file" format used by the solo radar-data editing package
!     * netcdf (FORAY format).
!     The output is either standard Cartesian (3D) or PPI (2D sweep-by-sweep).
!
!     inputs:
!     (1) parameter (namelist) file (e.g., oban.nml)
!     (2) radar data (dorade sweep or FORAY files)
!
!     outputs:
!     (1) oban.output
!     (2) objectively analyzed data in DART (text) format
!     (3) "                          " vis5d format
!     (4) "                          " netcdf
!     (5) beam information, in netcdf
!
!############################################################################
!
!     Original 1-pass oban code:  David Dowell, December 2001
!
!     Modifications for multipass Barnes by Penn State (see README):  Jan-April 2007
!
!     Rewrites to permit 2D multipass Barnes on sweep file
!     Restructuring to separate radar I/O from objective analysis
!     New data structure to facilitate modularity
!     FORAY input:
!                                                          Lou Wicker, Feb 2010
!
!
!     Bug fixes and modifications to work with split dBZ and Vr
!     sweeps:  Robin Tanamachi and Dan Dawson, Nov 2010
!
!     Merger of oban2d (dorade sweep file) and oban2f (FORAY) versions
!     Implementation of 3D (Cartesian) analysis
!     Incorporation of functionality from OPAWS1:
!                                                          David Dowell, Jan 2011
!
!     Removed grid-space clutter masking.  Added observation-space clutter masking.
!                                                          David Dowell, July 2011
!
!############################################################################

!
!  Run this job in background with the following command line syntax:
!
!   x.oban oban.nml >&! oban.output &
!
!   where oban.nml is the input namelist and oban.output is the printer output.
!

PROGRAM OBAN

  USE DTYPES_module
  USE OBAN_PARAMETERS
  USE OBAN_FIELDS
  USE OBAN_MODULE
  USE NAMELIST_MODULE
  
  implicit none

  include 'structures.inc'

  character(LEN=128), parameter :: version = "Version 2.1.1:  Updated 24 June 2013 [DCD]"

  integer i, j, k, ns, np, nf                 ! loop variables
  integer ls                                  ! length of input string

  logical, allocatable :: threshold(:,:)      ! Moved threshold array to calling program (from READSWEEP), so that subsequent calls to READSWEEP
                                              ! can access its contents
  logical reference_time_initialized

  TYPE(SWEEP_INFORMATION) :: sweep_info       ! information about individual sweeps, such as Nyquist velocity (m/s) for each field

  logical, allocatable :: cm_clutter(:,:,:)   ! .true. if (range, azimuth, elevation) bin has been determined to be contaminated by ground clutter
  integer cm_nr                               ! number of range bins for clutter mask
  real, allocatable :: cm_r(:)                ! range coordinates of bin edges (km)
  integer cm_na                               ! number of azimuth-angle bins for clutter mask
  real, allocatable :: cm_a(:)                ! azimuth angle coordinates of bin edges (deg)
  integer cm_ne                               ! number of elevation-angle bins for clutter mask
  real, allocatable :: cm_e(:)                ! elevation angle coordinates of bin edges (deg)
  real, allocatable :: cm_mean_refl(:,:,:)    ! mean reflectivity (dBZ) for (range, azimuth, elevation) bin
  type(rdat_info), dimension(maxrays) :: refl ! raw reflectivity scan, used in clutter masking
!  character(len=100) stat_file
!  character(len=20) stat_name
!  real, allocatable :: stats(:,:,:,:)

! DCD 11/26/10 adding these for possible later code updates
  real, allocatable :: min_threshold(:)      ! value below which input observations are set to missing
  real, allocatable :: max_threshold(:)      ! value above which input observations are set to missing
!
  real, allocatable :: beam_info(:,:,:)        ! beam information:
                                               !   (1) time offset (s) from central time
                                               !   (2) azimuth angle (deg)
                                               !   (3) elevation angle (deg)
  integer, allocatable :: num_beams(:)         ! number of beams in each sweep
  character(len=128) beam_info_file            ! name of netcdf file containing beam information
  parameter(beam_info_file = 'beam_info.nc')

  character(len=128) path                      ! path name (e.g., '/data/swp*DOW2*') of sweep files to be read in
  character(len=128) infile                    ! input parameter file name
  character(len=128) sfname0                   ! sweep file name temp variable
  character(len=128) command                   ! command to be executed at unix command line
  integer status                               ! status flag returned from unix command

  integer indx, iargc
  integer index, system, iostat

  integer, parameter ::   lunr = 10      


!############################################################################
! DEBUG FLAG:  USE this to turn on extra output


  logical, parameter :: debug = .false.

!############################################################################
! Store the radar observations in this derived type

  TYPE(VOLUME) :: vol

!############################################################################
! Store the objective analysis in this derived type

  TYPE(ANALYSISGRID) :: anal

!############################################################################
!
!     Read the input parameters, and allocate space for data.
!

  write(6,*)

  indx = iargc( )

  write(6,'("PROGRAM OBAN:  running version ",a)') version

  IF ( indx .eq. 1 ) THEN
  
    call getarg ( 1, infile )
    write(6,'("PROGRAM OBAN:  Namelist/Input file: ",a)') infile
    write(6,*)

  ELSE
  
    write(6,*) 'If nothing happens, remember to use x.oban oban.in on the command line '
 
  ENDIF

!
! Read in the namelist input data
!

  IF( .not. READ_NAMELIST(infile,'PARAMETERS') .or. & 
      .not. READ_NAMELIST(infile,'FIELDS')            ) THEN
   print *, 'OBAN:  PROBLEM READING NAMELIST'
   stop
  ELSE
   CALL WRITE_NAMELISTS(6)
   CALL VERIFY_NAMELISTS(6)
  ENDIF

! Logical for various types of sweepfile input

  IF (nswp.eq.-1) THEN

    open(unit=lunr,file=infile,status='old')

! Added code here to skip over the namelists and get to the raw ascii input at bottom of file

    file_search_loop1: DO WHILE (.true.)
      read(lunr,*) path
      if( path(1:6) .eq. "======") exit
    ENDDO file_search_loop1

! Now do what we normally do

    read(lunr,*) path
    ls = index(path, ' ') - 1
    write(command,'(A,A,A)') 'ls -1 ',path(1:ls),' > sweep_file_list.txt'
    write(6,'(a,a)') 'command = ', command
    status = system(command)
    IF (status.ne.0) THEN
      write(6,*) 'PROGRAM OBAN:  Unable to execute: ', command
      stop
    ENDIF
    close(lunr)

    open(unit=11, file='sweep_file_list.txt', status='old')     ! count number of sweep files
    nswp = 0
! DCD 11/23/10
    iostat = 0
    DO WHILE (iostat == 0 ) 
      read(11,*,iostat=iostat) sfname0
      nswp = nswp + 1
    ENDDO
    close(11)
    nswp = nswp - 1

    allocate(vol%filename(nswp))
    
    open(unit=11, file='sweep_file_list.txt', status='old')     ! read sweep file names
    DO ns = 1,nswp
      read(11,'(A)',end=12) vol%filename(ns)
      write(6,FMT='(2x,"SWP filename:  ",i3.3,1x,a)') ns, trim(vol%filename(ns))
    ENDDO

12  CONTINUE

    close(11)

  ELSE

    allocate(vol%filename(nswp))

! Added code here to skip over the namelists and get to the raw ascii input at bottom of file

    open(unit=lunr,file=infile,status='old')
    file_search_loop2: DO WHILE (.true.)
      read(lunr,*) path
      if( path(1:6) .eq. "======") exit
    ENDDO file_search_loop2

! Now do what we normally do
    
    DO ns = 1,nswp
      read(lunr,'(A)') vol%filename(ns)
      write(6,FMT='("SWP filename:  ",i3.3,1x,a)') ns, trim(vol%filename(ns))
    ENDDO
    close(lunr)

  ENDIF
  
  write(6,*)

  allocate(sweep_info%Nyquist_vel(nfld,nswp))
  allocate(sweep_info%year(nswp))
  allocate(sweep_info%month(nswp))
  allocate(sweep_info%day(nswp))
  allocate(sweep_info%hour(nswp))
  allocate(sweep_info%minute(nswp))
  allocate(sweep_info%second(nswp))
  sweep_info%Nyquist_vel(:,:) = 0.0

! If this is a 2D analysis (on a sweep surface), set the vertical levels to number of sweeps
  if (analysis_type .eq. 2) nz = nswp

! dz means nothing currently, but vis5d dump needs non-zero value
! DCD 12/9/10  a default value of dz is now set in the OBAN_PARAMETERS module
!  dz = 1.0
      
! Allocate the space for the fields to be read in

  allocate(vol%sweep%field(nfld))

! Printing info

  write(6,*) 'rlon = ', rlon
  write(6,*) 'rlat = ', rlat
  write(6,*) 'ralt = ', ralt
  write(6,*) 'glon = ', glon
  write(6,*) 'glat = ', glat
  write(6,*) 'galt = ', galt
  write(6,*) 'map_proj = ', map_proj
  if (map_proj .eq. 2) then
    write(6,*) 'tlat1 = ', tlat1
    write(6,*) 'tlat2 = ', tlat2
    write(6,*) 'clon = ', clon
  endif
  write(6,*) 'nx = ', nx
  write(6,*) 'ny = ', ny
  write(6,*) 'nz = ', nz
  write(6,*) 'dx = ', dx
  write(6,*) 'dy = ', dy
  write(6,*) 'dz = ', dz
  write(6,*) 'xmin = ', xmin
  write(6,*) 'ymin = ', ymin
  write(6,*) 'zmin = ', zmin
  write(6,*) 'cyr = ', cyr
  write(6,*) 'cmo = ', cmo
  write(6,*) 'cda = ', cda
  write(6,*) 'chr = ', chr
  write(6,*) 'cmn = ', cmn
  write(6,*) 'cse = ', cse
  write(6,*) 'ut = ', ut
  write(6,*) 'vt = ', vt
  
  DO nf = 1,nfld
    vol%sweep%field(nf)%name = fieldnames(nf)
    write(6,*) 'Field name = ',  vol%sweep%field(nf)%name
    write(6,*) 'Fill_Flag  = ',  fill_flag(nf)
    write(6,*) 'Fill_Value = ',  fill_value(nf)
    write(6,*) 'Unfold_Flag = ',  unfold_flag(nf)
    write(6,*) 'pre  oban filter flag:   ', pre_oban_filter_flag(nf)
    write(6,*) 'pre  oban filter value:  ', pre_oban_filter_value(nf)
    write(6,*) 'post oban filter flag:   ', post_oban_filter_flag(nf)
    write(6,*) 'post oban filter value:  ', post_oban_filter_value(nf)
  ENDDO
  
  if (analysis_type .eq. 1) write(6,*) 'Analysis type = 1 (3D Cartesian)'
  if (analysis_type .eq. 2) write(6,*) 'Analysis type = 2 (2D sweep by sweep)'
  if (method .eq. 1) then
    write(6,*) 'Interpolation method = 1 (Cressman)'
    write(6,*) 'Horizontal radius of influence (km) = ', hsp0
    if (analysis_type .eq. 1) write(6,*) 'Vertical radius of influence (km) = ', vsp0
  endif
  if (method .eq. 2) then
    write(6,*) 'Interpolation method = 2 (Barnes)'
    write(6,*) 'Horizontal smoothing parameter (km**2) = ', hsp0
    if (analysis_type .eq. 1) write(6,*) 'Vertical smoothing parameter (km**2) = ', vsp0
    write(6,*) 'gamma = ',gamma
    write(6,*) 'npass = ',npass
  endif
  
  write(6,*)
  write(6,*) 'Parameters for Steiner and Smith (2002) clutter removal:'
  write(6,*) 'remove_gc_refl_thresh, refl_thresh = ', remove_gc_refl_thresh, refl_thresh
  write(6,*) 'remove_gc_echo_top, refl_thresh = ', remove_gc_echo_top, refl_thresh
  write(6,*) 'remove_gc_spin_change, refl_fluc = ', remove_gc_spin_change, refl_fluc
  write(6,*) 'remove_gc_vert_grad, grad_thresh = ', remove_gc_vert_grad, grad_thresh
  IF (remove_gc_refl_thresh .or. remove_gc_echo_top .or. remove_gc_spin_change .or. remove_gc_vert_grad) THEN
    write(6,*) 'Sorry, the Steiner and Smith (2002) algorithm has not been implemented yet.  Aborting.'
    stop
  ENDIF

  write(6,*)
  write(6,*) 'Parameters for clutter mask:'
  write(6,*) 'cm_use_clutter_mask = ', cm_use_clutter_mask
  if (cm_use_clutter_mask) then
    write(6,*) 'cm_min_fixed_clutter_freq = ', cm_min_fixed_clutter_freq
    write(6,*) 'cm_min_moving_clutter_freq = ', cm_min_moving_clutter_freq
    write(6,*) 'cm_halo = ', cm_halo
    write(6,*) 'cm_use_refl_test = ', cm_use_refl_test
    write(6,*) 'cm_refl_fname = ', cm_refl_fname
    write(6,*) 'cm_refl_exceedance = ', cm_refl_exceedance
    write(6,*) 'cm_min_obs = ', cm_min_obs
    write(6,*) 'cm_min_sweeps = ', cm_min_sweeps
    write(6,*) 'cm_ncfile = ', cm_ncfile
  endif

  write(6,*)
  write(6,*) 'allow_extrapolation = ', allow_extrapolation
  write(6,*) 'append_eval = ', append_eval
  write(6,*) 'use_clear_air_type = ', use_clear_air_type
  write(6,*) 'clear_air_skip = ', clear_air_skip
  write(6,*) 'height_max = ', height_max
  write(6,*) 'mincount = ', mincount
  write(6,*) 'minsum = ', minsum
  write(6,*) 'minrange = ', minrange
  write(6,*) 'offset to year = ', year_cor
  write(6,*) 'offset to day = ', day_cor
  write(6,*) 'offset to seconds = ', sec_cor
  write(6,*) 'umass_data = ', umass_data
  write(6,*) 'az_corr_flag = ', az_corr_flag
  write(6,*) 'elcor = ', elcor
  write(6,*) 'azcor = ', azcor
  if (radar_data_format .eq. 1) then
    write(6,*) 'radar_data_format = 1 (dorade sweep files)'
  else if (radar_data_format .eq. 2) then
    write(6,*) 'radar_data_format = 2 (netcdf -- FORAY / WDSS-II)'
  endif
  write(6,*) 'Number of sweep files = ', nswp

  ls = index(output_prefix, ' ') - 1

  write(6,*) 'output_beam_info = ', output_beam_info
  if (output_dart) then
    write(6,*) 'DART outfile = ', "obs_seq_"//output_prefix(1:ls)//".out"
  endif
  if (output_netcdf) then
    write(6,*) 'netCDF file  = ', output_prefix(1:ls)//".nc"
  endif
  write(6,*)

! note:  if any of the following radar location parameters has a value of r_missing, then it is initialized
!        later from the radar data in READSWEEP / READFORAY
  vol%rlat = rlat
  vol%rlon = rlon
  vol%ralt = ralt

  allocate(beam_info(maxrays,nswp,3))
  allocate(num_beams(nswp))
  beam_info(:,:,:) = sbad


!############################################################################
!
!     Create 2D/3D interpolation grid
!
!############################################################################
!

! note:  anal%rlat, anal%rlon, and anal%ralt are initialized later in READSWEEP / READFORAY

  anal%dx   = dx
  anal%dy   = dy
  anal%dz   = dz
  anal%glat = glat
  anal%glon = glon
  anal%galt = galt
  anal%map_proj = map_proj
  anal%tlat1    = tlat1
  anal%tlat2    = tlat2
  anal%clon     = clon

  allocate(anal%xg(nx))
  allocate(anal%yg(ny))
  allocate(anal%zg(nz))

  anal%xmin = xmin
  anal%ymin = ymin
  anal%zmin = zmin

  call grid_coordinates(anal%xg, nx, dx, xmin)
  call grid_coordinates(anal%yg, ny, dy, ymin)
  call grid_coordinates(anal%zg, nz, dz, zmin)

!############################################################################
!
!     Interpolate the sweep file data to a grid.
!
!############################################################################

  write(6,*) 'Now interpolating data...'
  write(6,*) 'nx    = ',nx
  write(6,*) 'ny    = ',ny
  write(6,*) 'nz    = ',nz
  write(6,*) 'nfld  = ',nfld
  write(6,*) 'gamma = ',gamma
  write(6,*) 'hsp0  = ',hsp0
  write(6,*) 'vsp0  = ',vsp0
  write(6,*) 'npass = ',npass

  allocate(anal%f(nx,ny,nz,nfld,npass))
  anal%f(:,:,:,:,:) = 0.0
  allocate(anal%az(nx,ny,nz))
  anal%az(:,:,:) = sbad       ! DCD 3/9/11 replaced 0.0 with sbad
  allocate(anal%el(nx,ny,nz))
  anal%el(:,:,:) = sbad
  allocate(anal%height(nx,ny,nz))
  anal%height(:,:,:) = sbad   ! DCD 3/9/11 replaced 0.0 with sbad     
  allocate(anal%time(nx,ny,nz))
  anal%time(:,:,:) = sbad
  allocate(anal%count(nx,ny,nz,nfld))
  anal%count(:,:,:,:) = 0
  allocate(anal%name(nfld))
  anal%name(:) = vol%sweep%field(:)%name
  allocate(anal%day(nz))
  anal%day(:) = 0
  allocate(anal%sec(nz))
  anal%sec(:) = 0
  allocate(anal%error(nfld))
  anal%error(1:nfld) = error(1:nfld)

!############################################################################
!
! Initialize a clutter mask, if requested.
!
!############################################################################

  IF (cm_use_clutter_mask) THEN
    CALL READ_NETCDF_CLUTTER_STAT_DIMS(cm_ncfile, cm_nr, cm_na, cm_ne)
    allocate(cm_clutter(cm_nr,cm_na,cm_ne))
    allocate(cm_r(cm_nr+1))
    allocate(cm_a(cm_na+1))
    allocate(cm_e(cm_ne+1))
    allocate(cm_mean_refl(cm_nr,cm_na,cm_ne))
    CALL CLUTTER_MASK(cm_nr, cm_na, cm_ne, cm_clutter, cm_r, cm_a, cm_e, cm_mean_refl,   &
                      cm_min_fixed_clutter_freq, cm_min_moving_clutter_freq,          &
                      cm_halo, cm_min_obs, cm_min_sweeps, cm_ncfile)

!    allocate(stats(cm_nr,cm_na,cm_ne,1))
!    do k=1, cm_ne
!      do j=1, cm_na
!        do i=1, cm_nr
!          if (cm_clutter(i,j,k)) then
!            stats(i,j,k,1) = 1.0
!          else
!            stats(i,j,k,1) = 0.0
!          endif
!        enddo
!      enddo
!    enddo
!    stat_file = 'clutter_mask.nc'
!    stat_name = 'clutter_mask'
!    call WRITE_NETCDF_CLUTTER_STATS(stat_file, cm_nr, cm_r, cm_na, cm_a, cm_ne, cm_e, 1, stat_name, stats)
!    deallocate(stats)

  ENDIF
  
!############################################################################
!
! Do the multi-pass objective analysis, reading in sweep data during each pass.
!
!############################################################################

  ! initialize array that will store previous reflectivity sweep during clutter masking
  DO i=1, maxrays
    refl(i)%data(:) = sbad
  ENDDO

  DO np = 1,npass
    CALL OBAN_INIT(nfld, anal, allow_extrapolation)
    reference_time_initialized = .false.
    DO ns = 1,nswp
      IF(radar_data_format .eq. 1 ) THEN
        CALL READSWEEP(ns)
      ENDIF
      IF(radar_data_format .eq. 2 ) THEN
        CALL READFORAY(ns)
      ENDIF
      CALL PROCESS_SWEEP(vol, anal, analysis_type, np, ns,                 &
                         nfld, unfold_flag, sweep_info%Nyquist_vel(1,ns),  &
                         method, gamma, hsp0, vsp0,                        &
                         allow_extrapolation,                              &
                         minsum, minrange)
    ENDDO   ! sweep loop
    CALL FINISH_ANALYSIS(vol, anal, np, nfld, allow_extrapolation, minsum)
  ENDDO  ! pass loop
  CALL OBAN_CLEANUP

!############################################################################
!
!     Eliminate gridded values that
!     (1) were determined by only a few raw observations
!     (2) exceed the maximum height.
!
!############################################################################

  write(6,*) 'Removing analyzed values with count < ', mincount
  DO nf = 1, nfld
    DO k = 1, nz
      DO j = 1, ny
        DO i = 1, nx
          IF (anal%count(i,j,k,nf).lt.mincount) then
            anal%f(i,j,k,nf,1:npass) = sbad
          ENDIF
        ENDDO
      ENDDO
    ENDDO
  ENDDO

  IF (height_max .ne. r_missing) THEN
    write(6,*) 'Removing analyzed values with height > ', height_max
    DO k = 1, nz
      DO j = 1, ny
        DO i = 1, nx
          IF ( (anal%height(i,j,k).ne.sbad) .and. (anal%height(i,j,k).gt.height_max) ) then
            anal%f(i,j,k,1:nfld,1:npass) = sbad
          ENDIF
        ENDDO
      ENDDO
    ENDDO
  ENDIF

!############################################################################
!
! Threshold other fields based on first field (nf=1) - use the final
! pass to threshold all the other passes...
!
!############################################################################

  IF( ANY(post_oban_filter_flag(:) .eq. 1) ) THEN

    write(6,*)

    DO nf = 2,nfld

      write(6,*) 'Field:  ',vol%sweep%field(nf)%name, ' being thresholded where values of:  ', &
                            vol%sweep%field(1)%name, ' are less than ', post_oban_filter_value(nf)
      DO k = 1,nz
        DO j = 1,ny
          DO i = 1,nx
            IF( anal%f(i,j,k,1,   npass) .lt. post_oban_filter_value(nf) ) THEN
                anal%f(i,j,k,nf,1:npass) = sbad
            ENDIF
          ENDDO
        ENDDO
      ENDDO

    ENDDO

  ELSE IF( ANY(post_oban_filter_flag(:) .eq. -1) ) THEN

    write(6,*)

    DO nf = 2,nfld

      write(6,*) 'Field:  ',vol%sweep%field(nf)%name, ' being thresholded where values of:  ', &
                            vol%sweep%field(1)%name, ' are greater than ', post_oban_filter_value(nf)
      DO k = 1,nz
        DO j = 1,ny
          DO i = 1,nx
            IF( anal%f(i,j,k,1,   npass) .gt. post_oban_filter_value(nf) ) THEN
                anal%f(i,j,k,nf,1:npass) = sbad
            ENDIF
          ENDDO
        ENDDO
      ENDDO

    ENDDO

  ENDIF

!############################################################################
!
!    Chop out regions where you want to combine data sets (useful with MPAR)
!
!############################################################################

  IF( remove_sector ) THEN

    DO nf = 1,nfld

      write(6,*)
      write(6,*) 'Field:  ',vol%sweep%field(nf)%name, ' is having sector removed'

      IF( remove_sector_begin .lt. remove_sector_end ) THEN

        DO k = 1,nz
          DO j = 1,ny
            DO i = 1,nx
              IF( anal%az(i,j,k) .gt. remove_sector_begin .and. &    ! Notice the .AND. here....
                  anal%az(i,j,k) .lt. remove_sector_end  ) anal%f(i,j,k,nf,1:npass) = sbad
            ENDDO
          ENDDO
        ENDDO

      ELSE  ! here we change the logic when remove_sector_end < remove_sector_begin so that we can remove the extruded area

        DO k = 1,nz
          DO j = 1,ny
            DO i = 1,nx
              IF( anal%az(i,j,k) .gt. remove_sector_begin .or. &      ! Notice the .OR. here....
                  anal%az(i,j,k) .lt. remove_sector_end  ) anal%f(i,j,k,nf,1:npass) = sbad
            ENDDO
          ENDDO
        ENDDO

      ENDIF

    ENDDO

  ENDIF

!############################################################################
!
!     Output the results.
!
!############################################################################

!
! Output beam information (NetCDF)
!
  IF (output_beam_info) THEN
    write(6,*)
    write(6,*) 'Writing beam information to netcdf file...'
    call write_beam_info(beam_info_file, nswp, num_beams, beam_info)
  ENDIF
  deallocate(beam_info)
  deallocate(num_beams)

!
! Output analysis (DART format)
!
  IF (output_dart) THEN
    write(6,*)
    write(6,*) 'Outputting data to DART file'

!   DCD 11/26/10:  temporary code; eventually input these values from from oban.nml
    allocate(min_threshold(nfld))
    min_threshold(:) = -999.9
!   note:  if use_clear_air_type is .true., then the following subroutine can modify the reflectivity analysis
    CALL DART_radar_out(output_prefix, anal, sweep_info, &
                        nfld, min_threshold, fill_flag, fill_value, append_eval, use_clear_air_type, clear_air_skip)
    deallocate(min_threshold)
  ENDIF

!
! Output analysis (NetCDF)
!
  IF (output_netcdf) THEN
    write(6,*)
    write(6,*) 'Outputting data to netCDF file'
    CALL WRITENETCDF(output_prefix, analysis_type, anal, ut, vt, int(cyr), int(cmo), int(cda), int(chr), int(cmn), int(cse))
  ENDIF
  
!
! Vis5d output 
!
  IF (output_vis5d) THEN
    write(6,*)
    write(6,*) 'V5D is dead - long live V5D.  This feature is no longer avaiable'
  ENDIF

!############################################################################
!
! Clean up your mess, children
!

  deallocate(anal%f)
  deallocate(anal%az)
  deallocate(anal%el)
  deallocate(anal%height)
  deallocate(anal%time)
  deallocate(anal%count)
  deallocate(anal%name)
  deallocate(sweep_info%Nyquist_vel)
  deallocate(sweep_info%year)
  deallocate(sweep_info%month)
  deallocate(sweep_info%day)
  deallocate(sweep_info%hour)
  deallocate(sweep_info%minute)
  deallocate(sweep_info%second)
  IF (cm_use_clutter_mask) THEN
    deallocate(cm_clutter)
    deallocate(cm_r)
    deallocate(cm_a)
    deallocate(cm_e)
    deallocate(cm_mean_refl)
  ENDIF

  write(6,*)
  write(6,*) 'PROGRAM OBAN IS FINISHED.'
  write(6,*)

CONTAINS

!############################################################################
!
!     ##################################################################
!     ######                                                      ######
!     ######             SUBROUTINE READSWEEP                     ######
!     ######                                                      ######
!     ##################################################################
!
!
!     PURPOSE:
!
!     Use the c-fortran interface built by Dowell to read from the 
!         Dorade sweep file.  This routine needs to be moved to
!         fileio.f90


  SUBROUTINE READSWEEP(s)  
    
    include 'structures.inc'
    
    integer s                       ! sweep file number
    integer n                       ! field number
    integer r                       ! ray number
    integer g                       ! gate number
    integer m                       ! observational bin counter
    real x, y, z                    ! location of gate relative to grid origin (km)
    real ti                         ! time (s) relative to central time
    real timediff_jd                ! functions used by this subroutine
    real rangekm_to_gate            ! "                               "
    integer(kind=2), parameter :: cms=0.0
    real range                      ! distance from radar to gate (km)
    real datamax, datamin
    integer(kind=8) :: storage = 0, good_gates, status
    logical, allocatable :: threshold(:,:)
    integer year, month, day, hour, minute, second
    integer(kind=4) cjd             ! central julian day
    integer find_index              ! function used by this subroutine
    integer ri, ai, ei              ! range, azimuth, and elevation indices
    logical is_clutter
    logical field_corrections_made

    ! dorade data structures    
    type(vold_info)                     :: vold
    type(radd_info)                     :: radd
    type(celv_info)                     :: celv
    type(cfac_info)                     :: cfac
    type(parm_info), dimension(maxflds) :: parm
    type(swib_info)                     :: swib
    type(ryib_info), dimension(maxrays) :: ryib
    type(asib_info), dimension(maxrays) :: asib
    type(rdat_info), dimension(maxrays) :: rdat

    ! previous reflectivity sweep, used during clutter masking
    type(rdat_info), dimension(maxrays) :: prev_refl    


      write(6,FMT='("READSWEEP IS CALLED")') 
      field_corrections_made = .false.

      write(6,FMT='("READSWEEP:  Reading from ",a)') trim(vol%filename(s))

      IF ( cm_use_clutter_mask .and. cm_use_refl_test ) THEN
        DO r=1, maxrays
          prev_refl(r)%data(:) = refl(r)%data(:)
        ENDDO
        write(6,FMT='("READING REFLECTIVITY FIELD FOR CLUTTER MASKING:  ",a8)') cm_refl_fname
        call sweepread(vol%filename(s),vold,radd,celv,cfac,parm,swib,ryib,asib,refl,cm_refl_fname)
        call check_sweep_size(radd%num_param_desc, swib%num_rays)

!       For super-res 88D data, use the previous sweep if this is a second reflectivity sweep at a duplicate elevation angle.
        IF ( (cm_refl_fname .eq. 'REF') .and. (s.gt.1) .and.                &
             (radd%unambig_range .lt. 300.0) .and. (swib%num_rays .eq. 720) ) THEN
          write(6,*) 'DUPLICATE FOUND, USING REFLECTIVITY DATA FROM PREVIOUS SWEEP'
          DO r=1, maxrays
            refl(r)%data(:) = prev_refl(r)%data(:)
          ENDDO
        ENDIF

!       For 88D, use reflectivity data from the previous sweep if the current sweep has none.
        IF ( (cm_refl_fname .eq. 'REF') .and. (swib%num_rays .eq. 0) ) THEN
          IF (s.gt.1) THEN
            write(6,*) 'NO REFLECTIVITY DATA, USING REFLECTIVITY DATA FROM PREVIOUS SWEEP'
            DO r=1, maxrays
              refl(r)%data(:) = prev_refl(r)%data(:)
            ENDDO
          ELSE
            write(6,*) 'NOTE:  NO REFLECTIVITY DATA WILL BE AVAILABLE FOR REFLECTIVITY TEST'
          ENDIF
        ENDIF

      ENDIF

      DO n = 1,nfld
        
        write(6,FMT='("READING FIELD:  ",a8)') vol%sweep%field(n)%name
        
        call sweepread(vol%filename(s),vold,radd,celv,cfac,parm,swib,ryib,asib,rdat,vol%sweep%field(n)%name)

        call check_sweep_size(radd%num_param_desc, swib%num_rays)

        write(6,FMT='(1x,"Field:  ",a8,2x,"Unambiguous Range:   ",f6.1)') vol%sweep%field(n)%name, radd%unambig_range
        write(6,FMT='(1x,"Field:  ",a8,2x,"Number of Azimuths:  ",i4)') vol%sweep%field(n)%name, swib%num_rays

!       For super-res 88D data, don't use the second reflectivity sweep at a duplicate elevation angle.

        IF ( (vol%sweep%field(n)%name .eq. 'REF') .and. (radd%unambig_range .lt. 300.0) .and. (swib%num_rays .eq. 720) ) THEN
          write(6,FMT='(1x,a)') 'NOTE:  OBAN is assuming you want to use superres and that all variables are stored in SWP file!!!!'
          write(6,FMT='(1x,a)') 'NOTE:  OBAN is assuming you want to use superres and that all variables are stored in SWP file!!!!'
          write(6,FMT='(1x,a)') 'NOTE:  See lines 865-871 in oban.f90 to change this!!!'
          write(6,FMT='(1x,a)') 'NOTE:  See lines 865-871 in oban.f90 to change this!!!'
        ENDIF

!       IF ( (vol%sweep%field(n)%name .eq. 'REF') .and. & (radd%unambig_range .lt. 300.0) .and. (swib%num_rays .eq. 720) ) THEN
!         write(6,*) 'DELETING REFLECTIVITY DATA at duplicate elevation angle:  ', swib%fixed_ang
!         DO r=1, swib%num_rays
!           rdat(r)%data(:) = sbad
!         ENDDO
!       ENDIF

! DCD 12/8/10
        IF (rlat .eq. r_missing) vol%rlat = radd%radar_lat
        IF (rlon .eq. r_missing) vol%rlon = radd%radar_lon
        IF (ralt .eq. r_missing) vol%ralt = radd%radar_alt

        IF ( (s.eq.1) .and. (n.eq.1) ) THEN

          write(6,*)
          write(6,*) "READSWEEP:  radar latitude (deg):     ", vol%rlat
          write(6,*) "READSWEEP:  radar longitude (deg):    ", vol%rlon
          write(6,*) "READSWEEP:  radar altitude (km MSL):  ", vol%ralt
          write(6,*)

          anal%rlat = vol%rlat
          anal%rlon = vol%rlon
          anal%ralt = vol%ralt

          CALL ll_to_xy(vol%xoffset, vol%yoffset, map_proj, dtor*tlat1, dtor*tlat2, dtor*clon, &
                        dtor*glat, dtor*glon, dtor*vol%rlat, dtor*vol%rlon)
          vol%zoffset = vol%ralt - galt

          write(6,FMT='("X-Offset of radar Lat/Lon relative to Lat/Lon coordinate of analysis grid: ",f7.2," km")') vol%xoffset
          write(6,FMT='("Y-Offset of radar Lat/Lon relative to Lat/Lon coordinate of analysis grid: ",f7.2," km")') vol%yoffset
          write(6,FMT='("Z-Offset of radar height  relative to height             of analysis grid: ",f7.2," km")') vol%zoffset
          write(6,*)

        ENDIF

        IF (swib%num_rays .gt. 0) then
          call correct_az_el(ryib, swib%num_rays, azcor, elcor, az_corr_flag)
        ENDIF

        IF (umass_data) THEN
          call correct_umass_data(swib%num_rays, ryib, celv%total_gates, rdat)
        ENDIF

! DCD 11/26/10
        IF (unfold_flag(n).eq.1) THEN
          sweep_info%Nyquist_vel(n,s) = radd%unambig_vel
        ENDIF

! Check for the number of good gates here, so that we can keep the threshold information from 
! a previous sweep, if needed

        good_gates = 0

        DO r = 1,swib%num_rays
          DO g = 1,celv%total_gates
            IF( rdat(r)%data(g) .ne. sbad ) good_gates = good_gates + 1
          ENDDO
        ENDDO

        IF( good_gates < 1 ) THEN

          write(6,*)
          write(6,FMT='(A,2x,i6)') 'READSWEEP:  Number of good gates ==  0!!  ', good_gates
          write(6,FMT='(A,2x)')    'READSWEEP:  Skipping this variable in the sweep file....'
          write(6,*)

! The field in question may still be allocated from the last sweep
! Check to see if it is.  If so, deallocate it.

          IF( allocated(vol%sweep%field(n)%ob) ) DEALLOCATE(vol%sweep%field(n)%ob)
 
          CYCLE

        ENDIF

! Delete ground clutter.
 
        IF ( cm_use_clutter_mask ) THEN

          DO g = 1,celv%total_gates

            range = rangekm_to_gate(celv, g)
            ri = find_index(range, cm_r, cm_nr+1)

            IF ( (ri.ge.1) .and. (ri.le.cm_nr) ) THEN

              DO r = 1,swib%num_rays

                IF (rdat(r)%data(g) .ne. sbad) THEN

                  is_clutter = .false.

                  ai = find_index(ryib(r)%azimuth,   cm_a, cm_na+1)
                  ei = find_index(ryib(r)%elevation, cm_e, cm_ne+1)

                  IF ( (ai.ge.1) .and. (ai.le.cm_na) .and. (ei.ge.1) .and. (ei.le.cm_ne) ) THEN
                    is_clutter = cm_clutter(ri,ai,ei)
                    IF ( cm_use_refl_test .and.                     &
                         (cm_mean_refl(ri,ai,ei) .ne. sbad) .and.   &
                         (refl(r)%data(g) .ne. sbad) .and.          &
                         (refl(r)%data(g) .ge. (cm_mean_refl(ri,ai,ei)+cm_refl_exceedance)) ) THEN
                      is_clutter = .false.
                    ENDIF
                  ENDIF

                  IF (is_clutter) rdat(r)%data(g) = sbad

                ENDIF

              ENDDO

            ENDIF      ! IF ( (ri.ge.1) .and. (ri.le.cm_nr) )

          ENDDO      ! DO g = 1,celv%total_gates

        ENDIF      ! IF ( cm_use_clutter_mask )

! DCD 1/26/11
! Fill missing data in observation space.
        IF (fill_flag(n) .eq. 1) THEN
          DO r = 1,swib%num_rays
            DO g = 1,celv%total_gates
              IF (rdat(r)%data(g) .eq. sbad) THEN
                rdat(r)%data(g) = fill_value(n)
                good_gates = good_gates + 1
              ENDIF
            ENDDO
          ENDDO
        ENDIF

! DCD 1/19/11
! modified date and time corrections so that all specified parameters (year_cor, day_cor, sec_cor) are offsets
! note:  vold%mon, vold%day, vold%hour, vold%min, and vold%sec will not be corrected since these parameters are not needed for calculations

        IF ( (year_cor .ne. 0) .or. (day_cor .ne. 0) .or. (sec_cor .ne. 0) ) THEN

          write(6,*) 
          write(6,*) "Oban input file has corrections for DATE AND TIME"
          write(6,*) "OLD DATE AND TIME"
          write(6,*) "---------------------------------------------------------"
          write(6,*) "Original year               :  ", vold%year
          write(6,*) "Original julian day of ray 1:  ", ryib(1)%julian_day
          write(6,*) "Original hour       of ray 1:  ", ryib(1)%hour
          write(6,*) "Original min        of ray 1:  ", ryib(1)%min
          write(6,*) "Original sec        of ray 1:  ", ryib(1)%sec
 
          vold%year = vold%year + year_cor
          DO r=1, swib%num_rays
            call correct_time(ryib(r)%julian_day, day_cor, ryib(r)%hour, 0, ryib(r)%min, 0, ryib(r)%sec, sec_cor)
          ENDDO

          write(6,*) 
          write(6,*) "NEW DATE AND TIME"
          write(6,*) "---------------------------------------------------------"
          write(6,*) "New year               :  ", vold%year
          write(6,*) "New julian day of ray 1:  ", ryib(1)%julian_day
          write(6,*) "New hour       of ray 1:  ", ryib(1)%hour
          write(6,*) "New min        of ray 1:  ", ryib(1)%min
          write(6,*) "New sec        of ray 1:  ", ryib(1)%sec

        ENDIF      ! IF ( (year_cor .ne. 0) .or. (day_cor .ne. 0) .or. (sec_cor .ne. 0) ) THEN

!-------------------------------------------------------------------------------
        IF (.not. field_corrections_made) THEN

          field_corrections_made = .true.

          write(6,*) 
          write(6,*) "DATE AND TIME of SWEEP ", s, ", FIELD ", n
          write(6,*) "---------------------------------------------------------"
          write(6,*) 'Year of sweep       = ', vold%year
          write(6,*) 'Julian day of sweep = ', ryib(1)%julian_day 
          write(6,*) 'Hour of sweep       = ', ryib(1)%hour 
          write(6,*) 'Minute of sweep     = ', ryib(1)%min
          write(6,*) 'Second of sweep     = ', ryib(1)%sec
          write(6,*)

          CALL SET_DATE_GREGORIAN_JD(vol%day, vol%sec, int(vold%year), int(ryib(1)%julian_day), &
                                     int(ryib(1)%hour), int(ryib(1)%min), int(ryib(1)%sec))
          CALL GET_DATE_GREGORIAN(vol%day, vol%sec, year, month, day, hour, minute, second)
          sweep_info%year(s) = year
          sweep_info%month(s) = month
          sweep_info%day(s) = day
          sweep_info%hour(s) = hour
          sweep_info%minute(s) = minute
          sweep_info%second(s) = second

          IF (.not. reference_time_initialized) THEN
            reference_time_initialized = .true.
            IF (cyr .eq. i_missing) THEN
              cyr = year
              write(6,*) "READSWEEP:  setting reference year (cyr) to ", cyr
            ENDIF
            IF (cmo .eq. i_missing) THEN
              cmo = month
              write(6,*) "READSWEEP:  setting reference month (cmo) to ", cmo
            ENDIF
            IF (cda .eq. i_missing) THEN
              cda = day
              write(6,*) "READSWEEP:  setting reference day (cda) to ", cda
            ENDIF
            IF (chr .eq. i_missing) THEN
              chr = hour
              write(6,*) "READSWEEP:  setting reference hour (chr) to ", chr
            ENDIF
            IF (cmn .eq. i_missing) THEN
              cmn = minute
              write(6,*) "READSWEEP:  setting reference minute (cmn) to ", cmn
            ENDIF
            IF (cse .eq. i_missing) THEN
              cse = second
              write(6,*) "READSWEEP:  setting reference second (cse) to ", cse
            ENDIF
          ENDIF      ! IF (.not. reference_time_initialized)

          call set_julian_day(cjd, int(cyr), int(cmo), int(cda))
 
! This is where we change the time for the sweep if the sweep is being moved in a Lagrangian framework

          IF( abs(ut) .gt. 0.01 .or. abs(vt) .gt. 0.01 )  THEN
            write(6,*)
            write(6,*) "========================WARNING==============================================="
            write(6,*)
            write(6,*) "Because input UT/VT != 0.0, the program assumes you want to reset sweep times "
            write(6,*) "   to that from the oban input file and using translation velocity to move and"
            write(6,*) "   align the individual sweeps"
            write(6,*)
            write(6,*) "========================WARNING==============================================="
            CALL SET_DATE_GREGORIAN(vol%day, vol%sec, int(cyr), int(cmo), int(cda), int(chr), int(cmn), int(cse))
          ENDIF

          write(6,*) 
          write(6,*) 'Gregorian day = ', vol%day
          write(6,*) 'Gregorian sec = ', vol%sec
          write(6,*)

! Store sweep day/sec in analysis volume data structure (needed for DART OUTPUT)
           
          anal%day(s) = vol%day
          anal%sec(s) = vol%sec

! If pre_oban_filter is on, find out where to threshold...
! DTD: Check if threshold array is allocated, and deallocate it if it is

          IF( allocated(threshold) ) DEALLOCATE(threshold)

          ALLOCATE(threshold(celv%total_gates,swib%num_rays))
          threshold(:,:) = .false.

          IF( DEBUG ) THEN
            write(6,*)
            write(6,*) 'Number of gates/rays for reflectivity',celv%total_gates,swib%num_rays  
          ENDIF

! Technically, minrange isn't a "threshold" condition, but this fix works.

          IF( minrange .gt. 0.01 ) THEN
            DO r = 1,swib%num_rays
              DO g = 1,celv%total_gates
                range = rangekm_to_gate(celv, g)
                IF( range  .lt. minrange ) threshold(g,r) = .true.
              ENDDO
            ENDDO
          ENDIF

          IF( pre_oban_filter_flag(n) .ne. 0 ) THEN

            write(6,*) 
            write(6,*) "Pre-Oban-Filter Turned ON!:"
            write(6,*) "Observation field used for filtering is:  ", vol%sweep%field(n)%name
            write(6,*) "Observation field used for filtering is:  ", vol%sweep%field(n)%name

            DO r = 1,swib%num_rays
              DO g = 1,celv%total_gates
                IF( (pre_oban_filter_flag(n) > 0 .and. rdat(r)%data(g) .lt. pre_oban_filter_value(n)) .or. &
                    (pre_oban_filter_flag(n) < 0 .and. rdat(r)%data(g) .gt. pre_oban_filter_value(n)) ) threshold(g,r) = .true.
              ENDDO
            ENDDO

          ENDIF

        ENDIF  ! ENDIF for (.not. field_corrections_made)

! Thresholding data based on n==1 threshold flags (assuming its DBZ!!!)
 
        IF( pre_oban_filter_flag(n) .ne. 0 ) THEN

          DO r = 1,swib%num_rays
            DO g = 1,celv%total_gates
              IF( threshold(g,r) ) rdat(r)%data(g)  = sbad
            ENDDO
          ENDDO

        ENDIF
            
! Allocate observation data structure space for observations in this sweep.

        IF( allocated(vol%sweep%field(n)%ob) ) deallocate(vol%sweep%field(n)%ob)
        
        ALLOCATE(vol%sweep%field(n)%ob(good_gates), stat=status)

        IF( status .ne. 0 ) THEN
          write(6,*) 
          write(6,*) "Problem, ran out of space in READSWEEP!"
          write(6,*) "NSWP = ", s
          write(6,*) "Total MBytes allocated so far:  ", float(40*storage)/1.e6
          write(6,*) "Requested storage for this sweep:  ", float(40*good_gates)/1.0e6
          write(6,*) "Sorry, have to stop program!"
          write(6,*) 
          stop
        ELSE 
          storage = storage + good_gates
          write(6,*) 
          write(6,*) "Total MBytes allocated so far:  ", float(40*storage)/1.e6
          write(6,*) 
        ENDIF

!  Reset counter for observation to zero so that the data from each sweep is stored in a 1D sequence
        
        m = 0
        datamax = -1.0e9
        datamin = 1.0e9
        
        num_beams(s) = swib%num_rays

        DO r = 1,swib%num_rays

! DCD 1/19/11
          ti = timediff_jd(ryib(r)%julian_day, ryib(r)%hour, ryib(r)%min, ryib(r)%sec, ryib(r)%msec,  &
                           cjd, chr, cmn, cse, cms)
!          ti = timediff(vold%year, vold%mon, vold%day, ryib(r)%hour, ryib(r)%min, ryib(r)%sec, ryib(r)%msec,  &
!                        cyr, cmo, cda, chr, cmn, cse, cms)

          beam_info(r,s,1) = ti
          beam_info(r,s,2) = ryib(r)%azimuth
          beam_info(r,s,3) = ryib(r)%elevation

          DO g = 1,celv%total_gates

            range = rangekm_to_gate(celv, g)

            IF (rdat(r)%data(g) .ne. sbad ) THEN
            
              m = m + 1

! Here, create x/y/z coordinates based on distance from radar

! DCD 1/26/11 difference from OPAWS1:  x, y, and z here are relative to radar, not grid origin
              call xyzloc(x, y, z, range, dtor*ryib(r)%azimuth, dtor*ryib(r)%elevation, &
                          map_proj, dtor*tlat1, dtor*tlat2, dtor*clon,                  &
                          dtor*vol%rlat, dtor*vol%rlon, vol%ralt,                       &
                          dtor*vol%rlat, dtor*vol%rlon, vol%ralt, ut, vt, ti)

              vol%sweep%field(n)%ob(m)%x        = x
              vol%sweep%field(n)%ob(m)%y        = y
              vol%sweep%field(n)%ob(m)%z        = z
              vol%sweep%field(n)%ob(m)%az       = ryib(r)%azimuth
              vol%sweep%field(n)%ob(m)%el       = ryib(r)%elevation
              vol%sweep%field(n)%ob(m)%range    = range
              vol%sweep%field(n)%ob(m)%value    = rdat(r)%data(g)
! DCD 2/8/11
              IF( abs(ut) .gt. 0.01 .or. abs(vt) .gt. 0.01 ) THEN
                vol%sweep%field(n)%ob(m)%time   = 0.0
              ELSE
                vol%sweep%field(n)%ob(m)%time   = ti
              ENDIF
              datamax                           = max(datamax, rdat(r)%data(g))
              datamin                           = min(datamin, rdat(r)%data(g))

            ENDIF       ! (rdat(r)%data(g) .ne. sbad)

          ENDDO       ! g=1, celv%total_gates
          
        ENDDO       ! r=1, swib%num_rays
        
        vol%sweep%field(n)%number_of_valid_obs = m
        vol%sweep%field(n)%obmax               = datamax
        vol%sweep%field(n)%obmin               = datamin
        vol%sweep%field(n)%el                  = sum(vol%sweep%field(n)%ob(:)%el) / m 
        vol%sweep%field(n)%time                = sum(vol%sweep%field(n)%ob(:)%time) / m

        write(6,*) "Field:  ", vol%sweep%field(n)%name, " Max: ", datamax, " Min:  ", datamin
        write(6,*) "          Number of valid observations:  ", vol%sweep%field(n)%number_of_valid_obs
        write(6,*) "Offset time of first valid observation:  ", vol%sweep%field(n)%ob(1)%time 
        write(6,*) "Offset time of last  valid observation:  ", vol%sweep%field(n)%ob(m)%time 
        write(6,*) "                         Max elevation:  ", maxval(vol%sweep%field(n)%ob(1:m)%el)
        write(6,*) "                         Min elevation:  ", minval(vol%sweep%field(n)%ob(1:m)%el)
        write(6,*) "                        Mean elevation:  ", vol%sweep%field(n)%el
        write(6,*) "                             Mean time:  ", vol%sweep%field(n)%time
        write(6,*)
        
      ENDDO       ! n = 1,nfld

  END SUBROUTINE READSWEEP


!############################################################################
!
!     ##################################################################
!     ######                                                      ######
!     ######             SUBROUTINE READFORAY                     ######
!     ######                                                      ######
!     ##################################################################
!
!
!     PURPOSE:
!
!     Use a netcdf interface to read the foray-1 file.  This routine needs to be moved to
!         fileio.f90.


  SUBROUTINE READFORAY(s)  
    
    integer              :: s                       ! sweep file number
    integer              :: n                       ! field number
    integer              :: r                       ! ray number
    integer              :: g                       ! gate number
    integer              :: m                       ! observational bin counter
    real                 :: x, y, z                 ! location of gate relative to grid origin (km)
    real                 :: ti                      ! time (s) relative to central time
    real                 :: timediff4               ! functions used by this subroutine
    real                 :: datamax, datamin
    integer(kind=8)      :: storage = 0, good_gates, offset
    logical, allocatable :: threshold(:,:)

! Store the netcdf in this derived type

    TYPE(FORAY_DATA) :: fdata

      write(6,FMT='("READFORAY IS CALLED")') 

      write(6,FMT='("READFORAY:  Reading from ",a)') trim(vol%filename(s))

      IF ( cm_use_clutter_mask ) THEN
        write(6,FMT='("CLUTTER MASKING HAS NOT BEEN IMPLEMENTED YET FOR FORAY DATA")')
        stop
      ENDIF

      DO n = 1,nfld
        
        write(6,FMT='("ACCESSING FIELD:  ",a8)') vol%sweep%field(n)%name
        
        CALL READ_FORAY(vol%filename(s), vol%sweep%field(n)%name, fdata)

! DCD 1/20/11
! READSWEEP does the following tasks but READFORAY does not.  Are any of these procedures needed here?
! * delete 88D reflectivity data at a duplicate elevation angle
! * correct_az_el
! * correct_umass_data

        IF (unfold_flag(n).eq.1) THEN
          sweep_info%Nyquist_vel(n,s) = fdata%Nyquist_Velocity
        ENDIF

! DCD 1/20/11
! modified date and time corrections so that all specified parameters (year_cor, day_cor, sec_cor) are offsets

        IF ( (year_cor .ne. 0) .or. (day_cor .ne. 0) .or. (sec_cor .ne. 0) ) THEN

          write(6,*)
          write(6,*) "Oban input file has corrections for DATE AND TIME"
          write(6,*) "OLD DATE AND TIME"
          write(6,*) "---------------------------------------------------------"
          write(6,*) "Original year:   ", fdata%year
          write(6,*) "Original month:  ", fdata%month
          write(6,*) "Original day:    ", fdata%day
          write(6,*) "Original hour of ray(1):  ", fdata%hour
          write(6,*) "Original min  of ray(1):  ", fdata%minute
          write(6,*) "Original sec  of ray(1):  ", fdata%second

          fdata%year = fdata%year + year_cor
          offset = sec_cor + day_cor * 86400
          CALL ADJUST_DATE(fdata%year, fdata%month, fdata%day, fdata%hour, fdata%minute, fdata%second, offset)

          write(6,*)
          write(6,*) "NEW DATE AND TIME"
          write(6,*) "---------------------------------------------------------"
          write(6,*) "New year:   ", fdata%year
          write(6,*) "New month:  ", fdata%month
          write(6,*) "New day:    ", fdata%day
          write(6,*) "New hour of ray(1):  ", fdata%hour
          write(6,*) "New min  of ray(1):  ", fdata%minute
          write(6,*) "New sec  of ray(1):  ", fdata%second

        ENDIF

!-------------------------------------------------------------------------------
        IF( n .eq. 1 ) THEN

          write(6,*)
          write(6,*) "DATE AND TIME of N == 1 SWEEP"
          write(6,*) "---------------------------------------------------------"
          write(6,*) 'Year of sweep   = ', fdata%year
          write(6,*) 'Month of sweep  = ', fdata%month
          write(6,*) 'Day of sweep    = ', fdata%day 
          write(6,*) 'Hour of sweep   = ', fdata%hour 
          write(6,*) 'Minute of sweep = ', fdata%minute
          write(6,*) 'Second of sweep = ', fdata%second
          write(6,*)

          sweep_info%year(s) = fdata%year
          sweep_info%month(s) = fdata%month
          sweep_info%day(s) = fdata%day
          sweep_info%hour(s) = fdata%hour
          sweep_info%minute(s) = fdata%minute
          sweep_info%second(s) = fdata%second

          IF (s.eq.1) THEN
            IF (cyr .eq. i_missing) THEN
              cyr = fdata%year
              write(6,*) "READFORAY:  setting reference year (cyr) to ", cyr
            ENDIF
            IF (cmo .eq. i_missing) THEN
              cmo = fdata%month
              write(6,*) "READFORAY:  setting reference month (cmo) to ", cmo
            ENDIF
            IF (cda .eq. i_missing) THEN
              cda = fdata%day
              write(6,*) "READFORAY:  setting reference day (cda) to ", cda
            ENDIF
            IF (chr .eq. i_missing) THEN
              chr = fdata%hour
              write(6,*) "READFORAY:  setting reference hour (chr) to ", chr
            ENDIF
            IF (cmn .eq. i_missing) THEN
              cmn = fdata%minute
              write(6,*) "READFORAY:  setting reference minute (cmn) to ", cmn
            ENDIF
            IF (cse .eq. i_missing) THEN
              cse = fdata%second
              write(6,*) "READFORAY:  setting reference second (cse) to ", cse
            ENDIF
          ENDIF
 
! This is where we change the time for the sweep if the sweep is being moved in a Lagrangian framework
 
          IF( abs(ut) .gt. 0.01 .or. abs(vt) .gt. 0.01 )  THEN

            write(6,*) "==================================WARNING========================================="
            write(6,*)
            write(6,*) "Because input UT/VT != 0.0, the program assumes you want to reset sweep times "
            write(6,*) "   to that from the oban input file and using translation velocity to move and"
            write(6,*) "   align the individual sweeps"
            write(6,*)
            write(6,*) "==================================WARNING========================================="
            write(6,*)
            CALL SET_DATE_GREGORIAN(vol%day, vol%sec, int(cyr), int(cmo), int(cda), int(chr), int(cmn), int(cse))

          ELSE

            CALL SET_DATE_GREGORIAN(vol%day, vol%sec, fdata%year, fdata%month,  fdata%day, &
                                                      fdata%hour, fdata%minute, fdata%second)
          ENDIF

! Store sweep day/sec in analysis and volume data structure (needed for DART OUTPUT)
           
          write(6,*) 
          write(6,*) 'Gregorian day = ', vol%day
          write(6,*) 'Gregorian sec = ', vol%sec

          anal%day(s) = vol%day
          anal%sec(s) = vol%sec

! DCD 12/8/10
          IF (rlat .eq. r_missing) vol%rlat = fdata%latitude
          IF (rlon .eq. r_missing) vol%rlon = fdata%longitude
          IF (ralt .eq. r_missing) vol%ralt = fdata%height

          vol%missing = sbad

          IF ( (s.eq.1) .and. (n.eq.1) ) THEN

            write(6,*)
            write(6,*) "READFORAY:  radar latitude (deg):     ", vol%rlat
            write(6,*) "READFORAY:  radar longitude (deg):    ", vol%rlon
            write(6,*) "READFORAY:  radar altitude (km MSL):  ", vol%ralt
            write(6,*)

            anal%rlat = vol%rlat
            anal%rlon = vol%rlon
            anal%ralt = vol%ralt

            CALL ll_to_xy(vol%xoffset, vol%yoffset, map_proj, dtor*tlat1, dtor*tlat2, dtor*clon, &
                          dtor*glat, dtor*glon, dtor*vol%rlat, dtor*vol%rlon)
            vol%zoffset = vol%ralt - galt

            write(6,FMT='("X-Offset of radar Lat/Lon relative to Lat/Lon coordinate of analysis grid: ",f7.2," km")') vol%xoffset
            write(6,FMT='("Y-Offset of radar Lat/Lon relative to Lat/Lon coordinate of analysis grid: ",f7.2," km")') vol%yoffset
            write(6,FMT='("Z-Offset of radar height  relative to height             of analysis grid: ",f7.2," km")') vol%zoffset
            write(6,*)

          ENDIF

! If pre_oban_filter is on, find out where to threshold...
! DTD: Check if threshold array is allocated, and deallocate it if it is

          IF( allocated(threshold) ) DEALLOCATE(threshold)

          allocate(threshold(fdata%ngates,fdata%nazimuths))
          threshold(:,:) = .false.

! DCD 11/26/10
! Technically, minrange isn't a "threshold" condition, but this fix works.

          IF( minrange .gt. 0.01 ) THEN
            DO r = 1,fdata%nazimuths
              DO g = 1,fdata%ngates
                IF( fdata%range(g) .lt. minrange ) threshold(g,r) = .true.
              ENDDO
            ENDDO
          ENDIF

! DCD 11/26/10
          IF( pre_oban_filter_flag(n) .ne. 0 ) THEN

            write(6,*) 
            write(6,*) "Pre-Oban-Filter Turned ON!:"
            write(6,*) "Observation field used for filtering is:  ", vol%sweep%field(n)%name
            write(6,*) "Observation field used for filtering is:  ", vol%sweep%field(n)%name

            DO r = 1,fdata%nazimuths
              DO g = 1,fdata%ngates
! DCD 11/26/10
                IF( (pre_oban_filter_flag(n) > 0 .and. fdata%field(g,r) .lt. pre_oban_filter_value(n)) .or. &
                    (pre_oban_filter_flag(n) < 0 .and. fdata%field(g,r) .gt. pre_oban_filter_value(n)) ) threshold(g,r) = .true.
              ENDDO
            ENDDO

          ENDIF

        ENDIF  ! ENDIF for ( n .eq. 1 ) condition

! Thresholding data based on n==1 threshold flags

! DCD 11/26/10 
        IF( pre_oban_filter_flag(n) .ne. 0 ) THEN

          DO r = 1,fdata%nazimuths
            DO g = 1,fdata%ngates
              IF( threshold(g,r) ) fdata%field(g,r) = sbad
            ENDDO
          ENDDO

        ENDIF

! Now find how many gates are actually good.....

         good_gates = 0
 
         DO r = 1,fdata%nazimuths
           DO g = 1,fdata%ngates
             IF( fdata%field(g,r) .ne. sbad ) good_gates = good_gates + 1
           ENDDO
         ENDDO

         IF( good_gates < 1 ) THEN
 
          write(6,*)
          write(6,FMT='(A,2x,i6)') 'READFORAY:  Number of good gates ==  0!!  ', good_gates
          write(6,FMT='(A,2x)')    'READFORAY:  Skipping this variable in the sweep file....'
          write(6,*)

! The field in question may still be allocated from the last sweep
! Check to see if it is.  If so, deallocate it.

          IF( allocated(vol%sweep%field(n)%ob) ) DEALLOCATE(vol%sweep%field(n)%ob)
 
          CYCLE
 
         ENDIF

! DCD 1/26/11
! Fill missing data in observation space.
        IF (fill_flag(n) .eq. 1) THEN
          DO r = 1,fdata%nazimuths
            DO g = 1,fdata%ngates
              IF (fdata%field(g,r) .eq. sbad) THEN
                fdata%field(g,r) = fill_value(n)
                good_gates = good_gates + 1
              ENDIF
            ENDDO
          ENDDO
        ENDIF
             
! Allocate data space for observations in this sweep.

        IF( allocated(vol%sweep%field(n)%ob) ) deallocate(vol%sweep%field(n)%ob)

        allocate(vol%sweep%field(n)%ob(good_gates), stat=status)

        IF( status .ne. 0 ) THEN
          write(6,*) 
          write(6,*) "Problem, ran out of space in READFORAY!"
          write(6,*) "NSWP = ", s
          write(6,*) "Total MBytes allocated so far:  ", float(40*storage)/1.e6
          write(6,*) "Requested storage for this sweep:  ", float(40*good_gates)/1.0e6
          write(6,*) "Sorry, have to stop program!"
          write(6,*) 
          stop
        ELSE 
          storage = storage + good_gates
          write(6,*) 
          write(6,*) "Total MBytes allocated so far:  ", float(40*storage)/1.e6
          write(6,*) 
        ENDIF
 
!  Reset counter for observation to zero so that the data from each sweep is stored in a 1D sequence
         
         m = 0
         datamax = -1.0e9
         datamin =  1.0e9

         num_beams(s) = fdata%nazimuths

         DO r = 1,fdata%nazimuths
 
! DCD 1/20/11  replaced 0.0 with 0 twice in the following command
           ti = timediff4(fdata%year, fdata%month, fdata%day, fdata%hour, fdata%minute, fdata%second, 0,  &
                          int(cyr),   int(cmo),    int(cda),  int(chr),   int(cmn),     int(cse),     0)

           beam_info(r,s,1) = ti
           beam_info(r,s,2) = fdata%az(r)
           beam_info(r,s,3) = fdata%el(r)

           DO g = 1,fdata%ngates
 
             IF( fdata%field(g,r) .ne. sbad ) THEN
             
               m = m + 1
 
! Here, create x/y/z coordinates based on distance from radar
 
! DCD 1/26/11 difference from OPAWS1:  x, y, and z here are relative to radar, not grid origin
               call xyzloc(x, y, z, fdata%range(g), dtor*fdata%az(r), dtor*fdata%el(r), &
                           map_proj, dtor*tlat1, dtor*tlat2, dtor*clon,                 &
                           dtor*vol%rlat, dtor*vol%rlon, vol%ralt,                      &
                           dtor*vol%rlat, dtor*vol%rlon, vol%ralt, ut, vt, ti)

               vol%sweep%field(n)%ob(m)%x        = x
               vol%sweep%field(n)%ob(m)%y        = y
               vol%sweep%field(n)%ob(m)%z        = z
               vol%sweep%field(n)%ob(m)%az       = fdata%az(r)
               vol%sweep%field(n)%ob(m)%el       = fdata%el(r)
               vol%sweep%field(n)%ob(m)%range    = fdata%range(g)
               vol%sweep%field(n)%ob(m)%value    = fdata%field(g,r)
! DCD 2/8/11
               IF( abs(ut) .gt. 0.01 .or. abs(vt) .gt. 0.01 ) THEN
                 vol%sweep%field(n)%ob(m)%time   = 0.0
               ELSE
                 vol%sweep%field(n)%ob(m)%time   = ti
               ENDIF
               datamax                           = max(datamax, fdata%field(g,r))
               datamin                           = min(datamin, fdata%field(g,r))
 
             ENDIF       ! (fdata%field(g,r) .ne. sbad)
 
           ENDDO       ! g = 1,fdata%ngates
           
         ENDDO       ! r = 1,fdata%nazimuths
         
         vol%sweep%field(n)%number_of_valid_obs = m
         vol%sweep%field(n)%obmax               = datamax
         vol%sweep%field(n)%obmin               = datamin
         vol%sweep%field(n)%el                  = sum(vol%sweep%field(n)%ob(1:m)%el) / float(m)
         vol%sweep%field(n)%time                = sum(vol%sweep%field(n)%ob(1:m)%time) / float(m)
         
         write(6,*) "Field:  ", vol%sweep%field(n)%name, " Max: ", datamax, " Min:  ", datamin
         write(6,*) "Number of valid observations:  ",           vol%sweep%field(n)%number_of_valid_obs
         write(6,*) "Offset time of first valid observation:  ", vol%sweep%field(n)%ob(1)%time 
         write(6,*) "Offset time of last  valid observation:  ", vol%sweep%field(n)%ob(m)%time 
         write(6,*) "Max elevation:  ", maxval(vol%sweep%field(n)%ob(1:m)%el)
         write(6,*) "Min elevation:  ", minval(vol%sweep%field(n)%ob(1:m)%el)
         write(6,*) "Mean elevation: ", vol%sweep%field(n)%el
         write(6,*) "Mean time     : ", vol%sweep%field(n)%time
         write(6,*)
       
       ENDDO       ! n = 1,nfld

      deallocate(threshold)

  END SUBROUTINE READFORAY

END PROGRAM OBAN

SUBROUTINE READ_FORAY(filename, field_name, fdata)

  USE NETCDF
  USE DTYPES_module
                                                      
  implicit none 

! Store the netcdf in this derived type

  TYPE(FORAY_DATA) :: fdata
  
  
! name of netcdf file to read in

  character(len=*)   :: filename, field_name

! local variables

! DCD 12/9/10  removed unused variables attrnum, cell_spacing_method, count, start, dbz_id, dr, g_id, vr_id, len, length, xtype

  integer            :: ncid, az_id, varid
  integer            :: el_id, ti_id
  integer            :: status
  integer            :: n
  
  integer, parameter :: NDIMS   = 2
  
  character (len = 255) :: instrument_name
  
  character (len = *), parameter :: AZ_DIM   = "Azimuth"
  character (len = *), parameter :: AZ_NAME  = "Azimuth"
  character (len = *), parameter :: EL_NAME  = "Elevation"
  character (len = *), parameter :: GATE_DIM = "Gate"
  character (len = *), parameter :: GATE_NAME= "GateWidth"
  character (len = *), parameter :: TIM_NAME = "time_offset"
  character (len = *), parameter :: DBZ_NAME = "REF"
  character (len = *), parameter :: VR_NAME  = "VEL"
  
  integer   :: az_dimid, g_dimid
  integer   :: naz, ngates, cell_space_method
  integer(kind=8) :: int_volume_start_time
  integer   :: r, g, slen
  real      :: range_to_first_cell, datamin, datamax, elevation, nyquist, volume_start_time
  real(kind=4), allocatable :: field(:,:), gatewidth(:)

  character (len = 255) :: name

!-----------------------------------------------------------------------
!
! write(6,*) filename
!
!-----------------------------------------------------------------------
!  Open netCDF file 

  slen = len(trim(filename))
  filename = filename(slen-21:slen)
  print *, 'Total len of filename string:  ', slen, 'Trucated FILENAME: ', filename
  
  status = NF90_OPEN(trim(filename), nf90_nowrite, ncid)
  
  IF (status /= NF90_NOERR) then
    write(6,*) 'WRITE_main:  PROBLEM OPENING NETCDF FILE ', NF90_STRERROR(status)
    write(6,*) 'WRITE_main:  Filename = ', filename
    write(6,*) 'WRITE_main:  NCID = ', ncid
  ENDIF
  
  call check( nf90_get_att(ncid, nf90_global, "Time", volume_start_time), message='Vol_Start_Time' )

! Get field variable missing attribute

  call check( nf90_get_att(ncid,nf90_global,"MissingData",fdata%missing), message='Getting '//field_name//' missing value') 

! Get elevation for cfsweep

  call check( nf90_get_att(ncid,nf90_global,"Elevation",elevation), message='Getting '//field_name//' elevation value') 
  
! Radar lat long  height range2FirstCell

  call check( nf90_get_att(ncid, nf90_global, "Latitude", fdata%latitude), message='Getting latitude variable') 
  call check( nf90_get_att(ncid, nf90_global, "Longitude",fdata%longitude), message='Getting longitude variable' )
  call check( nf90_get_att(ncid, nf90_global, "Height", fdata%height), message='Getting height variable'  )
  call check( nf90_get_att(ncid, nf90_global, "RangeToFirstGate", range_to_first_cell), message='Getting range to first gate attr')
 
  read(filename(1:4), '(i4)') fdata%year
  read(filename(5:6), FMT='(i2)') fdata%month
  read(filename(7:8), FMT='(i2)') fdata%day
  read(filename(10:11), FMT='(i2)') fdata%hour   
  read(filename(12:13), FMT='(i2)') fdata%minute
  read(filename(14:15), FMT='(i2)') fdata%second
  
  print *, fdata%month
  print *, fdata%day
  print *, fdata%hour
  print *, fdata%minute
  print *, fdata%second
  print *, fdata%longitude
  print *, fdata%latitude
  print *, fdata%height, ' KM'

!-----
! Get the actual number of rays in the sweep

!   call check ( nf90_inq_varid(ncid, "volume_start_time", varid), message='Getting time offset varid' )
!   call check( nf90_get_var(ncid, varid, int_volume_start_time), message='Getting time offset' )
 
!-----
! Get the actual number of rays in the sweep

  call check ( nf90_inq_dimid(ncid, AZ_DIM, az_dimid),  message='Getting Azimuth dimension ID' )
  call check ( nf90_inquire_dimension(ncid, az_dimid, name, naz),  message='Getting Azimuth dimension')
  
! allocate space for aziumth variable

  IF( allocated(fdata%az) ) deallocate(fdata%az)
  allocate(fdata%az(naz))

  IF( allocated(fdata%el) ) deallocate(fdata%el)
  allocate(fdata%el(naz))

  IF( allocated(fdata%time) ) deallocate(fdata%time)
  allocate(fdata%time(naz))

  fdata%el(:)   = elevation
  fdata%az(:)   = 0.0
  fdata%time(:) = 0.0
  
! get the azimuthal data

  call check( nf90_inq_varid(ncid, AZ_name, az_id), message='Getting Azimuth var_id') 
  call check( nf90_get_var(ncid, az_id, fdata%az), message='Getting Azimuth variable' )
  
!-----
! Get range information

  call check ( nf90_inq_dimid(ncid, GATE_dim, g_dimid), message='Getting ngates var_id' )
  call check ( nf90_inquire_dimension(ncid, g_dimid, name, ngates), message='Getting ngates' )
! Nyquist velocity
  
  call check( nf90_get_att(ncid, nf90_global, "Nyquist_Vel-value", name), message='Getting Nyquist_Velocity variable'  )
  
  read(name(1:5), '(f4.2)') fdata%Nyquist_Velocity 
  print *, fdata%Nyquist_Velocity 

!  print *, 'LAT/LON/ALT', fdata%latitude, fdata%longitude, fdata%height

   fdata%nazimuths = naz
   fdata%ngates    = ngates
   fdata%name      = field_name
   print *, fdata%nazimuths, fdata%ngates, fdata%name 

! allocate space for data

  IF( allocated(field) ) deallocate(field)
  allocate(field(ngates, naz))
  field(:,:) = 0.0

  IF( allocated(fdata%field) ) deallocate(fdata%field)
  allocate(fdata%field(ngates,naz))
  fdata%field(:,:) = 0.0

  IF( allocated(fdata%range) ) deallocate(fdata%range)
  allocate(fdata%range(ngates))
  fdata%range(:) = 0.0
  allocate(gatewidth(naz))
  
! get gets

  call check( nf90_inq_varid(ncid, GATE_name, varid), message='Getting '//GATE_NAME//' var_id') 
  call check( nf90_get_var(ncid, varid, gatewidth), message='Getting '//Gate_NAME//' variable'  )

! Get field variable id and then data

  call check( nf90_inq_varid(ncid, field_name, varid), message='Getting '//field_name//' var_id') 
  call check( nf90_get_var(ncid, varid, field), message='Getting '//field_name//' variable'  )
 
! close netcdf file

  call check( nf90_close(ncid), message='Was trying to close netcdf file....')
  
! Correct the date and time for data

  CALL ADJUST_DATE(fdata%year, fdata%month, fdata%day, fdata%hour, fdata%minute, fdata%second, fdata%time(1))

! Find missing data
  datamin = 0.0
  datamax = 0.0
  DO r = 1,naz
    DO g = 1,ngates
     IF( field(g,r) <= fdata%missing ) THEN
       fdata%field(g,r) = fdata%real_missing
     ELSE
       fdata%field(g,r) = field(g,r)
     ENDIF
    ENDDO
  ENDDO

! write(6,*) filename, field_name, datamax, datamin, fdata%missing
  
! Adjust range information - range is a 1D array, so fail if its 2D...

  IF( (maxval(gatewidth) - minval(gatewidth)) > 10.0 ) THEN
     print *, 'Something werid - gate spacing is a function of azimuth - stopping'
     stop
  ELSE
    fdata%range(1) = range_to_first_cell/1000.
    DO n = 2,ngates
      fdata%range(n) = fdata%range(n-1) + gatewidth(1)/1000.
      print *, n, fdata%range(n)
    ENDDO
  ENDIF

  write(6,FMT='(1x,A,A)') "READ_FORAY:  Read in field:  ",field_name
  
CONTAINS

  SUBROUTINE CHECK(status, message, continue)
    integer, intent (in) :: status
    character(len=*), optional :: message
    logical, optional :: continue
    
    IF( status /= nf90_noerr ) THEN 
      IF( present(message) ) THEN
        write(6,*) message//"  "//trim(nf90_strerror(status))
        IF( present(continue) ) THEN
          return
        ELSE
          stop "Stopped"
        ENDIF
      ELSE
        write(6,*) trim(nf90_strerror(status))
        IF( present(continue) ) THEN
          return
        ELSE
          stop "Stopped"
        ENDIF
      ENDIF
    END IF

  END SUBROUTINE CHECK  
                                                                                                     
END SUBROUTINE READ_FORAY
