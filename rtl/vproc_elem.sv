// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_elem #(
    parameter int unsigned VLEN           = 128,    // Width in bits of vector registers
    parameter int unsigned XLEN           = 32,     // Width in bits of scalar registers
    parameter int unsigned OP_W           = 32,     // Operand width for vfirst.m
    parameter bit          BUF_RESULTS    = 1'b1,   // insert pipeline stage after computing result
    parameter type         CTRL_T         = logic,
    parameter bit          DONT_CARE_ZERO = 1'b0    // initialize don't care values to zero
) (
    // --- Clock & reset ---
    input logic clk_i,
    input logic async_rst_ni,
    input logic sync_rst_ni,

    // --- Inputs ---
    input logic           pipe_in_valid_i,
    input CTRL_T          pipe_in_ctrl_i,
    input logic  [31 : 0] pipe_in_op1_i,
    input logic  [31 : 0] pipe_in_op2_i,
    input logic           pipe_out_ready_i,
    input logic           pipe_in_xreg_ready_i,

    // --- Outputs ---
    output logic                 pipe_in_ready_o,
    output logic                 pipe_out_valid_o,
    output CTRL_T                pipe_out_ctrl_o,
`ifdef RISCV_ZVE32F
    output logic                 pipe_out_freg,
`endif
    output logic                 pipe_out_xreg_valid_o,
    output logic  [XLEN - 1 : 0] pipe_out_xreg_data_o,
    output logic  [       4 : 0] pipe_out_xreg_addr_o
);

  import vproc_pkg::*;

  // --- Structs ---

  typedef struct packed {
    logic [(VLEN/OP_W) - 1:0] counter;
    logic [(VLEN/OP_W) - 1:0] vl;
    logic vfirst_found;
    logic vfirst_xreg_signal_pending;
  } elem_ctrl_t;

  // --- Buffers ---

  elem_ctrl_t elem_ctrl_d, elem_ctrl_q;
  logic state_res_ready;
  logic state_res_valid_q, state_res_valid_d;
  CTRL_T state_res_q, state_res_d;

  always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_elem_stage_res_valid
    if (~async_rst_ni) begin
      state_res_valid_q <= 1'b0;
      state_res_q <= '0;
      elem_ctrl_q    <= '0;
    end else if (~sync_rst_ni) begin
      state_res_valid_q <= 1'b0;
      state_res_q <= '0;
      elem_ctrl_q    <= '0;
    end else if (state_res_ready) begin
      state_res_valid_q <= state_res_valid_d;
      state_res_q <= state_res_d;
      elem_ctrl_q    <= elem_ctrl_d;
    end
  end

  assign state_res_ready   = ~state_res_valid_q | pipe_out_ready_i;
  assign pipe_in_ready_o   = pipe_in_xreg_ready_i;
  assign state_res_valid_d = pipe_in_valid_i;
  assign state_res_d       = pipe_in_ctrl_i;

  logic [31:0] elem1, elem2;
  assign elem1 = pipe_in_op1_i;
  assign elem2 = pipe_in_op2_i;

  // XREG write-back
  assign pipe_out_xreg_addr_o = state_res_q.res_vaddr;
`ifdef RISCV_ZVE32F

  assign pipe_out_freg = pipe_out_xreg_valid_o & state_res_q.mode.elem.freg;
`endif

  assign pipe_out_valid_o = state_res_valid_q;
  assign pipe_out_ctrl_o  = state_res_q;

  // --- Comb. logic ---

  logic [31:0] counter_inc;
  assign elem_ctrl_d.counter = (pipe_in_ctrl_i.first_cycle ? '0 : elem_ctrl_q.counter) + counter_inc;
  assign elem_ctrl_d.vl = pipe_in_ctrl_i.first_cycle ? pipe_in_ctrl_i.vl : elem_ctrl_q.vl;
  logic [(VLEN/OP_W) - 1:0] vl;
  assign vl = pipe_in_ctrl_i.first_cycle ? pipe_in_ctrl_i.vl : elem_ctrl_q.vl;

  // Instantiate leading zero counter (pulp) for vfirst.m
  logic [OP_W - 1 : 0] lzc_input;
  logic [XLEN - 1 : 0] lzc_result;
  logic lzc_empty;
  lzc #(
      .WIDTH    (OP_W),  // Feed in as much as we get in one shift round
      .MODE     (1'b1),  // 1: leading zeros mode
      .CNT_WIDTH(XLEN)   // Result is a scalar register, so make it XLEN wide
  ) lzc (
      .in_i(lzc_input),
      .cnt_o(lzc_result),
      .empty_o(lzc_empty)
  );

  always_comb begin
    counter_inc          = DONT_CARE_ZERO ? '0 : 'x;
    lzc_input            = DONT_CARE_ZERO ? '0 : 'x;
    pipe_out_xreg_data_o = DONT_CARE_ZERO ? '0 : 'x;
    unique case (pipe_in_ctrl_i.mode.elem.op)
      ELEM_VFIRST: begin
        // Buffers
        elem_ctrl_d.vfirst_xreg_signal_pending = elem_ctrl_q.vfirst_xreg_signal_pending;
        elem_ctrl_d.vfirst_found = elem_ctrl_q.vfirst_found;
        // Default -1
        pipe_out_xreg_data_o = '1;
        pipe_out_xreg_valid_o = 1'b0;
        // VL is in bytes, increment the counter by the number of bytes processed
        counter_inc = (OP_W >> 3);
        // elem1: chunk of vs2 (pipeline width)
        // elem2: chunk of mask register v0 (pipeline width)
        // Find first one by ANDing and counting leading zeroes
        if (elem_ctrl_q.counter < vl && pipe_in_valid_i && pipe_in_ready_o && !elem_ctrl_q.vfirst_found) begin
          lzc_input = elem1 & elem2;
        end else begin
          lzc_input = '0;
        end

        // Accept result if it lies within VL and no result has been found yet
        if (!lzc_empty && !elem_ctrl_q.vfirst_found) begin
          if (elem_ctrl_q.counter + (lzc_result >> 3) < vl) begin
            // Result + # of already searched bits
            pipe_out_xreg_data_o = lzc_result + (elem_ctrl_q.counter << 3);
          end
          pipe_out_xreg_valid_o = 1'b1;
          elem_ctrl_d.vfirst_found = 1'b1;
        end

        // On the last cycle, if no result has been found, signal xreg
        if (pipe_in_ctrl_i.last_cycle || elem_ctrl_q.vfirst_xreg_signal_pending) begin
          if (pipe_in_ready_o) begin
            if (!elem_ctrl_q.vfirst_found) begin
              // Result will be -1, or the one found in the last cycle
              pipe_out_xreg_valid_o = 1'b1;
            end
            elem_ctrl_d.vfirst_found = 1'b0;
            elem_ctrl_d.vfirst_xreg_signal_pending = 1'b0;
          end else begin
            elem_ctrl_d.vfirst_xreg_signal_pending = 1'b1;
          end
        end
      end
      default: ;

    endcase
  end

endmodule
