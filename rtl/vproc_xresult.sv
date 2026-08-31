// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_xresult #(
    parameter int unsigned VLEN           = 128,    // Width in bits of vector registers
    parameter int unsigned XLEN           = 32,     // Width in bits of scalar registers
    parameter int unsigned OP_W           = 32,     // Operand width for vfirst.m
    parameter type         CTRL_T         = logic,
    parameter int unsigned XIF_ID_W       = 4,
    parameter bit          DONT_CARE_ZERO = 1'b0    // initialize don't care values to zero
) (
    // --- Clock & reset ---
    input logic clk_i,
    input logic async_rst_ni,
    input logic sync_rst_ni,

    // --- Inputs ---
    input logic                 pipe_in_valid_i,
    input CTRL_T                pipe_in_ctrl_i,
    input logic  [OP_W - 1 : 0] pipe_in_op1_i,
    input logic  [OP_W - 1 : 0] pipe_in_op2_i,
    input logic                 pipe_out_ready_i,
    input logic                 pipe_out_xreg_ready_i,

    // --- Outputs ---
    output logic                    pipe_in_ready_o,
    output logic                    pipe_out_valid_o,
    output CTRL_T                   pipe_out_ctrl_o,
`ifdef RISCV_ZVE32F
    output logic                    pipe_out_freg,
`endif
    output logic                    pipe_out_xreg_valid_o,
    output logic  [XIF_ID_W- 1 : 0] pipe_out_xreg_id_o,
    output logic  [   XLEN - 1 : 0] pipe_out_xreg_data_o,
    output logic  [          4 : 0] pipe_out_xreg_addr_o
);

  import vproc_pkg::*;

  // --- Structs ---

  typedef struct packed {
    logic [$clog2(VLEN):0] counter;
    logic [$clog2(VLEN):0] vl;
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

  always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_xresult_stage_res_valid
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

  assign state_res_ready    = ~state_res_valid_q | pipe_out_ready_i;
  assign pipe_out_xreg_id_o = state_res_q.id;
  assign pipe_in_ready_o    = '1;
  assign state_res_valid_d  = pipe_in_valid_i;
  assign state_res_d        = pipe_in_ctrl_i;

  logic [31:0] elem1, elem2;
  assign elem1 = pipe_in_op1_i;
  assign elem2 = pipe_in_op2_i;

  // --- Helper Signals ---
  logic first_cycle_i, vl_0_i, masked_i;
  logic [$clog2(VLEN):0] vl_i;
  assign first_cycle_i = pipe_in_ctrl_i.first_cycle;
  assign vl_0_i = pipe_in_ctrl_i.vl_0;
  assign vl_i = pipe_in_ctrl_i.vl;
  assign masked_i = pipe_in_ctrl_i.decode_metadata.masked;

  // XREG write-back
  assign pipe_out_xreg_addr_o = first_cycle_i ? pipe_in_ctrl_i.res_vaddr : state_res_q.res_vaddr;
`ifdef RISCV_ZVE32F
  assign pipe_out_freg = pipe_out_xreg_valid_o & state_res_q.mode.elem.freg;
`endif

  assign pipe_out_valid_o = pipe_out_xreg_valid_o & pipe_out_xreg_ready_i;
  assign pipe_out_ctrl_o  = state_res_q;

  logic valid_first_cycle, valid_last_cycle;
  assign valid_first_cycle = first_cycle_i & pipe_in_valid_i;
  assign valid_last_cycle  = pipe_in_ctrl_i.last_cycle & pipe_in_valid_i;

  logic [$clog2(VLEN)-1:0] counter_inc;
  assign elem_ctrl_d.counter = (first_cycle_i ? '0 : elem_ctrl_q.counter) + counter_inc;
  assign elem_ctrl_d.vl = first_cycle_i ? (vl_0_i ? '0 : vl_i + 1) : elem_ctrl_q.vl;
  logic [$clog2(VLEN):0] vl;

  always_comb begin
      unique case(pipe_in_ctrl_i.eew) //vl given in bytes, need to scale to elements
        VSEW_8: vl = first_cycle_i ? (vl_0_i ? '0 : vl_i + 1) : elem_ctrl_q.vl;
        VSEW_16: vl = first_cycle_i ? (vl_0_i ? '0 : (vl_i + 1) >> 1) : elem_ctrl_q.vl >> 1;
        VSEW_32: vl = first_cycle_i ? (vl_0_i ? '0 : (vl_i + 1) >> 2) : elem_ctrl_q.vl >> 2;
        default : vl = '0;
      endcase
  end

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

  // Instantiate pop counter (pulp) for vcpop.m
  logic [OP_W - 1 : 0] popc_input;
  // Result width is ceil(log2(INPUT_WIDTH)) + 1
  logic [$clog2(OP_W) : 0] popc_result;
  popcount #(
      .INPUT_WIDTH(OP_W)
  ) popc (
      .data_i(popc_input),
      .popcount_o(popc_result)
  );

  logic [$clog2(VLEN):0] counter;
  logic valid_last_cycle_detected;

  assign counter = first_cycle_i ? '0 : elem_ctrl_q.counter;
  assign last_cycle_d = valid_first_cycle ? 1'b0 : last_cycle_q;
  assign valid_last_cycle_detected = last_cycle_q | valid_last_cycle;
  assign pipe_out_xreg_data_o = xresult_q;

  // --- Debug signals ---
  logic res_vmv;
  logic counter_bit_ge_vl;
  assign counter_bit_ge_vl = (counter >= vl) ? '1 : '0;

  logic [$clog2(VLEN):0] vl_diff;
  logic [OP_W - 1:0] vl_mask;

  // --- State machine logic ---
  always_comb begin
    // Zero or don't care signals
    counter_inc = DONT_CARE_ZERO ? '0 : 'x;
    lzc_input = DONT_CARE_ZERO ? '0 : 'x;

    // Default zero signals
    pipe_out_xreg_valid_o = 1'b0;
    res_vmv = 1'b0;

    // Default register assignments
    xresult_d = xresult_q;
    unique case (elem_state_q)

      ACCEPTING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VFIRST: begin
            counter_inc = OP_W;
            if (counter < vl && pipe_in_valid_i) begin
              lzc_input = masked_i ? (elem1 & elem2) : elem1;
            end else begin
              lzc_input = '0;
            end

            if (!lzc_empty && ((counter + lzc_result) < vl)) begin
              xresult_d = lzc_result;
            end else begin
              xresult_d = '1;
            end
          end

          ELEM_VPOPC: begin
            counter_inc = OP_W;
            // Need to mask off partial input if VL does not align with OP_W
            vl_diff = vl - counter;
            // If we are in the last round (less than OP_W bits left) regarding VL
            // shift '1 according to the difference in counter and VL to produce a partial mask
            vl_mask = (vl_diff >= OP_W ? '1 : ({OP_W{1'b1}} >> (OP_W - vl_diff)));
            if (counter < vl && pipe_in_valid_i) begin
              popc_input = (masked_i ? (elem1 & elem2) : elem1) & vl_mask;
            end else begin
              popc_input = '0;
            end

            if (pipe_in_valid_i) begin
              xresult_d = (first_cycle_i ? '0 : xresult_q) + popc_result;
            end
          end

          ELEM_XMV: begin
            if (valid_first_cycle) begin
              res_vmv = 1'b1;
              unique case (pipe_in_ctrl_i.eew)
                VSEW_8:  xresult_d = {{(XLEN - 8) {elem1[7]}}, elem1[7 : 0]};
                VSEW_16: xresult_d = {{(XLEN - 16) {elem1[15]}}, elem1[15 : 0]};
                VSEW_32: xresult_d = elem1[31 : 0];
                default: ;
              endcase
            end
          end

          default: ;
        endcase
      end

      WAIT_XREG_READY: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VFIRST, ELEM_VPOPC, ELEM_XMV: begin
            pipe_out_xreg_valid_o = 1'b1;
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
            if ((!lzc_empty || counter >= vl) && pipe_in_valid_i) begin
              elem_state_d = WAIT_XREG_READY;
            end
          end

          ELEM_VPOPC: begin
            if (counter >= vl && pipe_in_valid_i) begin
              elem_state_d = WAIT_XREG_READY;
            end
          end

          ELEM_XMV: begin
            if (pipe_in_valid_i) begin
              elem_state_d = WAIT_XREG_READY;
            end
          end

          default: elem_state_d = ACCEPTING;
        endcase
      end

      WAIT_XREG_READY: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VFIRST, ELEM_VPOPC, ELEM_XMV: begin
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

          ELEM_VFIRST, ELEM_VPOPC, ELEM_XMV: begin
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
