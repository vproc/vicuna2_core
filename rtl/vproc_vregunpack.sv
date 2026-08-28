// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import vproc_pkg::*;
//This module is responsible for reading and shifting a single standard operand
module vreg_shift_register
#(
     // vector register ports configuration
    parameter int unsigned                        VREG_PORT_W        = 128,  // max port width
    parameter int unsigned                        VADDR_W            = 5,    // max addr width
    parameter int unsigned                        PIPE_OP_W          = 32   // datapath width of functional unit 

)(
    input  logic                                  clk_i,
    input  logic                                  async_rst_ni,
    input  logic                                  sync_rst_ni,

    //Handshake with vregunpack controller/dispatch
    input  logic                                 pipe_in_valid_i,
    output logic                               shift_reg_ready_o,
    input  vproc_pkg::cfg_vsew                     operand_eew_i,
    input  logic [3:0]                            operand_regs_i,
    input  vproc_pkg::op_fractional               operand_frac_i,
    input  vproc_pkg::cfg_emul                    operand_emul_i,
    input  logic [VADDR_W-1:0]              operand_vaddr_base_i,
    input  vproc_pkg::op_shift_rate         operand_shift_rate_i,
    input  logic                                  operand_sign_i,
    input  logic [3:0]                                 repeats_i,

    input  logic                                      use_xval_i,
    input  logic [31:0]                                   xval_i,

    //vreg read port interface
    input  logic                                   vreg_rd_gnt_i,
    output logic                                   vreg_rd_req_o,
    output logic [VADDR_W-1:0]                    vreg_rd_addr_o,
    input  logic [VREG_PORT_W-1:0]                vreg_rd_data_i,

    output logic                                      finished_o,

    //Pipeline handshake with functional units
    input  logic                                     vfu_ready_i,
    output logic                                vfu_data_valid_o,
    output logic [PIPE_OP_W-1:0]                      vfu_data_o


);
    //Control signals for operand shift register
    typedef struct packed {
    logic [VADDR_W-1:0]         current_vreg;
    logic [VADDR_W-1:0]         base_vreg;
    logic [3:0]                 vreg_reads_remaining;          //up to 8 vregs need to be read (LMUL8)
    logic [3:0]                 total_reads;                   //Some operations will need the contents of the register operand (group) multiple times
    cfg_vsew                    eew;
    logic [$clog2(VREG_PORT_W / 8 )-1:0] shifts_remaining; //Maximum counter value is elewise SEW 8
    logic [3:0]                 repeats_remaining;         //Some operations will need the contents of the register operand (group) multiple times
    logic                       valid_data;
    vproc_pkg::op_shift_rate    shift_rate;
    logic                       sign;
    vproc_pkg::cfg_emul         dest_emul;
    vproc_pkg::op_fractional    frac;
    } shift_reg_ctrl;

    shift_reg_ctrl ctrl_d, ctrl_q;

    // State machine for the operand shift register
    typedef enum logic {
        IDLE            = 1'b0,
        VREG_SHIFT      = 1'b1
    } shift_reg_state;

    shift_reg_state state_d, state_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            state_q <= IDLE;
            ctrl_q <= '0;
        end else begin
            state_q <= state_d;
            ctrl_q <= ctrl_d;
        end
    end

    //state transitions and control signal assignments
    always_comb begin
        state_d = state_q;
        ctrl_d = ctrl_q;
        vreg_rd_req_o = 1'b0;
        finished_o = 1'b0;
        unique case (state_q)
            IDLE: begin
                if (pipe_in_valid_i) begin
                    state_d = VREG_SHIFT;
                    ctrl_d.shifts_remaining = '0;
                    ctrl_d.current_vreg = operand_vaddr_base_i;
                    ctrl_d.base_vreg = operand_vaddr_base_i;
                    ctrl_d.eew = operand_eew_i;
                    ctrl_d.valid_data = 1'b0;
                    ctrl_d.shift_rate = operand_shift_rate_i;
                    ctrl_d.sign = operand_sign_i;
                    ctrl_d.dest_emul = operand_emul_i;
                    ctrl_d.vreg_reads_remaining = operand_regs_i;
                    ctrl_d.total_reads = operand_regs_i;
                    ctrl_d.repeats_remaining = repeats_i;
                    ctrl_d.frac = operand_frac_i;
                end
            end

            VREG_SHIFT: begin
                if (vfu_ready_i & ctrl_q.valid_data & !(ctrl_q.shifts_remaining == 0)) begin
                    ctrl_d.shifts_remaining = ctrl_q.shifts_remaining - 1; //Only shift if vector functional unit is ready
                end else if (ctrl_q.shifts_remaining == 0 & (vfu_ready_i | !ctrl_q.valid_data)) begin
                    if ((ctrl_q.vreg_reads_remaining == 0) & (ctrl_q.repeats_remaining == 0)) begin //if all reads complete, return to idle
                        state_d = IDLE;
                        finished_o = 1'b1;
                        ctrl_d.valid_data = 1'b0; 
                    end else begin
                        vreg_rd_req_o = !use_xval_i; //only issue read if using vector arg
                        if (vreg_rd_gnt_i | use_xval_i) begin //On successful load, set shift counter
                            unique case ({ctrl_q.frac, ctrl_q.shift_rate})  //Set number of shifts per register based on rate and fractional settings
                                {FULL_REG, SHIFT_FULL_WIDTH}: ctrl_d.shifts_remaining = VREG_PORT_W/PIPE_OP_W-1;// standard shift case
                                {MF2, SHIFT_FULL_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W/2)/PIPE_OP_W-1;// half register
                                {MF4, SHIFT_FULL_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W/4)/PIPE_OP_W-1;// quarter register
                                {MF8, SHIFT_FULL_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W/8)/PIPE_OP_W-1;// eighth register

                                {FULL_REG, SHIFT_HALF_WIDTH}: ctrl_d.shifts_remaining = (VREG_PORT_W*2)/PIPE_OP_W-1;// standard shift case
                                {MF2, SHIFT_HALF_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W)/PIPE_OP_W-1;// half register
                                {MF4, SHIFT_HALF_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W/2)/PIPE_OP_W-1;// quarter register
                                {MF8, SHIFT_HALF_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W/4)/PIPE_OP_W-1;// eighth register

                                {FULL_REG, SHIFT_QUARTER_WIDTH}: ctrl_d.shifts_remaining = (VREG_PORT_W*4)/PIPE_OP_W-1;// standard shift case
                                {MF2, SHIFT_QUARTER_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W*2)/PIPE_OP_W-1;// half register
                                {MF4, SHIFT_QUARTER_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W)/PIPE_OP_W-1;// quarter register
                                {MF8, SHIFT_QUARTER_WIDTH}:      ctrl_d.shifts_remaining = (VREG_PORT_W/2)/PIPE_OP_W-1;// eighth register

                                {FULL_REG, SHIFT_ELEMWISE}: begin
                                                                unique case(ctrl_q.eew)
                                                                    VSEW_32: ctrl_d.shifts_remaining = (VREG_PORT_W/32)-1;
                                                                    VSEW_16: ctrl_d.shifts_remaining = (VREG_PORT_W/16)-1;
                                                                    VSEW_8:  ctrl_d.shifts_remaining = (VREG_PORT_W/8)-1;
                                                                endcase
                                end
                                {MF2, SHIFT_ELEMWISE}: begin
                                                                unique case(ctrl_q.eew)
                                                                    VSEW_32: ctrl_d.shifts_remaining = (VREG_PORT_W/64)-1;
                                                                    VSEW_16: ctrl_d.shifts_remaining = (VREG_PORT_W/32)-1;
                                                                    VSEW_8:  ctrl_d.shifts_remaining = (VREG_PORT_W/16)-1;
                                                                endcase  
                                end
                                {MF4, SHIFT_ELEMWISE}: begin
                                                                unique case(ctrl_q.eew)
                                                                    VSEW_32: ctrl_d.shifts_remaining = (VREG_PORT_W/128)-1;
                                                                    VSEW_16: ctrl_d.shifts_remaining = (VREG_PORT_W/64)-1;
                                                                    VSEW_8:  ctrl_d.shifts_remaining = (VREG_PORT_W/32)-1;
                                                                endcase  
                                end
                                {MF8, SHIFT_ELEMWISE}: begin
                                                                unique case(ctrl_q.eew)
                                                                    VSEW_32: ctrl_d.shifts_remaining = (VREG_PORT_W/256)-1;
                                                                    VSEW_16: ctrl_d.shifts_remaining = (VREG_PORT_W/128)-1;
                                                                    VSEW_8:  ctrl_d.shifts_remaining = (VREG_PORT_W/64)-1;
                                                                endcase  
                                end
                            endcase
                            ctrl_d.vreg_reads_remaining = (ctrl_q.vreg_reads_remaining == 1) & !(ctrl_q.repeats_remaining == 1) ? ctrl_q.total_reads : ctrl_q.vreg_reads_remaining - 1;
                            ctrl_d.current_vreg = ctrl_q.vreg_reads_remaining == 1 ? ctrl_q.base_vreg  : ctrl_q.current_vreg + 1; // if on last read, reset to original address for possible repeat read of the register group
                            ctrl_d.repeats_remaining =  ctrl_q.vreg_reads_remaining == 1 ? ctrl_q.repeats_remaining - 1 : ctrl_q.repeats_remaining;
                            ctrl_d.valid_data = 1'b1;
                        end else begin
                            ctrl_d.valid_data = 1'b0; //On failed read, set data valid to 0
                        end
                    end
                end
            end
        endcase
    end

    //VREG Shift register
    logic [VREG_PORT_W-1:0] shift_reg_d, shift_reg_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            shift_reg_q <= '0;
        end else begin
            shift_reg_q <= shift_reg_d;
        end
    end

    always_comb begin
        shift_reg_d = shift_reg_q;
        if(state_q == VREG_SHIFT & ctrl_q.shifts_remaining == '0 & (vfu_ready_i | !ctrl_q.valid_data)) begin
            if (use_xval_i) begin
                unique case (ctrl_q.eew)
                        VSEW_32: begin
                            unique case (ctrl_q.shift_rate) 
                                SHIFT_FULL_WIDTH,
                                SHIFT_ELEMWISE:         shift_reg_d = {(VREG_PORT_W/32){xval_i[31:0]}};
                                SHIFT_HALF_WIDTH:       shift_reg_d = {(VREG_PORT_W/16){xval_i[15:0]}};
                                SHIFT_QUARTER_WIDTH:    shift_reg_d = {(VREG_PORT_W/8){xval_i[7:0]}};
                            endcase
                        end 
                        VSEW_16: begin
                            unique case (ctrl_q.shift_rate) 
                                SHIFT_FULL_WIDTH,
                                SHIFT_ELEMWISE:         shift_reg_d = {(VREG_PORT_W/16){xval_i[15:0]}};
                                SHIFT_HALF_WIDTH:       shift_reg_d = {(VREG_PORT_W/8){xval_i[7:0]}};
                            endcase
                        end 
                        VSEW_8:  shift_reg_d = {(VREG_PORT_W/8){xval_i[7:0]}};
                endcase
            end else begin
                shift_reg_d = vreg_rd_data_i;
            end
        end else if (state_q == VREG_SHIFT) begin
            if (vfu_ready_i) begin
                unique case (ctrl_q.shift_rate)
                        SHIFT_FULL_WIDTH:       shift_reg_d = {{(PIPE_OP_W){1'b0}}, shift_reg_q[VREG_PORT_W-1 : PIPE_OP_W]}; //standard shift case
                        SHIFT_HALF_WIDTH:       shift_reg_d = {{(PIPE_OP_W/2){1'b0}}, shift_reg_q[VREG_PORT_W-1 : PIPE_OP_W/2]};
                        SHIFT_QUARTER_WIDTH:    shift_reg_d = {{(PIPE_OP_W/4){1'b0}}, shift_reg_q[VREG_PORT_W-1 : PIPE_OP_W/4]};
                        SHIFT_ELEMWISE:         begin
                                                    unique case (ctrl_q.eew) //In this case shift out a single element each cycle
                                                        VSEW_32: shift_reg_d = {{(32){1'b0}}, shift_reg_q[VREG_PORT_W-1 : 32]};
                                                        VSEW_16: shift_reg_d = {{(16){1'b0}}, shift_reg_q[VREG_PORT_W-1 : 16]};
                                                        VSEW_8:  shift_reg_d = {{(8){1'b0}}, shift_reg_q[VREG_PORT_W-1 : 8]};
                                                    endcase
                        end
                endcase
            end
        end
    end

    assign vreg_rd_addr_o = ctrl_q.current_vreg;

    //Output assignments
    always_comb begin
        unique case (ctrl_q.shift_rate) //Select output bits based on shift rate
            SHIFT_ELEMWISE,             //Technically, for this case more data is present in a wider pipeline than only the next element to be shifted out.  Upper bits could be masked out, but functional units should know what bits are valid based on metadata/mask
            SHIFT_FULL_WIDTH:   vfu_data_o = shift_reg_q[PIPE_OP_W-1:0];
            SHIFT_HALF_WIDTH:   begin
                                    unique case (ctrl_q.eew)  //Destination SEW is passed here, so SEW8 is not possible
                                        VSEW_32: begin
                                            for (integer i = 0; i < PIPE_OP_W/32; i++) begin
                                                vfu_data_o[32*i +: 32] = {{(16){ctrl_d.sign & shift_reg_q[16*i + 15]}}, shift_reg_q[16 * i +: 16]};
                                            end
                                        end
                                        VSEW_16:  begin
                                            for (integer i = 0; i < PIPE_OP_W/16; i++) begin
                                                vfu_data_o[16*i +: 16] = {{(8){ctrl_d.sign & shift_reg_q[8*i + 7]}}, shift_reg_q[8 * i +: 8]};
                                            end
                                        end
                                    endcase
            end
            SHIFT_QUARTER_WIDTH:begin
                                    unique case (ctrl_q.eew)  //Destination SEW is passed here, so SEW8 and SEW16 is not possible
                                        VSEW_32: begin
                                            for (integer i = 0; i < PIPE_OP_W/32; i++) begin
                                                vfu_data_o[32*i +: 32] = {{(24){ctrl_d.sign & shift_reg_q[8*i + 7]}}, shift_reg_q[8 * i +: 8]};
                                            end
                                        end
                                    endcase
            end
        endcase
        vfu_data_valid_o = ctrl_q.valid_data; //ouput valid when valid data in the shift register
        shift_reg_ready_o = (state_q == IDLE);
    end

endmodule

//This module is responsible for loading the mask register v0(if necessary), taking in the current vl, and generating a byte mask to be passed to the pipeline
module mask_reg_shift_register
#(
     // vector register ports configuration
    parameter int unsigned                        VREG_PORT_W        = 128,  // max port width
    parameter int unsigned                        CFG_VL_W           = 7,
    parameter int unsigned                        PIPE_OP_W          = 32   // datapath width of functional unit 

)(
    input  logic                                  clk_i,
    input  logic                                  async_rst_ni,
    input  logic                                  sync_rst_ni,

    //Handshake with vregunpack controller/dispatch
    input  logic                                 pipe_in_valid_i,
    output logic                               shift_reg_ready_o,
    input  vproc_pkg::cfg_vsew                        dest_eew_i,
    input  vproc_pkg::cfg_emul                       dest_emul_i,  //could probably pass lmul directly here instead of emul + frac
    input  logic [3:0]                               dest_regs_i,
    input  vproc_pkg::op_fractional                  dest_frac_i,
    input  logic [3:0]                                 repeats_i,
    input  vproc_pkg::op_shift_rate            dest_shift_rate_i,
    input  logic [CFG_VL_W-1:0]                             vl_i,
    input  logic                                          vl_0_i,
    input  logic                                        masked_i,

    //vreg read port interface
    input  logic                                   vreg_rd_gnt_i,
    input  logic [VREG_PORT_W-1:0]                vreg_rd_data_i,

    output logic                                      finished_o,

    //Pipeline handshake with functional units
    input  logic                                     vfu_ready_i,
    output logic                                vfu_data_valid_o,
    output logic [PIPE_OP_W/8-1:0]                    vfu_mask_o


);

    //Control signals for mask shift register
    typedef struct packed {
    cfg_vsew                    eew;
    cfg_emul                    emul;
    logic [$clog2(VREG_PORT_W/8 * 8)-1:0] shifts_remaining; //maximum shift count for elemwise LMUL=8
    logic                       valid_data;
    logic                       masked;
    vproc_pkg::op_shift_rate    shift_rate;
    logic [3:0]                 repeats_remaining; //Some operations will need the contents of the mask register multiple times
    logic [CFG_VL_W-1:0]        vl;
    logic                       vl_0;
    vproc_pkg::op_fractional    frac;
    } shift_reg_ctrl;

    shift_reg_ctrl ctrl_d, ctrl_q;

    // State machine for the mask shift register
    typedef enum logic {
        IDLE            = 1'b0,
        VREG_SHIFT      = 1'b1
    } shift_reg_state;

    shift_reg_state state_d, state_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            state_q <= IDLE;
            ctrl_q <= '0;
        end else begin
            state_q <= state_d;
            ctrl_q <= ctrl_d;
        end
    end

    //state transitions and control signal assignments
    always_comb begin
        state_d = state_q;
        ctrl_d = ctrl_q;
        finished_o = 1'b0;
        unique case (state_q)
            IDLE: begin
                if (pipe_in_valid_i) begin
                    state_d = VREG_SHIFT;
                    ctrl_d.eew = dest_eew_i;
                    ctrl_d.emul = dest_emul_i;
                    ctrl_d.valid_data = 1'b0;
                    ctrl_d.masked     = masked_i;
                    ctrl_d.shift_rate = dest_shift_rate_i;
                    ctrl_d.repeats_remaining = repeats_i;
                    ctrl_d.vl = vl_i;
                    ctrl_d.vl_0 = vl_0_i;
                    ctrl_d.shifts_remaining = '0;
                    ctrl_d.frac = dest_frac_i;
                end
            end

            VREG_SHIFT: begin
                if (vfu_ready_i & ctrl_q.valid_data) begin
                    ctrl_d.shifts_remaining = ctrl_q.shifts_remaining - 1; //Only shift if vector functional unit is ready
                end
                if (ctrl_q.shifts_remaining == 0 && vfu_ready_i && ctrl_q.repeats_remaining == 0) begin
                    state_d = IDLE;
                    finished_o = 1'b1;
                    ctrl_d.valid_data = 1'b0; 
                end else begin
                    if ((vreg_rd_gnt_i | !ctrl_q.masked) & ctrl_q.shifts_remaining == 0 & (!ctrl_q.valid_data | vfu_ready_i)) begin
                        unique case (ctrl_q.shift_rate)
                            SHIFT_ELEMWISE: begin
                                unique case ({ctrl_q.emul, ctrl_q.eew}) //Set # of remaining shifts based on destination emul and fractional setting
                                            {EMUL_1, VSEW_8}: begin
                                                unique case (ctrl_q.frac) //Fractional only applies to EMUL1
                                                    FULL_REG: ctrl_d.shifts_remaining      = (    VREG_PORT_W)/8 - 1;
                                                    MF2:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/2)/8 - 1;
                                                    MF4:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/4)/8 - 1;
                                                    MF8:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/8)/8 - 1;
                                                endcase
                                            end
                                            {EMUL_1, VSEW_16}: begin
                                                unique case (ctrl_q.frac) //Fractional only applies to EMUL1
                                                    FULL_REG: ctrl_d.shifts_remaining      = (    VREG_PORT_W)/16 - 1;
                                                    MF2:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/2)/16 - 1;
                                                    MF4:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/4)/16 - 1;
                                                    MF8:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/8)/16 - 1;
                                                endcase
                                            end
                                            {EMUL_1, VSEW_32}: begin
                                                unique case (ctrl_q.frac) //Fractional only applies to EMUL1
                                                    FULL_REG: ctrl_d.shifts_remaining      = (    VREG_PORT_W)/32 - 1;
                                                    MF2:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/2)/32 - 1;
                                                    MF4:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/4)/32 - 1;
                                                    MF8:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/8)/32 - 1;
                                                endcase
                                            end
                                            {EMUL_2, VSEW_8}: ctrl_d.shifts_remaining      = ( 2 * VREG_PORT_W)/8 - 1;
                                            {EMUL_2, VSEW_16}: ctrl_d.shifts_remaining     = ( 2 * VREG_PORT_W)/16 - 1;
                                            {EMUL_2, VSEW_32}: ctrl_d.shifts_remaining     = ( 2 * VREG_PORT_W)/32 - 1;
                                            {EMUL_4, VSEW_8}: ctrl_d.shifts_remaining      = ( 4 * VREG_PORT_W)/8 - 1;
                                            {EMUL_4, VSEW_16}: ctrl_d.shifts_remaining     = ( 4 * VREG_PORT_W)/16 - 1;
                                            {EMUL_4, VSEW_32}: ctrl_d.shifts_remaining     = ( 4 * VREG_PORT_W)/32 - 1;
                                            {EMUL_8, VSEW_8}: ctrl_d.shifts_remaining      = ( 8 * VREG_PORT_W)/8 - 1;
                                            {EMUL_8, VSEW_16}: ctrl_d.shifts_remaining     = ( 8 * VREG_PORT_W)/16 - 1;
                                            {EMUL_8, VSEW_32}: ctrl_d.shifts_remaining     = ( 8 * VREG_PORT_W)/32 - 1;
                                endcase
                            end
                            default: begin //All other cases only depend on LMUL or Fractional Setting
                                        unique case (ctrl_q.emul) //Set # of remaining shifts based on destination emul
                                            EMUL_1: begin
                                                unique case (ctrl_q.frac) //Fractional only applies to EMUL1
                                                    FULL_REG: ctrl_d.shifts_remaining      = (    VREG_PORT_W)/PIPE_OP_W - 1;
                                                    MF2:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/2)/PIPE_OP_W - 1;
                                                    MF4:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/4)/PIPE_OP_W - 1;
                                                    MF8:      ctrl_d.shifts_remaining      = (  VREG_PORT_W/8)/PIPE_OP_W - 1;
                                                endcase
                                            end
                                            EMUL_2: ctrl_d.shifts_remaining     = (2 * VREG_PORT_W)/PIPE_OP_W - 1;
                                            EMUL_4: ctrl_d.shifts_remaining     = (4 * VREG_PORT_W)/PIPE_OP_W - 1;
                                            EMUL_8: ctrl_d.shifts_remaining     = (8 * VREG_PORT_W)/PIPE_OP_W - 1;
                                        endcase
                            end
                        endcase
                        ctrl_d.valid_data = 1'b1;
                        ctrl_d.repeats_remaining = ctrl_q.repeats_remaining - 1;
                    end else if (!(vreg_rd_gnt_i | !ctrl_q.masked) & ctrl_q.shifts_remaining == 0) begin
                        ctrl_d.valid_data = 1'b0; //On failed read, set data valid to 0
                    end
                end
            end
        endcase
    end

    //VREG Shift register
    logic [VREG_PORT_W-1:0] shift_reg_d, shift_reg_q; //Entire mask register loaded

    logic [VREG_PORT_W-1:0] vl_mask;

    logic [VREG_PORT_W-1:0] mask_reg_bytes; //translate mask register to byte register based on SEW

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            shift_reg_q <= '0;
        end else begin
            shift_reg_q <= shift_reg_d;
        end
    end

    always_comb begin
        vl_mask = '0;
        if (!ctrl_q.vl_0) begin
            for (int i = 0; i <= ctrl_q.vl; i++) begin //vl is passed as # bytes -1, so <= here + guard for vl=0.
                vl_mask[i] = 1'b1;
            end
        end
    end

    always_comb begin
        shift_reg_d = shift_reg_q;
        if (state_q == IDLE) begin
            shift_reg_d = '0;
        end else if(state_q == VREG_SHIFT && !ctrl_q.valid_data || state_q == VREG_SHIFT && (ctrl_q.shifts_remaining == 0 && !(ctrl_q.repeats_remaining == 0) && vfu_ready_i)) begin  //reset mask register if data not valid or a repeat is beginning
            shift_reg_d = ctrl_q.masked ? mask_reg_bytes & vl_mask : vl_mask; //If mask register needed, & with VL mask
        end else if (state_q == VREG_SHIFT) begin
            if (vfu_ready_i) begin
                unique case (ctrl_q.shift_rate)
                        SHIFT_ELEMWISE: begin
                            unique case(ctrl_q.eew)
                                VSEW_32: shift_reg_d = {{(4){1'b0}}, shift_reg_q[VREG_PORT_W-1 : 4]};
                                VSEW_16: shift_reg_d = {{(2){1'b0}}, shift_reg_q[VREG_PORT_W-1 : 2]};
                                VSEW_8:  shift_reg_d = {{(1){1'b0}}, shift_reg_q[VREG_PORT_W-1 : 1]};
                            endcase
                        end
                        default: shift_reg_d = {{(PIPE_OP_W/8){1'b0}}, shift_reg_q[VREG_PORT_W-1 : PIPE_OP_W/8]}; //mask is scaled based on destination EMUL/SEW/VL.  No need for different shift rates
                endcase
            end
        end
    end

    //Mask is always given based on the EEW of the destination (set in decode) 
    always_comb begin
        unique case (ctrl_q.eew)
                VSEW_32: begin
                    for (integer i = 0; i < VREG_PORT_W; i++) begin
                        mask_reg_bytes[i] = vreg_rd_data_i[i>>2]; //every bit in mask register is 4 bits bytewise
                    end
                end
                VSEW_16: begin
                    for (integer i = 0; i < VREG_PORT_W; i++) begin
                        mask_reg_bytes[i] = vreg_rd_data_i[i>>1]; //every bit in mask register is 4 bits bytewise
                    end
                end
                VSEW_8:  begin
                    mask_reg_bytes = vreg_rd_data_i;
                end
        endcase
    end

    //Output assignments
    always_comb begin
        unique case ({ctrl_q.shift_rate, ctrl_q.eew})
            {SHIFT_ELEMWISE, VSEW_32}:  vfu_mask_o = {{(PIPE_OP_W/8-4){1'b0}}, shift_reg_q[3:0]};
            {SHIFT_ELEMWISE, VSEW_16}:  vfu_mask_o = {{(PIPE_OP_W/8-2){1'b0}}, shift_reg_q[1:0]};
            {SHIFT_ELEMWISE, VSEW_8}:   vfu_mask_o = {{(PIPE_OP_W/8-1){1'b0}}, shift_reg_q[0]};
            default:                    vfu_mask_o = shift_reg_q[PIPE_OP_W/8-1:0];
        endcase
        vfu_data_valid_o = ctrl_q.valid_data; //ouput valid when valid data in the shift register
        shift_reg_ready_o = (state_q == IDLE);
    end

endmodule

// Unpacking vector registers to operands
module vproc_vregunpack
    #(
        // vector register ports configuration
        parameter int unsigned                        MAX_VPORT_W        = 128,  // max port width
        parameter int unsigned                        MAX_VADDR_W        = 5,    // max addr width
        parameter int unsigned                        VPORT_CNT          = 1,    // port count
        //parameter int unsigned                        VPORT_W[VPORT_CNT] = '{0}, // port widths
        parameter int unsigned                        VADDR_W[VPORT_CNT] = '{5}, // address widths
        parameter bit [VPORT_CNT-1:0]                 VPORT_BUFFER       = '0,   // buffer port
        parameter int unsigned                        VPORT_V0_W         = 128,  // width of v0 port
        parameter int unsigned                        ID_W               = 5,
        parameter int unsigned                        CFG_VL_W          = 7,

        // vector register operands configuration
        parameter int unsigned                        MAX_OP_W           = 64,   // max op width
        parameter int unsigned                        MEM_W              = 0,
        parameter int unsigned                        MEM_PORTS          = 1,
        parameter int unsigned                        OP_W    [VPORT_CNT]   = '{0}, // op widths
        parameter int unsigned                        OP_DYN_ADDR_SRC    = 0,    // dyn addr src idx
        parameter bit [VPORT_CNT-1:0]                    OP_DYN_ADDR        = '0,   // dynamic addr
        parameter bit [VPORT_CNT-1:0]                    OP_MASK            = '0,   // op is a mask
        parameter bit [VPORT_CNT-1:0]                    OP_XREG            = '0,   // op may be XREG
        parameter bit [VPORT_CNT-1:0]                    OP_NARROW          = '0,   // op may be narrow
        parameter bit [VPORT_CNT-1:0]                    OP_ALLOW_ELEMWISE  = '0,   // op may be 1 elem
        parameter bit [VPORT_CNT-1:0]                    OP_ALWAYS_ELEMWISE = '0,   // op is 1 elem
        parameter bit [VPORT_CNT-1:0]                    OP_HOLD_FLAG       = '0,   // allow hold of op

        parameter int unsigned                        UNPACK_STAGES      = 2,    // stage count
        parameter type                                FLAGS_T            = logic,// load struct type
        parameter type                                METADATA_T         = logic,
        parameter int unsigned                        CTRL_DATA_W        = 0,    // ctrl data width
        parameter bit                                 DONT_CARE_ZERO     = 1'b0,  // set don't care 0

        parameter bit [VPORT_CNT-1:0]                    OP_ALT_COUNTER     = '0,
        parameter bit                                 FIELD_COUNT_USED   = 1'b0,
        parameter bit [VPORT_CNT-1:0]                    OP_FIELD           = '0
    )(
        input  logic                                     clk_i,
        input  logic                                     async_rst_ni,
        input  logic                                     sync_rst_ni,

        // vector register file read ports
        output logic [VPORT_CNT-1:0][MAX_VADDR_W-1:0]    vreg_rd_addr_o,       // vreg read address
        input  logic [VPORT_CNT-1:0][MAX_VPORT_W-1:0]    vreg_rd_data_i,       // vreg read data
        input  logic [VPORT_CNT-1:0]                     vreg_rd_gnt_i,        // gnt signal for read ports
        output logic [VPORT_CNT-1:0]                     vreg_rd_req_o,        // req signal for read ports
        input  logic                [VPORT_V0_W -1:0]    vreg_rd_v0_i,         // vreg v0 read data
        output logic [ID_W-1:0]                          vreg_rd_id_o,         // instruction ID of requestor for arbitration

        // pipeline in
        input  logic                                     pipe_in_valid_i,
        output logic                                     pipe_in_ready_o,
        input  METADATA_T                                pipe_in_ctrl_i,       // pipeline control sigs TODO: Most signals below this one should be absorbed into this struct
        input  vproc_pkg::op_unit                        pipe_in_unit_i,
        input  vproc_pkg::cfg_vsew                       pipe_in_eew_i,        // current element width
        input  logic   [VPORT_CNT-1:0]                   pipe_in_op_load_i,    // load signals of ops
        input  logic   [VPORT_CNT-1:0][MAX_VADDR_W-1:0]  pipe_in_op_vaddr_i,   // vreg addresses of ops
        input  logic   [1:0][31           :0]            pipe_in_op_xval_i,    // X reg values for ops, only 2 of these
        input  logic   [MEM_PORTS-1:0]                   pipe_in_mem_req_valid_i,
        input  logic   [MEM_PORTS-1:0][2:0]              pipe_in_field_counter_i,

        input  logic   [31:0]                            pend_wr_map_i,        //Pending writes (as of the instruction being issued)
        input  logic   [31:0]                            pend_wr_clear_i,      //Writes that have been completed

        //Some vector functional units can access the V0 port, so access must be arbitrated (always give preference to vfu access)
        input  logic                                     vfu_vreg_rd_req_i,
        output logic                                     vfu_vreg_rd_gnt_o,
        input  [4:0]                                     vfu_vreg_rd_addr_i,
        input  [ID_W-1 : 0]                              vfu_vreg_rd_id_i,

        // pipeline out
        output logic   [VPORT_CNT-1:0]                   pipe_out_valid_o,
        input  logic   [VPORT_CNT-1:0]                   pipe_out_ready_i,
        output METADATA_T                                pipe_out_ctrl_o,      // pipeline control sigs
        output logic   [VPORT_CNT-1:0][MAX_OP_W   -1:0]  pipe_out_op_data_o,   // unpacked operands

        //vector register read mask
        output logic                                     pipe_out_mask_valid_o,
        input  logic                                     pipe_out_mask_ready_i,
        output logic   [MAX_OP_W/8-1:0]                  pipe_out_mask_data_o,

        // stage valid and control signals flags
        output logic                                     stage_valid_any_o,
        output logic [CTRL_DATA_W-1:0]                   ctrl_flags_any_o,
        output logic [CTRL_DATA_W-1:0]                   ctrl_flags_all_o
    );

    //////////
    // Top Level Unpack state machine
    //////////
    typedef enum logic {
        READY           = 2'b00,
        SHIFTING        = 2'b01
    } unpack_state;

    unpack_state state_d, state_q;

    logic [VPORT_CNT-1:0] active_ops_d, active_ops_q; //Keep track of how many shift regs are active for transition back to ready
    logic                 active_mask_d, active_mask_q; //Keep track if mask register is active for transition back to ready

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            state_q <= READY;
            shift_reg_in_valid_q <= 1'b0;
            active_ops_q <= '0;
            active_mask_q <= 1'b0;
        end else begin
            state_q <= state_d;
            shift_reg_in_valid_q <= shift_reg_in_valid_d;
            active_ops_q <= active_ops_d;
            active_mask_q <= active_mask_d;
        end
    end

    logic [VPORT_CNT-1:0] shift_regs_ready;              //input ready signals for all shift registers
    logic shift_reg_in_valid_d, shift_reg_in_valid_q;    //signal 1 cycle input valid for shift registers on transition from READY to SHIFTING
    always_comb begin
        state_d = state_q;
        shift_reg_in_valid_d = 1'b0;
        unique case (state_q)
            READY: begin
                pipe_in_ready_o = 1'b1;
                if (pipe_in_valid_i) begin
                    state_d = SHIFTING;
                    shift_reg_in_valid_d = 1'b1;
                end
            end
            SHIFTING: begin
                pipe_in_ready_o = 1'b0;
                if ((active_ops_d == '0 & !active_mask_d) & !shift_reg_in_valid_q) begin //Dont transition out of shifting state if loading data in OR until all shift registers (including mask register) are ready
                    state_d = READY;
                end
            end
        endcase
    end

    /*
    *   Buffer for metadata of instruction currently being unpacked.  Latched on first valid cycle and held
    */
    typedef struct packed {
        METADATA_T                               ctrl;
        op_unit                                  unit; //Most of these should already be present inside of metadata_t
        cfg_vsew                                 eew;
        cfg_emul                                 emul;
        logic   [MEM_PORTS-1:0]                  mem_req_valid;
        logic   [MEM_PORTS-1:0][2:0]             field_counter;
        logic   [VPORT_CNT-1:0]                  op_load;
        logic   [VPORT_CNT-1:0][MAX_VADDR_W-1:0] op_vaddr;
        logic   [2-1:0][31           :0]         op_xval; //Maximum 2 of these.  TODO: PARAMETERIZE
        logic   [VPORT_CNT-1:0][MAX_VPORT_W-1:0] op_buffer;
        logic   [VPORT_CNT-1:0][MAX_OP_W   -1:0] op_data;
        logic   [31:0]                           pend_wr_map;
    } vregunpack_state_t;

    vregunpack_state_t metadata_d, metadata_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            metadata_q <=  vregunpack_state_t'(DONT_CARE_ZERO ? '0 : 'x);
        end else begin
            metadata_q <= metadata_d;
        end
    end

    always_comb begin
        metadata_d = metadata_q;
        metadata_d.pend_wr_map = metadata_q.pend_wr_map & (~pend_wr_clear_i);
        if (state_q == READY) begin
            metadata_d.ctrl     = pipe_in_ctrl_i;
            metadata_d.unit     = pipe_in_unit_i;
            metadata_d.eew      = pipe_in_eew_i;
            metadata_d.emul     = pipe_in_ctrl_i.emul;
            metadata_d.op_load  = pipe_in_op_load_i;
            metadata_d.op_vaddr = pipe_in_op_vaddr_i;
            metadata_d.op_xval  = pipe_in_ctrl_i.op_xval;
            metadata_d.mem_req_valid = pipe_in_mem_req_valid_i;
            metadata_d.field_counter = pipe_in_field_counter_i;
            metadata_d.pend_wr_map = pend_wr_map_i & (~pend_wr_clear_i); //in case a pending write is cleared this cycle
        end
    end

    /////////////////
    //Operand Shift registers 
    //Currently, Maximum 3 Ports, rs1, rs2, rd
    /////////////////
    logic   [VPORT_CNT-1:0][MAX_OP_W   -1:0]  shift_reg_outputs;
    logic   [VPORT_CNT-1:0]                   shift_reg_done;

    logic   [VPORT_CNT-1:0]                   shift_reg_req;
    logic   [VPORT_CNT-1:0]                   shift_reg_gnt;
    logic   [VPORT_CNT-1:0][MAX_VADDR_W-1:0]  shift_reg_addr;
    generate
        //op0 port can be accessed by GATHER unit, so arbitration necessary.  Always give preference to vfu
        assign vreg_rd_req_o[0] = vfu_vreg_rd_req_i ? vfu_vreg_rd_req_i & ~metadata_q.pend_wr_map[vfu_vreg_rd_addr_i] : shift_reg_req[0] & ~metadata_q.pend_wr_map[shift_reg_addr[i]]; //Request signal from shift reg valid if not marked as pending write (not a data hazard)
        assign shift_reg_gnt[0] = vreg_rd_gnt_i[0] & !vfu_vreg_rd_req_i;
        assign vfu_vreg_rd_gnt_o = vreg_rd_gnt_i[0] & vfu_vreg_rd_req_i;
        assign vreg_rd_addr_o[0] = vfu_vreg_rd_req_i ? vfu_vreg_rd_addr_i : shift_reg_addr[0];

        //Standard accesses for other ports, and only allowed when vfu not accessing op 0 due to potentially conflicting IDs
        for (genvar i = 1; i < VPORT_CNT; i++) begin
            assign vreg_rd_req_o[i] = shift_reg_req[i] & ~metadata_q.pend_wr_map[vreg_rd_addr_o[i]] & (!vfu_vreg_rd_req_i | metadata_q.ctrl.id == vfu_vreg_rd_id_i); //Request signal from shift reg valid if not marked as pending write (not a data hazard) or blocked by access from previous instruction in vfu
            assign shift_reg_gnt[i] = vreg_rd_gnt_i[i];
            assign vreg_rd_addr_o[i] = shift_reg_addr[i];
        end
    endgenerate
    assign vreg_rd_id_o     = vfu_vreg_rd_req_i ? vfu_vreg_rd_id_i : metadata_q.ctrl.id;

    generate
        for (genvar i = 0; i < VPORT_CNT; i++) begin
            vreg_shift_register #(
                .VREG_PORT_W        (MAX_VPORT_W),
                .VADDR_W            (MAX_VADDR_W),
                .PIPE_OP_W          (MAX_OP_W)
            ) operand_register (

                .clk_i(clk_i),
                //.async_rst_ni,
                .sync_rst_ni(sync_rst_ni),

                .pipe_in_valid_i(shift_reg_in_valid_q & (metadata_q.ctrl.decode_metadata.operands[i].vreg | metadata_q.ctrl.decode_metadata.operands[i].xreg)),
                .shift_reg_ready_o(shift_regs_ready[i]),
                .operand_eew_i(metadata_q.ctrl.decode_metadata.operands[i].sew),                                          //TODO: Mixed precision operations will need an EEW/operand
                .operand_regs_i(metadata_q.ctrl.decode_metadata.operands[i].regs),
                .repeats_i(metadata_q.ctrl.decode_metadata.operands[i].repeats),
                .operand_emul_i(metadata_q.ctrl.decode_metadata.dest_emul),
                .operand_frac_i(metadata_q.ctrl.decode_metadata.operands[i].frac),
                .operand_vaddr_base_i(metadata_q.ctrl.decode_metadata.operands[i].r.vaddr),
                .operand_shift_rate_i(metadata_q.ctrl.decode_metadata.operands[i].shift_rate),
                .operand_sign_i(metadata_q.ctrl.decode_metadata.operands[i].sign), 

                .use_xval_i(metadata_q.ctrl.decode_metadata.operands[i].xreg),
                .xval_i(metadata_q.ctrl.decode_metadata.operands[i].r.xval),

                .finished_o(shift_reg_done[i]),

                .vreg_rd_gnt_i(shift_reg_gnt[i]),
                .vreg_rd_req_o(shift_reg_req[i]),
                .vreg_rd_addr_o(shift_reg_addr[i]),
                .vreg_rd_data_i(vreg_rd_data_i[i]),

                .vfu_ready_i(pipe_out_ready_i[i]),                                          //TODO: For desynced operands, will need a ready signal per operand
                .vfu_data_valid_o(shift_regs_valid[i]),
                .vfu_data_o(shift_reg_outputs[i])
            );
        end
    endgenerate

    /////////////////
    // Mask Shift Register
    // Uses special v0 port
    /////////////////

    logic mask_reg_gnt;
    assign mask_reg_gnt = ~metadata_q.pend_wr_map[0]; //mask reg can be read as long as there is not a pending write

    logic mask_done;
    mask_reg_shift_register #(
        .VREG_PORT_W        (MAX_VPORT_W),
        .CFG_VL_W           (CFG_VL_W),
        .PIPE_OP_W          (MAX_OP_W)
    ) mask_register (

        .clk_i(clk_i),
        //.async_rst_ni,
        .sync_rst_ni(sync_rst_ni),

        .pipe_in_valid_i(shift_reg_in_valid_q), //Mask shift reg triggered for every instruction
        .shift_reg_ready_o(mask_reg_ready),
        .dest_eew_i(metadata_q.ctrl.decode_metadata.mask_operand.sew),
        .dest_emul_i(metadata_q.ctrl.decode_metadata.dest_emul),
        .dest_frac_i(metadata_q.ctrl.decode_metadata.dest_frac),
        .repeats_i(metadata_q.ctrl.decode_metadata.mask_operand.repeats),
        .dest_shift_rate_i(metadata_q.ctrl.decode_metadata.mask_operand.shift_rate),

        .vl_i(metadata_q.ctrl.vl),
        .vl_0_i(metadata_q.ctrl.vl_0),
        .masked_i(metadata_q.ctrl.decode_metadata.masked),

        .finished_o(mask_done),   //Currently last cycle signalling ignored for shift reg.

        .vreg_rd_gnt_i(mask_reg_gnt),
        .vreg_rd_data_i(vreg_rd_v0_i),

        .vfu_ready_i(pipe_out_mask_ready_i),
        .vfu_data_valid_o(pipe_out_mask_valid_o),
        .vfu_mask_o(pipe_out_mask_data_o)
    );

    //////////////
    //Output signalling
    //////////////
    logic [VPORT_CNT-1:0] shift_regs_valid;

    //get list of active shift regs.  Scalar input arguments are immediately marked valid as well
    logic [VPORT_CNT-1:0] active_and_valid;
    generate
        for (genvar i = 0; i < VPORT_CNT; i++) begin
            assign active_and_valid[i] = shift_regs_valid[i] & (metadata_q.ctrl.decode_metadata.operands[i].vreg | metadata_q.ctrl.decode_metadata.operands[i].xreg); //TODO: loads mark the "scalar" register as valid, although value is passed through metadata buffers.  Will be necessary to fix this for segmented improvements
        end
    endgenerate

    //Unpack needs to generate a single cycle pulse for the first cycle of an operation
    //First cycle is the first valid output after shift regs have been activated.

    logic first_cycle_d, first_cycle_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            first_cycle_q <=  1'b0;
        end else begin
            first_cycle_q <= first_cycle_d;
        end
    end

    always_comb begin
        first_cycle_d = first_cycle_q;
        if (pipe_in_valid_i & pipe_in_ready_o) begin
            first_cycle_d = 1'b0;
        end else if (!first_cycle_q & (|(active_and_valid & pipe_out_ready_i) | pipe_out_mask_valid_o & pipe_out_mask_ready_i)) begin //only signal first cycle if vfu is ready to receive the first cycle of data or mask value
            first_cycle_d = 1'b1;
        end
    end

    always_comb begin
        if (state_q == READY && pipe_in_valid_i) begin
            for (int i = 0; i < VPORT_CNT; i++) begin
                active_ops_d[i] = pipe_in_ctrl_i.decode_metadata.operands[i].vreg | pipe_in_ctrl_i.decode_metadata.operands[i].xreg; //Set active ops for all vreg ops
            end
            active_mask_d = 1'b1; //mask always active
        end else begin
            active_ops_d = shift_reg_done ^ active_ops_q; //as ops finish, mark done.
            active_mask_d = mask_done ^ active_mask_q;
        end
    end

    //output signals
    always_comb begin
        pipe_out_valid_o = active_and_valid;
        pipe_out_ctrl_o = metadata_q.ctrl;
        pipe_out_ctrl_o.first_cycle = (|(active_and_valid & pipe_out_ready_i) | pipe_out_mask_valid_o & pipe_out_mask_ready_i) & !first_cycle_q; //Only signal on first valid result or mask that is accepted
        pipe_out_ctrl_o.last_cycle = (!active_mask_d) & (state_q == SHIFTING) & (|pipe_out_ready_i | pipe_out_mask_ready_i);  //signal last cycle when last valid mask register output is accepted (for most functional units all are in sync anyways)
    end

    //Vector Argument outputs come from the operand shift registers.
    generate
        for (genvar i = 0; i < VPORT_CNT; i++) begin
            always_comb begin
                pipe_out_op_data_o[i] = shift_reg_outputs[i];
            end
        end
    endgenerate

endmodule
