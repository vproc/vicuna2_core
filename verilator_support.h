// Collection of functions and variables for use with simulation with Verilator.
// Provides standardized access to verilator simulation functions without cluttering verilator_main.cpp
//
// In general, accesses to internal variables (exposed with VERILATOR_PUBLIC) should be handled here by passing in a reference to TOP.  Accesses to top level interface signals (i.e. memory interfaces) should be handled by the user.

#ifndef VERILATOR_SUPPORT_H
#define VERILATOR_SUPPORT_H


#include "Vvproc_top.h"


//Depeneding on the architecture selected, some of these files don't exist
#include "Vvproc_top_vproc_top.h"
#include "Vvproc_top_cv32e40x_core__pi1.h"

#ifdef RISCV_ZVE32X
#include "Vvproc_top_vproc_core__pi2.h"
#endif
#ifdef RISCV_F
#include "Vvproc_top_fpu_ss__I1_O0_F0_FBz6_FCz7.h"
#include "Vvproc_top_fpu_ss_regfile.h"
#endif
#include "verilated.h"

#include <stdio.h>
#include <stdint.h>

#ifdef TRACE_VCD
#include "verilated_vcd_c.h"
typedef VerilatedVcdC VerilatedTrace_t; //This file only exists if traces are enabled 
#else
typedef void VerilatedTrace_t;  
#endif
#ifdef TRACE_VCD
#include "verilated_vcd_c.h"
typedef VerilatedVcdC VerilatedTrace_t; //This file only exists if traces are enabled 
#else
typedef void VerilatedTrace_t;  
#endif

/*
* Functions and Variables used to detect a stall.  Returns true if IF_PC in CV32E40X core has not changed in the provided number of cycles  
* ARGS:
*   - *top          - pointer to verilator top module
*   -  max_cycles   - number of cycles after which a stall is declared
*/
inline uint32_t cycles_stalled = 0;
inline uint32_t last_IF_PC = 0;
bool check_stall(Vvproc_top *top, uint32_t max_cycles);

/*
* Function to check for a specific IF_PC.  Returns true if match.
* ARGS:
*   - *top          - pointer to verilator top module
*   -  address      - address to check for
*/
bool check_PC(Vvproc_top *top, uint32_t address);

/*
* Function to advance signal to the next cycle (i.e pass to after next falling edge)
* ARGS:
*   - *top          - pointer to verilator top module
*/
void advance_cycle(Vvproc_top *top);

/*
*   Function to read from memory and manage/update memory buffers.  Generalized to work on byte pointers for variable width interfaces.
*   Queues of correct sizes are expected to be allocated and provided by the user.
* ARGS:
*   address        - address of the load request being issued
*   req_valid      - validity of the load request being issued
*   mem_w          - width of the load interface in bits
*   mem_lat        - latency of the memory interface
*   mem_size       - total size of the memory address space
*
*   *model_data_i  - pointer to memory data read interface on verilator model
*   *model_valid_i - pointer to memory valid read interface on verilator model
*   *model_err_i   - pointer to memory error read interface on verilator model
*
*   **queue_data   - pointer to data queue
*   *queue_valid   - pointer to valid queue
*   *queue_err     - pointer to error queue
*
*   *mem           - pointer to memory space
*/
void update_mem_load(uint32_t address, bool req_valid, uint32_t mem_w, uint32_t mem_lat, uint32_t mem_size, unsigned char *model_data_i, bool *model_valid_i, bool *model_err_i, unsigned char **queue_data, bool *queue_valid, bool *queue_err, unsigned char *mem);

/*
*   Function to write to memory.  Generalized to work on byte pointers for variable width interfaces.
*   Values immediately written to memory.
* ARGS:
*   address        - address of the write request being issued
*   req_valid      - validity of the write request being issued
*   mem_w          - width of the write interface in bits
*   mem_size       - total size of the memory address space
*
*   *model_data_o  - pointer to memory data write interface on verilator model
*   *model_be_o    - pointer to byte enable write interface on verilator model
*
*   *mem           - pointer to memory space
*/
void update_mem_write(uint32_t address, bool req_valid, uint32_t mem_w, uint32_t mem_size, unsigned char *model_data_o, unsigned char *model_be_o, unsigned char *mem);

/*
* Check for a write to memory mapped io.  Returns true and copies written data to *data_out if a valid write occurs to the selected address
* ARGS:
*   address        - address of the write request being issued
*   req_valid      - validity of the write request being issued
*   mem_w          - width of the write interface in bits
*
*   *model_data_o  - pointer to memory data write interface on verilator model
*
*   memmap_address - address of the memory mapped io to check
*   *data_out      - pointer to memory mapped output
*/
bool check_memmapio(uint32_t address, bool req_valid, uint32_t mem_w, unsigned char *model_data_o, uint32_t memmap_address, char *data_out);

/*
*   Function to setup memory.  Handles checking memory parameters, allocates main memory, and loads program.  Returns unsigned char* to main memory.  Returns NULL if error
* ARGS:
*   mem_sz        - size of main memory to allocate
*   *prog_path    - program to load into memory
*/
unsigned char* load_program(uint32_t mem_sz, char *prog_path);
/*
*   Function to dump a region of memory into a file.
* ARGS:
*   start_addr        - start address of memory region
*   end_addr          - end address of memory region
*
*   *mem              - pointer to main memory
*
*   *dump_path        - file path to output file
*/
void dump_mem_region (uint32_t start_addr, uint32_t end_addr, unsigned char *mem, char *dump_path);



/*
*   Statistics Functions.  Two main functions+sub functions.
*
*   update_stats() - calls all sub-functions to update statistics.  Should only be called once per simulated cycle.  Some dumping functions depend on the stats updated by this function.
*   report_stats() - prints current state of all statistics to console.
*/

/*
*   Cycle count update
*/
inline int cycles = 0;
void update_cycles();

/*
*   Retired instruction count update
* ARGS:
*   - *top          - pointer to verilator top module
*/
inline int current_WB_PC = 0;
inline int last_WB_PC = 0;
inline int instr = 0;
void update_instructions(Vvproc_top *top);
/*
*   Total Vector Instructions executed update
* ARGS:
*   - *top          - pointer to verilator top module
*/
inline int vector_instr = 0;
void update_vector_count(Vvproc_top *top);

/*
* Average vector length calculation update.  
* ARGS:
*   - *top          - pointer to verilator top module
*/
inline int sum_vec_lengths = 0;
inline int sum_vec_lengths_bytes = 0;
inline float sum_vec_percentage = 0.0;
void update_avg_vector_len(Vvproc_top *top);

/*
* Top level function to update all statistics
* ARGS:
*   - *top          - pointer to verilator top module
*/
void update_stats(Vvproc_top *top);

/*
* Report current state of all collected statistics
*/
void report_stats();

/*
* Update .vcd trace file. If end_cycles == 0, output entire trace.
* ARGS:
*   - *tfp          - pointer to verilator vcd trace object
*   - begin_cycles  - cycle count to start trace
*   - end_cycles    - cycle count to end trace
*/
void update_vcd(VerilatedTrace_t *tfp, uint32_t begin_cycles, uint32_t end_cycles);


/*
* Update instruction trace file. If end_cycles == 0, output entire trace.
* ARGS:
*   - *top          - pointer to verilator top module
*   - *inst_trace   - pointer to .txt trace file output
*   - begin_cycles  - cycle count to start trace
*   - end_cycles    - cycle count to end trace
*/
void update_inst_trace(Vvproc_top *top, FILE *inst_trace, uint32_t begin_cycles, uint32_t end_cycles);

/*
* Update xreg commit log dump.  Appends any current commits to provided file.
* ARGS:
*   - *top          - pointer to verilator top module
*   - *commit_log   - pointer to .txt trace file output
*/
void update_xreg_commit(Vvproc_top *top, FILE *commit_log);

/*
* Update freg commit log dump.  Appends any current commits to provided file. In case RISCV_F is not enabled, remove references to fp_regfile signals as they don't exist
* ARGS:
*   - *top          - pointer to verilator top module
*   - *commit_log   - pointer to .txt trace file output
*/
void update_freg_commit(Vvproc_top *top, FILE *commit_log);

/*
* Update vreg commit log dump.  Appends any current commits to provided file. In case RISCV_ZVE32X is not enabled, remove references to vregfile signals as they don't exist
* ARGS:
*   - *top          - pointer to verilator top module
*   - vreg_w        - width of the vector registers
*   - *commit_log   - pointer to .txt trace file output
*/
void update_vreg_commit(Vvproc_top *top, int vreg_w, FILE *commit_log);


#endif