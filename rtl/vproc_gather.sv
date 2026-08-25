// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module vproc_gather #(
    parameter int unsigned VLEN           = 128,    // Width in bits of vector registers
    parameter int unsigned OP_W           = 32,     // Operand width.  This unit is currently locked to elemwise ops, so maximum 32
    parameter type         METADATA_T     = logic,
    parameter int unsigned XIF_ID_W       = 4,
    parameter bit          DONT_CARE_ZERO = 1'b0    // initialize don't care values to zero
) (
    // --- Clock & reset ---
    input logic                     clk_i,
    input logic                     async_rst_ni,
    input logic                     sync_rst_ni,

    // -- Input Handshake
    input logic                     pipe_in_valid_i,
    output logic                    pipe_in_ready_o,

    input logic                     pipe_in_mask_valid_i,
    output logic                    pipe_in_mask_ready_o,

    input METADATA_T                pipe_in_ctrl_i,
    
    input logic [OP_W - 1 : 0]      pipe_in_op_i,
    input logic [(OP_W/8) - 1 : 0]  pipe_in_mask_i,


    // --- Register Port ---
    output logic                    vreg_rd_req_o,
    input  logic                    vreg_rd_gnt_i,

    output [4:0]                    vreg_rd_addr_o,
    output [XIF_ID_W-1 : 0]         vreg_rd_id_o,

    input [VLEN-1:0]                vreg_rd_data_i,

    // --- Output Handshake ---

    output logic                    pipe_out_valid_o,
    input logic                     pipe_out_ready_i,

    output METADATA_T               pipe_out_ctrl_o,
    output logic [OP_W - 1 : 0]     pipe_out_res_o,
    output logic [(OP_W/8) - 1 : 0] pipe_out_mask_o
);

  import vproc_pkg::*;

  // --- Structs & enums ---

  typedef enum logic [1:0] {
    READY = 2'b00,
    INVALID_DATA = 2'b01,
    VALID_DATA = 2'b10
  } gather_state;

  typedef struct packed {
    logic [$clog2(VLEN/8)-1:0] byte_index;
    logic                      over_vlmax;
    logic                      complete;
  } gather_ctrl;

  // Registers
  gather_ctrl ctrl_d, ctrl_q;
  gather_state state_d, state_q;
  
  always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            ctrl_q <= '0;
            state_q <= READY;
        end else begin
            ctrl_q <= ctrl_d;
            state_q <= state_d;
        end
    end

  // Index/address calculation
  // Operand[0] contains the data
  // Operand[1] contains the indexes
  logic [$clog2(VLEN/8)-1:0] byte_index;
  logic [4:0]                vreg_addr;
  logic                      over_vlmax;

  logic[31:0]                index;
  always_comb begin
    if (!pipe_in_ctrl_i.mode.gather.scalar_rs1) begin
      unique case (pipe_in_ctrl_i.decode_metadata.operands[1].sew)
        VSEW_32: index = pipe_in_op_i[31:0];
        VSEW_16: index = {{(16){1'b0}}, pipe_in_op_i[15:0]};
        VSEW_8:  index = {{(24){1'b0}}, pipe_in_op_i[7:0]};
        default;
      endcase
    end else begin
      index = pipe_in_ctrl_i.decode_metadata.operands[1].r.xval; //If x/i, use full, non-truncated value
    end
  end

  always_comb begin
    over_vlmax = 0;
    byte_index = '0;
    vreg_addr  = '0;
    if (index < pipe_in_ctrl_i.vlmax) begin
      unique case (pipe_in_ctrl_i.decode_metadata.operands[0].sew)
        VSEW_32: begin
          byte_index = (index & {{(32 - ($clog2(VLEN/32))){1'b0}}, {($clog2(VLEN/32)){1'b1}}}) << 2;
          vreg_addr = (index >> $clog2(VLEN/32)) + pipe_in_ctrl_i.decode_metadata.operands[0].r.vaddr;
        end
        VSEW_16: begin
          byte_index = (index & {{(32 - ($clog2(VLEN/16))){1'b0}}, {($clog2(VLEN/16)){1'b1}}}) << 1;
          vreg_addr = (index >> $clog2(VLEN/16)) + pipe_in_ctrl_i.decode_metadata.operands[0].r.vaddr;
        end
        VSEW_8:  begin
          byte_index = (index & {{(32 - ($clog2(VLEN/8))){1'b0}}, {($clog2(VLEN/8)){1'b1}}});
          vreg_addr = (index >> $clog2(VLEN/8)) + pipe_in_ctrl_i.decode_metadata.operands[0].r.vaddr;
        end
        default:;
      endcase
    end else begin
      over_vlmax = 1'b1;
    end
    
  end

  // State machine logic
  always_comb begin
    state_d = state_q;
    ctrl_d = ctrl_q;
    unique case (state_q)
        READY: begin
          if (pipe_in_valid_i & pipe_in_ctrl_i.first_cycle) begin
             ctrl_d.complete = pipe_in_ctrl_i.last_cycle; //in case vlmax == 1 (VLEN 128, MF4, SEW32)
             ctrl_d.over_vlmax = over_vlmax;
             ctrl_d.byte_index = byte_index;
             if (vreg_rd_gnt_i | over_vlmax) begin
                state_d = VALID_DATA;
             end else begin
                state_d = INVALID_DATA;
             end
          end
        end
        INVALID_DATA: begin
          if (vreg_rd_gnt_i) begin
                state_d = VALID_DATA;
          end
        end
        VALID_DATA: begin
          if (pipe_out_ready_i) begin
            ctrl_d.over_vlmax = over_vlmax;
            ctrl_d.byte_index = byte_index;
            ctrl_d.complete = pipe_in_ctrl_i.last_cycle;
          end

          if (ctrl_q.complete) begin
            state_d = READY;
          end else if ((vreg_rd_gnt_i | over_vlmax) & pipe_out_ready_i) begin
            state_d = VALID_DATA;
          end else if (pipe_out_ready_i) begin
            state_d = INVALID_DATA;
          end
        end
    endcase
  end

  // Register access logic
  // Interface signals (req, addr, gnt) are sent to unpack for multiplexing and data hazard checking
  logic [VLEN-1:0] register_data_q;

  always_ff @(posedge clk_i) begin
      if (~sync_rst_ni) begin
          register_data_q <= '0;
      end else begin
          register_data_q <= vreg_rd_data_i;
      end
  end
  //TODO: This generates a vector register load for EVERY VALID INDEX (idx < VLMAX).  TODO: add check for idx in currently loaded register
  //TODO: Can also skip any data that is masked out
  assign vreg_rd_req_o = ((state_q == READY) & pipe_in_ctrl_i.first_cycle & !over_vlmax & pipe_in_valid_i & pipe_in_mask_valid_i) | (state_q == INVALID_DATA) | ((state_q == VALID_DATA) & pipe_out_ready_i & !over_vlmax);
  assign vreg_rd_id_o = pipe_in_ctrl_i.id;
  assign vreg_rd_addr_o = vreg_addr;

  //Input handshake, same condition for normal arg and mask
  assign pipe_in_ready_o      = pipe_in_valid_i & pipe_in_mask_valid_i & ((state_q == READY) | (state_q == VALID_DATA & pipe_out_ready_i));
  assign pipe_in_mask_ready_o = pipe_in_valid_i & pipe_in_mask_valid_i & ((state_q == READY) | (state_q == VALID_DATA & pipe_out_ready_i));

  //Mask and Metadata Handling
  logic [OP_W/8-1:0] mask_d, mask_q;
  METADATA_T         metadata_d, metadata_q;

  always_ff @(posedge clk_i) begin
  if (~sync_rst_ni) begin
          mask_q <= '0;
          metadata_q <= '0;
      end else begin
        if (pipe_in_ready_o | (pipe_out_ctrl_o.last_cycle & pipe_out_valid_o)) begin //only advance these buffers on accepted input data (both ready signals are synchronized)
          mask_q <= mask_d;
          metadata_q <= metadata_d;
        end
      end
  end

  assign metadata_d = pipe_in_ctrl_i;
  assign mask_d = pipe_in_mask_i;
  
  //Output
  assign pipe_out_mask_o = mask_q;
  assign pipe_out_valid_o = (state_q == VALID_DATA & pipe_out_ready_i);
  assign pipe_out_ctrl_o = metadata_q;

  always_comb begin
    if (ctrl_q.over_vlmax) begin
      pipe_out_res_o = '0; //If over vlmax, set output to 0;
    end else begin
      unique case (metadata_q.decode_metadata.operands[0].sew)
        VSEW_32: pipe_out_res_o = register_data_q[ctrl_q.byte_index*8 +: 32];
        VSEW_16: pipe_out_res_o = {{(16){1'b0}}, register_data_q[ctrl_q.byte_index*8 +: 16]};
        VSEW_8:  pipe_out_res_o = {{(24){1'b0}}, register_data_q[ctrl_q.byte_index*8 +: 8]};
        default:;
      endcase
    end
  end 

endmodule
