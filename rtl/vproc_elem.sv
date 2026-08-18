// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_elem #(
    parameter int unsigned VLEN           = 128,    // Width in bits of vector registers
    parameter int unsigned XLEN           = 32,     // Width in bits of scalar registers
    parameter int unsigned OP_W           = 32,     // Operand width for vfirst.m
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
    input logic           pipe_out_xreg_ready_i,

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

  typedef enum logic [1:0] {
    ACCEPTING = 2'b00,
    WAIT_XREG_READY = 2'b01,
    WAIT_LAST_CYCLE = 2'b10
  } elem_state_t;

  // --- Buffers ---
  elem_ctrl_t elem_ctrl_d, elem_ctrl_q;
  elem_state_t elem_state_d, elem_state_q;
  logic state_res_ready;
  logic state_res_valid_q, state_res_valid_d;
  CTRL_T state_res_q, state_res_d;
  logic [XLEN-1:0] xresult_d, xresult_q;
  logic last_cycle_d, last_cycle_q, last_cycle;

  always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_elem_stage_res_valid
    if (~async_rst_ni) begin
      state_res_valid_q <= 1'b0;
      state_res_q       <= '0;
      elem_ctrl_q       <= '0;
      elem_state_q      <= ACCEPTING;
      xresult_q         <= '0;
      last_cycle_q      <= 1'b0;

    end else if (~sync_rst_ni) begin
      state_res_valid_q <= 1'b0;
      state_res_q       <= '0;
      elem_ctrl_q       <= '0;
      elem_state_q      <= ACCEPTING;
      xresult_q         <= '0;
      last_cycle_q      <= 1'b0;

    end else if (state_res_ready) begin
      state_res_valid_q <= state_res_valid_d;
      state_res_q       <= state_res_d;
      elem_ctrl_q       <= elem_ctrl_d;
      elem_state_q      <= elem_state_d;
      xresult_q         <= xresult_d;
      last_cycle_q      <= last_cycle_d;

    end
  end

  assign state_res_ready   = ~state_res_valid_q | pipe_out_ready_i;
  assign pipe_in_ready_o   = pipe_out_xreg_ready_i;
  assign state_res_valid_d = pipe_in_valid_i;
  assign state_res_d       = pipe_in_ctrl_i;

  logic [31:0] elem1, elem2;
  assign elem1 = pipe_in_op1_i;
  assign elem2 = pipe_in_op2_i;

  // XREG write-back
  assign pipe_out_xreg_addr_o = pipe_in_ctrl_i.first_cycle ? pipe_in_ctrl_i.res_vaddr : state_res_q.res_vaddr;
`ifdef RISCV_ZVE32F
  assign pipe_out_freg = pipe_out_xreg_valid_o & state_res_q.mode.elem.freg;
`endif

  assign pipe_out_valid_o = pipe_out_xreg_valid_o & pipe_out_xreg_ready_i;
  assign pipe_out_ctrl_o  = state_res_q;

  logic valid_first_cycle, valid_last_cycle;
  assign valid_first_cycle = pipe_in_ctrl_i.first_cycle & pipe_in_valid_i;
  assign valid_last_cycle  = pipe_in_ctrl_i.last_cycle & pipe_in_valid_i;

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
      .MODE     (1'b0),  // 0: trailing zeros mode
      .CNT_WIDTH(XLEN)   // Result is a scalar register, so make it XLEN wide
  ) lzc (
      .in_i(lzc_input),
      .cnt_o(lzc_result),
      .empty_o(lzc_empty)
  );

  // --- Helper signals ---
  logic [(VLEN/OP_W) - 1:0] counter;
  logic valid_last_cycle_detected;

  assign counter = pipe_in_ctrl_i.first_cycle ? '0 : elem_ctrl_q.counter;
  assign last_cycle_d = valid_first_cycle ? 1'b0 : last_cycle_q;
  assign valid_last_cycle_detected = last_cycle_q | valid_last_cycle;
  assign pipe_out_xreg_data_o = xresult_q;

  // --- State machine logic ---
  always_comb begin
    // Zero or don't care signals
    counter_inc = DONT_CARE_ZERO ? '0 : 'x;
    lzc_input = DONT_CARE_ZERO ? '0 : 'x;

    // Default zero signals
    pipe_out_xreg_valid_o = 1'b0;

    // Default register assignments
    xresult_d = xresult_q;
    unique case (elem_state_q)
      ACCEPTING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)
          ELEM_VFIRST: begin

            if (counter < vl && pipe_in_valid_i && pipe_in_ready_o) begin
              lzc_input = pipe_in_ctrl_i.decode_metadata.masked ? (elem1 & elem2) : elem1;
            end else begin
              lzc_input = '0;
            end

            if (!lzc_empty && (counter + (lzc_result >> 3) < vl)) begin
              xresult_d = lzc_result;
            end else begin
              xresult_d = '1;
            end

          end
          default: ;
        endcase
      end
      WAIT_XREG_READY: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)
          ELEM_VFIRST: begin
            pipe_out_xreg_valid_o = 1'b1;
          end
          default: ;
        endcase
      end
      WAIT_LAST_CYCLE: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)
          ELEM_VFIRST: begin
          end
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  // --- State machine transitions ---
  always_comb begin
    elem_state_d = elem_state_q;
    unique case (elem_state_q)
      ACCEPTING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)
          ELEM_VFIRST: begin
            if (!lzc_empty | counter >= vl) begin
              elem_state_d = WAIT_XREG_READY;
            end
          end
          default: elem_state_d = ACCEPTING;
        endcase
      end
      WAIT_XREG_READY: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)
          ELEM_VFIRST: begin
            if (pipe_out_xreg_ready_i) begin
              if (valid_last_cycle_detected) begin
                elem_state_d = ACCEPTING;
              end else begin
                elem_state_d = WAIT_LAST_CYCLE;
              end
            end
          end
          default: elem_state_d = ACCEPTING;
        endcase
      end
      WAIT_LAST_CYCLE: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)
          ELEM_VFIRST: begin
            if (valid_last_cycle_detected) begin
              elem_state_d = ACCEPTING;
            end
          end
          default: elem_state_d = ACCEPTING;
        endcase
      end
      default: elem_state_d = ACCEPTING;
    endcase
  end

endmodule
