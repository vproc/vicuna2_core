# Vicuna 2.0 core

Contains the RTL for Vicuna 2.0 for inclusion in other projects.

Currently provides support for 'Zve32x', 'Zve32f' and 'Zvfh'.

## Overview

Vicuna 2.0 is an upgraded version of the original Vicuna vector co-processor targeting low-cost embedded devices.  It is attached to a main core using the Core V eXtension Interface (CV-X-IF).  Most parameters of the vector unit are configurable, allowing users to define and simulate many possible configurations targeted for their specific workload.
In addition, the number and width of the vector pipelines are configurable, as well as the placement of vector functional units within these pipelines.

## Supported RISC-V Extensions

Vicuna 2.0 provides support for the following ratified RISC-V extensions

- **Zve32x** - Support for the embedded vector integer sub-extension.
- **Zve32f** - Support for embedded vector floating-point sub-extension.  This support is based on the CV-FPU floating-point unit. *  
- **Zvfh** - Support for the vector half-precision floating-point. *

Support for vector floating-point operations depends on scalar floating-point support, either integrated into the scalar core or as an additional co-processor on the CV-X-IF interface.

* Support for floating-point comparison operations is currently in progress, which will complete support for the extensions. 

## Configuration Variables

Many vector unit configuration parameters are available to designers using the default 'dual pipeline' configuration.  These are:

- **VREG_W** - Vector register width in bits
- **VLANE_W** - Datapath width of pipeline containing all functional units in bits
- **VMEM_W** - Width of pipeline containing the Vector Load/Store unit in bits

When defining custom pipeline configurations, even more configuration options become available.  Such as:

- Elimination of structural hazards caused shared pipeline resources by moving vector functional units to new/different pipelines with different lane widths
- Size of vector instruction dispatch buffer, allowing more instructions to be buffered before stalling
- Complete removal of unused/rarely used functional units (this can cause non-compliance with the RISC-V Specifications) 

## Module Interface

Provided is a list of signals and interfaces used when including Vicuna 2.0 as a SystemVerilog module:

- clk_i - clock input
- rst_ni - active low reset signal
  
- xif_issue_if - CV-X-IF Issue Interface
- xif_commit_if - CV-X-IF Commit Interface
- xif_mem_if - Deprecated CV-X-IF Memory Interface.  Contains the Vector Read/Write Port
- xif_memres_if - Deprecated CV-X-IF Memory Interface.  Contains the Vector Read Port
- xif_result_if - CV-X-IF Result Interface

  When floating-point functionality is desired and the scalar floating point functionality is also implemented as a co-processor on the XIF interface, additional signals must be used alongside XIF Result.  These are:

- fpr_wr_req_valid - valid signal for a write to a floating point register.  Used to mark the register with a pending write
- fpr_wr_req_addr_o - destination register address for a write to a floating-point register.  Used to mark the register with a pending write
- fpr_res_valid - valid signal for data writing to a floating point register
- float_round_mode_i - floating point rounding mode for vector floating point operations taken from scalar fcsr
- fpu_res_acc - input to let Vicuna know that an instruction has been offloaded to another co-processor
- fpu_res_id - XIF ID of the instruction being sent to another co-processor       

In addition to these interfaces, additional signals are provided to allow for observation of CSR values and possible arbitration of memory busses if needed.

## Inclusion for Simulation with Verilator using CMake

When including Vicuna 2.0 in a Verilator project using CMake with the 'dual pipeline' configuration, the following variables need to be set.  Otherwise defaults will be selected.

- **RISCV_ARCH** - select the architecture for the system and vector unit to properly set preprocessor flags.  Currently supported are **rv32im_zve32x**, **rv32imf_zve32f**, **rv32imf_zfh_zve322f_zvfh**.
- **VREG_W** - vector register width in bits
- **VLANE_W** - vector pipeline width in bits
- **VMEM_W** - vector memory interface width in bits

The CMakeLists file provides three outputs to be used by the project including Vicuna 2.0.  These are:
- **VICUNA_SRCS** - list of all necessary source files for Vicuna and CV-FPU needed by Verilator
- **VICUNA_INCS** - list of all directories containing source files for Vicuna and CV-FPU needed by Verilator
- **VICUNA_FLAGS** - list of all pre-processor flags needed to configure Vicuna correctly.  These should be included when running Verilator.


