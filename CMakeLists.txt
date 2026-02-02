cmake_minimum_required(VERSION 3.10)
message(STATUS "CMake Version ${CMAKE_MAJOR_VERSION}.${CMAKE_MINOR_VERSION}.${CMAKE_PATCH_VERSION}")

### This file provides performs the setup for chosen dual-pipeline Vicuna configurations and provides paths to all RTL source files ###

########################
# Arguments
#
# INPUTS - to be defined by user
#
# RISCV_ARCH   : Select the processor architecture configuration.  Used to select the pipeline configuration defined config.mk.
# VREG_W       : Width(bits) of vector registers.
# VMEM_W       : Width(bits) of pipeline containing VLSU
# VLANE_W      : Width(bits) of pipeline containing all other functional units
#
# OUTPUTS - to be used to include Vicuna
#
# VICUNA_SRCS  : All source files for chosen configuration of Vicuna
# VICUNA_INCS  : All include directory paths for chosen configuration of Vicuna
# VICUNA_FLAGS : All preprocessor directive flags for chosen configuration of Vicuna
#
##########




#Currently Supported: rv32im_zve32x, rv32imf_zve32f, rv32imf_zfh_zve32f_zvfh
#Defaults are overwritten with user configurations defined on command line
set(RISCV_ARCH rv32im_zve32x CACHE STRING "Specify the configuration")
set(VREG_W 128 CACHE STRING "VREG_W")
set(VMEM_W 32 CACHE STRING "VMEM_W")
set(VLANE_W 32 CACHE STRING "VLANE_W")

##############
# Configuration Selection
##############
    
if(${RISCV_ARCH} STREQUAL "rv32im_zve32x")
    set(RISCV_ZVE32X "-DRISCV_ZVE32X" )
    set(RISCV_ZVE32F "" )
    set(RISCV_ZVFH "" )
    set(VPROC_CONFIG dual-zve32x)
    
elseif(${RISCV_ARCH} STREQUAL "rv32imf_zve32f")
    set(RISCV_ZVE32X "-DRISCV_ZVE32X" )
    set(RISCV_ZVE32F "-DRISCV_ZVE32F" )
    set(RISCV_ZVFH "" )
    set(VPROC_CONFIG dual-zve32f)
    
elseif(${RISCV_ARCH} STREQUAL "rv32imf_zfh_zve32f_zvfh") #Build CV32E40X with Vicuna (+floating point + half precision float) and FPU on the Xif interface
    set(RISCV_ZVE32X "-DRISCV_ZVE32X" )
    set(RISCV_ZVE32F "-DRISCV_ZVE32F" )
    set(RISCV_ZVFH "-DRISCV_ZVFH" )
    set(VPROC_CONFIG dual-zve32f) #pipeline configuration same as Zve32f.  VICUNA_FLAGS provides configuration for half float support

else()
    #message(FATAL_ERROR "Unsupported RISCV_ARCH selected for Vicuna Co-processor") #TODO: Scalar Selections don't need to cause a fatal error
    
endif()

# Experimental Features NOT STABLE
option(OLD_VICUNA "original vicuna configuration without early stopping for unused vector elements" ON)
option(FORCE_ALIGNED_READS "original vicuna configuration where all vector reads must be aligned with the VMEM Port" OFF)


##############
# Sources/Include Directories
##############

#Path to VICUNA sources  
set(DESIGN_RTL_DIR_VICUNA ${CMAKE_CURRENT_SOURCE_DIR}/rtl)

#Path to CVFPU sources
set(DESIGN_RTL_DIR_CVFPU ${CMAKE_CURRENT_SOURCE_DIR}/cvfpu/src)

set(DESIGN_RTL_DIR_COMMON ${CMAKE_CURRENT_SOURCE_DIR}/pulp_common_cells)


set(VICUNA_SOURCE   ${DESIGN_RTL_DIR_VICUNA}/vproc_pkg.sv                               #Vicuna sources
                    ${DESIGN_RTL_DIR_VICUNA}/../vproc_config.sv 
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_xif.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_core.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_vregpack.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_vregunpack.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_alu.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_decoder.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_dispatcher.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_div.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_div_shift_clz.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_elem.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_fpu.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_lsu.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_mul.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_mul_block.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_pending_wr.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_pipeline.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_pipeline_wrapper.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_queue.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_result.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_sld.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_unit_mux.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_unit_wrapper.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_vregfile.sv
                    ${DESIGN_RTL_DIR_VICUNA}/vproc_vreg_wr_mux.sv
                    ${DESIGN_RTL_DIR_COMMON}/src/fifo_v3.sv
                    )

set(VICUNA_INCLUDE  ${DESIGN_RTL_DIR_VICUNA}                                            #Vicuna Include Dirs
                    ${DESIGN_RTL_DIR_VICUNA}/../sva
                    ${DESIGN_RTL_DIR_COMMON}/include
                    ${DESIGN_RTL_DIR_COMMON}/src
                    )
                   
set(CVFPU_SOURCE    ${DESIGN_RTL_DIR_CVFPU}/fpnew_pkg.sv
                    ${DESIGN_RTL_DIR_CVFPU}/common_cells/src/cf_math_pkg.sv             #CVFPU Sources
                    ${DESIGN_RTL_DIR_CVFPU}/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_top.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_cast_multi.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_classifier.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_divsqrt_multi.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_divsqrt_th_32.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_divsqrt_th_64_multi.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_fma.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_fma_multi.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_noncomp.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_opgroup_block.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_opgroup_fmt_slice.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_opgroup_multifmt_slice.sv
                    ${DESIGN_RTL_DIR_CVFPU}/fpnew_rounding.sv
                    ${DESIGN_RTL_DIR_CVFPU}/common_cells/src/stream_fifo.sv     #TODO: CVFPU uses an older version of PULP common cells.  This may cause an issue
                    ${DESIGN_RTL_DIR_CVFPU}/common_cells/src/lzc.sv
                    ${DESIGN_RTL_DIR_CVFPU}/common_cells/src/rr_arb_tree.sv
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ctrl.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_double.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_ff1.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_pack.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_prepare.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_round.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_scalar_dp.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_bound_table.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_srt_radix16_with_sqrt.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl/ct_vfdsu_top.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v
                    #${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v
                    )
                    


set(CVFPU_INCLUDE   ${DESIGN_RTL_DIR_CVFPU}
                    ${DESIGN_RTL_DIR_CVFPU}/fpu_div_sqrt_mvp/hdl
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/vfdsu/rtl
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/openc910/C910_RTL_FACTORY/gen_rtl/clk/rtl
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl
                    ${DESIGN_RTL_DIR_CVFPU}/../vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl
                    )               
                   
                 
                   
##############
#Generate vproc_config.sv for chosen configuration.
##############
#TODO:Is there a better way to set required env variables for 'make' call to generate vproc_config.sv?
set(ENV{VPROC_CONFIG} ${VPROC_CONFIG})
set(ENV{VREG_W} ${VREG_W})
set(ENV{VMEM_W} ${VMEM_W})
set(ENV{VLANE_W} ${VLANE_W})
execute_process(COMMAND rm -f vproc_config.sv
                COMMAND make -f config.mk VPROC_CONFIG_PKG=vproc_config.sv
                WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})




##############
# Variables to be used by the project to include Vicuna
##############
set(VICUNA_FLAGS ${RISCV_ZVE32X} ${RISCV_ZVE32F} ${RISCV_ZVFH} ${FORCE_ALIGNED_READS} ${OLD_VICUNA} PARENT_SCOPE)

set(VICUNA_SRCS ${VICUNA_SOURCE} PARENT_SCOPE)
set(VICUNA_INCS ${VICUNA_INCLUDE} PARENT_SCOPE)

#Include these if FPNEW is not included elsewhere

set(VICUNA_FPU_SRCS ${CVFPU_SOURCE} PARENT_SCOPE) 
set(VICUNA_FPU_INCS ${CVFPU_INCLUDE} PARENT_SCOPE)
