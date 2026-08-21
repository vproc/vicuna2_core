// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module vproc_index #(
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
    input logic pipe_in_valid_i,
    input logic pipe_out_ready_i,
    input CTRL_T pipe_in_ctrl_i,
    // input logic  [31 : 0] pipe_in_op1_i,
    // input logic  [31 : 0] pipe_in_op2_i,
    input logic [(OP_W/8) - 1 : 0] pipe_in_mask_i,

    // --- Outputs ---
    output logic pipe_in_ready_o,
    output logic pipe_out_valid_o,
    output CTRL_T pipe_out_ctrl_o,
    output logic [OP_W - 1 : 0] pipe_out_res_o,
    output logic [(OP_W/8) - 1 : 0] pipe_out_mask_o
);

  import vproc_pkg::*;

  // --- Structs & enums ---

  typedef enum logic [1:0] {
    ACCEPTING = 2'b00,
    RESULT_AVAILABLE = 2'b01
  } index_state_t;

  // --- Sync ---

  always_ff @(posedge clk_i or negedge async_rst_ni) begin
    if (~async_rst_ni) begin
      counter_q <= '0;
      result_q <= '0;
      ctrl_q <= '0;
      mask_q <= '0;
      index_state_q <= ACCEPTING;

    end else if (~sync_rst_ni) begin
      counter_q <= '0;
      result_q <= '0;
      ctrl_q <= '0;
      mask_q <= '0;
      index_state_q <= ACCEPTING;

      // end else if (state_res_ready) begin
    end else begin
      counter_q <= counter_d;
      result_q <= result_d;
      ctrl_q <= ctrl_d;
      mask_q <= mask_d;
      index_state_q <= index_state_d;

    end
  end

  // --- Signals & assignments

  CTRL_T ctrl_d, ctrl_q;
  index_state_t index_state_d, index_state_q;
  assign ctrl_d = pipe_in_ctrl_i;
  assign pipe_in_ready_o = pipe_out_ready_i;
  assign pipe_out_ctrl_o = ctrl_q;

  // Some shorthands for input signals
  logic first_cycle_i, last_cycle_i;
  assign first_cycle_i = pipe_in_ctrl_i.first_cycle;
  assign last_cycle_i  = pipe_in_ctrl_i.last_cycle;

  logic [$clog2(VLEN):0] counter_d, counter_q;
  logic [$clog2(VLEN)-1:0] counter_inc;
  logic [OP_W - 1:0] result_d, result_q;
  logic [(OP_W/8) - 1 : 0] mask_d, mask_q;
  assign pipe_out_res_o  = result_q;
  assign pipe_out_mask_o = mask_q;

  // --- Configuration dependent constants ---

  always_comb begin
    counter_inc = '0;
    unique case (pipe_in_ctrl_i.mode.elem.op)
      // TODO: Old elem struct
      ELEM_VID: begin
        unique case (pipe_in_ctrl_i.eew)
          VSEW_8: begin
            counter_inc = OP_W >> 3;
          end
          VSEW_16: begin
            counter_inc = OP_W >> 4;
          end
          VSEW_32: begin
            counter_inc = OP_W >> 5;
          end
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  // --- vid.v MUX ---

  logic [OP_W - 1:0] vid_mux_result;
  generate
    for (genvar i = 0; i < (OP_W / 32); i++) gen_vid_mux: begin
      always_comb begin
        unique case (pipe_in_ctrl_i.eew)
          VSEW_8: begin
            vid_mux_result[i*32+8-1 : i*32] = counter_q + 4 * i;
            vid_mux_result[i*32+16-1 : i*32+8] = counter_q + 4 * i + 1;
            vid_mux_result[i*32+24-1 : i*32+16] = counter_q + 4 * i + 2;
            vid_mux_result[(i+1)*32-1 : i*32+24] = counter_q + 4 * i + 3;
          end
          VSEW_16: begin
            vid_mux_result[i*32+16-1 : i*32] = counter_q + 2 * i;
            vid_mux_result[(i+1)*32-1 : i*32+16] = counter_q + 2 * i + 1;
          end
          VSEW_32: begin
            vid_mux_result[(i+1)*32-1 : i*32] = counter_q + i;
          end
          default: ;
        endcase
      end
    end
  endgenerate


  // --- State machine logic ---

  always_comb begin

    counter_d = '0;
    result_d = result_q;
    mask_d = mask_q;

    unique case (index_state_q)

      ACCEPTING, RESULT_AVAILABLE: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VID: begin
            if (pipe_in_valid_i) begin
              counter_d = counter_q + counter_inc;
              result_d = vid_mux_result;
              mask_d = pipe_in_mask_i;
            end else begin
              counter_d = last_cycle_i ? '0 : counter_q;
            end
          end

          default: ;
        endcase
      end

      default: ;
    endcase
  end

  // --- State machine transitions & output signalling ---

  always_comb begin

    index_state_d = index_state_q;
    pipe_out_valid_o = '0;

    unique case (index_state_q)

      ACCEPTING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VID: begin
            if (pipe_in_valid_i) begin
              index_state_d = RESULT_AVAILABLE;
            end
          end

          default: index_state_d = ACCEPTING;
        endcase
      end

      RESULT_AVAILABLE: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VID: begin
            pipe_out_valid_o = '1;
            if (pipe_in_valid_i) begin
              index_state_d = RESULT_AVAILABLE;
            end else begin
              index_state_d = ACCEPTING;
            end
          end

          default: index_state_d = ACCEPTING;
        endcase
      end

      default: index_state_d = ACCEPTING;
    endcase
  end

endmodule
