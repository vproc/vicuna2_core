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
    input  vproc_pkg::cfg_emul                    operand_emul_i,
    input  logic [VADDR_W-1:0]              operand_vaddr_base_i,
    input  vproc_pkg::op_shift_rate         operand_shift_rate_i,

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
    logic [VADDR_W-1:0] current_vreg;
    logic [3:0]             vreg_reads_remaining;//up to 8 vregs need to be read (LMUL8)
    cfg_vsew                eew;
    logic [$clog2((VREG_PORT_W * 4) / PIPE_OP_W)-1:0] shifts_remaining; //TODO: EXTEND FOR ELEMWISE
    logic                   valid_data;
    vproc_pkg::op_shift_rate shift_rate;
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
                    ctrl_d.eew = operand_eew_i;
                    ctrl_d.valid_data = 1'b0;
                    ctrl_d.shift_rate = operand_shift_rate_i;
                    unique case ({operand_emul_i, operand_shift_rate_i}) //Destination EMUL is given to unpack.  Select number of source registers to read based on destination emul and shift rate
                        {EMUL_1, SHIFT_QUARTER_WIDTH},  // Read one register minimum for fractional emuls
                        {EMUL_1, SHIFT_HALF_WIDTH}, 
                        {EMUL_1, SHIFT_FULL_WIDTH},
                        {EMUL_2, SHIFT_HALF_WIDTH},
                        {EMUL_4, SHIFT_QUARTER_WIDTH}: ctrl_d.vreg_reads_remaining = 1;
                        {EMUL_2, SHIFT_FULL_WIDTH},
                        {EMUL_4, SHIFT_HALF_WIDTH},
                        {EMUL_8, SHIFT_QUARTER_WIDTH}: ctrl_d.vreg_reads_remaining = 2;
                        {EMUL_4, SHIFT_FULL_WIDTH},
                        {EMUL_8, SHIFT_HALF_WIDTH}: ctrl_d.vreg_reads_remaining = 4;
                        {EMUL_8, SHIFT_FULL_WIDTH}: ctrl_d.vreg_reads_remaining = 8;
                    endcase
                end
            end

            VREG_SHIFT: begin
                if (vfu_ready_i & ctrl_q.valid_data & !(ctrl_q.shifts_remaining == 0)) begin
                    ctrl_d.shifts_remaining = ctrl_q.shifts_remaining - 1; //Only shift if vector functional unit is ready
                end else if (ctrl_q.shifts_remaining == 0) begin
                    if (ctrl_q.vreg_reads_remaining == 0) begin //if all reads complete, return to idle
                        state_d = IDLE;
                        finished_o = 1'b1;
                        ctrl_d.valid_data = 1'b0; 
                    end else begin
                        vreg_rd_req_o = !use_xval_i; //only issue read if using vector arg
                        if (vreg_rd_gnt_i | use_xval_i) begin //On successful load, set shift counter
                            ctrl_d.vreg_reads_remaining = ctrl_q.vreg_reads_remaining - 1;
                            ctrl_d.shifts_remaining = '1;
                            unique case (ctrl_q.shift_rate)
                                SHIFT_FULL_WIDTH:       ctrl_d.shifts_remaining = VREG_PORT_W/PIPE_OP_W-1; //standard shift case
                                SHIFT_HALF_WIDTH:       ctrl_d.shifts_remaining = VREG_PORT_W*2/PIPE_OP_W-1;
                                SHIFT_QUARTER_WIDTH:    ctrl_d.shifts_remaining = VREG_PORT_W*4/PIPE_OP_W-1;
                                SHIFT_ELEMWISE:         ctrl_d.shifts_remaining = '1;
                            endcase
                            ctrl_d.current_vreg = ctrl_q.current_vreg + 1;
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
        if(state_q == VREG_SHIFT && ctrl_q.shifts_remaining == '0) begin
            if (use_xval_i) begin
                unique case (ctrl_q.eew)
                        VSEW_32: begin
                            unique case (ctrl_q.shift_rate) 
                                SHIFT_FULL_WIDTH:       shift_reg_d = {(VREG_PORT_W/32){xval_i[31:0]}};
                                SHIFT_HALF_WIDTH:       shift_reg_d = {(VREG_PORT_W/16){xval_i[15:0]}};
                                SHIFT_QUARTER_WIDTH:    shift_reg_d = {(VREG_PORT_W/8){xval_i[7:0]}};
                            endcase
                        end 
                        VSEW_16: begin
                            unique case (ctrl_q.shift_rate) 
                                SHIFT_FULL_WIDTH:       shift_reg_d = {(VREG_PORT_W/16){xval_i[15:0]}};
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
                        SHIFT_QUARTER_WIDTH:    shift_reg_d = '0; //TODO
                        SHIFT_ELEMWISE:         shift_reg_d = '0; //TODO
                endcase
            end
        end
    end

    assign vreg_rd_addr_o = ctrl_q.current_vreg;

    //Output assignments
    always_comb begin
        unique case (ctrl_q.shift_rate) //Select output bits based on shift rate TODO: SIGN EXTENSION
            SHIFT_FULL_WIDTH:   vfu_data_o = shift_reg_q[PIPE_OP_W-1:0];
            SHIFT_HALF_WIDTH:   begin
                                    unique case (ctrl_q.eew)  //Destination SEW is passed here, so SEW8 is not possible
                                        VSEW_32: begin
                                            for (integer i = 0; i < PIPE_OP_W/32; i++) begin
                                                vfu_data_o[32*i +: 32] = {{(16){1'b0}}, shift_reg_q[16 * i +: 16]};
                                            end
                                        end
                                        VSEW_16:  begin
                                            for (integer i = 0; i < PIPE_OP_W/16; i++) begin
                                                vfu_data_o[16*i +: 16] = {{(8){1'b0}}, shift_reg_q[8 * i +: 8]};
                                            end
                                        end
                                    endcase
                                end
            SHIFT_QUARTER_WIDTH:begin
                                    unique case (ctrl_q.eew)  //Destination SEW is passed here, so SEW8 and SEW16 is not possible
                                        VSEW_32: begin
                                            for (integer i = 0; i < PIPE_OP_W/32; i++) begin
                                                vfu_data_o[32*i +: 32] = {{(24){1'b0}}, shift_reg_q[8 * i +: 8]};
                                            end
                                        end
                                    endcase
                                end
            SHIFT_ELEMWISE:         vfu_data_o = '0; //TODO
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
    input  vproc_pkg::cfg_vsew                     operand_eew_i,
    input  vproc_pkg::cfg_emul                    operand_emul_i,
    input  vproc_pkg::op_shift_rate         operand_shift_rate_i,
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

    //Control signals for operand shift register
    typedef struct packed {
    cfg_vsew                    eew;
    logic [$clog2(VREG_PORT_W * 8 * 8 / PIPE_OP_W)-1:0] shifts_remaining; //TODO: Will need to be extended for elemwise
    logic                       valid_data;
    logic                       masked;
    vproc_pkg::op_shift_rate    shift_rate;
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
        finished_o = 1'b0;
        unique case (state_q)
            IDLE: begin
                if (pipe_in_valid_i) begin
                    state_d = VREG_SHIFT;
                    ctrl_d.eew = operand_eew_i;
                    ctrl_d.valid_data = 1'b0;
                    ctrl_d.masked     = masked_i;
                    ctrl_d.shift_rate = operand_shift_rate_i;
                    unique case ({operand_emul_i , operand_shift_rate_i}) //Set # of remaining shifts based on emul and shift rate
                        {EMUL_1, SHIFT_FULL_WIDTH}:     ctrl_d.shifts_remaining     = (    VREG_PORT_W)/PIPE_OP_W - 1;
                        {EMUL_1, SHIFT_HALF_WIDTH}, //TODO: INVESTIGATE  This condition is only true for fractional lmul operations, why does the number of shifts required increase here?  Number of shifts needed should ONLY depend on destination EMUL.  Can then get rid of other conditions
                        {EMUL_2, SHIFT_HALF_WIDTH},
                        {EMUL_2, SHIFT_FULL_WIDTH}:     ctrl_d.shifts_remaining     = (2 * VREG_PORT_W)/PIPE_OP_W - 1;
                        {EMUL_1, SHIFT_QUARTER_WIDTH},
                        {EMUL_4, SHIFT_HALF_WIDTH},
                        {EMUL_4, SHIFT_FULL_WIDTH}:     ctrl_d.shifts_remaining     = (4 * VREG_PORT_W)/PIPE_OP_W - 1;
                        
                        {EMUL_2, SHIFT_QUARTER_WIDTH},
                        {EMUL_8, SHIFT_HALF_WIDTH},
                        {EMUL_8, SHIFT_FULL_WIDTH}:     ctrl_d.shifts_remaining     = (8 * VREG_PORT_W)/PIPE_OP_W - 1;
                        
                        {EMUL_4, SHIFT_QUARTER_WIDTH}:  ctrl_d.shifts_remaining     = (16 * VREG_PORT_W)/PIPE_OP_W - 1;
                        {EMUL_8, SHIFT_QUARTER_WIDTH}:  ctrl_d.shifts_remaining     = (32 * VREG_PORT_W)/PIPE_OP_W - 1;
                    endcase
                end
            end

            VREG_SHIFT: begin
                if (vfu_ready_i & ctrl_q.valid_data) begin
                    ctrl_d.shifts_remaining = ctrl_q.shifts_remaining - 1; //Only shift if vector functional unit is ready
                end
                if (ctrl_q.shifts_remaining == 0 & vfu_ready_i) begin //Only 1 register needs to be read/shifted, exit when no shifts remain
                    state_d = IDLE;
                    finished_o = 1'b1;
                    ctrl_d.valid_data = 1'b0; 
                end else begin
                    if (vreg_rd_gnt_i | !ctrl_q.masked) begin
                        ctrl_d.valid_data = 1'b1;
                    end else begin
                        ctrl_d.valid_data = 1'b0; //On failed read, set data valid to 0
                    end
                end
            end
        endcase
    end

    //VREG Shift register
    logic [VREG_PORT_W-1:0] shift_reg_d, shift_reg_q; //Entire mask register loaded

    logic [VREG_PORT_W-1:0] mask_reg_bytes; //translate mask register to byte register based on SEW

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            shift_reg_q <= '0;
        end else begin
            shift_reg_q <= shift_reg_d;
        end
    end

    always_comb begin
        shift_reg_d = shift_reg_q;
        if (state_q == IDLE) begin //generate initial state based on vl
            shift_reg_d = '0;
            if (!vl_0_i) begin
                for (int i = 0; i <= vl_i; i++) begin //vl is passed as # bytes -1, so <= here + guard for vl=0.
                    shift_reg_d[i] = 1'b1; //TODO: Might need to adjust based on shift rate
                end
            end
        end else if(state_q == VREG_SHIFT && !ctrl_q.valid_data) begin
            shift_reg_d = ctrl_q.masked ? mask_reg_bytes & shift_reg_q : shift_reg_q; //If mask register needed, & with VL mask
        end else if (state_q == VREG_SHIFT) begin
            if (vfu_ready_i) begin
                shift_reg_d = {{(PIPE_OP_W/8){1'b0}}, shift_reg_q[VREG_PORT_W-1 : PIPE_OP_W/8]}; //mask is scaled based on destination EMUL/SEW.  No need for different shift rates (TODO: except for elemwise)
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
        vfu_mask_o = shift_reg_q[PIPE_OP_W/8-1:0];
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
        input  METADATA_T                                pipe_in_ctrl_i,       // pipeline control sigs
        input  vproc_pkg::op_unit                        pipe_in_unit_i,
        input  vproc_pkg::cfg_vsew                       pipe_in_alt_eew_i,
        input  vproc_pkg::cfg_vsew                       pipe_in_eew_i,        // current element width
        input  logic   [VPORT_CNT-1:0]                   pipe_in_op_load_i,    // load signals of ops
        input  logic   [VPORT_CNT-1:0][MAX_VADDR_W-1:0]  pipe_in_op_vaddr_i,   // vreg addresses of ops
        input  FLAGS_T [VPORT_CNT-1:0]                   pipe_in_op_flags_i,   // unpack flags of ops
        input  logic   [1:0][31           :0]            pipe_in_op_xval_i,    // X reg values for ops, only 2 of these
        input  logic   [MEM_PORTS-1:0]                   pipe_in_mem_req_valid_i,
        input  logic   [MEM_PORTS-1:0][2:0]              pipe_in_field_counter_i,

        input  logic   [31:0]                            pend_wr_map_i,        //Pending writes (as of the instruction being issued)
        input  logic   [31:0]                            pend_wr_clear_i,      //Writes that have been completed

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
        cfg_vsew                                 alt_eew;
        logic   [MEM_PORTS-1:0]                  mem_req_valid;
        logic   [MEM_PORTS-1:0][2:0]             field_counter;
        logic   [VPORT_CNT-1:0]                  op_load;
        logic   [VPORT_CNT-1:0][MAX_VADDR_W-1:0] op_vaddr;
        FLAGS_T [VPORT_CNT-1:0]                  op_flags;
        logic   [2-1:0][31           :0]         op_xval; //Maximum 2 of these.  TODO: PARAMETERIZE
        logic   [VPORT_CNT-1:0][MAX_VPORT_W-1:0] op_buffer;
        logic   [VPORT_CNT-1:0][MAX_OP_W   -1:0] op_data;
        logic   [31:0]                           pend_wr_map;
        logic                                    masked;
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
            metadata_d.alt_eew  = pipe_in_alt_eew_i;
            metadata_d.eew      = pipe_in_eew_i;
            metadata_d.emul     = pipe_in_ctrl_i.emul;
            metadata_d.op_load  = pipe_in_op_load_i;
            metadata_d.op_vaddr = pipe_in_op_vaddr_i;
            metadata_d.op_flags = pipe_in_op_flags_i;
            metadata_d.op_xval  = pipe_in_ctrl_i.op_xval;
            metadata_d.mem_req_valid = pipe_in_mem_req_valid_i;
            metadata_d.field_counter = pipe_in_field_counter_i;
            metadata_d.pend_wr_map = pend_wr_map_i & (~pend_wr_clear_i); //in case a pending write is cleared this cycle
            metadata_d.masked = pipe_in_ctrl_i.masked;
        end
    end

    /////////////////
    //Operand Shift registers 
    //Maximum 3 Ports, rs1, rs2, rd
    /////////////////
    logic   [VPORT_CNT-1:0][MAX_OP_W   -1:0]  shift_reg_outputs;
    logic   [VPORT_CNT-1:0]                   shift_reg_done;
    logic   [VPORT_CNT-1:0]                   shift_reg_req;
    generate
        for (genvar i = 0; i < VPORT_CNT; i++) begin
            assign vreg_rd_req_o[i] = shift_reg_req[i] & ~metadata_q.pend_wr_map[vreg_rd_addr_o[i]]; //Request signal from shift reg valid if not marked as pending write (not a data hazard)
        end
    endgenerate
    assign vreg_rd_id_o     = metadata_q.ctrl.id;

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

                .pipe_in_valid_i(shift_reg_in_valid_q & (metadata_q.op_flags[i].vreg | metadata_q.op_flags[i].xreg)),
                .shift_reg_ready_o(shift_regs_ready[i]),
                .operand_eew_i(metadata_q.eew),                                          //TODO: Mixed precision operations will need an EEW/operand
                .operand_emul_i(metadata_q.emul), 
                .operand_vaddr_base_i(metadata_q.op_vaddr[i]),
                .operand_shift_rate_i(metadata_q.ctrl.op_flags[i].shift_rate), 

                .use_xval_i(metadata_q.op_flags[i].xreg),
                .xval_i(metadata_q.op_xval[i]),

                .finished_o(shift_reg_done[i]),

                .vreg_rd_gnt_i(vreg_rd_gnt_i[i]),
                .vreg_rd_req_o(shift_reg_req[i]),
                .vreg_rd_addr_o(vreg_rd_addr_o[i]),
                .vreg_rd_data_i(vreg_rd_data_i[i]),

                .vfu_ready_i(pipe_out_ready_i),                                          //TODO: For desynced operands, will need a ready signal per operand
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
        .operand_eew_i(metadata_q.eew),         //TODO: For mixed width ops, always ensure the destination sew is passed here
        .operand_emul_i(metadata_q.emul),
        .operand_shift_rate_i(metadata_q.ctrl.op_flags[0].shift_rate), //TODO: Currently based off of OP0 shift rate
        
        .vl_i(metadata_q.ctrl.vl),
        .vl_0_i(metadata_q.ctrl.vl_0),
        .masked_i(metadata_q.masked),

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
            assign active_and_valid[i] = shift_regs_valid[i] & metadata_q.op_flags[i].vreg | metadata_q.op_flags[i].xreg; //TODO: loads mark the "scalar" register as valid, although value is passed through metadata buffers.  Will be necessary to fix this for segmented improvements
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
                active_ops_d[i] = pipe_in_ctrl_i.op_flags[i].vreg | pipe_in_ctrl_i.op_flags[i].xreg; //Set active ops for all vreg ops
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


//// OLD
//     vproc_pkg::cfg_vsew                    pipe_in_eew_q;
//     vproc_pkg::op_unit                     pipe_in_unit_q;
//       always_ff @(posedge clk_i) begin
//     if (~sync_rst_ni) begin
//         pipe_in_eew_q <= '0;
//         pipe_in_unit_q <= '0;
//     end else begin
//         pipe_in_eew_q <= pipe_in_eew_i;  //Need to buffer this value, temporary fix.  
//         pipe_in_unit_q <= pipe_in_unit_i;
//     end
//   end
  

//     generate
//         for (genvar i = 0; i < VPORT_CNT; i++) begin
//             if (VPORT_W[i] > MAX_VPORT_W) begin
//                 $fatal(1, "Vector register read port %d is %d bits wide, exceeds maximum of %d",
//                           i, VPORT_W[i], MAX_VPORT_W);
//             end
//             if (VADDR_W[i] > MAX_VADDR_W) begin
//                 $fatal(1, "Vector register read port %d has %d address bits, exceeds maximum of %d",
//                           i, VADDR_W[i], MAX_VADDR_W);
//             end
//         end
//         for (genvar i = 0; i < OP_CNT; i++) begin
//             if (OP_W[i] > MAX_OP_W) begin
//                 $fatal(1, "Operand %d has a width of %d bits, exceeds maximum of %d",
//                           i, OP_W[i], MAX_OP_W);
//             end
//             if (OP_STAGE[i] + 1 > UNPACK_STAGES) begin
//                 $fatal(1, "Operand %d load stage %d is invalid (unpack has %d stages)",
//                           i, OP_STAGE[i], UNPACK_STAGES);
//             end
//         end
//     endgenerate

//     typedef struct packed {
//         logic               [CTRL_DATA_W-1:0] ctrl;
//         op_unit                               unit;
//         cfg_vsew                              eew;
//         cfg_vsew                              alt_eew;
//         logic   [MEM_PORTS-1:0]               mem_req_valid;
//         logic   [MEM_PORTS-1:0][2:0]          field_counter;
//         logic   [OP_CNT-1:0]                  op_load;
//         logic   [OP_CNT-1:0][MAX_VADDR_W-1:0] op_vaddr;
//         FLAGS_T [OP_CNT-1:0]                  op_flags;
//         logic   [OP_CNT-1:0][31           :0] op_xval;
//         logic   [OP_CNT-1:0][MAX_VPORT_W-1:0] op_buffer;
//         logic   [OP_CNT-1:0][MAX_OP_W   -1:0] op_data;
//     } vregunpack_state_t;

//     vregunpack_state_t stage_0;
//     always_comb begin
//         stage_0          = vregunpack_state_t'(DONT_CARE_ZERO ? '0 : 'x);
//         `ifdef OLD_VICUNA
//         stage_0.ctrl     = pipe_in_ctrl_i;
//         stage_0.unit     = pipe_in_unit_i;
//         stage_0.alt_eew  = pipe_in_alt_eew_i;
//         stage_0.eew      = pipe_in_eew_q;
//         stage_0.op_load  = pipe_in_op_load_i;
//         stage_0.op_vaddr = pipe_in_op_vaddr_i;
//         stage_0.op_flags = pipe_in_op_flags_i;
//         stage_0.op_xval  = pipe_in_op_xval_i;
//         stage_0.mem_req_valid = pipe_in_mem_req_valid_i;
//         stage_0.field_counter = pipe_in_field_counter_i;
//         `else
//         if (pipe_in_ready_o & pipe_in_valid_i) begin
//             stage_0.ctrl     = pipe_in_ctrl_i;
//             stage_0.unit     = pipe_in_unit_i;
//             stage_0.alt_eew  = pipe_in_alt_eew_i;
//             stage_0.eew      = pipe_in_eew_q;
//             stage_0.op_load  = pipe_in_op_load_i;
//             stage_0.op_vaddr = pipe_in_op_vaddr_i;
//             stage_0.op_flags = pipe_in_op_flags_i;
//             stage_0.op_xval  = pipe_in_op_xval_i;
//             stage_0.mem_req_valid = pipe_in_mem_req_valid_i;
//             stage_0.field_counter = pipe_in_field_counter_i;
//         end
//         `endif
//     end

//     // Unpack stage signals.  Note that stage 0 gets assigned the input values and hence is not an
//     // actual stage.  Thus, there are intentionally one more valid, ready, and state signals than
//     // actual stages.
//     logic              [UNPACK_STAGES:0] stage_valid, stage_valid_q, stage_valid_d;
//     vregunpack_state_t [UNPACK_STAGES:0] stage_state, stage_state_q, stage_state_d;
//     logic              [UNPACK_STAGES:0] stage_ready;

//     always_ff @(posedge clk_i or negedge async_rst_ni) begin
//         if (~async_rst_ni) begin
//             stage_valid_q <= '0;
//         end
//         else if (~sync_rst_ni) begin
//             stage_valid_q <= '0;
//         end
//         else begin
//             stage_valid_q <= stage_valid_d;
//         end
//     end
//     always_ff @(posedge clk_i) begin
//         stage_state_q <= stage_state_d;
//         field_buffer_q <= field_buffer_d;
//     end

//     always_comb begin
//         `ifdef OLD_VICUNA
//         stage_valid[0] = pipe_in_valid_i;
//         `else
//         stage_valid[0] = pipe_in_valid_i & pipe_in_ready_o;
//         `endif
//         stage_state[0] = stage_0;
//         for (int i = 1; i < UNPACK_STAGES + 1; i++) begin
//             stage_valid[i] = stage_valid_q[i];
//             stage_state[i] = stage_state_q[i];
//         end
//     end

//     // Operand buffers next-state signal and extracted operand data
//     logic [OP_CNT-1:0][MAX_VPORT_W-1:0] op_buffer_next;
//     logic [OP_CNT-1:0][MAX_OP_W   -1:0] op_data;

//     logic [6:0][MAX_VPORT_W-1:0] field_buffer_q;
//     logic [6:0][MAX_VPORT_W-1:0] field_buffer_d;
//     logic [6:0][MAX_VPORT_W-1:0] field_buffer_next;

//     always_comb begin
//         stage_valid_d = stage_valid_q;
//         stage_state_d = stage_state_q;
//         field_buffer_d = field_buffer_q;
        
//         for (int i = 1; i < UNPACK_STAGES + 1; i++) begin
//             if (stage_ready[i]) begin
//                 `ifdef OLD_VICUNA
//                     stage_valid_d[i] = (i == 1) ? pipe_in_valid_i : stage_valid_q[i-1];
//                 `else
//                     stage_valid_d[i] = (i == 1) ? pipe_in_valid_i & pipe_in_ready_o : stage_valid_q[i-1];
//                 `endif
                
//                 stage_state_d[i] = (i == 1) ? stage_0         : stage_state_q[i-1];

//                 // operand buffer is part of the stage after the respective vreg load; this is a
//                 // cyclic buffer and thus must only be updated if the associated stage will be valid
//                 // in the next cycle (i.e., if the prior stage is currently valid) and retains its
//                 // current value otherwise.  Note that in contrast to all other state logic the
//                 // operand buffer is never carried over from the previous stage.
//                 for (int j = 0; j < OP_CNT; j++) begin
//                     if (i == OP_STAGE[j] + 1) begin
//                         if (stage_valid_q[OP_STAGE[j]]) begin
//                             stage_state_d[i].op_buffer[j] = op_buffer_next[j];
//                             if(OP_FIELD[j]) begin
//                                 field_buffer_d = field_buffer_next;
//                             end
//                         end else begin
//                             stage_state_d[i].op_buffer[j] = stage_state_q[i].op_buffer[j];
//                             if(OP_FIELD[j]) begin
//                                 field_buffer_d = field_buffer_q;
//                             end
//                         end
//                     end
//                 end

//                 // unpacked operands are buffered starting from two stages after the respective
//                 // vreg load
//                 for (int j = 0; j < OP_CNT; j++) begin
//                     if (i == OP_STAGE[j] + 2) begin
//                         stage_state_d[i].op_data[j] = op_data[j];
//                     end
//                 end
//             end
//         end
//     end

//     always_comb begin
//         // None of the unpack stages can stall by itself, hence all the stages are ready if the
//         // output pipe is ready.  Additionally any stage that is not currently valid is also ready
//         // to accept new data.  However, this might create problems if buffered vector register
//         // ports have inconsistent ready conditions when being loaded by different operands in
//         // different stages.  To avoid troubles, all stages are only ready when the output pipe is
//         // ready if any of the vector register ports is being buffered.
//         stage_ready = {(UNPACK_STAGES+1){pipe_out_ready_i}};
//         if (VPORT_BUFFER == '0) begin
//             for (int i = 0; i < UNPACK_STAGES; i++) begin
//                 for (int j = i; j < UNPACK_STAGES; j++) begin
//                     if (~stage_valid[j]) begin
//                         // A stage is ready if the next stage is ready or if it is invalid, which
//                         // implies that a stage is also ready if any subsequent stage is invalid.
//                         stage_ready[i] = 1'b1;
//                     end
//                 end
//             end
//         end
//     end


//     // Generate a stall in case the next operation and the current one will use the same read port
//     // Confirm with all pending loads in the unpack stages that the OP_SRC is not shared
//     `ifndef OLD_VICUNA
//     //TODO: find a more efficient way to store/collect these signals
//     logic [UNPACK_STAGES-1:0][OP_CNT-1:0][OP_CNT-1:0] op_conflict;
//     generate
//         //for every operand in the incoming instruction
//         for (genvar i = 0; i < OP_CNT; i++) begin
//             //for every operand that could be currently in the unpack pipeline
//             for (genvar j = 0; j < OP_CNT; j++) begin
//                 //For every stage in the unpack pipeline
//                 for (genvar k = 0; k < UNPACK_STAGES; k++) begin
//                     //If the operand is due to be loaded and there could be a conflict
//                     if ( (k < OP_STAGE[j]) & (OP_SRC[i] == OP_SRC[j])) begin
//                         //Mark if a conflict has occurred and a stall needs to be generated (only if input is actually valid)
//                         assign op_conflict[k][i][j] = pipe_in_op_load_i[i] & stage_state_q[1].op_load[j]  & pipe_in_valid_i;
//                     end else begin
//                         //otherwise, no conflict
//                         assign op_conflict[k][i][j] = 1'b0;
//                     end      
//                 end     
//             end
//         end
//     endgenerate
//     `endif






//     always_comb begin
//         `ifdef OLD_VICUNA
//         pipe_in_ready_o    = stage_ready[0];
//         `else
//         pipe_in_ready_o    = stage_ready[0] & (~|op_conflict);
//         `endif

//         pipe_out_valid_o   = stage_valid[UNPACK_STAGES];
//         pipe_out_ctrl_o    = stage_state[UNPACK_STAGES].ctrl;
//         pipe_out_op_data_o = stage_state[UNPACK_STAGES].op_data;
//         // make operands that have just been unpacked available to the output pipe
//         for (int i = 0; i < OP_CNT; i++) begin
//             if (OP_STAGE[i] + 1 == UNPACK_STAGES) begin
//                 pipe_out_op_data_o[i] = op_data[i];
//             end
//         end
//     end

//     // Addressing signals and vreg addresses of operands and masks;  addressing takes place in the
//     // stage prior to loading the operand buffer if the respective vreg is buffered and in the same
//     // stage otherwise.
//     logic [OP_CNT-1:0]                  op_addressing;
//     logic [OP_CNT-1:0][MAX_VADDR_W-1:0] op_vreg_addr;
//     generate
//         for (genvar i = 0; i < OP_CNT; i++) begin
//             localparam int unsigned ADDR_STAGE = (OP_SRC[i] < VPORT_CNT) ? (
//                 VPORT_BUFFER[OP_SRC[i]] ? OP_STAGE[i] - 1 : OP_STAGE[i]
//             ) : OP_STAGE[i];
//             assign op_addressing[i] = stage_valid[ADDR_STAGE] &
//                                       stage_state[ADDR_STAGE].op_load[i] &
//                                       (~OP_XREG[i] | stage_state[ADDR_STAGE].op_flags[i].vreg);
//             if (OP_DYN_ADDR[i]) begin
//                 // assign legal values for v0 operands to avoid parser errors
//                 localparam int unsigned OP_VADDR_W = (OP_SRC[i]<VPORT_CNT) ? VADDR_W[OP_SRC[i]] : 5;
//                 localparam int unsigned OP_VPORT_W = (OP_SRC[i]<VPORT_CNT) ? VPORT_W[OP_SRC[i]] : 8;

//                 // get dynamic address offset from operand with index OP_DYN_ADDR_SRC
//                 logic [OP_W[OP_DYN_ADDR_SRC]-1:0] op_dyn_addr_data;
//                 assign op_dyn_addr_data = (OP_STAGE[OP_DYN_ADDR_SRC] + 1 == ADDR_STAGE) ? op_data[
//                                               OP_DYN_ADDR_SRC][OP_W[OP_DYN_ADDR_SRC]-1:0
//                                           ] : stage_state[ADDR_STAGE].op_data[
//                                               OP_DYN_ADDR_SRC][OP_W[OP_DYN_ADDR_SRC]-1:0
//                                           ];
//                 logic [31:0] op_dyn_addr_offset;
//                 always_comb begin
//                     op_dyn_addr_offset = DONT_CARE_ZERO ? '0 : 'x;
//                     unique case (stage_state[ADDR_STAGE].eew)
//                         VSEW_8:  op_dyn_addr_offset = {24'b0, op_dyn_addr_data[7 :0]      };
//                         VSEW_16: op_dyn_addr_offset = {15'b0, op_dyn_addr_data[15:0], 1'b0};
//                         VSEW_32: op_dyn_addr_offset = {       op_dyn_addr_data[29:0], 2'b0};
//                         default: ;
//                     endcase
//                 end
//                 // the address offset may be used to address up to 1/4 of the available vector
//                 // register space and is OR-ed with the specified base address
//                 assign op_vreg_addr[i] = stage_state[ADDR_STAGE].op_vaddr[i] | {2'b0,
//                     op_dyn_addr_offset[$clog2(OP_VPORT_W/8 ) +: OP_VADDR_W-2],
//                     {(MAX_VADDR_W-OP_VADDR_W){1'b0}}
//                 };
//             end else begin
//                 assign op_vreg_addr[i] = stage_state[ADDR_STAGE].op_vaddr[i];
//             end
//         end
//     endgenerate

//     // Vreg addressing
//     generate
//         for (genvar i = 0; i < VPORT_CNT; i++) begin
//             always_comb begin
//                 vreg_rd_addr_o[i] = DONT_CARE_ZERO ? '0 : 'x;
//                 for (int j = 0; j < OP_CNT; j++) begin
//                     if ((i == OP_SRC[j]) & op_addressing[j]) begin
//                         vreg_rd_addr_o[i] = {
//                             op_vreg_addr[j][MAX_VADDR_W-1:MAX_VADDR_W-VADDR_W[i]],
//                             {(MAX_VADDR_W-VADDR_W[i]){1'b0}}
//                         };
//                     end
//                 end
//             end
//         end
//     endgenerate

//     // Vreg buffering
//     logic [VPORT_CNT-1:0][MAX_VPORT_W-1:0] vreg_buffer_q, vreg_buffer_d;
//     always_ff @(posedge clk_i) begin
//         vreg_buffer_q <= vreg_buffer_d;
//     end
//     always_comb begin
//         vreg_buffer_d = vreg_buffer_q;
//         for (int i = 0; i < VPORT_CNT; i++) begin
//             // Ensure consistent ready signals by using the output pipe ready signal for all stages
//             // and for buffering vector register ports if any vector register port is buffered.
//             if (pipe_out_ready_i) begin
//                 vreg_buffer_d[i] = vreg_rd_data_i[i];
//             end
//         end
//     end

//     // Vector register values of operands
//     logic [OP_CNT-1:0][MAX_VPORT_W-1:0] op_vreg_data;
//     always_comb begin
//         for (int i = 0; i < OP_CNT; i++) begin
//             op_vreg_data[i] = (OP_SRC[i] < VPORT_CNT) ? (
//                 VPORT_BUFFER[OP_SRC[i]] ? vreg_buffer_q [OP_SRC[i]] : vreg_rd_data_i[OP_SRC[i]]
//             ) : MAX_VPORT_W'(vreg_rd_v0_i);
//         end
//     end

//     // Load signals, vregs, current buffers, and unpack settings of operands and masks
//     logic    [OP_CNT-1:0]                       op_load;
//     FLAGS_T  [OP_CNT-1:0]                       op_load_flags;
//     cfg_vsew [OP_CNT-1:0]                       op_load_eew;
//     logic    [OP_CNT-1:0][MAX_VPORT_W-1:0]      op_buffer;
//     FLAGS_T  [OP_CNT-1:0]                       op_extract_flags;
//     cfg_vsew [OP_CNT-1:0]                       op_extract_eew;
//     logic    [OP_CNT-1:0][31:0]                 op_xval;
//     logic    [OP_CNT-1:0][MEM_PORTS-1:0][2:0]   op_load_field_counter;
//     logic    [OP_CNT-1:0][MEM_PORTS-1:0][2:0]   op_extract_field_counter;
//     logic    [OP_CNT-1:0][MEM_PORTS-1:0]        op_load_mem_req_valid;
//     logic    [OP_CNT-1:0][MEM_PORTS-1:0]        op_extract_mem_req_valid;
//     always_comb begin
//         for (int i = 0; i < OP_CNT; i++) begin
//             op_load         [i] = stage_state[OP_STAGE[i]    ].op_load[i];
//             op_load_flags   [i] = stage_state[OP_STAGE[i]    ].op_flags[i];
//             op_load_eew     [i] = stage_state[OP_STAGE[i]    ].unit == UNIT_LSU & OP_ALT_COUNTER[i] ? stage_state[OP_STAGE[i]    ].alt_eew : stage_state[OP_STAGE[i]    ].eew;
//             op_buffer       [i] = stage_state[OP_STAGE[i] + 1].op_buffer[i];
//             op_extract_flags[i] = stage_state[OP_STAGE[i] + 1].op_flags[i];
//             op_extract_eew  [i] = stage_state[OP_STAGE[i]    ].unit == UNIT_LSU & OP_ALT_COUNTER[i] ? stage_state[OP_STAGE[i]    ].alt_eew : stage_state[OP_STAGE[i]    ].eew;
//             op_xval         [i] = stage_state[OP_STAGE[i] + 1].op_xval[i];
//             op_load_field_counter [i] = stage_state[OP_STAGE[i]    ].field_counter;
//             op_extract_field_counter [i] = stage_state[OP_STAGE[i] + 1].field_counter;
//             op_load_mem_req_valid [i] = stage_state[OP_STAGE[i]    ].mem_req_valid;
//             op_extract_mem_req_valid [i] = stage_state[OP_STAGE[i] + 1].mem_req_valid;
//         end

//     end

//     // Operand buffer update logic
//     generate
//         for (genvar i = 0; i < OP_CNT; i++) begin
//             logic [OP_W[i]-1:0] op_default;
//             logic [OP_W[i]-1:0] op_mem_default [MEM_PORTS-1:0];
//             // move next mask section (depends on EEW) into lower 3/4 of operand part for masks
//             if (OP_MASK[i]) begin
//                 if (OP_ALWAYS_ELEMWISE[i]) begin
//                     if (OP_W[i] > 1) begin
//                         assign op_default[OP_W[i]-2:0] = op_buffer[i][OP_W[i]-1:1];
//                     end else begin
//                         assign op_default = DONT_CARE_ZERO ? '0 : 'x;
//                     end
//                 end else begin
//                     always_comb begin
//                         op_default = op_buffer[i][OP_W[i]-1:0];
//                         op_default[(OP_W[i]*3)/4-1:0] = DONT_CARE_ZERO ? '0 : 'x;
//                         unique case (op_load_eew[i])
//                             VSEW_16: op_default[(OP_W[i]*3)/4-1:0        ] =
//                                    op_buffer[i][(OP_W[i]*5)/4-1:OP_W[i]/2];
//                             VSEW_32: op_default[(OP_W[i]*3)/4-1:0        ] =
//                                    op_buffer[i][ OP_W[i]     -1:OP_W[i]/4];
//                             default: ;
//                         endcase
//                         if (OP_ALLOW_ELEMWISE[i] & op_load_flags[i].elemwise) begin
//                             unique case (op_load_flags[i].lsu_instr & ~op_load_flags[i].field_instr)
//                                 1'b0: op_default[OP_W[i]-2:0] = op_buffer[i][OP_W[i]-1:1];
//                                 1'b1: op_default[OP_W[i]-1-MEM_PORTS:0] = op_buffer[i][OP_W[i]-1:MEM_PORTS];
//                             endcase
//                         end
//                     end
//                 end
//             end
//             else begin
//                 always_comb begin
//                     // retain current value by default
//                     op_default = op_buffer[i][OP_W[i]-1:0];
                    
//                     for(int j = 0; j < MEM_PORTS; j++) begin
//                     	op_mem_default[j] = op_buffer[i][OP_W[i]-1:0];
//                     end

//                     if(FIELD_COUNT_USED) begin

//                         // use field buffer value instead of op_buffer where field 0 resides
//                         if(OP_FIELD[i]) begin
//                             if(op_load_flags[i].field_instr) begin
//                                 op_mem_default[0][OP_W[i]-1:0] = op_buffer[i][OP_W[i]+MEM_W-1:MEM_W];
//                             end

//                             for(int j = 0; j < MEM_PORTS; j++) begin
//                                 if(op_load_flags[i].field_instr & op_load_field_counter[i][j] > 0) begin
//                                     op_mem_default[j][OP_W[i]-1:0] = field_buffer_q[op_load_field_counter[i][j] - 1][OP_W[i]+MEM_W-1:MEM_W];
//                                 end
//                             end
//                         end
//                     end

//                     if (~OP_HOLD_FLAG[i] | ~op_load_flags[i].hold) begin
//                         // shift down operand part by one byte, halfword, or word for element-wise unpacking
//                         if (OP_ALWAYS_ELEMWISE[i] | (OP_ALLOW_ELEMWISE[i] & op_load_flags[i].elemwise)) begin
//                             if (~OP_HOLD_FLAG[i] | ~op_load_flags[i].hold) begin
//                                 op_default[OP_W[i]-9:0] = DONT_CARE_ZERO ? '0 : 'x;
//                                 unique case ({op_load_eew[i], OP_NARROW[i] & op_load_flags[i].narrow})
//                                     {VSEW_8 , 1'b0},
//                                     {VSEW_16, 1'b1}: op_default[OP_W[i]-9:0] = op_buffer[i][OP_W[i]-1 :8 ];
//                                     {VSEW_16, 1'b0},
//                                     {VSEW_32, 1'b1}: op_default[OP_W[i]-9:0] = op_buffer[i][OP_W[i]+7 :16];
//                                     {VSEW_32, 1'b0}: op_default[OP_W[i]-9:0] = op_buffer[i][OP_W[i]+23:32];
//                                     default: ;
//                                 endcase

//                                 if(op_load_flags[i].lsu_instr) begin

//                                     if(~op_load_flags[i].field_instr) begin
//                                         op_default[OP_W[i]-9:0] = DONT_CARE_ZERO ? '0 : 'x;
//                                         unique case (op_load_eew[i])
//                                             VSEW_8: op_default[OP_W[i]-9:0] = op_buffer[i][OP_W[i]-1 :8*MEM_PORTS ];
//                                             VSEW_16: op_default[OP_W[i]-9:0] = op_buffer[i][OP_W[i]+7 :16*MEM_PORTS];
//                                             VSEW_32: op_default[OP_W[i]-9:0] = op_buffer[i][OP_W[i]+23:32*MEM_PORTS];
//                                             default: ;
//                                         endcase
//                                     end

//                                     for(int j = 0; j < MEM_PORTS; j++) begin
//                                         op_mem_default[j][OP_W[i]-9:0] = DONT_CARE_ZERO ? '0 : 'x;
//                                     end

//                                     op_mem_default[0] = op_default;
                                
//                                     if(FIELD_COUNT_USED) begin
//                                         if(OP_FIELD[i]) begin
//                                             for(int j = 0; j < MEM_PORTS; j++) begin
//                                                 if(op_load_flags[i].field_instr & op_load_field_counter[i][j] > 0) begin
//                                                     unique case (op_load_eew[i])
//                                                         VSEW_8: op_mem_default[j][OP_W[i]-9:0] = field_buffer_q[op_load_field_counter[i][j] - 1][OP_W[i]-1 :8 ];
//                                                         VSEW_16: op_mem_default[j][OP_W[i]-9:0] = field_buffer_q[op_load_field_counter[i][j] - 1][OP_W[i]+7 :16];
//                                                         VSEW_32: op_mem_default[j][OP_W[i]-9:0] = field_buffer_q[op_load_field_counter[i][j] - 1][OP_W[i]+23:32];
//                                                         default: ;
//                                                     endcase
//                                                 end
//                                             end
//                                         end
//                                     end
//                                 end

//                             end
//                         end
                       
//                         else if (op_load_flags[i].vf4_ext) begin
//                              // shift down upper 3/4 of operand part to support narrow operands for [s/z]ext.vf4
//                             op_default[(3*OP_W[i])/4-1:0] = op_buffer[i][OP_W[i]-1:(OP_W[i])/4];  
//                         end else if (OP_NARROW[i]) begin
//                              // shift down upper half of operand part to support narrow operands
//                             op_default[OP_W[i]/2-1:0] = op_buffer[i][OP_W[i]-1:OP_W[i]/2];
//                         end
//                     end
//                 end
//             end

//             localparam int unsigned OP_VPORT_W = (OP_SRC[i] < VPORT_CNT) ? VPORT_W[OP_SRC[i]] :
//                                                                            VPORT_V0_W;
//             always_comb begin
//                 // by default, retain current value for upper part and assign default value for
//                 // lower part
//                 op_buffer_next[i] = {op_buffer[i][MAX_VPORT_W-1:OP_W[i]], op_default};
                
//                 if(OP_FIELD[i]) begin
// 		        for(int k = 0; k < 7; k++) begin
// 		            field_buffer_next[k] = field_buffer_q[k];
// 		        end
//                 end

//                 if(op_load_flags[i].lsu_instr) begin
                        
//                     // retain current value without shifting since it is turn of other field
//                     if(op_load_flags[i].field_instr & op_load_field_counter[i][0] > 0) begin
//                         op_buffer_next[i] = op_buffer[i];
//                     end


//                     if(OP_FIELD[i]) begin
//                         if(op_load_mem_req_valid[i][0] == 1 & op_load_field_counter[i][0] == 0) begin
//                             op_buffer_next[i] = {op_buffer[i][MAX_VPORT_W-1:OP_W[i]], op_mem_default[0]}; 
//                         end

//                         for(int j = 0; j < MEM_PORTS; j++) begin
//                             // shift value if it is turn of field or retain value if it is not turn of field
//                             if(op_load_mem_req_valid[i][j] == 1 & op_load_field_counter[i][j] > 0) begin
//                                 field_buffer_next[op_load_field_counter[i][j]-1] = {field_buffer_q[op_load_field_counter[i][j]-1][MAX_VPORT_W-1:OP_W[i]], op_mem_default[j]};
//                             end
//                         end

//                     end

//                 end

//                 // shift signal overrides mask, narrow, or element-wise updates and shifts entire
//                 // content right by the width of the operand; full-size operands shift every cycle
//                 if ((~OP_MASK[i] & ~OP_NARROW[i] & ~OP_ALLOW_ELEMWISE[i] & ~OP_ALWAYS_ELEMWISE[i]) |
//                     op_load_flags[i].shift
//                 ) begin

//                     op_buffer_next[i][OP_VPORT_W-OP_W[i]-1:0] = op_buffer[i][OP_VPORT_W-1:OP_W[i]];
                    
//                     for(int j = 0; j < MEM_PORTS; j++) begin

//                         if(OP_FIELD[i] & FIELD_COUNT_USED & op_load_flags[i].field_instr) begin
//                             if(op_load_mem_req_valid[i][j] == 1 & op_load_field_counter[i][j] > 0) begin
//                                 field_buffer_next[op_load_field_counter[i][j] - 1][OP_VPORT_W-OP_W[i]-1:0] = field_buffer_q[op_load_field_counter[i][j] - 1][OP_VPORT_W-1:OP_W[i]];
//                             end
//                         end
//                     end

//                     // if it is turn of field, do not shift value of op_buffer
//                     if(FIELD_COUNT_USED & op_load_flags[i].field_instr  & op_load_field_counter[i][0] > 0) begin
//                         op_buffer_next[i] = op_buffer[i];
//                     end
//                 end
//                 // load signal overrides all others and moves vreg value into buffer
//                 if (op_load[i]) begin

//                     // if it is turn of field load value into field buffer, otherwise into op_buffer
//                     if(OP_FIELD[i] & FIELD_COUNT_USED & op_load_flags[i].field_instr  & op_load_field_counter[i][0] > 0) begin
//                         field_buffer_next[op_load_field_counter[i][0] - 1][OP_VPORT_W-1:0] = op_vreg_data[i][OP_VPORT_W-1:0];
//                     end else begin
//                         op_buffer_next[i][OP_VPORT_W-1:0] = op_vreg_data[i][OP_VPORT_W-1:0];
//                     end
//                 end

//             end

//         end
//     endgenerate


//     // Operand extraction logic   
//     generate
//         for (genvar i = 0; i < OP_CNT; i++) begin

//             logic [OP_W[i]-1:0] op_field_helper;

//             if(MEM_PORTS == 1 & OP_FIELD[i]) begin
//                 always_comb begin
//                     op_field_helper = field_buffer_q[op_extract_field_counter[i][0] - 1];
//                 end
//             end else if(OP_FIELD[i]) begin
//                 always_comb begin
//                     // Default assignment to avoid latches
//                     op_field_helper = '0;

//                     for(int j = 0; j < MEM_PORTS; j++) begin
//                         if(op_extract_field_counter[i][j] > 0) begin
//                             op_field_helper[MEM_W*j +: MEM_W] = field_buffer_q[op_extract_field_counter[i][j] - 1][MEM_W-1:0];
//                         end
//                     end
//                 end
//             end else begin
//                 assign op_field_helper = '0; 
//             end

//             always_comb begin
//                 // operand is lower part of operand buffer by default
//                 op_data[i]              = DONT_CARE_ZERO ? '0 : 'x;
//                 op_data[i][OP_W[i]-1:0] = op_buffer[i][OP_W[i]-1:0];

//                 if (OP_MASK[i]) begin
//                     if (OP_ALWAYS_ELEMWISE[i]) begin
//                         // An always element-wise mask consists of only one bit, however all the
//                         // lower OP_W bits of the buffer are moved to the operand without
//                         // modification (which is the default for full-size operands) to support
//                         // alternative uses of the mask data in the first cycle of an instruction.
//                     end else begin
//                         // convert element mask to byte mask if this operand is a mask
//                         op_data[i][OP_W[i]-1:0] = DONT_CARE_ZERO ? '0 : 'x;
//                         unique case (op_extract_eew[i])
//                             VSEW_8: begin
//                                 op_data[i][OP_W[i]-1:0] = op_buffer[i][OP_W[i]-1:0];
//                             end
//                             VSEW_16: begin
//                                 for (int j = 0; j < OP_W[i] / 2; j++) begin
//                                     op_data[i][j*2  ] = op_buffer[i][j];
//                                     op_data[i][j*2+1] = op_buffer[i][j];
//                                 end
//                             end
//                             VSEW_32: begin
//                                 for (int j = 0; j < OP_W[i] / 4; j++) begin
//                                     op_data[i][j*4  ] = op_buffer[i][j];
//                                     op_data[i][j*4+1] = op_buffer[i][j];
//                                     op_data[i][j*4+2] = op_buffer[i][j];
//                                     op_data[i][j*4+3] = op_buffer[i][j];
//                                 end
//                             end
//                             default: ;
//                         endcase
//                     end
//                 end else if(FIELD_COUNT_USED & OP_FIELD[i] & op_extract_flags[i].lsu_instr & op_extract_flags[i].field_instr) begin
//                     // take result value out of field buffer if it is turn of field
//                     for(int j = 0; j < MEM_PORTS; j++) begin
//                         unique case (op_extract_eew[i])
//                             VSEW_8: begin
//                                 if(op_extract_field_counter[i][j] > 0) begin
//                                     op_data[i][8*j +: 8] = field_buffer_q[op_extract_field_counter[i][j] - 1][7:0];
//                                 end
//                             end
//                             VSEW_16: begin
//                                 if(op_extract_field_counter[i][j] > 0) begin
//                                     op_data[i][16*j +: 16] = field_buffer_q[op_extract_field_counter[i][j] - 1][15:0];
//                                 end
//                             end
//                             VSEW_32: begin
//                                 if(op_extract_field_counter[i][j] > 0) begin
//                                     op_data[i][32*j +: 32] = field_buffer_q[op_extract_field_counter[i][j] - 1][31:0];
//                                 end
//                             end
//                             default: ;
//                         endcase
//                     end

//                     if(~op_extract_flags[i].elemwise) begin
//                         op_data[i] = op_field_helper;
//                     end
//                 end else begin
//                     // extend each element to twice its size if this operand is narrow.  If this is a vf4 extension extend to 4 times its size
//                     if (OP_NARROW[i] & op_extract_flags[i].narrow) begin
//                         op_data[i] = DONT_CARE_ZERO ? '0 : 'x;
//                         unique case ({op_extract_eew[i], op_extract_flags[i].vf4_ext})
//                             {VSEW_16, 1'b0}: begin
//                                 for (int j = 0; j < OP_W[i] / 16; j++) begin
//                                     op_data[i][16*j +: 16] = {
//                                         // upper bits are either sign or zero extended
//                                         {8 {op_extract_flags[i].sigext & op_buffer[i][8 *j + 7 ]}},
//                                         op_buffer[i][8 *j +: 8 ]
//                                     };
//                                 end
//                             end
//                             {VSEW_32, 1'b0}: begin
//                                 for (int j = 0; j < OP_W[i] / 32; j++) begin
//                                     op_data[i][32*j +: 32] = {
//                                         // upper bits are either sign or zero extended
//                                         {16{op_extract_flags[i].sigext & op_buffer[i][16*j + 15]}},
//                                         op_buffer[i][16*j +: 16]
//                                     };
//                                 end
//                             end
//                             {VSEW_32, 1'b1}: begin // case for vf4_sign_extension
//                                 for (int j = 0; j < OP_W[i] / 32; j++) begin
//                                     op_data[i][32*j +: 32] = {
//                                         // upper bits are either sign or zero extended
//                                         {24{op_extract_flags[i].sigext & op_buffer[i][8*j + 7]}},
//                                         op_buffer[i][8 *j +: 8]
//                                     };
//                                 end
//                             end
//                             default: ;
//                         endcase
//                     end
//                     // fill operand elements with lower bits of XREG value if operand is no vreg
//                     if (OP_XREG[i] & ~op_extract_flags[i].vreg) begin
//                         op_data[i] = DONT_CARE_ZERO ? '0 : 'x;
//                         unique case (op_extract_eew[i])
//                             VSEW_8: begin
//                                 for (int j = 0; j < OP_W[i] / 8; j++) begin
//                                     op_data[i][8*j  +: 8 ] = op_xval[i][7 :0];
//                                 end
//                             end
//                             VSEW_16: begin
//                                 for (int j = 0; j < OP_W[i] / 16; j++) begin
//                                     op_data[i][16*j +: 16] = op_xval[i][15:0];
//                                 end
//                             end
//                             VSEW_32: begin
//                                 for (int j = 0; j < OP_W[i] / 32; j++) begin
//                                     op_data[i][32*j +: 32] = op_xval[i];
//                                 end
//                             end
//                             default: ;
//                         endcase
//                     end
//                 end
//             end
//         end
//     endgenerate

//     // Collect load signals and vreg addresses of valid stages up to load stage of the respective
//     // operand and combine them into a pending read mask
//     logic [UNPACK_STAGES:0][VPORT_CNT-1:0][(1<<MAX_VADDR_W)-1:0] pend_vreg_reads;
//     generate
//         for (genvar i = 0; i < UNPACK_STAGES + 1; i++) begin
//             for (genvar j = 0; j < VPORT_CNT; j++) begin
//                 always_comb begin
//                     pend_vreg_reads[i][j] = '0;
//                     for (int k = 0; k < OP_CNT; k++) begin
//                         if ((j == OP_SRC[k]) & (i <= OP_STAGE[k]) & ~OP_DYN_ADDR[k]) begin
//                             if (stage_valid[i] & stage_state[i].op_load [k] & (
//                                 ~OP_XREG[k]    | stage_state[i].op_flags[k].vreg)
//                             ) begin
//                                 pend_vreg_reads[i][j][
//                                     (stage_state[i].op_vaddr[k] << (MAX_VADDR_W-VADDR_W[j])) +:
//                                                              (1 << (MAX_VADDR_W-VADDR_W[j]))
//                                 ] = '1;
//                             end
//                         end
//                     end
//                 end
//             end
//         end
//     endgenerate
//     always_comb begin
//         pending_vreg_reads_o = '0;
//         for (int i = 0; i < UNPACK_STAGES + 1; i++) begin
//             for (int j = 0; j < VPORT_CNT; j++) begin
//                 pending_vreg_reads_o |= pend_vreg_reads[i][j];
//             end
//         end
//     end

//     // Stage valid and control signals flags.  These flags allow to check whether any of the unpack
//     // stages is valid and to check whether a flag that is part of the control signals is set in any
//     // or in all valid stages.
//     always_comb begin
//         stage_valid_any_o = stage_valid != '0;
//         ctrl_flags_any_o  = {CTRL_DATA_W{1'b0}};
//         ctrl_flags_all_o  = {CTRL_DATA_W{1'b1}};
//         for (int i = 0; i < UNPACK_STAGES + 1; i++) begin
//             if (stage_valid[i]) begin
//                 ctrl_flags_any_o |= stage_state[i].ctrl;
//                 ctrl_flags_all_o &= stage_state[i].ctrl;
//             end
//         end
//     end


// `ifdef VPROC_SVA
// `include "vproc_vregunpack_sva.svh"
// `endif

endmodule
