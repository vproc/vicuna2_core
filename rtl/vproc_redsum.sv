// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//Fracturable + Maskable adder/and/or/xor for use below
module fractureable_reduction_unit import vproc_pkg::*; #(
)(
    input  cfg_vsew               sew_i,

    input  opcode_reduction       op_i,

    input  logic [32  -1:0]       a_i,
    input  logic [4   -1:0]       a_mask_i,
    input  logic [32  -1:0]       b_i,

    output logic [32  -1:0]       c_o

);

    // Masking logic signals
    logic [31:0] a_masked;
    always_comb begin
        unique case (op_i)
            OP_REDOR,
            OP_REDSUM: begin
                a_masked[7:0]   = a_mask_i[0] ? a_i[7:0] : '0;
                a_masked[15:8]  = a_mask_i[1] ? a_i[15:8] : '0;
                a_masked[23:16] = a_mask_i[2] ? a_i[23:16] : '0;
                a_masked[31:24] = a_mask_i[3] ? a_i[31:24] : '0;
            end
            OP_REDAND: begin
                a_masked[7:0]   = a_mask_i[0] ? a_i[7:0] : '1;
                a_masked[15:8]  = a_mask_i[1] ? a_i[15:8] : '1;
                a_masked[23:16] = a_mask_i[2] ? a_i[23:16] : '1;
                a_masked[31:24] = a_mask_i[3] ? a_i[31:24] : '1;
            end
            OP_REDXOR: begin
                a_masked[7:0]   = a_mask_i[0] ? a_i[7:0]   : ~b_i[7:0];
                a_masked[15:8]  = a_mask_i[1] ? a_i[15:8]  : ~b_i[15:8];
                a_masked[23:16] = a_mask_i[2] ? a_i[23:16] : ~b_i[23:16];
                a_masked[31:24] = a_mask_i[3] ? a_i[31:24] : ~b_i[31:24];
            end
        endcase
    end
    
    // Carry logic signals for fracturable redsum
    logic carry_0_1, carry_1_2, carry_2_3;
    assign carry_0_1 = (sew_i != VSEW_8);
    assign carry_1_2 = (sew_i == VSEW_32);
    assign carry_2_3 = (sew_i != VSEW_8);
    logic [8:0] c_0, c_1, c_2, c_3;

    //Adder
    always_comb begin
        unique case (op_i)
        OP_REDSUM: begin
            c_0 = a_masked[7:0] + b_i[7:0];
            c_1 = a_masked[15:8] + b_i[15:8] + (carry_0_1 && c_0[8]);
            c_2 = a_masked[23:16] + b_i[23:16] + (carry_1_2 && c_1[8]);
            c_3 = a_masked[31:24] + b_i[31:24] + (carry_2_3 && c_2[8]);
        end
        OP_REDAND: begin
            c_0 = a_masked[7:0] & b_i[7:0];
            c_1 = a_masked[15:8] & b_i[15:8];
            c_2 = a_masked[23:16] & b_i[23:16];
            c_3 = a_masked[31:24] & b_i[31:24];
        end
        OP_REDOR: begin
            c_0 = a_masked[7:0] | b_i[7:0];
            c_1 = a_masked[15:8] | b_i[15:8];
            c_2 = a_masked[23:16] | b_i[23:16];
            c_3 = a_masked[31:24] | b_i[31:24];
        end
        OP_REDXOR: begin
            c_0 = a_masked[7:0] ^ b_i[7:0];
            c_1 = a_masked[15:8] ^ b_i[15:8];
            c_2 = a_masked[23:16] ^ b_i[23:16];
            c_3 = a_masked[31:24] ^ b_i[31:24];
        end
        endcase
    end

    assign c_o = {c_3[7:0], c_2[7:0], c_1[7:0], c_0[7:0]};

endmodule;

//Redsum module
module vproc_vredsum import vproc_pkg::*; #(
        parameter int unsigned          OP_W             = 64,
        parameter type                  CTRL_T           = logic,
        parameter bit                   DONT_CARE_ZERO   = 1'b0 // initialize don't care values to zero    
    )(
        input  logic                    clk_i,
        input  logic                    async_rst_ni,
        input  logic                    sync_rst_ni,

        input  logic                    pipe_in_valid_i,
        output logic                    pipe_in_ready_o,
        input  CTRL_T                   pipe_in_ctrl_i,
        input  logic [OP_W  -1:0]       pipe_in_op1_i,
        input  logic [OP_W  -1:0]       pipe_in_op2_i,
        input  logic [OP_W/8-1:0]       pipe_in_mask_i,

        output logic                    pipe_out_valid_o,
        input  logic                    pipe_out_ready_i,
        output CTRL_T                   pipe_out_ctrl_o,
        output logic [OP_W  -1:0]       pipe_out_res_o,
        output logic [OP_W/8-1:0]       pipe_out_mask_o
    );
    //Buffer for pipeline metadata
    CTRL_T ctrl_d, ctrl_q; //TODO: Not necessary to buffer this much data
       //Output signalling
    always_comb begin
        ctrl_d = pipe_in_ctrl_i;
        if (!pipe_in_ctrl_i.first_cycle) begin
            //This instruction only writes to a single vreg, the address from the first cycle.  hold this address
            ctrl_d.res_vaddr = ctrl_q.res_vaddr;
        end
    end
    always_ff @(posedge clk_i) begin
        begin
            if (pipe_in_valid_i) begin
                ctrl_q <= ctrl_d;
            end
        end
    end

    //////////////////
    // Reduction Control logic
    /////////////////
    // Three phases for reduction operation:
    //  Parallel Sum Phase:      Every cycle, valid data is provided on the pipe_in_op2_i input.  This data is summed in parallel with the values held in the accumulator register
    //  Wide Reduction Phase:    Once the last data cycle has been received, all values in accumulator registers must be reduced to a single value.  Switch input+output muxes to fixed reduction mode.  This mode only occurs when OP_W > 64
    //  Result Reduction Phase:  Once the result is reduced to two 32 bit results, move to final reduction phase.  Switch muxes for these two buffers to perform final reduction
    typedef enum logic [1:0] {
        PARALLEL_SUM = 2'b00,
        WIDE_RED = 2'b01,
        RESULT_RED   = 2'b10
    } reduction_state;

    reduction_state state_q, state_d;
    logic[$clog2(OP_W/32)-1:0] red_cnt_d, red_cnt_q; //counter for # cycles to complete reduction once last_cycle is triggered
    logic[1:0] res_cnt_d, res_cnt_q; //counter for # cycles to complete final reduction depending on SEW (1, 2, or 3)
    always_ff @(posedge clk_i, sync_rst_ni) begin
        begin
            if (~sync_rst_ni) begin 
                state_q <= PARALLEL_SUM;
                red_cnt_q <= '0;
                res_cnt_q <= '0;
            end else begin
                state_q <= state_d;
                red_cnt_q <= red_cnt_d;
                res_cnt_q <= res_cnt_d;
            end
        end
    end

    //////////////////
    logic complete;
    generate
        //When OP_W >= 64, need the WIDE_RED state
        if (OP_W >= 64) begin
            always_comb begin : next_state_ctrl
                state_d = state_q;
                red_cnt_d = red_cnt_q;
                res_cnt_d = res_cnt_q;
                complete = 1'b0;
                unique case (state_q)
                    //In this state, a new OP_W set of data arrives each cycle to be summed in parallel
                    PARALLEL_SUM: begin
                        if (pipe_in_ctrl_i.last_cycle & pipe_in_valid_i) begin
                            state_d = WIDE_RED;
                            red_cnt_d = $clog2(OP_W/32) - 1; //# cycles to spend in WIDE_RED state - 1
                        end 
                    end
                    //In this state, all data has be received and a sum is performed across acc_q.  Only necessary for OP_W >= 64
                    WIDE_RED: begin
                        red_cnt_d = red_cnt_q-1;
                        if (!(|red_cnt_q)) begin
                            state_d = RESULT_RED;
                            unique case (ctrl_q.eew) //# cycles to spend in RESULT_RED state - 1
                                VSEW_8: res_cnt_d = 2'b10;  // For SEW_8, output is valid after two more reduction cycles
                                VSEW_16: res_cnt_d = 2'b01; // For SEW_16, output is valid after one more reduction cycle
                                VSEW_32: res_cnt_d = 2'b00; // For SEW_32, output is valid next cycle
                            endcase
                        end
                    end
                    //In this state, all data exists in one 32 bit wide section of acc_q.  Reduce further based on SEW and signal output
                    RESULT_RED: begin
                        res_cnt_d = res_cnt_q-1;
                        state_d = (res_cnt_q == 2'b00) ? PARALLEL_SUM : RESULT_RED;
                        complete = (res_cnt_q == 2'b00); //only signal complete on last cycle here
                    end
                default:
                    state_d = PARALLEL_SUM; 
                endcase

            end 
         end else begin
            //when OP_W=32, state machine is smaller
            always_comb begin : next_state_ctrl
                state_d = state_q;
                red_cnt_d = red_cnt_q;
                res_cnt_d = res_cnt_q;
                complete = 1'b0;
                unique case (state_q)
                    //In this state, a new OP_W set of data arrives each cycle to be summed in parallel
                    PARALLEL_SUM: begin
                        //No need for WIDE_RED state if OP_W=32
                        if (pipe_in_ctrl_i.last_cycle & pipe_in_valid_i) begin
                            state_d = RESULT_RED;
                            unique case (ctrl_q.eew) //# cycles to spend in RESULT_RED state - 1
                                VSEW_8: res_cnt_d = 2'b10;  // For SEW_32, output is valid after two more reduction cycles
                                VSEW_16: res_cnt_d = 2'b01; // For SEW_32, output is valid after one more reduction cycle
                                VSEW_32: res_cnt_d = 2'b00; // For SEW_32, output is valid next cycle
                            endcase
                        end
                    end
                    //In this state, all data exists in one 32 bit wide section of acc_q.  Reduce further based on SEW and signal output
                    RESULT_RED: begin
                        res_cnt_d = res_cnt_q-1;
                        state_d = (res_cnt_q == 2'b00) ? PARALLEL_SUM : RESULT_RED;
                        complete = (res_cnt_q == 2'b00);
                    end
                default:
                    state_d = PARALLEL_SUM; 
                endcase
            end
        end
    endgenerate

    //////////////////
    //Intermediate result register.  A series of 32 bit registers, one for each ALU
    //During PARALLEL_SUM, only updates if pipeline inputs are valid
    //////////////////
    logic [OP_W/32-1:0][32  -1:0] acc_d, acc_q;
    always_ff @(posedge clk_i) begin
        begin
            if (state_q == PARALLEL_SUM) begin
                acc_q <=  pipe_in_valid_i ? acc_d: acc_q;
            end else begin
                acc_q <= acc_d;
            end
        end
    end

    //////////////////
    //Adder input signals
    //input_a and input_b are the inputs to the adders.  each 32 bit section goes to a different adder
    //////////////////
    logic [OP_W/32-1:0][32  -1:0] input_a, input_b;

    //////////////////
    //when OP_W == 64, adder 0 must be used for the WIDE_RED phase
    //////////////////
    generate
        if (OP_W == 64) begin
            always_comb begin : input_handling_adder_0_a
                if (state_q == RESULT_RED) begin //In RESULT RED, take input from upper half of this adder's output
                    input_a[0][31:16] = '0;
                    input_a[0][15:0] = acc_q[0][31:16];
                end else if (state_q == WIDE_RED) begin
                    input_a[0][31:0] = acc_q[1][31:0]; //take input from output of adder 1
                end else begin
                    input_a[0][31:0] = pipe_in_op2_i[31:0];
                end 
            end 
        end else begin
            always_comb begin : input_handling_adder_0_a
                if (state_q == RESULT_RED) begin //In RESULT RED, take input from upper half of this adder's output
                    input_a[0][31:16] = '0;
                    input_a[0][15:0] = acc_q[0][31:16];
                end else begin
                    input_a[0][31:0] = pipe_in_op2_i[31:0];
                end
            end
        end
    endgenerate

    //Reduction scheme ensures adder 0 only has simple input handling and can easily be used for the first vreg value in cycle one.
    always_comb begin : input_handling_adder_0_b
         //first cycle takes value from other vreg
        if (pipe_in_ctrl_i.first_cycle & pipe_in_valid_i) begin
            unique case (pipe_in_ctrl_i.eew) //# cycles to spend in RESULT_RED state - 1
                                VSEW_8:  input_b[0][31:0] = (pipe_in_ctrl_i.mode.reduction.op == OP_REDSUM | pipe_in_ctrl_i.mode.reduction.op == OP_REDOR) ? {{(24){1'b0}} , pipe_in_op1_i[7:0]} : (pipe_in_ctrl_i.mode.reduction.op == OP_REDAND) ? {{(24){1'b1}} , pipe_in_op1_i[7:0]} : {~pipe_in_op2_i[31:24] , pipe_in_op1_i[7:0]};
                                VSEW_16: input_b[0][31:0] = (pipe_in_ctrl_i.mode.reduction.op == OP_REDSUM | pipe_in_ctrl_i.mode.reduction.op == OP_REDOR) ? {{(16){1'b0}} , pipe_in_op1_i[15:0]} : (pipe_in_ctrl_i.mode.reduction.op == OP_REDAND) ? {{(16){1'b1}} , pipe_in_op1_i[15:0]} : {~pipe_in_op2_i[31:16] , pipe_in_op1_i[15:0]};
                                VSEW_32: input_b[0][31:0] = pipe_in_op1_i[31:0];
            endcase
        end else begin
            input_b[0][31:0] = acc_q[0][31:0]; //other cycles take value from accumulator
        end
    end
    //////////////////        
    //Input assignments for the remaining adders
    //////////////////
    //Useful constants
    localparam int CENTER_0 = (OP_W / 32) / 2 - 1;
    localparam int CENTER_1 = (OP_W / 32) / 2;
    localparam int NUM_ADDERS = OP_W / 32;
    generate
        //Simple case for OP_W=64
        if (OP_W == 64) begin
            always_comb begin : input_handling_adder_1_a
                input_a[1] = pipe_in_op2_i[63:32];
            end
        end else if (OP_W > 64) begin
            ////////////////////////
            // Three sections need to be handled: upper half, lower half, and center two adders (ex: for OP_W = 256, 8 adders.  Adders 7-5 are upper half, adders 0-2 are lower half, adders 4-3 are center)
            // During PARALLEL_SUM, all sections route to their corresponding place in the acc_q register
            // During WIDE_RED, input_a and outputs of adders are changed to route to accumulate results in the center two adders.
            // In the last cycle of WIDE_RED, the final sum is added using center adder (OP_W / 32) / 2 - 1 (adder 3 for OP_W=256)
            ////////////////////////
            for (genvar i = CENTER_1 + 1; i < NUM_ADDERS; i++) begin
                //Every other adder starting from CENTER_1 takes from its neighbor during WIDE_RED
                if (((i - CENTER_1) % 2) == 0) begin
                    always_comb begin : input_handling_upper_a
                        if (state_q == WIDE_RED) begin //During WIDE_RED
                            input_a[i][31:0] = acc_q[i + 1][31:0];
                        end else begin //During Parallel Sum
                            input_a[i][31:0] = pipe_in_op2_i[32*i +: 32];
                        end 
                    end
                end else begin
                    always_comb begin : input_handling_upper_a
                        input_a[i][31:0] = pipe_in_op2_i[32*i +: 32];
                    end
                end
            end

            always_comb begin : input_handling_center_1_a
                if (state_q == WIDE_RED) begin //During WIDE_RED
                    input_a[CENTER_1][31:0] = acc_q[CENTER_1 + 1][31:0];
                end else begin //During Parallel Sum
                    input_a[CENTER_1][31:0] = pipe_in_op2_i[32*CENTER_1 +: 32];
                end 
            end

            always_comb begin : input_handling_center_0_a
                if (state_q == RESULT_RED) begin //In RESULT RED, take input from upper half of this adder's output
                    input_a[CENTER_0][31:16] = '0;
                    input_a[CENTER_0][15:0] = acc_q[CENTER_0][31:16];
                end else if ((state_q == WIDE_RED) & !(|red_cnt_q)) begin //Last cycle of WIDE_RED
                    input_a[CENTER_0][31:0] = acc_q[CENTER_1][31:0]; 
                end else if (state_q == WIDE_RED) begin //During WIDE_RED
                    input_a[CENTER_0][31:0] = acc_q[CENTER_0 - 1][31:0];
                end else begin
                    input_a[CENTER_0][31:0] = pipe_in_op2_i[32*CENTER_0 +: 32]; //During Parallel Sum
                end
            end

            for (genvar i = CENTER_0 - 1; i > 0; i--) begin //adder 0 inputs handled separately above
                if (((CENTER_0 - i) % 2) == 0) begin
                    always_comb begin : input_handling_lower_a
                        if (state_q == WIDE_RED) begin //During WIDE_RED
                            input_a[i][31:0] = acc_q[i - 1][31:0];
                        end else begin //During Parallel Sum
                            input_a[i][31:0] = pipe_in_op2_i[32*i +: 32];
                        end
                    end 
                end else begin
                    always_comb begin : input_handling_lower_a
                        input_a[i][31:0] = pipe_in_op2_i[32*i +: 32];
                    end
                end
            end
        end
    endgenerate

    //input b.  No special routing, value taken from either acc_q or set to 0 in first cycle
    generate
        if (OP_W >= 64) begin
            always_comb begin : input_handling_b
                for ( int i = 1; i< (OP_W / 32); i++) begin
                    if (pipe_in_ctrl_i.first_cycle & pipe_in_valid_i) begin
                        input_b[i][31:0] = (pipe_in_ctrl_i.mode.reduction.op == OP_REDSUM | pipe_in_ctrl_i.mode.reduction.op == OP_REDOR) ? '0 : (pipe_in_ctrl_i.mode.reduction.op == OP_REDAND)  ? '1 : ~pipe_in_op2_i[i*32 +: 32]; //first cycle has no input data, set to initial
                    end else begin
                        input_b[i][31:0] = acc_q[i][31:0]; //other cycles take value from accumulator
                    end
                end
            end
        end
    endgenerate

    //////////////////
    // Adder output routing.  Necessary for OP_W>64
    //////////////////
    logic [OP_W/32-1:0][32  -1:0] output_c;

    generate
        //Simple case for OP_W=64
        if (OP_W <= 64) begin
            always_comb begin
                acc_d = output_c;
                if (state_q == RESULT_RED && ctrl_q.eew == VSEW_8) begin //In RESULT RED with SEW_8, need to route partial byte result to correct place for next cycle
                    acc_d[0][23:16] = output_c[0][15:8];
                end
            end
        end else if (OP_W > 64) begin
            /////////////
            // Same three sections as above need to be handled here to enable one valid routing for WIDE_RED
            ////////////

            for (genvar i = CENTER_1 + 1; i < NUM_ADDERS; i++) begin
                //Every other adder starting from CENTER_1 routes its output closer to CENTER_1 to be aligned for next cycle.  Each subsequent adder must route  1 closer to CENTER_1
                if ( i < NUM_ADDERS - NUM_ADDERS/4 ) begin //only innermost half needs special routing of the output
                    always_comb begin : output_handling_upper
                        if (state_q == WIDE_RED) begin //During WIDE_RED
                            acc_d[i] = output_c[i + (i - CENTER_1)];
                        end else begin //During Parallel Sum
                            acc_d[i] = output_c[i];
                        end 
                    end
                end else begin
                    always_comb begin : output_handling_upper
                        acc_d[i] = output_c[i];
                    end
                end
            end

            always_comb begin : output_handling_center
                acc_d[CENTER_0] = output_c[CENTER_0];
                if (state_q == RESULT_RED && ctrl_q.eew == VSEW_8) begin //In RESULT RED with SEW_8, need to route partial byte result to correct place for next cycle
                    acc_d[CENTER_0][23:16] = output_c[CENTER_0][15:8];
                end
                acc_d[CENTER_1] = output_c[CENTER_1];
            end

            for (genvar i = CENTER_0 - 1; i >= 0; i--) begin
                //Every other adder starting from CENTER_0 routes its output closer to CENTER_0 to be aligned for next cycle.  Each subsequent adder must route  1 closer to CENTER_0
                if ( i >= NUM_ADDERS/4 ) begin //only innermost half needs special routing of the output
                    always_comb begin : output_handling_upper
                        if (state_q == WIDE_RED) begin //During WIDE_RED
                            acc_d[i] = output_c[i - (CENTER_0 - i)];
                        end else begin //During Parallel Sum
                            acc_d[i] = output_c[i];
                        end 
                    end
                end else begin
                    always_comb begin : output_handling_upper
                        acc_d[i] = output_c[i];
                    end
                end
            end

        end
    endgenerate

    //////////////////
    // Mask Handling.  Mask values from pipeline only apply to input_a, and only during the parallel sum phase.
    //////////////////
    logic [OP_W/32-1:0][4  -1:0] input_a_mask;


    // logic [OP_W/8-1:0] vl_mask;
    // logic [OP_W/8-1:0] combined_mask;
    // assign vl_mask        = ~pipe_in_ctrl_i.vl_part_0 ? ({(OP_W/8){1'b1}} >> (~pipe_in_ctrl_i.vl_part)) : '0;

    always_comb begin
        for (int i = 0; i < OP_W/32; i++) begin
            if (state_q == PARALLEL_SUM) begin
                input_a_mask[i] = pipe_in_mask_i[4*i +: 4];
            end else begin
                input_a_mask[i] = 4'b1111; 
            end
        end
    end

    //////////////////
    //SEW signalling for fracturable adders
    //////////////////
    cfg_vsew sew;
    assign sew = (pipe_in_ctrl_i.first_cycle) ? ctrl_d.eew : ctrl_q.eew;
    opcode_reduction op_mode;
    assign op_mode = (pipe_in_ctrl_i.first_cycle) ? ctrl_d.mode.reduction.op : ctrl_q.mode.reduction.op;

    generate
        for (genvar i = 0; i < OP_W / 32; i++) begin
            //Fracturable adder
            fractureable_reduction_unit #(
            ) fractureable_reduction_unit (
                .sew_i(sew),
                .op_i(op_mode),

                .a_i(input_a[i]),
                .a_mask_i(input_a_mask[i]),

                .b_i(input_b[i]),

                .c_o(output_c[i])
            );
        end 
    endgenerate;

    //////////////////
    //Output port signalling
    //////////////////
    always_comb begin
        pipe_out_valid_o = complete;
        pipe_in_ready_o = (state_q == PARALLEL_SUM); //pipe in ready in parallel sum state
        pipe_out_ctrl_o = ctrl_q; //TODO Remove most of this
        pipe_out_res_o =  acc_q[(OP_W / 32) / 2 - 1][31:0];//Output always comes from this adder (# adders / 2 -1 = OP_W/64 -1)
        pipe_out_mask_o = '0;
        unique case(ctrl_q.eew)
            VSEW_32: pipe_out_mask_o[3:0] = !ctrl_q.vl_0 ? 4'b1111 : 4'b0000; //vl_0 case should not be necessary according to my reading of the spec
            VSEW_16: pipe_out_mask_o[1:0] = !ctrl_q.vl_0 ? 2'b11 : 2'b00;
            VSEW_8:  pipe_out_mask_o[0] = !ctrl_q.vl_0 ? 1'b1 : 1'b0;
        endcase
    end
endmodule;
