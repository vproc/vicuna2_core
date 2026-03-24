// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Author: Daniel Blattner (e12020646@student.tuwien.ac.at)

module vproc_zvbb #(
        parameter int unsigned          ZVBB_OP_W        = 64,
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
        input  logic [ZVBB_OP_W  -1:0]  pipe_in_op1_i,
        input  logic [ZVBB_OP_W  -1:0]  pipe_in_op2_i,
        input  logic [ZVBB_OP_W/8-1:0]  pipe_in_mask_i,

        output logic                    pipe_out_valid_o,
        input  logic                    pipe_out_ready_i,
        output CTRL_T                   pipe_out_ctrl_o,
        output logic [ZVBB_OP_W  -1:0]  pipe_out_res_o,
        output logic [ZVBB_OP_W/8-1:0]  pipe_out_mask_o
    ); /*verilator public_module*/

    import vproc_pkg::*;

    // Parameter asserts
    initial begin
        // Operand width must be a multiple of 32
        assert ( (ZVBB_OP_W & 31) == 0 ) else begin 
            $error("ZVBB operand width (ZVBB_OP_W) must be a multiple of 32. It is currently %d",ZVBB_OP_W);
        end
    end

    typedef struct packed {
        CTRL_T ctrl;
        logic [ZVBB_OP_W  -1:0] op1;
        logic [ZVBB_OP_W  -1:0] op2;
        logic [ZVBB_OP_W/8-1:0] mask;
    } zvbb_instr;

    ///////////////////////////////////////////////////////////////////////////
    // BUFFERS

    localparam PIPELINE_STAGES = 3;
    zvbb_instr stage[PIPELINE_STAGES];

    // Handshake vars
    logic valid[PIPELINE_STAGES];
    /* verilator lint_off UNOPTFLAT */
    logic ready[PIPELINE_STAGES];
    /* verilator lint_on UNOPTFLAT */

    generate  
        // Input Stage
        if (BUF_OPERANDS) begin
            always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_zvbb_input_stage_valid
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
            always_ff @(posedge clk_i) begin : vproc_zvbb_input_stage
                if (ready[0] & pipe_in_valid_i) begin
                    stage[0].ctrl <= pipe_in_ctrl_i;
                    stage[0].op1 <= pipe_in_op1_i;
                    stage[0].op2 <= pipe_in_op2_i;
                    stage[0].mask <= pipe_in_mask_i;
                end
            end
            assign ready[0] = ~valid[0] | ready[1];
        end else begin
            always_comb begin : vproc_zvbb_input_stage
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
                always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_zvbb_intermediate_stage_valid
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
                always_ff @(posedge clk_i) begin : vproc_zvbb_intermediate_stage
                    if (ready[idx] & valid[idx-1]) begin
                        stage[idx] <= stage[idx-1];
                    end
                end
                assign ready[idx] = ~valid[idx] | ready[idx+1];
            end else begin
                always_comb begin : vproc_zvbb_intermediate_stage
                    stage[idx] = stage[idx-1];
                    valid[idx] = valid[idx-1];
                    ready[idx] = ready[idx+1];
                end
            end
        end

        // Output Stage
        if (BUF_RESULTS) begin
            always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_zvbb_output_stage_valid
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
            always_ff @(posedge clk_i) begin : vproc_zvbb_output_stage
                if (ready[PIPELINE_STAGES-1] & valid[PIPELINE_STAGES-2]) begin
                    stage[PIPELINE_STAGES-1] <= stage[PIPELINE_STAGES-2];
                    pipe_out_res_o <= result;
                end
            end
            assign ready[PIPELINE_STAGES-1] = ~valid[PIPELINE_STAGES-1] | pipe_out_ready_i;
        end else begin
            always_comb begin : vproc_zvbb_output_stage
                stage[PIPELINE_STAGES-1] = stage[PIPELINE_STAGES-2];
                valid[PIPELINE_STAGES-1] = valid[PIPELINE_STAGES-2];
                ready[PIPELINE_STAGES-1] = pipe_out_ready_i;
            end
            assign pipe_out_valid_o = valid[PIPELINE_STAGES-1];
            assign pipe_out_res_o = result;
        end
        assign pipe_out_ctrl_o = stage[PIPELINE_STAGES-1].ctrl;

        // result byte mask
        logic [ZVBB_OP_W/8-1:0] vl_mask;
        assign vl_mask        = ~stage[PIPELINE_STAGES-1].ctrl.vl_part_0 ? ({(ZVBB_OP_W/8){1'b1}} >> (~stage[PIPELINE_STAGES-1].ctrl.vl_part)) : '0;
        assign pipe_out_mask_o = (stage[PIPELINE_STAGES-1].ctrl.mode.zvbb.masked ? stage[PIPELINE_STAGES-1].mask : {(ZVBB_OP_W/8){1'b1}}) & vl_mask;

    endgenerate

    // BUFFERS END
    ///////////////////////////////////////////////////////////////////////////

    // Notes:
    // -) Scalar registers or immediates are already in the operand correctly coppied

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR AND-NOT
    logic [ZVBB_OP_W-1:0] result_vandn = ~stage[PIPELINE_STAGES-2].op1 & stage[PIPELINE_STAGES-2].op2;
    // END VECTOR AND-NOT
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR REVERSE

    // A seperate function, which reverese the bits in bytes.
    // It is used in several reverse instruction, especially with EEW=8
    function logic[ZVBB_OP_W-1:0] reverseBitsInBytes;
        input logic[ZVBB_OP_W-1:0] in;
        logic[ZVBB_OP_W-1:0] reverseInput;
        for(int i=0; i < ZVBB_OP_W/8; i++) begin
            for(int j=0; j < 8; j++) begin
                reverseInput[8*i + j] = in[8*i + 7-j];
            end 
        end
        return reverseInput;
    endfunction
    logic [ZVBB_OP_W-1:0] reversedBitsInBytes;
    assign reversedBitsInBytes = reverseBitsInBytes(stage[PIPELINE_STAGES-2].op2);

    logic [ZVBB_OP_W-1:0] result_rev;
    always_comb begin : chooseRevereseResult
        result_rev = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.mode.zvbb.op)
            ZVBB_VBREV: begin
                unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
                    VSEW_8: begin
                        // Resuse the reverseBitsInByte function
                        result_rev = reversedBitsInBytes;
                    end
                    VSEW_16: begin
                        for (int i=0; i < ZVBB_OP_W/16; i++) begin
                            for (int j=0; j < 16; j++) begin
                                result_rev[16*i + j] = stage[PIPELINE_STAGES-2].op2[16*i + 15-j];
                            end
                        end
                    end
                    VSEW_32: begin
                        for (int i=0; i < ZVBB_OP_W/32; i++) begin
                            for (int j=0; j < 32; j++) begin
                                result_rev[32*i + j] = stage[PIPELINE_STAGES-2].op2[32*i + 31-j];
                            end
                        end
                    end 
                    default: ;
                endcase
            end
            ZVBB_VBREV8: begin
                // Reverse bits in bytes is functional the same for all EEW 
                result_rev = reversedBitsInBytes;
            end
            ZVBB_VREV8: begin
                unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
                    VSEW_8: begin
                        // Reverse bytes with EEW=8 has no effect
                        result_rev = stage[PIPELINE_STAGES-2].op2;
                    end
                    VSEW_16: begin
                        for (int i=0; i < ZVBB_OP_W/16; i++) begin
                            result_rev[16*i +: 8] = stage[PIPELINE_STAGES-2].op2[16*i+8 +: 8];
                            result_rev[16*i+8 +: 8] = stage[PIPELINE_STAGES-2].op2[16*i +: 8];
                        end
                    end
                    VSEW_32: begin
                        for (int i=0; i < ZVBB_OP_W/32; i++) begin
                            result_rev[32*i +: 8] = stage[PIPELINE_STAGES-2].op2[32*i+24 +: 8];
                            result_rev[32*i+8 +: 8] = stage[PIPELINE_STAGES-2].op2[32*i+16 +: 8];
                            result_rev[32*i+16 +: 8] = stage[PIPELINE_STAGES-2].op2[32*i+8 +: 8];
                            result_rev[32*i+24 +: 8] = stage[PIPELINE_STAGES-2].op2[32*i +: 8];
                        end
                    end 
                    default: ;
                endcase
            end
            default: ;
        endcase
    end
    // END VECTOR REVERSE
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR COUNT ZEROS

    // Credit for counting leading zeros using a balance tree structures goes to Grabul
    // Link: https://electronics.stackexchange.com/a/196992
    // The algorithm was sligthly modified to be usable for also counting trailing zeros

    // The counting direction is given by the countDir input: 0 -> leading zeros, 1 -> trailing zeros
    function logic[1:0] twoPair;
        input logic [1:0] v;
        input logic countDir;
        // Count the leading/trailing zero of two bits
        unique case ({countDir,v})
            3'b000 : return 2'b10;
            3'b001 : return 2'b01;
            3'b110 : return 2'b01;
            3'b100 : return 2'b10;
            default : return 2'b00;
        endcase
    endfunction : twoPair

    // If the first half is not max count (i.e. there is somewhere a 1), only consider the result of first half
    // If both halfs have max count (10...0), return the max value (100...0)
    // If the first half has max count and the second half is not max, then result if 01<secondHalf[MSB-1:0]>
    `define combinePairs(funcName, WIDTH)                                   \
    function logic[WIDTH:0] funcName;                                       \
        input logic [2*WIDTH-1:0] v;                                        \
        input logic countDir;                                               \
        logic[WIDTH-1:0] firstHalf;                                         \
        logic[WIDTH-1:0] secondHalf;                                        \
        assign firstHalf = countDir ? v[0 +: WIDTH] : v[WIDTH +: WIDTH];    \
        assign secondHalf = countDir ? v[WIDTH +: WIDTH] : v[0 +: WIDTH];   \
        if (firstHalf[WIDTH-1] == 1'b0) begin                               \
            return {1'b0,firstHalf};                                        \
        end else begin                                                      \
            return {firstHalf[WIDTH-1] & secondHalf[WIDTH-1],               \
                    ~secondHalf[WIDTH-1],                                   \
                    secondHalf[0 +: WIDTH-1]};                              \
        end                                                                 \
    endfunction : funcName;
    `combinePairs(combineTwoWidthPairs,2);
    `combinePairs(combineThreeWidthPairs,3);
    `combinePairs(combineFourWidthPairs,4);
    `combinePairs(combineFiveWidthPairs,5);

    logic [(ZVBB_OP_W/2)*2-1:0] twoBitCount;
    logic [(ZVBB_OP_W/4)*3-1:0] fourBitCount;
    logic [(ZVBB_OP_W/8)*4-1:0] eigthBitCount;
    logic [(ZVBB_OP_W/16)*5-1:0] sixteenBitCount;
    logic [(ZVBB_OP_W/32)*6-1:0] thirtytwoBitCount;
    logic countingDirection = (stage[PIPELINE_STAGES-2].ctrl.mode.zvbb.op == ZVBB_VCTZ);
    always_comb begin : countingZeroBalancedTree
        for (int i=0; i < ZVBB_OP_W/2; i++) begin
            twoBitCount[2*i +: 2] = twoPair(stage[PIPELINE_STAGES-2].op2[2*i +: 2],countingDirection);
        end
        for(int i=0; i < ZVBB_OP_W/4; i++) begin
            fourBitCount[3*i +: 3] = combineTwoWidthPairs(twoBitCount[4*i +: 4],countingDirection);
        end
        for(int i=0; i < ZVBB_OP_W/8; i++) begin
            eigthBitCount[4*i +: 4] = combineThreeWidthPairs(fourBitCount[6*i +: 6],countingDirection);
        end
        for(int i=0; i < ZVBB_OP_W/16; i++) begin
            sixteenBitCount[5*i +: 5] = combineFourWidthPairs(eigthBitCount[8*i +: 8],countingDirection);
        end
        for(int i=0; i < ZVBB_OP_W/32; i++) begin
            thirtytwoBitCount[6*i +: 6] = combineFiveWidthPairs(sixteenBitCount[10*i +: 10],countingDirection);
        end
    end

    logic [ZVBB_OP_W-1:0] result_cz;
    always_comb begin  : chooseCountingZeroResult
        result_cz = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
            VSEW_8: begin
                for (int i=0; i < ZVBB_OP_W/8; i++) begin
                    result_cz[8*i +: 8] = {4'b0,eigthBitCount[4*i +: 4]};
                end
            end
            VSEW_16: begin
                for (int i=0; i < ZVBB_OP_W/16; i++) begin
                    result_cz[16*i +: 16] = {11'b0,sixteenBitCount[5*i +: 5]};
                end
            end
            VSEW_32: begin
                for (int i=0; i < ZVBB_OP_W/32; i++) begin
                    result_cz[32*i +: 32] = {26'b0,thirtytwoBitCount[6*i +: 6]};
                end
            end 
            default: ;
        endcase
    end
    // END VECTOR COUNT ZEROS
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR POPULATION COUNT

    // Masking constants
    localparam logic [ZVBB_OP_W-1:0] twoSumPattern = {ZVBB_OP_W/2{2'b01}};
    localparam logic [ZVBB_OP_W-1:0] fourSumPattern = {ZVBB_OP_W/4{4'h3}};
    localparam logic [ZVBB_OP_W-1:0] eigthSumPattern = {ZVBB_OP_W/8{8'h07}};
    // Og value 16'h001F
    localparam logic [ZVBB_OP_W-1:0] sixteenSumPattern = {ZVBB_OP_W/16{16'h000F}};
    // Og value 16'h003F
    localparam logic [ZVBB_OP_W-1:0] thirtytwoSumPattern = {ZVBB_OP_W/32{32'h0000_001F}};
    // Calculate the subtotals by shifting-mask-add operations
    logic [ZVBB_OP_W-1:0] twoSum;
    logic [ZVBB_OP_W-1:0] fourSum;
    logic [ZVBB_OP_W-1:0] eigthSum;
    logic [ZVBB_OP_W-1:0] sixteenSum;
    logic [ZVBB_OP_W-1:0] thirtytwoSum;
    always_comb begin : subtotalCalculation
        twoSum = (stage[PIPELINE_STAGES-2].op2 & twoSumPattern) + 
            ({1'b0,stage[PIPELINE_STAGES-2].op2[ZVBB_OP_W-1:1]} & twoSumPattern);
        fourSum = (twoSum & fourSumPattern) + 
            ({2'b0,twoSum[ZVBB_OP_W-1:2]} & fourSumPattern);
        eigthSum = (fourSum & eigthSumPattern) + 
            ({4'b0,fourSum[ZVBB_OP_W-1:4]} & eigthSumPattern);
        sixteenSum = (eigthSum & sixteenSumPattern) + 
            ({8'b0,eigthSum[ZVBB_OP_W-1:8]} & sixteenSumPattern);
        thirtytwoSum = (sixteenSum & thirtytwoSumPattern) + 
            ({16'b0,sixteenSum[ZVBB_OP_W-1:16]} & thirtytwoSumPattern);
    end

    logic [ZVBB_OP_W-1:0] result_vcpop;
    always_comb begin : choosePopulationCountResult
        result_vcpop = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
            VSEW_8: begin
                result_vcpop = eigthSum;
            end
            VSEW_16: begin
                result_vcpop = sixteenSum;
            end
            VSEW_32: begin
                result_vcpop = thirtytwoSum;
            end 
            default: ;
        endcase
    end
    // END VECTOR POPULATION COUNT
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR ROTATE

    // Direction: 1 -> Left, 0 -> Right
    // Barrel shifter for 8,16 and 32 bits
    function logic[7:0] eigthBitRotater;
        input logic[7:0] in;
        input logic[2:0] bits;
        input logic direction;
        logic[7:0] levels[2:0];
        if (bits[0]==1'b1) begin
            levels[0] = direction ? {in[6:0],in[7]} : {in[0],in[7:1]};
        end else begin
            levels[0] = in;
        end
        if (bits[1]==1'b1) begin
            levels[1] = direction ? {levels[0][5:0],levels[0][7:6]} : {levels[0][1:0],levels[0][7:2]};
        end else begin
            levels[1] = levels[0];
        end
        if (bits[2]==1'b1) begin
            levels[2] = direction ? {levels[1][3:0],levels[1][7:4]} : {levels[1][3:0],levels[1][7:4]};
        end else begin
            levels[2] = levels[1];
        end
        return levels[2];
    endfunction
    function logic[15:0] sixteenBitRotater;
        input logic[15:0] in;
        input logic[3:0] bits;
        input logic direction;
        logic[15:0] levels[3:0];
        if (bits[0]==1'b1) begin
            levels[0] = direction ? {in[14:0],in[15]} : {in[0],in[15:1]};
        end else begin
            levels[0] = in;
        end
        if (bits[1]==1'b1) begin
            levels[1] = direction ? {levels[0][13:0],levels[0][15:14]} : {levels[0][1:0],levels[0][15:2]};
        end else begin
            levels[1] = levels[0];
        end
        if (bits[2]==1'b1) begin
            levels[2] = direction ? {levels[1][11:0],levels[1][15:12]} : {levels[1][3:0],levels[1][15:4]};
        end else begin
            levels[2] = levels[1];
        end
        if (bits[3]==1'b1) begin
            levels[3] = direction ? {levels[2][7:0],levels[2][15:8]} : {levels[2][7:0],levels[2][15:8]};
        end else begin
            levels[3] = levels[2];
        end
        return levels[3];
    endfunction
    function logic[31:0] thirtytwoBitRotater;
        input logic[31:0] in;
        input logic[4:0] bits;
        input logic direction;
        logic[31:0] levels[4:0];
        if (bits[0]==1'b1) begin
            levels[0] = direction ? {in[30:0],in[31]} : {in[0],in[31:1]};
        end else begin
            levels[0] = in;
        end
        if (bits[1]==1'b1) begin
            levels[1] = direction ? {levels[0][29:0],levels[0][31:30]} : {levels[0][1:0],levels[0][31:2]};
        end else begin
            levels[1] = levels[0];
        end
        if (bits[2]==1'b1) begin
            levels[2] = direction ? {levels[1][27:0],levels[1][31:28]} : {levels[1][3:0],levels[1][31:4]};
        end else begin
            levels[2] = levels[1];
        end
        if (bits[3]==1'b1) begin
            levels[3] = direction ? {levels[2][23:0],levels[2][31:24]} : {levels[2][7:0],levels[2][31:8]};
        end else begin
            levels[3] = levels[2];
        end
        if (bits[4]==1'b1) begin
            levels[4] = direction ? {levels[3][15:0],levels[3][31:16]} : {levels[3][15:0],levels[3][31:16]};
        end else begin
            levels[4] = levels[3];
        end
        return levels[4];
    endfunction

    logic [ZVBB_OP_W  -1:0] result_rot;
    logic rotatingDirection = (stage[PIPELINE_STAGES-2].ctrl.mode.zvbb.op == ZVBB_VROL);
    always_comb begin : chooseRotateResult
        result_rot = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
            VSEW_8: begin
                for (int i=0; i < ZVBB_OP_W/8; i++) begin
                    result_rot[8*i +: 8] = eigthBitRotater(
                        stage[PIPELINE_STAGES-2].op2[8*i +: 8],
                        stage[PIPELINE_STAGES-2].op1[8*i +: 3],
                        rotatingDirection);
                end
            end
            VSEW_16: begin
                for (int i=0; i < ZVBB_OP_W/16; i++) begin
                    result_rot[16*i +: 16] = sixteenBitRotater(
                        stage[PIPELINE_STAGES-2].op2[16*i +: 16],
                        stage[PIPELINE_STAGES-2].op1[16*i +: 4],
                        rotatingDirection);
                end
            end
            VSEW_32: begin
                for (int i=0; i < ZVBB_OP_W/32; i++) begin
                    result_rot[32*i +: 32] = thirtytwoBitRotater(
                        stage[PIPELINE_STAGES-2].op2[32*i +: 32],
                        stage[PIPELINE_STAGES-2].op1[32*i +: 5],
                        rotatingDirection);
                end
            end 
            default: ;
        endcase
    end

    // END VECTOR ROTATE
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR WIDENING SHIFT LEFT
    logic [ZVBB_OP_W-1:0] result_vwsll;
    always_comb begin : chooseWideningShiftLeftResult
        result_vwsll = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.eew)
            VSEW_8: ; // No SEW=8 should happen
            VSEW_16: begin
                for (int i=0; i < ZVBB_OP_W/16; i++) begin
                    result_vwsll[16*i +: 16] = {8'b0,stage[PIPELINE_STAGES-2].op2[16*i +: 8]} << stage[PIPELINE_STAGES-2].op1[16*i +: 4];
                end
            end
            VSEW_32: begin
                for (int i=0; i < ZVBB_OP_W/32; i++) begin
                    result_vwsll[32*i +: 32] = {16'b0,stage[PIPELINE_STAGES-2].op2[32*i +: 16]} << stage[PIPELINE_STAGES-2].op1[32*i +: 5];
                end
            end 
            default: ;
        endcase
    end
    // END VECTOR WIDENING SHIFT LEFT
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // RESULT
    logic [ZVBB_OP_W-1:0] result;
    always_comb begin
        result = DONT_CARE_ZERO ? '0 : 'x;
        unique case (stage[PIPELINE_STAGES-2].ctrl.mode.zvbb.op)
            // Vector and-not
            ZVBB_VANDN: result = result_vandn;
            // Vector Reverse bits/bytes
            ZVBB_VBREV,
            ZVBB_VBREV8,
            ZVBB_VREV8: result = result_rev;
            // Vector count zero
            ZVBB_VCLZ,
            ZVBB_VCTZ: result = result_cz;
            // Vector population count
            ZVBB_VCPOP: result = result_vcpop;
            // Vector rotate
            ZVBB_VROL,
            ZVBB_VROR: result = result_rot;
            // Vector widening shift left
            ZVBB_VWSLL: result = result_vwsll;
            default: ;
        endcase
    end
    // RESULT END
    ///////////////////////////////////////////////////////////////////////////


endmodule
