// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module vproc_elem #(
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

    // --- Handshake Unpack ---
    input logic [2:0] pipe_in_valid_i,
    output logic [2:0] pipe_in_ready_o,
    input logic pipe_in_mask_valid_i,
    output logic pipe_in_mask_ready_o,

    // --- Handshake Pack ---
    input  logic pipe_out_ready_i,
    output logic pipe_out_valid_o,

    // --- Inputs ---
    input CTRL_T pipe_in_ctrl_i,
    input logic [OP_W - 1 : 0] pipe_in_op1_i,
    input logic [OP_W - 1 : 0] pipe_in_op2_i,
    input logic [OP_W - 1 : 0] pipe_in_op3_i,
    input logic [(OP_W/8) - 1 : 0] pipe_in_mask_i,

    // --- Outputs ---
    output CTRL_T pipe_out_ctrl_o,
    output logic [OP_W - 1 : 0] pipe_out_res_o,
    output logic [(OP_W/8) - 1 : 0] pipe_out_mask_o,
    output logic pipe_out_first_cycle_o
);

  import vproc_pkg::*;

  // --- Structs & enums ---

  typedef enum logic [2:0] {
    ACCEPTING = 3'b000,
    RESULT_AVAILABLE = 3'b001,
    SKIP = 3'b010,
    WRITE_REMAINING = 3'b011,
    FLUSH_OPS = 3'b100
  } elem_state_t;

  // --- Sync ---

  always_ff @(posedge clk_i or negedge async_rst_ni) begin
    if (~async_rst_ni) begin
      counter_q <= '0;
      result_q <= '0;
      ctrl_q <= '0;
      mask_q <= '0;
      last_cycle_q <= '0;
      first_result_q <= '0;
      elem_state_q <= ACCEPTING;

    end else if (~sync_rst_ni) begin
      counter_q <= '0;
      result_q <= '0;
      ctrl_q <= '0;
      mask_q <= '0;
      last_cycle_q <= '0;
      first_result_q <= '0;
      elem_state_q <= ACCEPTING;

    end else begin
      counter_q <= counter_d;
      result_q <= result_d;
      ctrl_q <= ctrl_d;
      mask_q <= mask_d;
      last_cycle_q <= last_cycle_d;
      first_result_q <= first_result_d;
      elem_state_q <= elem_state_d;

    end
  end

  // --- Signals & assignments

  CTRL_T ctrl_d, ctrl_q;
  elem_state_t elem_state_d, elem_state_q;
  assign ctrl_d = pipe_in_ctrl_i;
  assign pipe_out_ctrl_o = ctrl_q;

  // We have to wait to signal first cycle until we actually have a result
  logic first_result_d, first_result_q;

  // Some shorthands for input signals
  logic first_cycle_i, last_cycle_d, last_cycle_q;
  assign first_cycle_i = pipe_in_ctrl_i.first_cycle;
  assign last_cycle_d  = pipe_in_ctrl_i.last_cycle;

  logic [$clog2(VLEN):0] counter_d, counter_q;
  // logic [$clog2(VLEN)-1:0] counter_inc;
  logic [OP_W - 1:0] result_d, result_q;
  logic [(OP_W/8) - 1 : 0] mask_d, mask_q;
  assign mask_d = pipe_in_mask_i;
  assign pipe_out_res_o = result_q;
  assign pipe_out_mask_o = mask_q;

  logic [OP_W - 1 : 0] vs2_elem, vd_elem;
  logic vs2_valid, vd_valid, vs1_valid, vs2_ready, vs1_ready, vd_ready;
  logic all_valid;
  assign vs2_elem = pipe_in_op1_i;
  assign vd_elem = pipe_in_op3_i;
  assign vs2_valid = pipe_in_valid_i[0] & pipe_in_mask_valid_i;
  assign vs1_valid = pipe_in_valid_i[1];
  assign vd_valid = pipe_in_valid_i[2] & pipe_in_mask_valid_i;
  assign pipe_in_ready_o[0] = vs2_ready;
  assign pipe_in_ready_o[1] = vs1_ready;
  assign pipe_in_ready_o[2] = vd_ready;
  assign all_valid = pipe_in_mask_valid_i & vs1_valid & vs2_valid & vd_valid;

  // vs1
  logic [OP_W - 1 : 0] shifted_op2;
  assign shifted_op2 = pipe_in_op2_i >> (counter_q & {$clog2(OP_W) {1'b1}});
  logic vs1_bit;
  assign vs1_bit = shifted_op2[0];

  logic [$clog2(VLEN):0] vl;
  assign vl = (pipe_in_ctrl_i.vl_0 ? '0 : pipe_in_ctrl_i.vl + 1) >> pipe_in_ctrl_i.eew;

  // --- State machine logic ---

  always_comb begin

    counter_d = '0;
    result_d = result_q;
    vs2_ready = 1'b0;
    vs1_ready = 1'b0;
    vd_ready = 1'b0;
    pipe_in_mask_ready_o = 1'b0;

    unique case (elem_state_q)

      ACCEPTING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin
            result_d = vs2_elem;
            if (pipe_out_ready_i && all_valid) begin
              counter_d = counter_q + 1;

              if ((counter_q & {$clog2(OP_W) {1'b1}}) + 1 == OP_W) begin
                // In the last round, signal that we are ready for new values
                vs1_ready = 1'b1;
                // counter_d = '0;
              end
              // else begin
              //   counter_d = counter_q + 1;
              // end

              vs2_ready = 1'b1;
              if (vs1_bit && counter_q < vl) begin
                pipe_in_mask_ready_o = 1'b1;
                vd_ready = 1'b1;
              end

            end
          end

          default: ;
        endcase
      end

      RESULT_AVAILABLE, SKIP: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin
            if (pipe_out_ready_i && all_valid) begin
              result_d  = vs2_elem;
              counter_d = counter_q + 1;

              if ((counter_q & {$clog2(OP_W) {1'b1}}) + 1 == OP_W) begin
                // In the last round, signal that we are ready for new values
                vs1_ready = 1'b1;
                // counter_d = '0;
              end
              // else begin
              //   counter_d = counter_q + 1;
              // end

              vs2_ready = 1'b1;
              if (vs1_bit && counter_q < vl) begin
                pipe_in_mask_ready_o = 1'b1;
                vd_ready = 1'b1;
              end

            end else if (vd_valid) begin
              vd_ready = 1'b1;
              result_d = vd_elem;
              pipe_in_mask_ready_o = 1'b1;
              counter_d = '0;
            end
          end

          default: ;
        endcase
      end

      WRITE_REMAINING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin
            result_d = vd_elem;
            if (pipe_out_ready_i && vd_valid) begin
              vd_ready = 1'b1;
              pipe_in_mask_ready_o = 1'b1;
            end
          end

          default: ;
        endcase
      end

      FLUSH_OPS: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin
            if (vs1_valid) begin
              vs1_ready = 1'b1;
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

    elem_state_d = elem_state_q;
    first_result_d = first_result_q;
    pipe_out_valid_o = 1'b0;
    pipe_out_first_cycle_o = 1'b0;

    unique case (elem_state_q)

      ACCEPTING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin
            if (pipe_out_ready_i && all_valid) begin
              if (vs1_bit && counter_q < vl) begin
                elem_state_d = RESULT_AVAILABLE;
              end else begin
                elem_state_d = SKIP;
              end
            end
          end

          default: elem_state_d = ACCEPTING;
        endcase
      end

      RESULT_AVAILABLE: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin

            pipe_out_valid_o = 1'b1;
            first_result_d = 1'b1;
            pipe_out_first_cycle_o = first_result_q ? 1'b0 : 1'b1;

            if (last_cycle_q) begin
              elem_state_d = FLUSH_OPS;
            end else if (pipe_out_ready_i && all_valid) begin
              elem_state_d = (vs1_bit && counter_q < vl) ? RESULT_AVAILABLE : SKIP;
              // TODO: due to data hazards, vs2 could be invalid even if we are not done
              // this can be properly done by using a done signal from individual unpack shift registers
            end else if (!vs2_valid) begin
              elem_state_d = WRITE_REMAINING;
            end

          end

          default: elem_state_d = ACCEPTING;
        endcase
      end

      SKIP: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin

            if (last_cycle_q) begin
              elem_state_d = FLUSH_OPS;
            end else if (pipe_out_ready_i && all_valid) begin
              if (vs1_bit && counter_q < vl) begin
                elem_state_d = RESULT_AVAILABLE;
              end
              // TODO: due to data hazards, vs2 could be invalid even if we are not done
              // this can be properly done by using a done signal from individual unpack shift registers
            end else if (!vs2_valid) begin
              elem_state_d = WRITE_REMAINING;
            end

          end

          default: elem_state_d = ACCEPTING;
        endcase
      end

      WRITE_REMAINING: begin
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin

            pipe_out_valid_o = 1'b1;
            first_result_d = 1'b1;
            pipe_out_first_cycle_o = first_result_q ? 1'b0 : 1'b1;

            if (last_cycle_q) begin
              elem_state_d = FLUSH_OPS;
            end
          end

          default: elem_state_d = ACCEPTING;
        endcase
      end

      FLUSH_OPS: begin
        first_result_d = 1'b0;
        unique case (pipe_in_ctrl_i.mode.elem.op)

          ELEM_VCOMPRESS: begin
            if (!vs1_valid) begin
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
