// Collection of functions and variables for use with simulation with Verilator.
// Provides standardized access to verilator simulation functions without cluttering verilator_main.cpp
//
// In general, accesses to internal variables (exposed with VERILATOR_PUBLIC) should be handled here by passing in a reference to TOP.  Accesses to top level interface signals (i.e. memory interfaces) should be handled by the user.
#include "verilator_support.h"
/*
* Functions and Variables used to detect a stall.  Returns true if IF_PC in CV32E40X core has not changed in the provided number of cycles  
* ARGS:
*   - *top          - pointer to verilator top module
*   -  max_cycles   - number of cycles after which a stall is declared
*/
bool check_stall(Vvproc_top *top, uint32_t max_cycles) {

    uint32_t current_IF_PC = top->vproc_top->core->pc_if;
    if (current_IF_PC == last_IF_PC) {
        cycles_stalled++;
    } else {
        cycles_stalled = 0;
    }

    last_IF_PC = current_IF_PC;

    if ( cycles_stalled >= max_cycles) {
        fprintf(stderr, "ERROR: SIMULATION STALLED FOR %d CYCLES AT IF_PC = 0x%x\n", max_cycles, current_IF_PC);
        return true;
    }
        
    return false;
}

/*
* Function to check for a specific IF_PC.  Returns true if match.
* ARGS:
*   - *top          - pointer to verilator top module
*   -  address      - address to check for
*/
bool check_PC(Vvproc_top *top, uint32_t address) {
    return (top->vproc_top->core->pc_if == address);
}

/*
* Function to advance signal to the next cycle (i.e pass to after next falling edge)
* ARGS:
*   - *top          - pointer to verilator top module
*/
void advance_cycle(Vvproc_top *top){
    // rising clock edge
    top->clk_i = 1;
    top->eval();

    // falling clock edge
    top->clk_i = 0;
    top->eval();
    return;
}

/*
*   Function to read from memory and manage/update memory buffers.  Generalized to work on byte pointers for variable width interfaces.
*   Queues of correct sizes are expected to be allocated and provided by the user.
*
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
void update_mem_load(uint32_t address, bool req_valid, uint32_t mem_w, uint32_t mem_lat, uint32_t mem_size, unsigned char *model_data_i, bool *model_valid_i, bool *model_err_i, unsigned char **queue_data, bool *queue_valid, bool *queue_err, unsigned char *mem){

    // Put read data on the processor read port.
    for (int i = 0; i < mem_w/8; i++)
    {
        model_data_i[i]  = queue_data[mem_lat-1][i];
    }
    *model_valid_i = queue_valid[mem_lat-1];
    *model_err_i   = queue_err[mem_lat-1];


    //Next, advance fifo buffers by one cycle

    for (int i = mem_lat-1; i > 0; i--) {
        
        for (int j = 0; j < mem_w/8; j++)
        {
            queue_data[i][j] = queue_data[i-1][j];
        }
        queue_valid[i] = queue_valid[i-1];
        queue_err[i]   = queue_err[i-1];
    }

    //Next evaluate an outstanding request and put at the end of the buffer.
    bool valid = (address < mem_size) & req_valid;

    //set new queue entry to zero
    for (int i = 0; i < mem_w/8; i++)
    {
        queue_data[0][i] = 0;
    }
    
    if (valid)
    {
        //Copy each valid byte into buffer
        for (int i = 0; i < mem_w/8; i++) {
            queue_data[0][i] |= mem[address+i];
        }
    }

    queue_valid[0] = req_valid;
    queue_err[0]   = !valid;
}

/*
*   Function to write to memory.  Generalized to work on byte pointers for variable width interfaces.
*   Values immediately written to memory.
*
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
void update_mem_write(uint32_t address, bool req_valid, uint32_t mem_w, uint32_t mem_size, unsigned char *model_data_o, unsigned char *model_be_o, unsigned char *mem){
    if (req_valid) {
        for (int i = 0; i < mem_w / 8; i++) {
            if ((model_be_o[i/8] & (1<<(i%8)))) {
                mem[address+i] = model_data_o[i];
            }
            
        }
    }
}

/*
* Check for a write to memory mapped io.  Returns true and copies written data to *data_out if a valid write occurs to the selected address
*   address        - address of the write request being issued
*   req_valid      - validity of the write request being issued
*   mem_w          - width of the write interface in bits
*
*   *model_data_o  - pointer to memory data write interface on verilator model
*
*   memmap_address - address of the memory mapped io to check
*   *data_out      - pointer to memory mapped output
*/
bool check_memmapio(uint32_t address, bool req_valid, uint32_t mem_w, unsigned char *model_data_o, uint32_t memmap_address, char *data_out){
    if (req_valid) {
        if (address == memmap_address){
            for (int i = 0; i < mem_w / 8; i++) {
                data_out[i] = model_data_o[i]; 
            }
            return true;
        }
    }
    return false;
}

/*
*   Function to setup memory.  Handles checking memory parameters, allocates main memory, and loads program.  Returns unsigned char* to main memory.  Returns NULL if error
*
*   mem_sz        - size of main memory to allocate
*   *prog_path    - program to load into memory
*/
unsigned char* load_program(uint32_t mem_sz, char *prog_path){
    unsigned char *mem = (unsigned char *)malloc(mem_sz);
    if (mem == NULL) {
        fprintf(stderr, "ERROR: allocating %d bytes of memory: %s\n", mem_sz, strerror(errno));
        return NULL;
    }

    FILE *ftmp = fopen(prog_path, "r");
    if (ftmp == NULL) {
        fprintf(stderr, "ERROR: invalid program path `%s': %s\n", prog_path, strerror(errno));
        return NULL;
    }
    memset(mem, 0, mem_sz);
    char buf[256];
    int addr = 0;
    while (fgets(buf, sizeof(buf), ftmp) != NULL) {
        if (buf[0] == '#' || buf[0] == '/')
            continue;
        char *ptr = buf;
        if (buf[0] == '@') {
            addr = strtol(ptr + 1, &ptr, 16) * 4;
            while (*ptr == ' ')
                ptr++;
        }
        while (*ptr != '\n' && *ptr != 0) {
            int data = strtol(ptr, &ptr, 16);
            int i;
            for (i = 0; i < 4; i++)
                mem[addr+i] = data >> (8*i);
            addr += 4;
            while (*ptr == ' ')
                ptr++;
        }
    }
    fclose(ftmp);
    return mem;
}
/*
*   Function to dump a region of memory into a file.
*
*   start_addr        - start address of memory region
*   end_addr          - end address of memory region
*
*   *mem              - pointer to main memory
*
*   *dump_path        - file path to output file
*/
void dump_mem_region (uint32_t start_addr, uint32_t end_addr, unsigned char *mem, char *dump_path){

    FILE *ftmp = fopen(dump_path, "w");
    if (ftmp == NULL) {
        fprintf(stderr, "ERROR: opening `%s': %s\n", dump_path, strerror(errno));
        return;
    }
    int addr;
    for (addr = start_addr; addr < end_addr; addr += 4) {
        int data = mem[addr] | (mem[addr+1] << 8) | (mem[addr+2] << 16) | (mem[addr+3] << 24);
        fprintf(ftmp, "%08x\n", data);
    }
    fclose(ftmp);
    return;
}

/*
*   Cycle count update
*/
void update_cycles(){
    cycles++;
    return;
}

/*
*   Retired instruction count update
* ARGS:
*   - *top          - pointer to verilator top module
*/
void update_instructions(Vvproc_top *top){
    current_WB_PC = top->vproc_top->core->instruction_wb_pc;
    if (current_WB_PC != last_WB_PC) {
        instr++;
    }
    last_WB_PC = current_WB_PC;
    return;
}

/*
*   Total Vector Instructions executed update
* ARGS:
*   - *top          - pointer to verilator top module
*/
void update_vector_count(Vvproc_top *top){
    if( top->vproc_top->vcore_result_valid && top->vproc_top->vcore_result_ready){
        vector_instr++;
    }
    return;
}

/*
* Average vector length calculation update.  
* ARGS:
*   - *top          - pointer to verilator top module
*/
void update_avg_vector_len(Vvproc_top *top){
     if( top->vproc_top->vcore_result_valid && top->vproc_top->vcore_result_ready){
        sum_vec_lengths+= top->vproc_top->csr_vl_o; //running sum of number of elements in vectors
        int cur_vec_len_bytes = 0;
        switch ((top->vproc_top->csr_vtype_o >> 3) & 7) //sew stored in bits [5:3]
        { 
            case 0: //sew == 8
            sum_vec_lengths_bytes+= top->vproc_top->csr_vl_o; //each element is one byte
            cur_vec_len_bytes = top->vproc_top->csr_vl_o;
            break;
            case 1: //sew == 16
            sum_vec_lengths_bytes+= top->vproc_top->csr_vl_o * 2; // each element two bytes
            cur_vec_len_bytes = top->vproc_top->csr_vl_o * 2;
            break;
            case 2: //sew == 32
            sum_vec_lengths_bytes+= top->vproc_top->csr_vl_o * 4; // each element four bytes
            cur_vec_len_bytes = top->vproc_top->csr_vl_o * 4;
            break;
            default:
            fprintf(stderr, "UNSUPPORTED SEW DETECTED\n");
        }
        
        switch (top->vproc_top->csr_vtype_o & 7) //LMUL stored in bits [2:0]
        { 
            case 0: //LMUL = 1
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o); //each element is one byte

            case 1: //LMUL == 2
                sum_vec_percentage += ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o * 2); // 2 vector regs in group
            break;
            case 2: //LMUL == 4
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o * 4); // 4 vector regs in group
            break;
            case 4: //LMUL == 8
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o * 8); // 4 vector regs in group
            break;
            case 7: //LMUL = 1/2
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o/2.0); //each element is one byte
            case 6: //LMUL = 1/4
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o/4.0); //each element is one byte
            case 5: //LMUL = 1/8
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o/8.0); //each element is one byte
            default:
                sum_vec_lengths_bytes+= ((float)cur_vec_len_bytes)/((float)top->vproc_top->csr_vlen_b_o); //each element is one byte
            break;
        }
    }
    return;
}

/*
* Top level function to update all statistics
* ARGS:
*   - *top          - pointer to verilator top module
*/
void update_stats(Vvproc_top *top){
    update_cycles();
    update_instructions(top);
    update_vector_count(top);
    update_avg_vector_len(top);
}

/*
* Report current state of all collected statistics
*/
void report_stats(){
    fprintf(stderr, "Total Cycles: %d\n", cycles);
    fprintf(stderr, "Instruction Count: %d CPI : %f \n\n", instr, ((float)(cycles))/((float)instr));
    
    fprintf(stderr, "Number of Vector Instructions Executed: %d  \n", vector_instr);
    fprintf(stderr, "AVG VL Elements: %f  \n", ((float)(sum_vec_lengths))/((float)vector_instr));
    fprintf(stderr, "AVG VL Bytes: %f  \n\n", ((float)(sum_vec_lengths_bytes))/((float)vector_instr));
    fprintf(stderr, "AVG VREG Usage %: %f  \n\n", ((float)(sum_vec_percentage))/((float)vector_instr) * 100);
    return;

}

/*
* Update .vcd trace file. If end_cycles == 0, output entire trace.
* ARGS:
*   - *tfp          - pointer to verilator vcd trace object
*   - begin_cycles  - cycle count to start trace
*   - end_cycles    - cycle count to end trace
*/
void update_vcd(VerilatedTrace_t *tfp, uint32_t begin_cycles, uint32_t end_cycles){
    if (tfp != NULL)
    {
        if ((cycles >= begin_cycles) && ( cycles < end_cycles) || (end_cycles == 0))
        {
            #ifdef TRACE_VCD
            tfp->dump(cycles);
            #endif
        }
    }
    return;
}


/*
* Update instruction trace file. If end_cycles == 0, output entire trace.
* ARGS:
*   - *top          - pointer to verilator top module
*   - *inst_trace   - pointer to .txt trace file output
*   - begin_cycles  - cycle count to start trace
*   - end_cycles    - cycle count to end trace
*/
void update_inst_trace(Vvproc_top *top, FILE *inst_trace, uint32_t begin_cycles, uint32_t end_cycles){
    if (inst_trace != NULL)
    {
        if ((cycles >= begin_cycles) && ( cycles < end_cycles) || (end_cycles == 0))
        {
            if ((current_WB_PC != last_WB_PC)) //using values from stats, make sure update_stats() is called first
            {
                //mark trace file for new instruction in wb
                fprintf(inst_trace, "NEW PC\n");
            }
            fprintf(inst_trace, "%08x\n", top->vproc_top->core->instruction_wb);
        }
    }
    return;
}

    
/*
* Update xreg commit log dump.  Appends any current commits to provided file.
* ARGS:
*   - *top          - pointer to verilator top module
*   - *commit_log   - pointer to .txt trace file output
*/
void update_xreg_commit(Vvproc_top *top, FILE *commit_log){
    if(top->vproc_top->core->rf_we_wb)
    {
        fprintf(commit_log, "x%d 0x%08x\n", top->vproc_top->core->rf_waddr_wb, top->vproc_top->core->rf_wdata_wb);
    }
    return;
}

/*
* Update freg commit log dump.  Appends any current commits to provided file.  In case RISCV_F is not enabled, remove references to fp_regfile signals as they don't exist
* ARGS:
*   - *top          - pointer to verilator top module
*   - *commit_log   - pointer to .txt trace file output
*/
void update_freg_commit(Vvproc_top *top, FILE *commit_log){
    #ifdef RISCV_F
    if(top->vproc_top->fpu_ss_i->gen_fp_register_file__DOT__fpu_ss_regfile_i->fpr_commit_valid)
    {
        fprintf(commit_log, "f%d 0x%08x\n", top->vproc_top->fpu_ss_i->gen_fp_register_file__DOT__fpu_ss_regfile_i->fpr_commit_addr, top->vproc_top->fpu_ss_i->gen_fp_register_file__DOT__fpu_ss_regfile_i->fpr_commit_data);
    }
    #endif
    return;
}

/*
* Update vreg commit log dump.  Appends any current commits to provided file. In case RISCV_ZVE32X is not enabled, remove references to vregfile signals as they don't exist
* ARGS:
*   - *top          - pointer to verilator top module
*   - vreg_w        - width of the vector registers
*   - *commit_log   - pointer to .txt trace file output
*/
void update_vreg_commit(Vvproc_top *top, int vreg_w, FILE *commit_log){
        #ifdef RISCV_ZVE32X
        //write commit log for vregs.  Currently set up for one write port.  Only log a commit when an element is actually written. Mask handled internally in case entire write is masked out
        if(top->vproc_top->v_core->vregfile_wr_en_q)
        {
            fprintf(commit_log, "v%d 0x", top->vproc_top->v_core->vregfile_wr_addr_q);
            unsigned char* reg_write_data = (unsigned char*)&(top->vproc_top->v_core->vregfile_wr_data_q);
            //bytes written out in this order to match the outputs from spike
            for (int i = vreg_w/8-1; i >= 0; i--)
            {   
                //write XX for bytes that are masked out, these aren't written
                if ((int)top->vproc_top->v_core->vregfile_wr_mask_q & (0x1 << i))
                {
                    fprintf(commit_log, "%02x", reg_write_data[i]);
                }
                else
                {
                    fprintf(commit_log, "XX");
                }
            }
            fprintf(commit_log, "\n");
        } 
        #endif 
    return;
}
