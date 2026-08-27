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
    input logic pipe_in_mask_valid_i,
    input logic pipe_out_ready_i,
    input CTRL_T pipe_in_ctrl_i,
    input logic [OP_W - 1 : 0] pipe_in_op1_i,
    input logic [OP_W - 1 : 0] pipe_in_op2_i,
    input logic [(OP_W/8) - 1 : 0] pipe_in_mask_i,

    // --- Outputs ---
    output logic pipe_in_ready_o,
    output logic pipe_out_valid_o,
    output logic pipe_in_mask_ready_o,
    output CTRL_T pipe_out_ctrl_o,
    output logic [OP_W - 1 : 0] pipe_out_res_o,
    output logic [(OP_W/8) - 1 : 0] pipe_out_mask_o
);

  import vproc_pkg::*;

  // --- Structs & enums ---

  typedef enum logic [1:0] {
    ACCEPTING = 2'b00,
    RESULT_AVAILABLE = 2'b01,
    FLUSH_OPS = 2'b10
  } index_state_t;

  // --- Sync ---

  always_ff @(posedge clk_i or negedge async_rst_ni) begin
    if (~async_rst_ni) begin
      counter_q <= '0;
      result_q <= '0;
      ctrl_q <= '0;
      mask_q <= '0;
      index_state_q <= ACCEPTING;
      viota_sum_q <= '0;

    end else if (~sync_rst_ni) begin
      counter_q <= '0;
      result_q <= '0;
      ctrl_q <= '0;
      mask_q <= '0;
      index_state_q <= ACCEPTING;
      viota_sum_q <= '0;

    end else begin
      counter_q <= counter_d;
      result_q <= result_d;
      ctrl_q <= ctrl_d;
      mask_q <= mask_d;
      index_state_q <= index_state_d;
      viota_sum_q <= viota_sum_d;

    end
  end

  // --- Signals & assignments

  CTRL_T ctrl_d, ctrl_q;
  index_state_t index_state_d, index_state_q;
  assign ctrl_d = pipe_in_ctrl_i;
  assign pipe_out_ctrl_o = ctrl_q;

  // Some shorthands for input signals
  logic first_cycle_i, last_cycle_i, masked_i;
  assign first_cycle_i = pipe_in_ctrl_i.first_cycle;
  assign last_cycle_i = pipe_in_ctrl_i.last_cycle;
  assign masked_i = pipe_in_ctrl_i.decode_metadata.masked;

  logic [$clog2(VLEN):0] counter_d, counter_q;
  logic [$clog2(VLEN)-1:0] counter_inc;
  logic [OP_W - 1:0] result_d, result_q;
  logic [(OP_W/8) - 1 : 0] mask_d, mask_q;
  assign pipe_out_res_o  = result_q;
  assign pipe_out_mask_o = mask_q;

  logic all_valid_i;
  assign all_valid_i = pipe_in_valid_i & pipe_in_mask_valid_i;

  // --- Configuration dependent constants ---

  always_comb begin
    counter_inc = '0;
    unique case (pipe_in_ctrl_i.mode.elem.op)
      // TODO: Old elem struct
      ELEM_VID, ELEM_VIOTA: begin
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
        unique case (pipe_in_ctrl_i.eew)
          VSEW_8:  top_bit = viota_mask[(OP_W/8)-1];
          VSEW_16: top_bit = viota_mask[(OP_W/16)-1];
          VSEW_32: top_bit = viota_mask[(OP_W/32)-1];
          default: top_bit = 1'b0;
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

  // --- viota.m MUX ---

  logic [$clog2(VLEN):0] vl;
  logic [  OP_W - 1 : 0] viota_mask;
  logic [OP_W - 1 : 0] shifted_op1, shifted_op2;
  logic [OP_W - 1:0] viota_mux_result;
  logic [$clog2(VLEN):0] viota_sum_d, viota_sum_q;
  logic top_bit;

  assign vl = pipe_in_ctrl_i.vl_0 ? '0 : pipe_in_ctrl_i.vl + 1;
  // As we need only the bottom 1, 2, or 4 bits, depending on SEW,
  // shift out bits we already used. Since the counter keeps track of all bits
  // processed and thus goes over the max. number of bits per set of operands,
  // mask off the upper bits of the counter
  assign shifted_op1 = pipe_in_op1_i >> (counter_q & {$clog2(OP_W) {1'b1}});
  assign shifted_op2 = pipe_in_op2_i >> (counter_q & {$clog2(OP_W) {1'b1}});
  assign viota_mask = masked_i ? shifted_op1 & shifted_op2 : shifted_op1;

  generate
    for (genvar i = 0; i < (OP_W / 32); i++) gen_viota_mux: begin
      always_comb begin
        unique case (pipe_in_ctrl_i.eew)
          // i == 0: previous sum (0 at the beginning) is fed into first byte/hword/word,
          // Subsequent elements are connected to previous elements + the relevant mask bit
          /* verilator lint_off ALWCOMBORDER */
          VSEW_8: begin
            viota_mux_result[i*32+8-1 : i*32]       = i > 0 ? viota_mux_result[i*32-1 : (i-1)*32+24]  + viota_mask[4*i + 3] : viota_sum_q;
            viota_mux_result[i*32+16-1 : i*32+8]    =         viota_mux_result[i*32+8-1 : i*32]       + viota_mask[4*i];
            viota_mux_result[i*32+24-1 : i*32+16]   =         viota_mux_result[i*32+16-1 : i*32+8]    + viota_mask[4*i + 1];
            viota_mux_result[(i+1)*32-1 : i*32+24]  =         viota_mux_result[i*32+24-1 : i*32+16]   + viota_mask[4*i + 2];
          end
          VSEW_16: begin
            viota_mux_result[i*32+16-1 : i*32]      = i > 0 ? viota_mux_result[i*32-1 : (i-1)*32+16]  + viota_mask[2*i + 1] : viota_sum_q;
            viota_mux_result[(i+1)*32-1 : i*32+16]  =         viota_mux_result[i*32+16-1 : i*32]      + viota_mask[2*i];
          end
          VSEW_32: begin
            viota_mux_result[(i+1)*32-1 : i*32]     = i > 0 ? viota_mux_result[i*32-1 :(i-1)*32]      + viota_mask[i] : viota_sum_q;
          end
          /* verilator lint_on ALWCOMBORDER */
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
    pipe_in_ready_o = pipe_out_ready_i;
    pipe_in_mask_ready_o = pipe_out_ready_i;

    unique case (index_state_q)

      ACCEPTING, RESULT_AVAILABLE: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VID: begin
            if (all_valid_i) begin
              counter_d = counter_q + counter_inc;
              result_d = vid_mux_result;
              mask_d = pipe_in_mask_i;
            end else begin
              counter_d = last_cycle_i ? '0 : counter_q;
            end
          end

          ELEM_VIOTA: begin
            // TODO: maybe needs to be ANDed with pipe_out_ready_i
            // (most instances of all_valid_i)
            if (all_valid_i) begin
              if (last_cycle_i) begin
                viota_sum_d = '0;
                counter_d   = '0;
              end else begin
                unique case (pipe_in_ctrl_i.eew)
                  VSEW_8:  viota_sum_d = viota_mux_result[OP_W-1:OP_W-8] + top_bit;
                  VSEW_16: viota_sum_d = viota_mux_result[OP_W-1:OP_W-16] + top_bit;
                  VSEW_32: viota_sum_d = viota_mux_result[OP_W-1:OP_W-32] + top_bit;
                  default: ;
                endcase
                if (counter_q + counter_inc == OP_W) begin
                  // In the last round, signal that we are ready for new values
                  counter_d = '0;
                  pipe_in_ready_o = 1'b1;
                end else begin
                  counter_d = counter_q + counter_inc;
                  pipe_in_ready_o = 1'b0;
                end
              end
              result_d = viota_mux_result;
              mask_d   = pipe_in_mask_i;
            end
          end

          default: ;
        endcase
      end

      FLUSH_OPS: begin
        pipe_in_ready_o = 1'b1;
        pipe_in_mask_ready_o = 1'b1;
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
            if (all_valid_i) begin
              index_state_d = RESULT_AVAILABLE;
            end
          end

          ELEM_VIOTA: begin
            if (all_valid_i) begin
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
            if (all_valid_i) begin
              index_state_d = RESULT_AVAILABLE;
            end else begin
              index_state_d = ACCEPTING;
            end
          end

          ELEM_VIOTA: begin
            pipe_out_valid_o = '1;
            if (all_valid_i) begin
              index_state_d = RESULT_AVAILABLE;
            end else begin
              index_state_d = ACCEPTING;
            end
          end

          default: index_state_d = ACCEPTING;
        endcase
      end

      FLUSH_OPS: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VIOTA: begin
            if (pipe_in_mask_valid_i || pipe_in_valid_i) begin
              index_state_d = FLUSH_OPS;
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
