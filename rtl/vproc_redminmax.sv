// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

//Tree-based reduction unit for vredmin/vredminu/vredmax/vredmaxu
module vproc_vredminmax import vproc_pkg::*; #(
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

    //Stub: elaborates and occupies the unit slot, produces no results yet
    assign pipe_in_ready_o  = 1'b1;
    assign pipe_out_valid_o = 1'b0;
    assign pipe_out_ctrl_o  = '0;
    assign pipe_out_res_o   = '0;
    assign pipe_out_mask_o  = '0;

endmodule
