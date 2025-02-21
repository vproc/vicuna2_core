// Copyright 2024 TU Munich
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_div #(
        parameter int unsigned        DIV_OP_W       = 64,   // DIV unit operand width in bits.
        parameter type                CTRL_T         = logic
    )(
        input  logic                  clk_i,
        input  logic                  async_rst_ni,
        input  logic                  sync_rst_ni,

        input  logic                  pipe_in_valid_i,
        output logic                  pipe_in_ready_o,
        input  CTRL_T                 pipe_in_ctrl_i,
        input  logic [DIV_OP_W  -1:0] pipe_in_op1_i,
        input  logic [DIV_OP_W  -1:0] pipe_in_op2_i,
        input  logic [DIV_OP_W/8-1:0] pipe_in_mask_i,

        output logic                  pipe_out_valid_o,
        input  logic                  pipe_out_ready_i,
        output CTRL_T                 pipe_out_ctrl_o,
        output logic [DIV_OP_W  -1:0] pipe_out_res_o,
        output logic [DIV_OP_W/8-1:0] pipe_out_mask_o
    );

    import vproc_pkg::*;

    ///////////////////////////////////////////////////////////////////////////
    //Input connections
    assign data_valid_i_d = pipe_in_valid_i;
    assign div_ready_i_d = pipe_out_ready_i;
    assign operand_mask_d = pipe_in_mask_i;
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    //Output Connections
    assign pipe_out_ctrl_o = unit_ctrl_q;
    assign pipe_out_res_o = result;
    assign pipe_out_valid_o = div_valid_o_d;

    always_comb begin
        pipe_in_ready_o = &div_ready_o & (shift_counter_next == 2'b00); //only signal out when all data has been processed
        div_valid_o_d = &div_valid_o & (shift_counter_next == 2'b00);
    end
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    //Input/Output Buffers
    

    logic [DIV_OP_W  -1:0] opa_i_d, opa_i_q, opb_i_d, opb_i_q;
    CTRL_T                unit_ctrl_d, unit_ctrl_q;
    logic                 data_valid_i_d, data_valid_i_q;

    logic                  div_valid_o_d, div_valid_o_q;
    logic                  div_ready_i_d;

    logic [DIV_OP_W/8-1:0] operand_mask_d, operand_mask_q;

    logic [DIV_OP_W/8-1:0] result_mask_d, result_mask_q;

    logic [DIV_OP_W  -1:0] result, result_partial_d, result_partial_d_shifted,result_partial_q;


    always_ff @(posedge clk_i) begin
        //only advance input buffers if ALL div units are ready
        if ( &div_ready_o ) begin
            opa_i_q <= opa_i_d;
            opb_i_q <= opb_i_d;
            unit_ctrl_q <= unit_ctrl_d;
            data_valid_i_q <= data_valid_i_d | !(shift_counter_next == 2'b00); //Hold data valid high if still data left to process
            operand_mask_q <= operand_mask_d;
            if (pipe_out_valid_o & unit_ctrl_q.last_cycle) begin
                opa_i_q <= 'b0;
                opb_i_q <= 'b0;
                unit_ctrl_q <= 'b0;
                data_valid_i_q <= 'b0;
                operand_mask_q <= 'b0;
            end
        end

        if (&div_valid_o) begin
            result_partial_q <= result_partial_d_shifted; 
        end

    end

    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    // Mask out generation

    // result byte mask
    logic [DIV_OP_W/8-1:0] vl_mask;

    assign vl_mask        = ~unit_ctrl_q.vl_part_0 ? ({(DIV_OP_W/8){1'b1}} >> (~unit_ctrl_q.vl_part)) : '0;
    assign pipe_out_mask_o = (unit_ctrl_q.mode.div.masked ? operand_mask_q : {(DIV_OP_W/8){1'b1}}) & vl_mask;

    ///////////////////////////////////////////////////////////////////////////

    
    ///////////////////////////////////////////////////////////////////////////
    //Shifts + sign extensions for inputs
    always_comb begin
        //if counter == 00 (meaning SEW==32 or all data finished) pass through from inputs
        if (shift_counter_next == 2'b00) begin
            opa_i_d = pipe_in_op2_i;
            opb_i_d = pipe_in_op1_i;
            unit_ctrl_d = pipe_in_ctrl_i;
        end else if (unit_ctrl_q.eew == VSEW_16) begin
            //if SEW is 16, shift top half down
            opa_i_d[DIV_OP_W/2-1:0] = opa_i_q[DIV_OP_W-1:DIV_OP_W/2];
            opb_i_d[DIV_OP_W/2-1:0] = opb_i_q[DIV_OP_W-1:DIV_OP_W/2];
            unit_ctrl_d = unit_ctrl_q;
        end else if (unit_ctrl_q.eew == VSEW_8) begin
            //if SEW is 8, shift top 3/4 down
            opa_i_d[(3*DIV_OP_W/4)-1:0] = opa_i_q[DIV_OP_W-1:(DIV_OP_W/4)];
            opb_i_d[(3*DIV_OP_W/4)-1:0] = opb_i_q[DIV_OP_W-1:(DIV_OP_W/4)];
            unit_ctrl_d = unit_ctrl_q;
        end else begin
            opa_i_d = opa_i_q;
            opb_i_d = opb_i_q;
            unit_ctrl_d = unit_ctrl_q;
        end

    end

    //Shifts + combinatins with buffer for outputs
    always_comb begin
        unique case (unit_ctrl_q.eew)
                VSEW_16 : begin 
                              result = {result_partial_d[(DIV_OP_W/2-1):0], result_partial_q[(DIV_OP_W/2-1):0]}; //Combine top half saved in buffer with current bottom half
                              result_partial_d_shifted = result_partial_d;                                       //Data already in lower half, dont need to save anything from buffer
                        end

                VSEW_8  : begin 
                              result = {result_partial_d[(DIV_OP_W/4-1):0], result_partial_q[(3*DIV_OP_W/4)-1:0]};                                             //Combine top 3/4 saved in buffer with current bottom 1/4
                              result_partial_d_shifted = {8'b00000000, result_partial_d[(DIV_OP_W/4)-1:0], result_partial_q[(3*DIV_OP_W/4)-1:(DIV_OP_W/4)] }; //put new data in position 2, previous pos 2/3 become new position 3/4
                        end
                default : result = result_partial_d;                                                               //Result is already DIV_OP_W wide, pass directly
        endcase
    end


    //Shift counter control: 
    logic [1:0] shift_counter, shift_counter_next;

    always_ff @(posedge clk_i) begin
        if (async_rst_ni == 1'b0 | (pipe_out_valid_o & unit_ctrl_q.last_cycle)) begin
            shift_counter <= 2'b0;
        end else begin
            shift_counter <= shift_counter_next;
        end

    end

    always_comb begin
        if (&div_valid_o == 1'b1) begin
            unique case (unit_ctrl_q.eew)
                VSEW_32 : shift_counter_next = 2'b00;
                VSEW_16 : shift_counter_next = shift_counter + 2;
                VSEW_8  : shift_counter_next = shift_counter + 1;
                default: shift_counter_next = 2'b00;
            endcase
        end else begin
            shift_counter_next = shift_counter;
        end 
    end

    ///////////////////////////////////////////////////////////////////////////



    ///////////////////////////////////////////////////////////////////////////
    // DIV ARITHMETIC
    // Each div unit handles one 32 bit result.

    logic [DIV_OP_W/32  -1:0] div_en, div_ready_o, div_valid_o;
    logic [DIV_OP_W  -1:0] div_in_opa, div_in_opb;
    logic [DIV_OP_W  -1:0] div_out;

     generate
        for (genvar g = 0; g < DIV_OP_W / 32; g++) begin

            //based on SEW and OP, select and extend the operands and pack the current set of outputs
            always_comb begin
                unique case ({unit_ctrl_q.eew, unit_ctrl_q.mode.div.op})
                    {VSEW_32, DIV_DIVU},
                    {VSEW_32, DIV_REMU},
                    {VSEW_32, DIV_DIV},
                    {VSEW_32, DIV_REM}: begin
                        div_in_opa[32*g +: 32]  = opa_i_q[32*g +: 32];
                        div_in_opb[32*g +: 32]  = opb_i_q[32*g +: 32];
                        result_partial_d[32*g +: 32]    = div_out[32*g +: 32];
                    end
                    {VSEW_16, DIV_DIVU},
                    {VSEW_16, DIV_REMU}: begin
                        div_in_opa[32*g +: 32]  = {16'b0,  opa_i_q[16*g +: 16]};
                        div_in_opb[32*g +: 32]  = {16'b0,  opb_i_q[16*g +: 16]};
                        result_partial_d[16*g +: 16]    = div_out[32*g +: 16];
                    end
                    {VSEW_16, DIV_DIV},
                    {VSEW_16, DIV_REM}: begin
                        div_in_opa[32*g +: 32]  = {{16{opa_i_q[16*g + 15]}},  opa_i_q[16*g +: 16]};
                        div_in_opb[32*g +: 32]  = {{16{opb_i_q[16*g + 15]}},  opb_i_q[16*g +: 16]};
                        result_partial_d[16*g +: 16]    = div_out[32*g +: 16];
                    end
                    {VSEW_8, DIV_DIVU},
                    {VSEW_8, DIV_REMU}: begin
                        div_in_opa[32*g +: 32]  = {24'b0,  opa_i_q[8*g +: 8]};
                        div_in_opb[32*g +: 32]  = {24'b0,  opb_i_q[8*g +: 8]};
                        result_partial_d[8*g +: 8]      = div_out[32*g +: 8];
                    end
                    {VSEW_8, DIV_DIV},
                    {VSEW_8, DIV_REM}: begin
                        div_in_opa[32*g +: 32]  = {{24{opa_i_q[8*g + 7]}},  opa_i_q[8*g +: 8]};
                        div_in_opb[32*g +: 32]  = {{24{opb_i_q[8*g + 7]}},  opb_i_q[8*g +: 8]};
                        result_partial_d[8*g +: 8]      = div_out[32*g +: 8];
                    end
                    default: begin
                        div_in_opa[32*g +: 32]  = 32'b0;
                        div_in_opb[32*g +: 32]  = 32'b0;
                        result_partial_d[32*g +: 32]    = 32'b0;
                    end
                endcase
            end


            logic           div_en;               
            logic           div_clz_en;
            logic [31:0]    div_clz_data_rev;
            logic [5:0]     div_clz_result;
            logic           div_shift_en;
            logic [5:0]     div_shift_amt;
            logic [31:0]    div_op_b_shifted;

            cv32e40x_div div_i
            (
            .clk                ( clk_i                                ),
            .rst_n              ( async_rst_ni                         ), //which reset signal should be used? TODO

            // Input IF
            .data_ind_timing_i  ( 1'b1                                 ), // When enabled, all divisions take same number of cycles.  Drastically improves performance on unit tests(unexpected)
            .operator_i         ( unit_ctrl_q.mode.div.op           ), 
            .op_a_i             ( div_in_opa[32*g +: 32]            ),
            .op_b_i             ( div_in_opb[32*g +: 32]            ),

            // ALU CLZ interface
            .alu_clz_result_i   ( div_clz_result                       ), 
            .alu_clz_en_o       ( div_clz_en                           ), 
            .alu_clz_data_rev_o ( div_clz_data_rev                     ), 

            // ALU shifter interface
            .alu_op_b_shifted_i ( div_op_b_shifted                     ), 
            .alu_shift_en_o     ( div_shift_en                         ), 
            .alu_shift_amt_o    ( div_shift_amt                        ), 

            // Result
            .result_o           ( div_out[32*g +: 32]           ),

            // divider enable, not affected by kill/halt
            .div_en_i           ( 1'b1                          ), //

            // Handshakes
            .valid_i            ( data_valid_i_q                        ), //comes from EX_VALID
            .ready_o            ( div_ready_o[g]                       ), //goes to EX_READY
            .valid_o            ( div_valid_o[g]                       ), //goes to WB_VALID
            .ready_i            ( div_ready_i_d                          )  //comes from WB_READY 

            );

            ////
            // Shifter and CLZ unit from ALU needed to support the CV32E40X DIV unit
            ////
            vproc_div_shift_clz shift_clz_i
            (
            .muldiv_operand_b_i  ( div_in_opb[32*g +: 32]  ),

            // ALU CLZ interface
            .div_clz_en_i        ( div_clz_en                    ),
            .div_clz_data_rev_i  ( div_clz_data_rev              ),
            .div_clz_result_o    ( div_clz_result                ),

            // ALU shifter interface
            .div_shift_en_i      ( div_shift_en                  ),
            .div_shift_amt_i     ( div_shift_amt                 ),
            .div_op_b_shifted_o  ( div_op_b_shifted              )
            );
        end
    endgenerate
endmodule
