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

    //STUB: correct handshake, wrong arithmetic. Result is always zero.
    //Accepts every operand chunk, then completes once after last_cycle.

    //Buffer for pipeline metadata (mirrors vproc_vredsum)
    CTRL_T ctrl_d, ctrl_q;
    always_comb begin
        ctrl_d = pipe_in_ctrl_i;
        if (!pipe_in_ctrl_i.first_cycle) begin
            //This instruction only writes a single vreg: hold the first cycle's address
            ctrl_d.res_vaddr = ctrl_q.res_vaddr;
        end
    end
    always_ff @(posedge clk_i) begin
        if (pipe_in_valid_i & pipe_in_ready_o) begin
            ctrl_q <= ctrl_d;
        end
    end

    //One result per instruction, raised after the final operand chunk
    logic complete_q;
    always_ff @(posedge clk_i) begin
        if (!sync_rst_ni) begin
            complete_q <= 1'b0;
        end else if (pipe_in_valid_i & pipe_in_ready_o & pipe_in_ctrl_i.last_cycle) begin
            complete_q <= 1'b1;
        end else if (complete_q & pipe_out_ready_i) begin
            complete_q <= 1'b0;
        end
    end

    assign pipe_in_ready_o  = ~complete_q;
    assign pipe_out_valid_o = complete_q;
    assign pipe_out_ctrl_o  = ctrl_q;
    assign pipe_out_res_o   = '0;

    //Single element result, width follows SEW (mirrors vproc_vredsum)
    always_comb begin
        pipe_out_mask_o = '0;
        unique case (ctrl_q.eew)
            VSEW_32: pipe_out_mask_o[3:0] = !ctrl_q.vl_0 ? 4'b1111 : 4'b0000;
            VSEW_16: pipe_out_mask_o[1:0] = !ctrl_q.vl_0 ? 2'b11 : 2'b00;
            VSEW_8:  pipe_out_mask_o[0]   = !ctrl_q.vl_0 ? 1'b1 : 1'b0;
            default: pipe_out_mask_o = '0;
        endcase
    end

endmodule
