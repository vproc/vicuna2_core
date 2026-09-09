// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

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

    // Tree parameters 
    localparam int unsigned NLEAF  = OP_W / 8; // worst case, biggest possible tree
    localparam int unsigned LEVELS = $clog2(NLEAF); 

    // normalizes elements to 33 bit signed
    function automatic logic signed [32:0] normalize(input logic [31:0] v,
                                                     input cfg_vsew    sew,
                                                     input logic       is_signed);

        logic [32:0] k;
        case (sew)
            VSEW_8:  k = is_signed ? {{25{v[7]}},  v[7:0] } : {25'b0, v[7:0] };
            VSEW_16: k = is_signed ? {{17{v[15]}}, v[15:0]} : {17'b0, v[15:0]};
            default: k = is_signed ? { v[31],      v[31:0]} : {1'b0,  v[31:0]};
        endcase
        return k;
    endfunction

    // compares and returns winner
    function automatic logic [31:0] minmax(input logic [31:0] a,
                                           input logic [31:0] b,
                                           input cfg_vsew     sew,
                                           input logic [2:0]  op);

        // op[1] = max over min, op[0] = signed over unsigned
        logic a_lt_b;
        a_lt_b = $signed(normalize(a, sew, op[0])) < $signed(normalize(b, sew, op[0]));
        return (a_lt_b ^ op[1]) ? a : b; // invert for max
    endfunction

    // neutral value: loses every comparison (unused lanes, masked, past vl)
    function automatic logic [31:0] identity(input cfg_vsew    sew,
                                             input logic [2:0] op);

        logic [31:0] id;

        // unsigned
        if (!op[0]) begin
            id = op[1] ? 32'h00000000 : 32'hFFFFFFFF;

        // signed
        end else begin
            case (sew)
                VSEW_8:  id = op[1] ? 32'h00000080 : 32'h0000007F;
                VSEW_16: id = op[1] ? 32'h00008000 : 32'h00007FFF;
                default: id = op[1] ? 32'h80000000 : 32'h7FFFFFFF;
            endcase
        end
        return id;
    endfunction

    cfg_vsew     sew;
    logic [2:0]  op;
    logic [31:0] id;
    assign sew = pipe_in_ctrl_i.eew;
    assign op  = pipe_in_ctrl_i.mode.reduction.op;
    assign id  = identity(sew, op);

    logic [31:0] leaf [NLEAF]; // NLEAF words of 32 bits

    // assign tree leafs with their values
    always_comb begin

        // default assign id
        for (int i = 0; i < NLEAF; i++) begin
            leaf[i] = id;
        end

        // slice op2 into elements at this SEW, masked lanes get id
        case (sew)
            VSEW_8: begin
                for (int i = 0; i < OP_W/8; i++) begin
                    leaf[i] = pipe_in_mask_i[i]    ? {24'b0, pipe_in_op2_i[8*i  +:  8]} : id;
                end
            end
            VSEW_16: begin
                for (int i = 0; i < OP_W/16; i++) begin
                    leaf[i] = pipe_in_mask_i[2*i]  ? {16'b0, pipe_in_op2_i[16*i +: 16]} : id;
                end
            end
            default: begin
                for (int i = 0; i < OP_W/32; i++) begin
                    leaf[i] = pipe_in_mask_i[4*i]  ? pipe_in_op2_i[32*i +: 32]  : id;
                end
            end
        endcase
    end

    // THE TREE
    logic [31:0] node [LEVELS+1][NLEAF];
    always_comb begin

        // default assign id
        for (int l = 0; l <= LEVELS; l++) begin
            for (int i = 0; i < NLEAF; i++) begin
                node[l][i] = id;
            end
        end

        // connect leafs to tree
        for (int i = 0; i < NLEAF; i++) begin
            node[0][i] = leaf[i];
        end

        // compare and forward
        for (int l = 1; l <= LEVELS; l++) begin
            for (int i = 0; i < (NLEAF >> l); i++) begin
                node[l][i] = minmax(node[l-1][2*i], node[l-1][2*i+1], sew, op);
            end
        end
    end

    // this chunk's winner
    logic [31:0] root;
    assign root = node[LEVELS][0];

    // read scalar operand
    logic [31:0] seed;
    always_comb begin
        case (sew)
            VSEW_8:  seed = {24'b0, pipe_in_op1_i[7:0]};
            VSEW_16: seed = {16'b0, pipe_in_op1_i[15:0]};
            default: seed =         pipe_in_op1_i[31:0];
        endcase
    end

    // compare accumulated value
    logic [31:0] acc_d, acc_q;
    assign acc_d = minmax(root, pipe_in_ctrl_i.first_cycle ? seed : acc_q, sew, op); // compare this chunk's winner to the winner so far
    always_ff @(posedge clk_i) begin
        if (pipe_in_valid_i & pipe_in_ready_o) begin
            acc_q <= acc_d;
        end
    end

    // METADATA forwarding
    CTRL_T ctrl_d, ctrl_q;
    always_comb begin
        ctrl_d = pipe_in_ctrl_i;
        if (!pipe_in_ctrl_i.first_cycle) begin
            ctrl_d.res_vaddr = ctrl_q.res_vaddr;
        end
    end
    always_ff @(posedge clk_i) begin
        if (pipe_in_valid_i & pipe_in_ready_o) begin
            ctrl_q <= ctrl_d;
        end
    end

    // check if done
    logic complete_q;
    always_ff @(posedge clk_i) begin
        if (!sync_rst_ni) begin
            complete_q <= 1'b0;
        end else begin
            complete_q <= pipe_in_valid_i & pipe_in_ready_o & pipe_in_ctrl_i.last_cycle;
        end
    end

    assign pipe_in_ready_o  = ~complete_q;
    assign pipe_out_valid_o = complete_q;
    assign pipe_out_ctrl_o  = ctrl_q;
    assign pipe_out_res_o   = acc_q;

    // apply write byte enable according to SEW
    always_comb begin
        pipe_out_mask_o = '0;
        case (ctrl_q.eew)
            VSEW_32: pipe_out_mask_o[3:0] = !ctrl_q.vl_0 ? 4'b1111 : 4'b0000;
            VSEW_16: pipe_out_mask_o[1:0] = !ctrl_q.vl_0 ? 2'b11 : 2'b00;
            VSEW_8:  pipe_out_mask_o[0]   = !ctrl_q.vl_0 ? 1'b1 : 1'b0;
            default: pipe_out_mask_o = '0;
        endcase
    end

endmodule
