// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


// Packing results into vector registers  #TODO: Break up standard result shift reg and mask shift reg to be more modular
module vproc_vregpack #(
        // vector register port configuration
        parameter int unsigned                      VPORT_W             = 128,    // vreg port width
        parameter int unsigned                      VADDR_W             = 5,    // vreg address width

        // vector register result configuration
        parameter int unsigned                      MAX_RES_W           = 64,
        parameter int unsigned                      MEM_W               = 0,
        parameter int unsigned                      MEM_PORTS           = 1,
        parameter int unsigned                      RES_CNT             = 1,
        parameter int unsigned                      RES_W[RES_CNT]      = '{0}, // result width
        parameter bit [RES_CNT-1:0]                 RES_MASK            = '0,   // result is a mask
        parameter bit [RES_CNT-1:0]                 RES_NARROW          = '0,   // result may be narrow
        parameter bit [RES_CNT-1:0]                 RES_ALLOW_ELEMWISE  = '0,   // result may be 1 elem
        parameter bit [RES_CNT-1:0]                 RES_ALWAYS_ELEMWISE = '0,   // result is 1 elem

        parameter type                              FLAGS_T             = logic,// flags struct type
        parameter int unsigned                      INSTR_ID_W          = 3,    // instruction IDs width
        parameter int unsigned                      INSTR_ID_CNT        = 8,    // number of instr IDs
        parameter bit                               DONT_CARE_ZERO      = 1'b0,  // set don't care 0

        parameter bit                               FIELD_COUNT_USED    = 1'b0
    )(
        input  logic                                clk_i,
        input  logic                                async_rst_ni,
        input  logic                                sync_rst_ni,

        // pipeline in
        input  logic                                pipe_in_valid_i,
        output logic                                pipe_in_ready_o,
        input  logic   [INSTR_ID_W            -1:0] pipe_in_instr_id_i,         // ID of instruction
        input  vproc_pkg::cfg_vsew                  pipe_in_eew_i,              // current elem width
        input  logic   [VADDR_W               -1:0] pipe_in_vaddr_i,            // vreg address
        input  logic   [RES_CNT-1:0]                pipe_in_res_store_i,        // result store signal
        input  logic   [RES_CNT-1:0]                pipe_in_res_valid_i,        // result is valid
        input  FLAGS_T [RES_CNT-1:0]                pipe_in_res_flags_i,        // result flags
        input  logic   [RES_CNT-1:0][MAX_RES_W-1:0] pipe_in_res_data_i,         // result data
        input  logic   [RES_CNT-1:0][MAX_RES_W-1:0] pipe_in_res_mask_i,         // result mask  //TODO: This is way too wide (segmented ops with multiple results should also only need 1 mask?)
        input  logic                                pipe_in_pend_clr_i,         // clear pend writes
        input  logic   [$clog2(VADDR_W-1)     -1:0] pipe_in_pend_clr_cnt_i,     // vregs to clear count
        input  logic                                pipe_in_instr_done_i,       // instr done flag

        // vector register file write port
        output logic                                vreg_wr_req_o,
        input  logic                                vreg_wr_gnt_i,
        output logic   [VADDR_W               -1:0] vreg_wr_addr_o,             // vreg write address
        output logic   [VPORT_W/8             -1:0] vreg_wr_be_o,               // vreg byte enable
        output logic   [VPORT_W               -1:0] vreg_wr_data_o,             // vreg write data
        output logic   [INSTR_ID_W-1:0]             vreg_wr_id_o,               // vreg write id for port arbitration

        output logic                                vreg_wr_clr_o,              // clear addr from pend writes
        output logic   [$clog2(VADDR_W-1)     -1:0] vreg_wr_clr_cnt_o,          // number of vregs to clear

        // pending vector register reads (writes stall if the destination register is not clear)
        input  logic   [(1<<VADDR_W)          -1:0] pending_vreg_reads_i,

        // Instruction IDs state (vector register writes stall while the ID of the current
        // instruction is speculative and are inhibited if it is killed)
        input  vproc_pkg::instr_state [INSTR_ID_CNT-1:0] instr_state_i,

        // Signals that this instruction ID is done
        output logic                                instr_done_valid_o,
        output logic   [INSTR_ID_W            -1:0] instr_done_id_o
    );

    import vproc_pkg::*;

    //////
    //Control signals for repack shift register
    //////

    typedef struct packed {
    logic [VADDR_W-1:0]                         current_vreg;
    cfg_vsew                                    eew;
    logic [$clog2(VPORT_W/8)-1:0]               shifts_remaining; //Max counter value is for SEW8 Elemwise ops
    logic [INSTR_ID_W            -1:0]          instr_id;
    logic                                       valid;
    logic                                       last_cycle;
    logic                                       store;
    result_shift_rate                           shift_rate;
    //Specialized control signals for mask result reg TODO: should be broken out into its own module
    logic [$clog2(VPORT_W/(MAX_RES_W/32))-1:0]  mask_reg_idx;
    logic                                       mask_valid;
    logic                                       mask_complete;
    op_fractional                               frac;
    } repack_reg_ctrl;

    repack_reg_ctrl ctrl_d, ctrl_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            ctrl_q <= '0;
        end else begin
            ctrl_q <= ctrl_d;
        end
    end

    // In case of ops which write a single element, bypass shifting logic and attempt write directly.
    logic single_element_res;
    assign single_element_res = pipe_in_res_flags_i[0].single_elem_res;

    always_comb begin
        ctrl_d = ctrl_q;
        ctrl_d.valid = (pipe_in_valid_i | (ctrl_q.valid & !(vreg_wr_gnt_i | ctrl_q.store))) & !single_element_res & !pipe_in_res_flags_i[0].mask_res; //Hold valid signal if write port is blocked on last write
        ctrl_d.last_cycle = ((pipe_in_res_flags_i[0].last_cycle & pipe_in_valid_i) | (ctrl_q.last_cycle & ctrl_q.valid & ctrl_q.shifts_remaining == '0 & !(vreg_wr_gnt_i | ctrl_q.store))) & !single_element_res;
        ctrl_d.store = pipe_in_res_flags_i[0].store;
        if (pipe_in_valid_i & pipe_in_res_flags_i[0].first_cycle & !pipe_in_res_flags_i[0].mask_res ) begin
            if (!single_element_res) begin
                    //Load configuration from the pipeline if not single element result //TODO: Only one set of result flags should be passed through the pipeline
                ctrl_d.current_vreg = pipe_in_vaddr_i;
                ctrl_d.eew = pipe_in_eew_i;
                ctrl_d.instr_id = pipe_in_instr_id_i;
                ctrl_d.shift_rate = pipe_in_res_flags_i[0].shift_rate;
                ctrl_d.frac       = pipe_in_res_flags_i[0].dest_frac;
                unique case({pipe_in_res_flags_i[0].shift_rate, pipe_in_res_flags_i[0].dest_frac})
                    {RES_FULL_WIDTH, FULL_REG}: ctrl_d.shifts_remaining = VPORT_W / MAX_RES_W - 1;      //Standard case when functional units produce full datapath per cycle
                    {RES_FULL_WIDTH, MF2}:      ctrl_d.shifts_remaining = (VPORT_W / 2) / MAX_RES_W - 1;
                    {RES_FULL_WIDTH, MF4}:      ctrl_d.shifts_remaining = (VPORT_W / 4) / MAX_RES_W - 1;
                    {RES_FULL_WIDTH, MF8}:      ctrl_d.shifts_remaining = (VPORT_W / 8) / MAX_RES_W - 1;
                    {RES_NARROW_WIDTH, FULL_REG}: ctrl_d.shifts_remaining = VPORT_W*2 / MAX_RES_W - 1;  //Narrowing ops require twice as many cycles to fill the register
                    {RES_NARROW_WIDTH, MF2}:      ctrl_d.shifts_remaining = ((VPORT_W*2)/2) / MAX_RES_W - 1;
                    {RES_NARROW_WIDTH, MF4}:      ctrl_d.shifts_remaining = ((VPORT_W*2)/4) / MAX_RES_W - 1; 
                    {RES_NARROW_WIDTH, MF8}:      ctrl_d.shifts_remaining = ((VPORT_W*2)/8) / MAX_RES_W - 1; 
                    {RES_ELEMWISE_WIDTH, FULL_REG}: begin                                                     //Elemwise result shifts depends on SEW of result
                                        unique case(cur_sew)
                                            VSEW_32: ctrl_d.shifts_remaining = (VPORT_W/32)-1;
                                            VSEW_16: ctrl_d.shifts_remaining = (VPORT_W/16)-1;
                                            VSEW_8:  ctrl_d.shifts_remaining = (VPORT_W/8)-1;
                                        endcase
                    end
                    {RES_ELEMWISE_WIDTH, MF2}: begin
                                        unique case(cur_sew)
                                            VSEW_32: ctrl_d.shifts_remaining = ((VPORT_W/32)/2)-1;
                                            VSEW_16: ctrl_d.shifts_remaining = ((VPORT_W/16)/2)-1;
                                            VSEW_8:  ctrl_d.shifts_remaining = ((VPORT_W/8)/2)-1;
                                        endcase
                    end
                    {RES_ELEMWISE_WIDTH, MF4}: begin
                                        unique case(cur_sew)
                                            VSEW_32: ctrl_d.shifts_remaining = ((VPORT_W/32)/4)-1;
                                            VSEW_16: ctrl_d.shifts_remaining = ((VPORT_W/16)/4)-1;
                                            VSEW_8:  ctrl_d.shifts_remaining = ((VPORT_W/8)/4)-1;
                                        endcase
                    end
                    {RES_ELEMWISE_WIDTH, MF8}: begin
                                        unique case(cur_sew)
                                            VSEW_32: ctrl_d.shifts_remaining = ((VPORT_W/32)/8)-1;
                                            VSEW_16: ctrl_d.shifts_remaining = ((VPORT_W/16)/8)-1;
                                            VSEW_8:  ctrl_d.shifts_remaining = ((VPORT_W/8)/8)-1;
                                        endcase
                    end
                endcase
            end
        end else if (ctrl_q.valid) begin
            if (ctrl_q.shifts_remaining == '0) begin //Full register data ready to write
                if (vreg_wr_gnt_i | ctrl_q.store) begin
                    ctrl_d.current_vreg = ctrl_q.current_vreg + 1;
                    // only reset counter here if write can be performed this cycle
                    unique case({ctrl_q.shift_rate, ctrl_q.frac})
                        {RES_FULL_WIDTH, FULL_REG}: ctrl_d.shifts_remaining = VPORT_W / MAX_RES_W - 1;      //Standard case when functional units produce full datapath per cycle
                        {RES_FULL_WIDTH, MF2}:      ctrl_d.shifts_remaining = (VPORT_W / 2) / MAX_RES_W - 1;
                        {RES_FULL_WIDTH, MF4}:      ctrl_d.shifts_remaining = (VPORT_W / 4) / MAX_RES_W - 1;
                        {RES_FULL_WIDTH, MF8}:      ctrl_d.shifts_remaining = (VPORT_W / 8) / MAX_RES_W - 1;
                        {RES_NARROW_WIDTH, FULL_REG}: ctrl_d.shifts_remaining = VPORT_W*2 / MAX_RES_W - 1;  //Narrowing ops require twice as many cycles to fill the register
                        {RES_NARROW_WIDTH, MF2}:      ctrl_d.shifts_remaining = ((VPORT_W*2)/2) / MAX_RES_W - 1;
                        {RES_NARROW_WIDTH, MF4}:      ctrl_d.shifts_remaining = ((VPORT_W*2)/4) / MAX_RES_W - 1; 
                        {RES_NARROW_WIDTH, MF8}:      ctrl_d.shifts_remaining = ((VPORT_W*2)/8) / MAX_RES_W - 1; 
                        {RES_ELEMWISE_WIDTH, FULL_REG}: begin                                                     //Elemwise result shifts depends on SEW of result
                                            unique case(cur_sew)
                                                VSEW_32: ctrl_d.shifts_remaining = (VPORT_W/32)-1;
                                                VSEW_16: ctrl_d.shifts_remaining = (VPORT_W/16)-1;
                                                VSEW_8:  ctrl_d.shifts_remaining = (VPORT_W/8)-1;
                                            endcase
                        end
                        {RES_ELEMWISE_WIDTH, MF2}: begin
                                            unique case(cur_sew)
                                                VSEW_32: ctrl_d.shifts_remaining = ((VPORT_W/32)/2)-1;
                                                VSEW_16: ctrl_d.shifts_remaining = ((VPORT_W/16)/2)-1;
                                                VSEW_8:  ctrl_d.shifts_remaining = ((VPORT_W/8)/2)-1;
                                            endcase
                        end
                        {RES_ELEMWISE_WIDTH, MF4}: begin
                                            unique case(cur_sew)
                                                VSEW_32: ctrl_d.shifts_remaining = ((VPORT_W/32)/4)-1;
                                                VSEW_16: ctrl_d.shifts_remaining = ((VPORT_W/16)/4)-1;
                                                VSEW_8:  ctrl_d.shifts_remaining = ((VPORT_W/8)/4)-1;
                                            endcase
                        end
                        {RES_ELEMWISE_WIDTH, MF8}: begin
                                            unique case(cur_sew)
                                                VSEW_32: ctrl_d.shifts_remaining = ((VPORT_W/32)/8)-1;
                                                VSEW_16: ctrl_d.shifts_remaining = ((VPORT_W/16)/8)-1;
                                                VSEW_8:  ctrl_d.shifts_remaining = ((VPORT_W/8)/8)-1;
                                            endcase
                        end
                    endcase
                end
            end else begin
                ctrl_d.shifts_remaining = (pipe_in_valid_i) ? ctrl_q.shifts_remaining-1 : ctrl_q.shifts_remaining;
            end
        end else if (pipe_in_res_valid_i & pipe_in_res_flags_i[0].first_cycle & pipe_in_res_flags_i[0].mask_res) begin //If input is a mask  //TODO: Break this state machine out
                unique case (pipe_in_eew_i) //Set starting write index, first write at idx has already occurred
                    VSEW_32: ctrl_d.mask_reg_idx = MAX_RES_W/32;
                    VSEW_16: ctrl_d.mask_reg_idx = MAX_RES_W/16;
                    VSEW_8:  ctrl_d.mask_reg_idx = MAX_RES_W/8;
                endcase
                ctrl_d.mask_valid = 1'b1;
                ctrl_d.current_vreg = pipe_in_vaddr_i;
                ctrl_d.eew = pipe_in_eew_i;
                ctrl_d.instr_id = pipe_in_instr_id_i;
        end else if (pipe_in_res_valid_i & pipe_in_res_flags_i[0].last_cycle & pipe_in_res_flags_i[0].mask_res) begin
                ctrl_d.mask_complete = 1'b1;
        end else if (pipe_in_res_valid_i & !ctrl_q.mask_complete & pipe_in_res_flags_i[0].mask_res) begin
                unique case (ctrl_q.eew) //increment index
                    VSEW_32: ctrl_d.mask_reg_idx = ctrl_q.mask_reg_idx + MAX_RES_W/32;
                    VSEW_16: ctrl_d.mask_reg_idx = ctrl_q.mask_reg_idx + MAX_RES_W/16;
                    VSEW_8:  ctrl_d.mask_reg_idx = ctrl_q.mask_reg_idx + MAX_RES_W/8;
                endcase
        end else if (ctrl_q.mask_valid && ctrl_q.mask_complete) begin
            ctrl_d.mask_complete = !vreg_wr_gnt_i; //On successful write, clear status bits
            ctrl_d.valid = !vreg_wr_gnt_i;
            ctrl_d.mask_reg_idx = '0;
        end
    end
 
    //////
    // Result Assembly Shift Registers.  One for register write data and mask
    //////

    logic [VPORT_W-1:0]   shift_reg_d, shift_reg_q;
    logic [VPORT_W/8-1:0] shift_reg_mask_d, shift_reg_mask_q;

    logic [VPORT_W-1:0]   shift_reg_mask_result_d, shift_reg_mask_result_q;
    logic [VPORT_W/8-1:0]   shift_reg_mask_result_mask_d, shift_reg_mask_result_mask_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            shift_reg_q <= '0;
            shift_reg_mask_q <= '0;
            shift_reg_mask_result_q <= '0;
            shift_reg_mask_result_mask_q <= '0;
        end else begin
            if (pipe_in_valid_i) begin
                shift_reg_q <= shift_reg_d;
                shift_reg_mask_q <= shift_reg_mask_d;
                shift_reg_mask_result_q <= shift_reg_mask_result_d;
                shift_reg_mask_result_mask_q <= shift_reg_mask_result_mask_d;
            end
        end
    end

    //On first cycle, take control bits from the pipeline  //TODO: should be able to always take these from pipeline?
    result_shift_rate cur_shift_mode;
    assign cur_shift_mode = pipe_in_res_flags_i[0].first_cycle ? pipe_in_res_flags_i[0].shift_rate : ctrl_q.shift_rate;
    cfg_vsew          cur_sew;
    assign cur_sew = pipe_in_res_flags_i[0].first_cycle ? pipe_in_eew_i : ctrl_q.eew;
    op_fractional     cur_frac;
    assign cur_frac = pipe_in_res_flags_i[0].first_cycle ? pipe_in_res_flags_i[0].dest_frac : ctrl_q.frac;

    always_comb begin
        if ((pipe_in_valid_i) & !pipe_in_res_flags_i[0].mask_res) begin
            if (!(ctrl_q.shifts_remaining == '0) || ( vreg_wr_gnt_i | ctrl_q.store ) || pipe_in_res_flags_i[0].first_cycle) begin
                unique case ({cur_shift_mode, cur_sew})
                {RES_FULL_WIDTH,VSEW_32},
                {RES_FULL_WIDTH,VSEW_16},
                {RES_FULL_WIDTH,VSEW_8}:    begin //Standard Case
                                                unique case (cur_frac)
                                                    FULL_REG: begin
                                                        shift_reg_d = {pipe_in_res_data_i[0], shift_reg_q[VPORT_W-1 : MAX_RES_W]};
                                                        shift_reg_mask_d = {pipe_in_res_mask_i[0][VPORT_W/8-1:0], shift_reg_mask_q[VPORT_W/8-1 : MAX_RES_W/8]};
                                                    end
                                                    MF2: begin
                                                        if (VPORT_W/2 <= MAX_RES_W) begin
                                                            shift_reg_d = {{(VPORT_W/2){1'b0}}, pipe_in_res_data_i[0]};
                                                            shift_reg_mask_d = {{((VPORT_W/2)/8){1'b0}}, pipe_in_res_mask_i[0][(VPORT_W/2)/8-1:0]};
                                                        end else begin
                                                            shift_reg_d = {{(VPORT_W/2){1'b0}}, pipe_in_res_data_i[0], shift_reg_q[VPORT_W/2-1 : MAX_RES_W]};
                                                            shift_reg_mask_d = {{((VPORT_W/2)/8){1'b0}}, pipe_in_res_mask_i[0][(VPORT_W/2)/8-1:0], shift_reg_mask_q[(VPORT_W/2)/8-1 : MAX_RES_W/8]};
                                                        end
                                                    end
                                                    MF4: begin
                                                        if (VPORT_W/4 <= MAX_RES_W) begin
                                                            shift_reg_d = {{(VPORT_W*3/4){1'b0}}, pipe_in_res_data_i[0]};
                                                            shift_reg_mask_d = {{((VPORT_W*3/4)/8){1'b0}}, pipe_in_res_mask_i[0][(VPORT_W/4)/8-1:0]};
                                                        end else begin
                                                            shift_reg_d = {{(VPORT_W*3/4){1'b0}}, pipe_in_res_data_i[0], shift_reg_q[VPORT_W/4-1 : MAX_RES_W]};
                                                            shift_reg_mask_d = {{((VPORT_W*3/4)/8){1'b0}}, pipe_in_res_mask_i[0][(VPORT_W/4)/8-1:0], shift_reg_mask_q[(VPORT_W/4)/8-1 : MAX_RES_W/8]};
                                                        end
                                                    end
                                                    MF8: begin
                                                        if (VPORT_W/8 <= MAX_RES_W) begin
                                                            shift_reg_d = {{(VPORT_W*7/8){1'b0}}, pipe_in_res_data_i[0]};
                                                            shift_reg_mask_d = {{((VPORT_W*7/8)/8){1'b0}}, pipe_in_res_mask_i[0][(VPORT_W/8)/8-1:0]};
                                                        end else begin
                                                            shift_reg_d = {{(VPORT_W*7/8){1'b0}}, pipe_in_res_data_i[0], shift_reg_q[VPORT_W/8-1 : MAX_RES_W]};
                                                            shift_reg_mask_d = {{((VPORT_W*7/8)/8){1'b0}}, pipe_in_res_mask_i[0][(VPORT_W/8)/8-1:0], shift_reg_mask_q[(VPORT_W/8)/8-1 : MAX_RES_W/8]};
                                                        end
                                                    end
                                                endcase
                end
                {RES_NARROW_WIDTH,VSEW_32}: //Decode increases EEW of narrowing ops
                                            begin //Input is 16 bit elements with padding
                                                    unique case (cur_frac)
                                                    FULL_REG: begin  //TODO: All other shifts should be rewritten in the same style as the narrowing ones.  This should remove the need for the check for port_w <= max_res_w
                                                        shift_reg_mask_d[(VPORT_W/8) - (MAX_RES_W/8)/2 -1 : 0] = shift_reg_mask_q[(VPORT_W/8) -1: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W) -1 - MAX_RES_W/2 : 0] = shift_reg_q[(VPORT_W) -1: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/32; i++) begin
                                                            shift_reg_d[(VPORT_W)-MAX_RES_W/2+i*16 +: 16] = pipe_in_res_data_i[0][i*32 +: 16];
                                                            shift_reg_mask_d[(VPORT_W)/8-MAX_RES_W/16+i*2 +: 2] = pipe_in_res_mask_i[0][i*4 +: 2];
                                                        end
                                                    end
                                                    MF2: begin
                                                        shift_reg_mask_d[(VPORT_W/8) - 1:(VPORT_W/8)/2] = '0; //upper 3/4s 0 for mf4 result
                                                        shift_reg_mask_d[(VPORT_W/8)/2 -1 : 0] = shift_reg_mask_q[(VPORT_W/8)/2 -1 + (MAX_RES_W/8)/2: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W)/2 -1 : 0] = shift_reg_q[(VPORT_W)/2 -1 + (MAX_RES_W)/2: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/32; i++) begin
                                                            shift_reg_d[(VPORT_W/2)-MAX_RES_W/2+i*16 +: 16] = pipe_in_res_data_i[0][i*32 +: 16];
                                                            shift_reg_mask_d[(VPORT_W/2)/8-MAX_RES_W/16+i*2 +: 2] = pipe_in_res_mask_i[0][i*4 +: 2];
                                                        end
                                                    end
                                                    MF4: begin
                                                        shift_reg_mask_d[(VPORT_W/8) - 1:(VPORT_W/8)/4] = '0; //upper 3/4s 0 for mf4 result
                                                        shift_reg_mask_d[(VPORT_W/8)/4 -1 : 0] = shift_reg_mask_q[(VPORT_W/8)/4 -1 + (MAX_RES_W/8)/2: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W)/4 -1 : 0] = shift_reg_q[(VPORT_W)/4 -1 + (MAX_RES_W)/2: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/32; i++) begin
                                                            shift_reg_d[(VPORT_W/4)-MAX_RES_W/2+i*16 +: 16] = pipe_in_res_data_i[0][i*32 +: 16];
                                                            shift_reg_mask_d[(VPORT_W/4)/8-MAX_RES_W/16+i*2 +: 2] = pipe_in_res_mask_i[0][i*4 +: 2];
                                                        end
                                                    end
                                                    MF8: begin
                                                        shift_reg_mask_d[(VPORT_W/8) - 1:(VPORT_W/8)/8] = '0; //upper 3/4s 0 for mf4 result
                                                        shift_reg_mask_d[(VPORT_W/8)/8 -1 : 0] = shift_reg_mask_q[(VPORT_W/8)/8 -1 + (MAX_RES_W/8)/2: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W)/8 -1 : 0] = shift_reg_q[(VPORT_W)/8 -1 + (MAX_RES_W)/2: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/32; i++) begin
                                                            shift_reg_d[(VPORT_W/8)-MAX_RES_W/2+i*16 +: 16] = pipe_in_res_data_i[0][i*32 +: 16];
                                                            shift_reg_mask_d[(VPORT_W/8)/8-MAX_RES_W/16+i*2 +: 2] = pipe_in_res_mask_i[0][i*4 +: 2];
                                                        end
                                                    end
                                                endcase
                end
                {RES_NARROW_WIDTH,VSEW_16}: //Decode increases EEW of narrowing ops
                                            begin //Input is 8 bit elements with padding
                                                    unique case (cur_frac)
                                                    FULL_REG: begin
                                                        shift_reg_mask_d[(VPORT_W/8) -(MAX_RES_W/8)/2 -1 : 0] = shift_reg_mask_q[(VPORT_W/8) -1: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W) - MAX_RES_W/2 -1 : 0] = shift_reg_q[(VPORT_W) -1: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/16; i++) begin
                                                            shift_reg_d[(VPORT_W)-MAX_RES_W/2+i*8 +: 8] = pipe_in_res_data_i[0][i*16 +: 8];
                                                            shift_reg_mask_d[(VPORT_W)/8-MAX_RES_W/16+i] = pipe_in_res_mask_i[0][i*2];
                                                        end
                                                    end
                                                    MF2: begin
                                                        shift_reg_mask_d[(VPORT_W/8) - 1:(VPORT_W/8)/2] = '0; //upper 3/4s 0 for mf4 result
                                                        shift_reg_mask_d[(VPORT_W/8)/2 -1 : 0] = shift_reg_mask_q[(VPORT_W/8)/2 -1 + (MAX_RES_W/8)/2: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W)/2 -1 : 0] = shift_reg_q[(VPORT_W)/2 -1 + (MAX_RES_W)/2: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/16; i++) begin
                                                            shift_reg_d[(VPORT_W/2)-MAX_RES_W/2+i*8 +: 8] = pipe_in_res_data_i[0][i*16 +: 8];
                                                            shift_reg_mask_d[(VPORT_W/2)/8-MAX_RES_W/16+i] = pipe_in_res_mask_i[0][i*2];
                                                        end
                                                    end
                                                    MF4: begin
                                                        shift_reg_mask_d[(VPORT_W/8) - 1:(VPORT_W/8)/4] = '0; //upper 3/4s 0 for mf4 result
                                                        shift_reg_mask_d[(VPORT_W/8)/4 -1 : 0] = shift_reg_mask_q[(VPORT_W/8)/4 -1 + (MAX_RES_W/8)/2: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W)/4 -1 : 0] = shift_reg_q[(VPORT_W)/4 -1 + (MAX_RES_W)/2: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/16; i++) begin
                                                            shift_reg_d[(VPORT_W/4)-MAX_RES_W/2+i*8 +: 8] = pipe_in_res_data_i[0][i*16 +: 8];
                                                            shift_reg_mask_d[(VPORT_W/4)/8-MAX_RES_W/16+i] = pipe_in_res_mask_i[0][i*2];
                                                        end
                                                    end
                                                    MF8: begin
                                                        shift_reg_mask_d[(VPORT_W/8) - 1:(VPORT_W/8)/8] = '0; //upper 3/4s 0 for mf4 result
                                                        shift_reg_mask_d[(VPORT_W/8)/8 -1 : 0] = shift_reg_mask_q[(VPORT_W/8)/8 -1 + (MAX_RES_W/8)/2: (MAX_RES_W/8)/2];
                                                        shift_reg_d[(VPORT_W)/8 -1 : 0] = shift_reg_q[(VPORT_W)/8 -1 + (MAX_RES_W)/2: (MAX_RES_W)/2];
                                                        for (integer i = 0; i < MAX_RES_W/16; i++) begin
                                                            shift_reg_d[(VPORT_W/8)-MAX_RES_W/2+i*8 +: 8] = pipe_in_res_data_i[0][i*16 +: 8];
                                                            shift_reg_mask_d[(VPORT_W/8)/8-MAX_RES_W/16+i] = pipe_in_res_mask_i[0][i*2];
                                                        end
                                                    end
                                                    endcase
                                            end
                {RES_ELEMWISE_WIDTH,VSEW_32}:
                                            begin
                                                unique case (cur_frac)
                                                    FULL_REG: begin
                                                        shift_reg_d = {pipe_in_res_data_i[0][31:0], shift_reg_q[VPORT_W-1 : 32]};
                                                        shift_reg_mask_d = {pipe_in_res_mask_i[0][3:0], shift_reg_mask_q[VPORT_W/8-1 : 4]};
                                                    end
                                                    MF2: begin
                                                        if (VPORT_W/2 <= 32) begin
                                                            shift_reg_d = {{(VPORT_W/2){1'b0}}, pipe_in_res_data_i[0][31:0]};
                                                            shift_reg_mask_d = {{((VPORT_W/2)/8){1'b0}}, pipe_in_res_mask_i[0][3:0]};                     
                                                        end else begin
                                                            shift_reg_d = {{(VPORT_W/2){1'b0}}, pipe_in_res_data_i[0][31:0], shift_reg_q[VPORT_W/2-1 : 32]};
                                                            shift_reg_mask_d = {{((VPORT_W/2)/8){1'b0}}, pipe_in_res_mask_i[0][3:0], shift_reg_mask_q[(VPORT_W/2)/8-1 : 4]};
                                                        end
                                                    end
                                                    MF4: begin
                                                        if (VPORT_W/4 <= 32) begin
                                                            shift_reg_d = {{(VPORT_W*3/4){1'b0}}, pipe_in_res_data_i[0][31:0]};
                                                            shift_reg_mask_d = {{((VPORT_W*3/4)/8){1'b0}}, pipe_in_res_mask_i[0][3:0]};
                                                        end else begin
                                                            shift_reg_d = {{(VPORT_W*3/4){1'b0}}, pipe_in_res_data_i[0][31:0], shift_reg_q[VPORT_W/4-1 : 32]};
                                                            shift_reg_mask_d = {{((VPORT_W*3/4)/8){1'b0}}, pipe_in_res_mask_i[0][3:0], shift_reg_mask_q[(VPORT_W/4)/8-1 : 4]};
                                                        end
                                                    end
                                                    MF8: begin
                                                        if (VPORT_W/8 <= 32) begin
                                                            shift_reg_d = {{(VPORT_W*7/8){1'b0}}, pipe_in_res_data_i[0][31:0]};
                                                            shift_reg_mask_d = {{((VPORT_W*7/8)/8){1'b0}}, pipe_in_res_mask_i[0][3:0]};
                                                        end else begin
                                                            shift_reg_d = {{(VPORT_W*7/8){1'b0}},pipe_in_res_data_i[0][31:0], shift_reg_q[VPORT_W/8-1 : 32]};
                                                            shift_reg_mask_d = {{((VPORT_W*7/8)/8){1'b0}}, pipe_in_res_mask_i[0][3:0], shift_reg_mask_q[(VPORT_W/8)/8-1 : 4]};
                                                        end
                                                    end
                                                endcase
                                            end
                {RES_ELEMWISE_WIDTH,VSEW_16}:  //Since minimum pipe width is 32, impossible for special condition with single cycle completion here
                                            begin
                                                unique case (cur_frac)
                                                    FULL_REG: begin
                                                        shift_reg_d = {pipe_in_res_data_i[0][15:0], shift_reg_q[VPORT_W-1 : 16]};
                                                        shift_reg_mask_d = {pipe_in_res_mask_i[0][1:0], shift_reg_mask_q[VPORT_W/8-1 : 2]};
                                                    end
                                                    MF2: begin
                                                        shift_reg_d = {{(VPORT_W/2){1'b0}}, pipe_in_res_data_i[0][15:0], shift_reg_q[VPORT_W/2-1 : 16]};
                                                        shift_reg_mask_d = {{((VPORT_W/2)/8){1'b0}}, pipe_in_res_mask_i[0][1:0], shift_reg_mask_q[(VPORT_W/2)/8-1 : 2]};
                                                    end
                                                    MF4: begin
                                                        shift_reg_d = {{(VPORT_W*3/4){1'b0}}, pipe_in_res_data_i[0][15:0], shift_reg_q[VPORT_W/4-1 : 16]};
                                                        shift_reg_mask_d = {{((VPORT_W*3/4)/8){1'b0}}, pipe_in_res_mask_i[0][1:0], shift_reg_mask_q[(VPORT_W/4)/8-1 : 2]};
                                                    end
                                                    MF8: begin
                                                        shift_reg_d = {{(VPORT_W*7/8){1'b0}},pipe_in_res_data_i[0][15:0], shift_reg_q[VPORT_W/8-1 : 16]};
                                                        shift_reg_mask_d = {{((VPORT_W*7/8)/8){1'b0}}, pipe_in_res_mask_i[0][1:0], shift_reg_mask_q[(VPORT_W/8)/8-1 : 2]};
                                                    end
                                                endcase
                                            end
                {RES_ELEMWISE_WIDTH,VSEW_8}: //Since minimum pipe width is 32, impossible for special condition with single cycle completion here
                                            begin
                                                unique case (cur_frac)
                                                    FULL_REG: begin
                                                        shift_reg_d = {pipe_in_res_data_i[0][7:0], shift_reg_q[VPORT_W-1 : 8]};
                                                        shift_reg_mask_d = {pipe_in_res_mask_i[0][0], shift_reg_mask_q[VPORT_W/8-1 : 1]};
                                                    end
                                                    MF2: begin
                                                        shift_reg_d = {{(VPORT_W/2){1'b0}}, pipe_in_res_data_i[0][7:0], shift_reg_q[VPORT_W/2-1 : 8]};
                                                        shift_reg_mask_d = {{((VPORT_W/2)/8){1'b0}}, pipe_in_res_mask_i[0][0], shift_reg_mask_q[(VPORT_W/2)/8-1 : 1]};
                                                    end
                                                    MF4: begin
                                                        shift_reg_d = {{(VPORT_W*3/4){1'b0}}, pipe_in_res_data_i[0][7:0], shift_reg_q[VPORT_W/4-1 : 8]};
                                                        shift_reg_mask_d = {{((VPORT_W*3/4)/8){1'b0}}, pipe_in_res_mask_i[0][0], shift_reg_mask_q[(VPORT_W/4)/8-1 : 1]};
                                                    end
                                                    MF8: begin
                                                        shift_reg_d = {{(VPORT_W*7/8){1'b0}},pipe_in_res_data_i[0][7:0], shift_reg_q[VPORT_W/8-1 : 8]};
                                                        shift_reg_mask_d = {{((VPORT_W*7/8)/8){1'b0}}, pipe_in_res_mask_i[0][0], shift_reg_mask_q[(VPORT_W/8)/8-1 : 1]};
                                                    end
                                                endcase
                                            end
                endcase
            end
        end else if (pipe_in_res_valid_i & pipe_in_res_flags_i[0].mask_res) begin
            shift_reg_mask_result_d = pipe_in_res_flags_i[0].first_cycle ? '0 : shift_reg_mask_result_q;
            shift_reg_mask_result_mask_d = pipe_in_res_flags_i[0].first_cycle ? '0 : shift_reg_mask_result_mask_q;  //zero out upper bits
            unique case (cur_sew) //increment index
                    VSEW_32: begin
                            for (integer i = 0; i < MAX_RES_W/32; i++) begin
                                shift_reg_mask_result_d[ctrl_q.mask_reg_idx + i] = pipe_in_res_data_i[0][i*32];
                                shift_reg_mask_result_mask_d[(ctrl_q.mask_reg_idx + i) >> 3] = 1'b1;
                            end
                    end
                    VSEW_16: begin
                            for (integer i = 0; i < MAX_RES_W/16; i++) begin
                                shift_reg_mask_result_d[ctrl_q.mask_reg_idx + i] = pipe_in_res_data_i[0][i*16];
                                shift_reg_mask_result_mask_d[(ctrl_q.mask_reg_idx + i) >> 3] = 1'b1;
                            end
                    end
                    VSEW_8: begin
                            for (integer i = 0; i < MAX_RES_W/8; i++) begin
                                shift_reg_mask_result_d[ctrl_q.mask_reg_idx + i] = pipe_in_res_data_i[0][i*8];
                                shift_reg_mask_result_mask_d[(ctrl_q.mask_reg_idx + i) >> 3] = 1'b1;
                            end
                    end
            endcase
        end
    end

    //////
    // register write port logic
    //////
    always_comb begin
        vreg_wr_req_o = ((ctrl_q.shifts_remaining == '0) & ((ctrl_q.valid & !ctrl_q.store)) | (single_element_res & !ctrl_q.store)) | ctrl_q.mask_complete;  //Only write on last cycle and when the instruction is valid
        vreg_wr_addr_o  = single_element_res ? pipe_in_vaddr_i : ctrl_q.current_vreg;
        vreg_wr_be_o    = ctrl_q.mask_complete ? shift_reg_mask_result_mask_q : single_element_res ? pipe_in_res_mask_i[0] : shift_reg_mask_q;
        vreg_wr_data_o  = ctrl_q.mask_complete ? shift_reg_mask_result_q : single_element_res ? pipe_in_res_data_i[0] : shift_reg_q;
        vreg_wr_id_o    = single_element_res ? pipe_in_instr_id_i : ctrl_q.instr_id;
    end

    // signalling completion logic
    always_comb begin
        instr_done_valid_o = (vreg_wr_gnt_i | ctrl_q.store) & ctrl_q.valid & ctrl_q.last_cycle | (single_element_res & vreg_wr_gnt_i) | (ctrl_q.mask_complete & vreg_wr_gnt_i); //Done on last valid write
        instr_done_id_o = single_element_res ? pipe_in_instr_id_i : ctrl_q.instr_id;
    end

    //////
    // Handshake logic with unit mux
    //////
    //Unit ready when writes are successful, not narrowing, and successful single element writes occur //TODO: Confirm stall condition for failed write is correct?
    assign pipe_in_ready_o = !(!vreg_wr_gnt_i & vreg_wr_req_o) & !(single_element_res & !vreg_wr_gnt_i) & !(ctrl_q.mask_complete & !vreg_wr_gnt_i); //TODO: Allow single cycle "writes" to signal completion and not actually write back (xreg results)

endmodule
