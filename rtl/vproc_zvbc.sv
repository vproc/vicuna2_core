// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Author: Daniel Blattner (e12020646@student.tuwien.ac.at)

module vproc_zvbc #(
        parameter int unsigned          ZVBC_OP_W        = 64,
        parameter bit                   BUF_OPERANDS     = 1'b1, // insert pipeline stage after operand extraction
        parameter bit                   BUF_INTERMEDIATE = 1'b1, // insert pipeline stage for for intermediate results
        parameter bit                   BUF_RESULTS      = 1'b1, // insert pipeline stage after computing result
        parameter type                  CTRL_T           = logic,
        parameter bit                   DONT_CARE_ZERO   = 1'b0, // initialize don't care values to zero
        parameter bit                   ZKT_ACTIVE       = 1'b0  // flag to enforce data independent runtime
    )(
        input  logic                    clk_i,
        input  logic                    async_rst_ni,
        input  logic                    sync_rst_ni,

        input  logic                    pipe_in_valid_i,
        output logic                    pipe_in_ready_o,
        input  CTRL_T                   pipe_in_ctrl_i,
        input  logic [ZVBC_OP_W  -1:0]  pipe_in_op1_i,
        input  logic [ZVBC_OP_W  -1:0]  pipe_in_op2_i,
        input  logic [ZVBC_OP_W/8-1:0]  pipe_in_mask_i,

        output logic                    pipe_out_valid_o,
        input  logic                    pipe_out_ready_i,
        output CTRL_T                   pipe_out_ctrl_o,
        output logic [ZVBC_OP_W  -1:0]  pipe_out_res_o,
        output logic [ZVBC_OP_W/8-1:0]  pipe_out_mask_o
    );

    import vproc_pkg::*;

    // Parameter asserts
    initial begin
        // Operand width must be a multiple of 32
        assert ( (ZVBC_OP_W & 31) == 0 ) else begin 
            $error("ZVBC operand width (ZVBC_OP_W) must be a multiple of 32. It is currently %d",ZVBC_OP_W);
        end
    end

    typedef struct packed {
        CTRL_T ctrl;
        logic [ZVBC_OP_W  -1:0] op1;
        logic [ZVBC_OP_W  -1:0] op2;
        logic [ZVBC_OP_W/8-1:0] mask;
    } zvbc_instr;

    ///////////////////////////////////////////////////////////////////////////
    // BUFFERS

    localparam PIPELINE_STAGES = 3;
    zvbc_instr stage[PIPELINE_STAGES];

    // Handshake vars
    logic valid[PIPELINE_STAGES];
    /* verilator lint_off UNOPTFLAT */
    logic ready[PIPELINE_STAGES];
    /* verilator lint_on UNOPTFLAT */

    generate  
        // Input Stage
        if (BUF_OPERANDS) begin 
            always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_zvbc_input_stage_valid
                if (~async_rst_ni) begin
                    valid[0] <= 1'b0;
                end
                else if (~sync_rst_ni) begin
                    valid[0] <= 1'b0;
                end
                else if (ready[0]) begin
                    valid[0] <= pipe_in_valid_i;
                end
            end
            always_ff @(posedge clk_i) begin : vproc_zvbc_input_stage
                if (ready[0] & pipe_in_valid_i) begin
                    stage[0].ctrl <= pipe_in_ctrl_i;
                    stage[0].op1 <= pipe_in_op1_i;
                    stage[0].op2 <= pipe_in_op2_i;
                    stage[0].mask <= pipe_in_mask_i;
                end
            end
            assign ready[0] = ~valid[0] | ready[1];
        end else begin
            always_comb begin : vproc_zvbc_input_stage
                stage[0].ctrl = pipe_in_ctrl_i;
                stage[0].op1 = pipe_in_op1_i;
                stage[0].op2 = pipe_in_op2_i;
                stage[0].mask = pipe_in_mask_i;
                valid[0] = pipe_in_valid_i;
                ready[0] = ready[1];
            end
        end
        assign pipe_in_ready_o = ready[0];

        // Intermediate Stage(s)
        genvar idx;
        for(idx=1; idx<PIPELINE_STAGES-1; idx++) begin
            if (BUF_INTERMEDIATE) begin
                always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_zvbc_intermediate_stage_valid
                    if (~async_rst_ni) begin
                        valid[idx] <= 1'b0;
                    end
                    else if (~sync_rst_ni) begin
                        valid[idx] <= 1'b0;
                    end
                    else if (ready[idx]) begin
                        valid[idx] <= valid[idx-1];
                    end
                end
                always_ff @(posedge clk_i) begin : vproc_zvbc_intermediate_stage
                    if (ready[idx] & valid[idx-1]) begin
                        stage[idx] <= stage[idx-1];
                    end
                end
                assign ready[idx] = ~valid[idx] | ready[idx+1];
            end else begin
                always_comb begin : vproc_zvbc_intermediate_stage
                    stage[idx] = stage[idx-1];
                    valid[idx] = valid[idx-1];
                    ready[idx] = ready[idx+1];
                end
            end
        end

        // Output Stage
        if (BUF_RESULTS) begin
            always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_zvbc_output_stage_valid
                if (~async_rst_ni) begin
                    pipe_out_valid_o <= 1'b0;
                end
                else if (~sync_rst_ni) begin
                    pipe_out_valid_o <= 1'b0;
                end
                else if (ready[PIPELINE_STAGES-1]) begin
                    pipe_out_valid_o <= valid[PIPELINE_STAGES-2];
                end
            end
            always_ff @(posedge clk_i) begin : vproc_zvbc_output_stage
                if (ready[PIPELINE_STAGES-1] & valid[PIPELINE_STAGES-2]) begin
                    stage[PIPELINE_STAGES-1] <= stage[PIPELINE_STAGES-2];
                    pipe_out_res_o <= result;
                end
            end
            assign ready[PIPELINE_STAGES-1] = ~valid[PIPELINE_STAGES-1] | pipe_out_ready_i;
        end else begin
            always_comb begin : vproc_zvbc_output_stage
                stage[PIPELINE_STAGES-1] = stage[PIPELINE_STAGES-2];
                valid[PIPELINE_STAGES-1] = valid[PIPELINE_STAGES-2];
                ready[PIPELINE_STAGES-1] = pipe_out_ready_i;
            end
            assign pipe_out_valid_o = valid[PIPELINE_STAGES-1];
            assign pipe_out_res_o = result;
        end
        assign pipe_out_ctrl_o = stage[PIPELINE_STAGES-1].ctrl;

        // result byte mask
        logic [ZVBC_OP_W/8-1:0] vl_mask;
        assign vl_mask        = ~stage[PIPELINE_STAGES-1].ctrl.vl_part_0 ? ({(ZVBC_OP_W/8){1'b1}} >> (~stage[PIPELINE_STAGES-1].ctrl.vl_part)) : '0;
        assign pipe_out_mask_o = (stage[PIPELINE_STAGES-1].ctrl.mode.zvbc.masked ? stage[PIPELINE_STAGES-1].mask : {(ZVBC_OP_W/8){1'b1}}) & vl_mask;

    endgenerate

    // BUFFERS END
    ///////////////////////////////////////////////////////////////////////////

    // Generate all the lane masks
    // SEW=8 Masks
    const logic[ZVBC_OP_W-1:0][ZVBC_OP_W-1:0] eigthBitMask = (ZVBC_OP_W*ZVBC_OP_W)'( // Truncate leading zeros
        {ZVBC_OP_W/8{ // Repeat until the whole operand with is filled
            {8{1'b0}}, // Create offset to "shift" base pattern
            {8{{ZVBC_OP_W-8{1'b0}},8'hFF}} // Base pattern
        }}
    );
    // SEW=16 Masks
    const logic[ZVBC_OP_W-1:0][ZVBC_OP_W-1:0] sixteenBitMask = (ZVBC_OP_W*ZVBC_OP_W)'( // Truncate leading zeros
        {ZVBC_OP_W/16{ // Repeat until the whole operand with is filled
            {16{1'b0}}, // Create offset to "shift" base pattern
            {16{{ZVBC_OP_W-16{1'b0}},16'hFFFF}} // Base pattern
            }
        }
    );
    // SEW=32 Masks
    const logic[ZVBC_OP_W-1:0][ZVBC_OP_W-1:0] thirtytwoBitMask = (ZVBC_OP_W*ZVBC_OP_W)'( // Truncate leading zeros
        {ZVBC_OP_W/32{ // Repeat until the whole operand with is filled
            {32{1'b0}}, // Create offset to "shift" base pattern
            {32{{ZVBC_OP_W-32{1'b0}},32'hFFFF_FFFF}} // Base pattern
            }
        }
    );
    
    // Choose lane mask set accoring to SEW
    logic[ZVBC_OP_W-1:0][ZVBC_OP_W-1:0] laneMask;
    always_comb begin : chooseCorrectLaneMask
        unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
            VSEW_8: begin
                laneMask = eigthBitMask;
            end
            VSEW_16: begin
                laneMask = sixteenBitMask;
            end
            VSEW_32: begin
                laneMask = thirtytwoBitMask;
            end 
            default: ;
        endcase
    end

    // Calculate the carryless multiplication
    logic[ZVBC_OP_W-1:0][ZVBC_OP_W-1:0] singleMaskedLane;
    always_comb begin : singleMaskedLaneGen
        // First calculate each line seperatelly and mask according SEW
        for(int i=0; i<ZVBC_OP_W; i++) begin
            singleMaskedLane[i] = stage[PIPELINE_STAGES-2].op1 & 
                {ZVBC_OP_W{stage[PIPELINE_STAGES-2].op2[i]}} & 
                laneMask[i];
        end
    end
    logic [ZVBC_OP_W-1:0][2*ZVBC_OP_W-1:0] paritalMul;
    logic [2*ZVBC_OP_W-1:0] cmul;
    always_comb begin : carrylessMultiplication
        // XOR and shift all lanes
        paritalMul[0] = {{ZVBC_OP_W{1'b0}},singleMaskedLane[0]};
        /* verilator lint_off ALWCOMBORDER */
        for(int i=1; i<ZVBC_OP_W; i++) begin
            paritalMul[i] = paritalMul[i-1] ^ ({{ZVBC_OP_W{1'b0}},singleMaskedLane[i]} << i);
        end
        /* verilator lint_on ALWCOMBORDER */
        cmul = paritalMul[ZVBC_OP_W-1];
    end

    ///////////////////////////////////////////////////////////////////////////
    // RESULT
    logic [ZVBC_OP_W-1:0] result;
    always_comb begin
        result = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.mode.zvbc.op)
            ZVBC_VCLMUL: 
                unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
                    VSEW_8: begin
                        for (int i=0; i < ZVBC_OP_W/8; i++) begin
                            result[8*i +: 8] = cmul[16*i +: 8];
                        end
                    end
                    VSEW_16: begin
                        for (int i=0; i < ZVBC_OP_W/16; i++) begin
                            result[16*i +: 16] = cmul[32*i +: 16];
                        end
                    end
                    VSEW_32: begin
                        for (int i=0; i < ZVBC_OP_W/32; i++) begin
                            result[32*i +: 32] = cmul[64*i +: 32];
                        end
                    end 
                    default: ;
                endcase
            ZVBC_VCLMULH: 
                unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
                    VSEW_8: begin
                        for (int i=0; i < ZVBC_OP_W/8; i++) begin
                            result[8*i +: 8] = cmul[16*i+8 +: 8];
                        end
                    end
                    VSEW_16: begin
                        for (int i=0; i < ZVBC_OP_W/16; i++) begin
                            result[16*i +: 16] = cmul[32*i+16 +: 16];
                        end
                    end
                    VSEW_32: begin
                        for (int i=0; i < ZVBC_OP_W/32; i++) begin
                            result[32*i +: 32] = cmul[64*i+32 +: 32];
                        end
                    end 
                    default: ;
                endcase
            default: ;
        endcase
    end
    // RESULT END
    ///////////////////////////////////////////////////////////////////////////


endmodule
