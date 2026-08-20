// Copyright 2024 TU Munich
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_div #(
        parameter int unsigned        DIV_OP_W       = 32,   // DIV unit operand width in bits.
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
    //Input/Output Buffers Defines
    ///////////////////////////////////////////////////////////////////////////

    logic [DIV_OP_W  -1:0] opa_i_q, opb_i_q;
    CTRL_T                  unit_ctrl_q;
    logic                   data_valid_i_q;

    logic [DIV_OP_W/8-1:0] operand_mask_q;

    ///////////////////////////////////////////////////////////////////////////
    // DIV ARITHMETIC Defines
    ///////////////////////////////////////////////////////////////////////////
    logic [DIV_OP_W/32  -1:0] div_ready_o, div_valid_o;
    logic [DIV_OP_W  -1:0] div_out;
    logic [DIV_OP_W  -1:0] div_in_opa, div_in_opb;

    ///////////////////////////////////////////////////////////////////////////
    //Output Connections
    ///////////////////////////////////////////////////////////////////////////
    assign pipe_out_ctrl_o = unit_ctrl_q;
    assign pipe_out_res_o = div_out;
    assign pipe_out_valid_o = &div_valid_o;
    assign pipe_out_mask_o = operand_mask_q;
    assign pipe_in_ready_o  = &div_ready_o & ~data_valid_i_q;
    ///////////////////////////////////////////////////////////////////////////

    ///////////////////////////////////////////////////////////////////////////
    //Input/Output Buffers
    ///////////////////////////////////////////////////////////////////////////
    always_ff @(posedge clk_i or negedge async_rst_ni) begin
        if (~async_rst_ni || ~sync_rst_ni) begin
            opa_i_q        <= '0;
            opb_i_q        <= '0;
            unit_ctrl_q    <= '0;
            data_valid_i_q <= 1'b0;
            operand_mask_q <= '0;
        end else if (pipe_in_valid_i & pipe_in_ready_o) begin
            opa_i_q        <= pipe_in_op2_i;
            opb_i_q        <= pipe_in_op1_i;
            unit_ctrl_q    <= pipe_in_ctrl_i;
            operand_mask_q <= pipe_in_mask_i;
            data_valid_i_q <= 1'b1;
        end else if (&div_ready_o) begin
            data_valid_i_q <= 1'b0;
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    // sign extension
    always_comb begin
        div_in_opa = '0;
        div_in_opb = '0;

        for (integer g = 0; g < DIV_OP_W / 32; g++) begin
            unique case (unit_ctrl_q.eew)
                VSEW_32: begin
                    div_in_opa[32*g +: 32] = opa_i_q[32*g +: 32];
                    div_in_opb[32*g +: 32] = opb_i_q[32*g +: 32];
                end
                VSEW_16: begin
                    div_in_opa[32*g +: 32] = {{16{unit_ctrl_q.decode_metadata.operands[0].sign & opa_i_q[16*g + 15]}}, opa_i_q[16*g +: 16]};
                    div_in_opb[32*g +: 32] = {{16{unit_ctrl_q.decode_metadata.operands[1].sign & opb_i_q[16*g + 15]}}, opb_i_q[16*g +: 16]};
                end
                VSEW_8: begin
                    div_in_opa[32*g +: 32] = {{24{unit_ctrl_q.decode_metadata.operands[0].sign & opa_i_q[8*g + 7]}}, opa_i_q[8*g +: 8]};
                    div_in_opb[32*g +: 32] = {{24{unit_ctrl_q.decode_metadata.operands[1].sign & opb_i_q[8*g + 7]}}, opb_i_q[8*g +: 8]};
                end
                default: ;
            endcase
        end
    end

    ///////////////////////////////////////////////////////////////////////////
    //generate div units
     generate
        for (genvar g = 0; g < DIV_OP_W / 32; g++) begin

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
            .op_a_i             ( div_in_opa[32*g +: 32]         ),
            .op_b_i             ( div_in_opb[32*g +: 32]         ),

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
            .ready_i            ( pipe_out_ready_i                        )  //comes from WB_READY 

            );

            ////
            // Shifter and CLZ unit from ALU needed to support the CV32E40X DIV unit
            ////
            vproc_div_shift_clz shift_clz_i
            (
            .muldiv_operand_b_i  ( div_in_opb[32*g +: 32] ),

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
