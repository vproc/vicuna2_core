// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_unit_wrapper
  import vproc_pkg::*;
#(
    parameter op_unit                         UNIT             = UNIT_ALU,
    parameter int unsigned                    XIF_ID_W         = 4,
    parameter int unsigned                    XIF_ID_CNT       = 8,
    parameter int unsigned                    VREG_W           = 128,
    parameter int unsigned                    OP_CNT           = 2,
    parameter int unsigned                    MAX_OP_W         = 32,
    parameter int unsigned                    MEM_W            = 0,
    parameter int unsigned                    RES_CNT          = 2,
    parameter int unsigned                    MAX_RES_W        = 32,
    parameter int unsigned                    VLSU_QUEUE_SZ    = 4,
    parameter bit          [VLSU_FLAGS_W-1:0] VLSU_FLAGS       = '0,
    parameter mul_type                        MUL_TYPE         = MUL_GENERIC,
    parameter type                            CTRL_T           = logic,
    parameter type                            COUNTER_T        = logic,
    parameter int unsigned                    COUNTER_W        = 0,
    parameter int unsigned                    MEM_PORTS        = 1,
    parameter int unsigned                    PORT_QUEUE_DEPTH = 2,
    parameter bit                             DONT_CARE_ZERO   = 1'b0
) (
    input logic clk_i,
    input logic async_rst_ni,
    input logic sync_rst_ni,

    input  logic  [OP_CNT -1:0]                pipe_in_valid_i,
    output logic  [OP_CNT -1:0]                pipe_in_ready_o,
    input  CTRL_T                              pipe_in_ctrl_i,
    input  logic  [OP_CNT -1:0][MAX_OP_W -1:0] pipe_in_op_data_i,

    input  logic                   pipe_in_mask_valid_i,
    output logic                   pipe_in_mask_ready_o,
    input  logic [MAX_OP_W/8 -1:0] pipe_in_mask_data_i,

    output logic                                   pipe_out_valid_o,
    input  logic                                   pipe_out_ready_i,
    output logic      [XIF_ID_W              -1:0] pipe_out_instr_id_o,
    output cfg_vsew                                pipe_out_eew_o,
    output logic      [                       4:0] pipe_out_vaddr_o,
    output logic                                   pipe_out_res_store_o,
    output logic                                   pipe_out_res_valid_o,
    output pack_flags                              pipe_out_res_flags_o,
    output logic      [             MAX_RES_W-1:0] pipe_out_res_data_o,
    output logic      [             MAX_RES_W-1:0] pipe_out_res_mask_o,
    output logic                                   pipe_out_pend_clear_o,
    output logic      [                       1:0] pipe_out_pend_clear_cnt_o,
    output logic                                   pipe_out_instr_done_o,
    output logic                                   pending_load_o,
    output logic                                   pending_store_o,

    input logic [31:0] vreg_pend_rd_i,

    input instr_state [XIF_ID_CNT         -1:0] instr_state_i,

    OBI_BUS.Manager obi_bus[MEM_PORTS-1:0],

    output logic                              trans_complete_valid_o,
    input  logic                              trans_complete_ready_i,
    output logic [XIF_ID_W              -1:0] trans_complete_id_o,
    output logic                              trans_complete_exc_o,
    output logic [                       5:0] trans_complete_exccode_o,

`ifdef RISCV_ZVE32F
    output logic                              freg_res,
`endif
    output logic                              xreg_valid_o,
    input  logic                              xreg_ready_i,
    output logic [XIF_ID_W              -1:0] xreg_id_o,
    output logic [                       4:0] xreg_addr_o,
    output logic [                      31:0] xreg_data_o,

    output logic                              vreg_rd_req_o,
    input  logic                              vreg_rd_gnt_i,
    output [4:0]                              vreg_rd_addr_o,
    output [XIF_ID_W-1 : 0]                   vreg_rd_id_o,
    input  [VREG_W-1:0]                       vreg_rd_data_i
);

  generate
    if (UNIT == UNIT_LSU) gen_lsu_wrapper: begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      logic  [ MEM_PORTS-1:0] unit_out_valid;
      logic                   indexed_op_clear_ready;

      //For LSU, only signal ready when all necessary operands are valid
      logic  [    OP_CNT-1:0] necessary_ops;
      for (genvar i = 0; i < OP_CNT; i++) begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
      end

      logic unit_in_valid_i;
      assign unit_in_valid_i = &(~(pipe_in_valid_i ^ necessary_ops)) & (|pipe_in_valid_i | pipe_in_mask_valid_i) & ! indexed_op_clear_ready; //Input valid only if all necessary ops are valid (including mask) and not clearing an index operand

      logic unit_ready_in_o;
      for (genvar i = 0; i < 2; i++) begin
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i; //Unit ready only if all necessary ops are valid
      end
      assign pipe_in_ready_o[2] = unit_ready_in_o & unit_in_valid_i | indexed_op_clear_ready;
      assign pipe_in_mask_ready_o = unit_ready_in_o & unit_in_valid_i; //Mask ready synchronized with other arguments

      vproc_lsu #(
          .MAX_OP_W        (MAX_OP_W),
          .VMEM_W          (MEM_W),
          .VLEN            (VREG_W),
          .MEM_PORTS       (MEM_PORTS),
          .CTRL_T          (CTRL_T),
          .XIF_ID_W        (XIF_ID_W),
          .XIF_ID_CNT      (XIF_ID_CNT),
          .VLSU_QUEUE_SZ   (VLSU_QUEUE_SZ),
          .VLSU_FLAGS      (VLSU_FLAGS),
          .PORT_QUEUE_DEPTH(PORT_QUEUE_DEPTH),
          .DONT_CARE_ZERO  (DONT_CARE_ZERO)
      ) lsu (
          .clk_i                   (clk_i),
          .async_rst_ni            (async_rst_ni),
          .sync_rst_ni             (sync_rst_ni),
          .pipe_in_valid_i         (unit_in_valid_i),
          .pipe_in_ready_o         (unit_ready_in_o),
          .pipe_in_ctrl_i          (pipe_in_ctrl_i),
          .pipe_in_op1_i           (pipe_in_op_data_i[0]),
          .pipe_in_op2_i           (pipe_in_op_data_i[1]),
          .pipe_in_op3_i           (pipe_in_op_data_i[2]),
          .pipe_in_mask_i          (pipe_in_mask_data_i),
          .pipe_in_op3_valid_i     (pipe_in_valid_i[2]),
          .pipe_in_op3_ready_o     (indexed_op_clear_ready),
          .pipe_out_valid_o        (unit_out_valid),
          .pipe_out_ready_i        (pipe_out_ready_i),
          .pipe_out_ctrl_o         (unit_out_ctrl),
          .pipe_out_pend_clr_o     (pipe_out_pend_clear_o),
          .pipe_out_res_o          (unit_out_res),
          .pipe_out_mask_o         (unit_out_mask),
          .pending_load_o          (pending_load_o),
          .pending_store_o         (pending_store_o),
          .vreg_pend_rd_i          (vreg_pend_rd_i),
          .instr_state_i           (instr_state_i),
          .trans_complete_valid_o  (trans_complete_valid_o),
          .trans_complete_ready_i  (trans_complete_ready_i),
          .trans_complete_id_o     (trans_complete_id_o),
          .trans_complete_exc_o    (trans_complete_exc_o),
          .trans_complete_exccode_o(trans_complete_exccode_o),
          .obi_bus                 (obi_bus)
      );
      always_comb begin
        pipe_out_instr_id_o  = unit_out_ctrl.id;
        pipe_out_eew_o       = unit_out_ctrl.decode_metadata.operands[1].sew;
        pipe_out_vaddr_o     = unit_out_ctrl.res_vaddr;
        pipe_out_res_flags_o = '{default: pack_flags'('0)};
        pipe_out_res_mask_o  = '0;
        pipe_out_valid_o     = |unit_out_valid;
        if (unit_out_ctrl.mode.lsu.stride == LSU_STRIDED | unit_out_ctrl.mode.lsu.stride == LSU_INDEXED) begin
          pipe_out_res_flags_o.shift_rate = RES_ELEMWISE_WIDTH;
        end else begin
          pipe_out_res_flags_o.shift_rate = RES_FULL_WIDTH;
        end
        // for(int j = 0; j < MEM_PORTS; j++) begin //TODO: This loop is no longer valid
        //     if(unit_out_valid[j]) begin
        pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_valid_o                = unit_out_valid[0];
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o.shift          = unit_out_ctrl.res_shift;
        pipe_out_res_flags_o.elemwise       = unit_out_ctrl.mode.lsu.stride != LSU_UNITSTRIDE;
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
        pipe_out_res_flags_o.lsu_instr      = 1;
        pipe_out_res_flags_o.store          = unit_out_ctrl.mode.lsu.store;
        pipe_out_res_flags_o.field_instr    = unit_out_ctrl.field_init_count > 0;
        pipe_out_res_flags_o.first_cycle    = unit_out_ctrl.first_cycle;
        pipe_out_res_flags_o.last_cycle     = unit_out_ctrl.last_cycle;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        //     end
        // end
      end
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;

    end else if (UNIT == UNIT_ALU) gen_alu_wrapper: begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res_alu;
      logic  [MAX_OP_W/8-1:0] unit_out_res_cmp;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      logic                   unit_in_op3_ready;
      logic                   unit_in_op3_valid;

      //For ALU, only signal ready when all necessary operands are valid
      logic  [           1:0] necessary_ops;  //only including Op1 + Op2 here
      for (genvar i = 0; i < 2; i++) begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
      end

      logic unit_in_valid_i;
      assign unit_in_valid_i = ~(pipe_in_valid_i[0] ^ necessary_ops[0]) & ~(pipe_in_valid_i[1] ^ necessary_ops[1]) & (|pipe_in_valid_i | pipe_in_mask_valid_i); //Input valid only if all necessary ops are valid (including mask)

      logic unit_ready_in_o;
      for (genvar i = 0; i < 2; i++) begin
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i; //Unit ready only if all necessary ops are valid
      end
      assign pipe_in_ready_o[2]   = unit_in_op3_ready;                //Op3 ready signal handled separately, as this might need to be signalled to clear data in unpack
      assign unit_in_op3_valid = pipe_in_valid_i[2];
      vproc_alu #(
          .VLEN          (VREG_W),
          .ALU_OP_W      (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) alu (
          .clk_i               (clk_i),
          .async_rst_ni        (async_rst_ni),
          .sync_rst_ni         (sync_rst_ni),
          .pipe_in_valid_i     (unit_in_valid_i),
          .pipe_in_ready_o     (unit_ready_in_o),
          .pipe_in_ctrl_i      (pipe_in_ctrl_i),
          .pipe_in_op1_i       (pipe_in_op_data_i[1]),
          .pipe_in_op2_i       (pipe_in_op_data_i[0]),
          .pipe_in_op3_valid_i (unit_in_op3_valid),
          .pipe_in_op3_ready_o (unit_in_op3_ready),
          .pipe_in_op3_i       (pipe_in_op_data_i[2]),
          .pipe_in_mask_valid_i(pipe_in_mask_valid_i),
          .pipe_in_mask_ready_o(pipe_in_mask_ready_o),
          .pipe_in_mask_i      (pipe_in_mask_data_i),
          .pipe_out_valid_o    (pipe_out_valid_o),
          .pipe_out_ready_i    (pipe_out_ready_i),
          .pipe_out_ctrl_o     (unit_out_ctrl),
          .pipe_out_res_alu_o  (unit_out_res_alu),
          .pipe_out_res_cmp_o  (unit_out_res_cmp),
          .pipe_out_mask_o     (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o = unit_out_ctrl.id;
        pipe_out_eew_o = unit_out_ctrl.eew;
        pipe_out_vaddr_o = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o = '0;
        pipe_out_res_valid_o = '0;
        pipe_out_res_flags_o = '{default: pack_flags'('0)};
        pipe_out_res_data_o = '0;
        pipe_out_res_mask_o = '0;

        pipe_out_res_store_o                 = unit_out_ctrl.res_store & ~unit_out_ctrl.mode.alu.cmp; //TODO: Not using this signal
        pipe_out_res_flags_o.shift = unit_out_ctrl.res_shift;
        pipe_out_res_flags_o.narrow = unit_out_ctrl.res_narrow[0];
        pipe_out_res_flags_o.narrow_frac = unit_out_ctrl.res_narrow_frac;
        pipe_out_res_flags_o.saturate = unit_out_ctrl.mode.alu.sat_res;
        pipe_out_res_flags_o.sig = unit_out_ctrl.mode.alu.sigext;
        pipe_out_res_valid_o = pipe_out_valid_o;
        pipe_out_res_data_o = unit_out_res_alu;
        pipe_out_res_flags_o.first_cycle = unit_out_ctrl.first_cycle;
        pipe_out_res_flags_o.last_cycle = unit_out_ctrl.last_cycle;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o.vreg_idx = unit_out_ctrl.vreg_idx;

        if (unit_out_ctrl.res_narrow[0]) begin
          pipe_out_res_flags_o.shift_rate = RES_NARROW_WIDTH;
          unique case ({unit_out_ctrl.decode_metadata.dest_emul, unit_out_ctrl.decode_metadata.dest_frac})
                {EMUL_1, FULL_REG}: pipe_out_res_flags_o.dest_frac = MF2;
                {EMUL_1, MF2}: pipe_out_res_flags_o.dest_frac = MF4;
                {EMUL_1, MF4}: pipe_out_res_flags_o.dest_frac = MF8;
                default: pipe_out_res_flags_o.dest_frac = FULL_REG;
          endcase
        end else if (unit_out_ctrl.mode.alu.cmp) begin
          //put bitwise results in the format expected by pack  TODO: Ideally, just do this inside ALU when generating output
          pipe_out_res_data_o = '0;
          pipe_out_res_flags_o.mask_res = 1'b1;
          unique case (unit_out_ctrl.eew)
            VSEW_32: begin
              for (integer i = 0; i < MAX_OP_W / 32; i++) begin
                pipe_out_res_data_o[i*32] = unit_out_res_cmp[i*4];
              end
            end
            VSEW_16: begin
              for (integer i = 0; i < MAX_OP_W / 16; i++) begin
                pipe_out_res_data_o[i*16] = unit_out_res_cmp[i*2];
              end
            end
            VSEW_8: begin
              for (integer i = 0; i < MAX_OP_W / 8; i++) begin
                pipe_out_res_data_o[i*8] = unit_out_res_cmp[i];
              end
            end
          endcase
        end else begin
          pipe_out_res_flags_o.shift_rate = RES_FULL_WIDTH;
        end

      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.mode.alu.cmp ? unit_out_ctrl.last_cycle : unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o = unit_out_ctrl.last_cycle;
    end else if (UNIT == UNIT_MUL) gen_mul_wrapper: begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;

      //For MUL, only signal ready when all necessary operands are valid
      logic  [    OP_CNT-1:0] necessary_ops;
      for (genvar i = 0; i < OP_CNT; i++) begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
      end

      logic unit_in_valid_i;
      assign unit_in_valid_i = &(~(pipe_in_valid_i ^ necessary_ops)) & (|pipe_in_valid_i | pipe_in_mask_valid_i); //Input valid only if all necessary ops are valid (including mask)

      logic unit_ready_in_o;
      for (genvar i = 0; i < OP_CNT; i++) begin
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i; //Unit ready only if all necessary ops are valid
      end
      assign pipe_in_mask_ready_o = unit_ready_in_o & unit_in_valid_i; //Mask ready synchronized with other arguments


      vproc_mul #(
          .MUL_OP_W      (MAX_OP_W),
          .MUL_TYPE      (MUL_TYPE),
          .CTRL_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) mul (
          .clk_i           (clk_i),
          .async_rst_ni    (async_rst_ni),
          .sync_rst_ni     (sync_rst_ni),
          .pipe_in_valid_i (unit_in_valid_i),
          .pipe_in_ready_o (unit_ready_in_o),
          .pipe_in_ctrl_i  (pipe_in_ctrl_i),
          .pipe_in_op1_i   (pipe_in_op_data_i[1]),
          .pipe_in_op2_i   (pipe_in_op_data_i[0]),
          .pipe_in_op3_i   (pipe_in_op_data_i[2]),
          .pipe_in_mask_i  (pipe_in_mask_data_i),
          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        pipe_out_eew_o                      = unit_out_ctrl.eew;
        pipe_out_vaddr_o                    = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                = '0;
        pipe_out_res_valid_o                = '0;
        pipe_out_res_flags_o                = '{default: pack_flags'('0)};
        pipe_out_res_data_o                 = '0;
        pipe_out_res_mask_o                 = '0;
        pipe_out_res_flags_o.shift          = 1'b1;
        pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o                = pipe_out_valid_o;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o.first_cycle    = unit_out_ctrl.first_cycle;
        pipe_out_res_flags_o.last_cycle     = unit_out_ctrl.last_cycle;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;
    end else if (UNIT == UNIT_SLD) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      vproc_sld #(
          .OP_W          (MAX_OP_W),
          .VLEN          (VREG_W),
          .METADATA_T    (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) sld (
          .clk_i               (clk_i),
          .async_rst_ni        (async_rst_ni),
          .sync_rst_ni         (sync_rst_ni),
          .pipe_in_valid_i     (pipe_in_valid_i),
          .pipe_in_ready_o     (pipe_in_ready_o),
          .pipe_in_ctrl_i      (pipe_in_ctrl_i),
          .pipe_in_op_i        (pipe_in_op_data_i[0]),
          .pipe_in_mask_ready_o(pipe_in_mask_ready_o),
          .pipe_in_mask_valid_i(pipe_in_mask_valid_i),
          .pipe_in_mask_i      (pipe_in_mask_data_i),
          .pipe_out_valid_o    (pipe_out_valid_o),
          .pipe_out_ready_i    (pipe_out_ready_i),
          .pipe_out_ctrl_o     (unit_out_ctrl),
          .pipe_out_res_o      (unit_out_res),
          .pipe_out_mask_o     (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        pipe_out_eew_o                      = unit_out_ctrl.eew;
        pipe_out_vaddr_o                    = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                = '0;
        pipe_out_res_valid_o                = '0;
        pipe_out_res_flags_o                = '{default: pack_flags'('0)};
        pipe_out_res_data_o                 = '0;
        pipe_out_res_mask_o                 = '0;
        pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o                = pipe_out_valid_o;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
        pipe_out_res_flags_o.first_cycle    = unit_out_ctrl.first_cycle;
        pipe_out_res_flags_o.last_cycle     = unit_out_ctrl.last_cycle;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;
    end else if (UNIT == UNIT_XRESULT) gen_elem_wrapper: begin
      CTRL_T                  unit_out_ctrl;
      // TODO: res and mask not connected to ELEM, but also not needed
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      // For ELEM, only signal ready when all necessary operands are valid
      logic  [    OP_CNT-1:0] necessary_ops;
      for (genvar i = 0; i < OP_CNT; i++) gen_nec_ops: begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
      end

      logic unit_in_valid_i;
      // Input valid only if all necessary ops are valid (including mask)
      assign unit_in_valid_i = &(~(pipe_in_valid_i ^ necessary_ops)) & (|pipe_in_valid_i | pipe_in_mask_valid_i);

      logic unit_ready_in_o;
      for (genvar i = 0; i < OP_CNT; i++) gen_in_ready: begin
        // Unit ready only if all necessary ops are valid
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i;
      end
      // Mask is just ready when the rest is ready
      assign pipe_in_mask_ready_o = unit_ready_in_o & unit_in_valid_i;
      vproc_xresult #(
          .VLEN          (VREG_W),
          .XLEN          (32),
          .OP_W          (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .XIF_ID_W      (XIF_ID_W),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) elem (
          .clk_i                (clk_i),
          .async_rst_ni         (async_rst_ni),
          .sync_rst_ni          (sync_rst_ni),
          .pipe_in_valid_i      (unit_in_valid_i),
          .pipe_in_ctrl_i       (pipe_in_ctrl_i),
          .pipe_in_op1_i        (pipe_in_op_data_i[0]),
          .pipe_in_op2_i        (pipe_in_op_data_i[1]),
          .pipe_out_ready_i     (pipe_out_ready_i),
          .pipe_out_xreg_ready_i(xreg_ready_i),
          .pipe_in_ready_o      (unit_ready_in_o),
          .pipe_out_valid_o     (pipe_out_valid_o),
          .pipe_out_ctrl_o      (unit_out_ctrl),
          .pipe_out_xreg_valid_o(xreg_valid_o),
          .pipe_out_xreg_id_o   (xreg_id_o),
          .pipe_out_xreg_data_o (xreg_data_o),
          .pipe_out_xreg_addr_o (xreg_addr_o)
      );

      always_comb begin
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        pipe_out_eew_o                      = unit_out_ctrl.eew;
        pipe_out_vaddr_o                    = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                = '0;
        pipe_out_res_valid_o                = '0;
        pipe_out_res_flags_o                = '{default: pack_flags'('0)};
        pipe_out_res_data_o                 = '0;
        pipe_out_res_mask_o                 = '0;
        pipe_out_res_flags_o.shift          = 1'b1;
        pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o                = pipe_out_valid_o;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o.first_cycle    = xreg_valid_o;
        pipe_out_res_flags_o.last_cycle     = xreg_valid_o;
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
        pipe_out_res_flags_o.store          = 1'b1;  //All instructions in this unit do not write back to register file
      end

      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;

    end else if (UNIT == UNIT_INDEX) gen_index_wrapper: begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      logic  [    OP_CNT-1:0] necessary_ops;
      for (genvar i = 0; i < OP_CNT; i++) gen_nec_ops: begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
      end

      logic unit_in_valid_i;
      // Input valid only if all necessary ops are valid
      assign unit_in_valid_i = &(~(pipe_in_valid_i ^ necessary_ops));

      logic unit_ready_in_o;
      for (genvar i = 0; i < OP_CNT; i++) gen_in_ready: begin
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i;
      end
      logic unit_mask_ready_o;
      // assign pipe_in_mask_ready_o = unit_ready_in_o & unit_in_valid_i;
      assign pipe_in_mask_ready_o = unit_mask_ready_o & pipe_in_mask_valid_i;
      vproc_index #(
          .VLEN          (VREG_W),
          .XLEN          (32),
          .OP_W          (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .XIF_ID_W      (XIF_ID_W),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) index (
          .clk_i               (clk_i),
          .async_rst_ni        (async_rst_ni),
          .sync_rst_ni         (sync_rst_ni),
          .pipe_in_valid_i     (unit_in_valid_i),
          .pipe_in_mask_valid_i(pipe_in_mask_valid_i),
          .pipe_out_ready_i    (pipe_out_ready_i),
          .pipe_in_ctrl_i      (pipe_in_ctrl_i),
          .pipe_in_op1_i       (pipe_in_op_data_i[0]),
          .pipe_in_op2_i       (pipe_in_op_data_i[1]),
          .pipe_in_mask_i      (pipe_in_mask_data_i),
          .pipe_in_ready_o     (unit_ready_in_o),
          .pipe_out_valid_o    (pipe_out_valid_o),
          .pipe_in_mask_ready_o(unit_mask_ready_o),
          .pipe_out_ctrl_o     (unit_out_ctrl),
          .pipe_out_res_o      (unit_out_res),
          .pipe_out_mask_o     (unit_out_mask)
      );

      always_comb begin
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        pipe_out_eew_o                      = unit_out_ctrl.eew;
        pipe_out_vaddr_o                    = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                = '0;
        // pipe_out_res_valid_o                = '0;
        pipe_out_res_flags_o                = '{default: pack_flags'('0)};
        // pipe_out_res_data_o                 = '0;
        // pipe_out_res_mask_o                 = '0;
        pipe_out_res_flags_o.shift          = 1'b1;
        // pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o                = pipe_out_valid_o;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o.first_cycle    = unit_out_ctrl.first_cycle;
        pipe_out_res_flags_o.last_cycle     = unit_out_ctrl.last_cycle;
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
      end

      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;

    end else if (UNIT == UNIT_DIV) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;

      logic  [    OP_CNT-1:0] necessary_ops;
      logic unit_in_valid_i, unit_ready_in_o;

      for (genvar i = 0; i < OP_CNT; i++) begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i;
      end

      assign unit_in_valid_i = &(~(pipe_in_valid_i ^ necessary_ops)) & (|pipe_in_valid_i | pipe_in_mask_valid_i); //Input valid only if all necessary ops are valid (including mask)
      assign pipe_in_mask_ready_o = unit_ready_in_o & unit_in_valid_i;

      vproc_div #(
          .DIV_OP_W(32),
          .CTRL_T  (CTRL_T)
      ) div (
          .clk_i           (clk_i),
          .async_rst_ni    (async_rst_ni),
          .sync_rst_ni     (sync_rst_ni),
          .pipe_in_valid_i (unit_in_valid_i),
          .pipe_in_ready_o (unit_ready_in_o),
          .pipe_in_ctrl_i  (pipe_in_ctrl_i),
          .pipe_in_op1_i   (pipe_in_op_data_i[1]),
          .pipe_in_op2_i   (pipe_in_op_data_i[0]),
          .pipe_in_mask_i  (pipe_in_mask_data_i),
          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );

      always_comb begin
          pipe_out_instr_id_o = unit_out_ctrl.id;
          pipe_out_eew_o      = unit_out_ctrl.eew;
          pipe_out_vaddr_o    = unit_out_ctrl.res_vaddr;
          pipe_out_res_store_o = '0;
          pipe_out_res_valid_o = '0;
          pipe_out_res_flags_o = '{default: pack_flags'('0)};
          pipe_out_res_data_o  = '0;
          pipe_out_res_mask_o  = '0;
          pipe_out_res_flags_o.shift           = unit_out_ctrl.res_shift;
          pipe_out_res_flags_o.shift_rate      = RES_ELEMWISE_WIDTH;
          pipe_out_res_flags_o.elemwise        = 1'b1;
          pipe_out_res_store_o                 = unit_out_ctrl.res_store;
          pipe_out_res_valid_o                 = pipe_out_valid_o;
          pipe_out_res_data_o                  = unit_out_res;
          pipe_out_res_mask_o[MAX_OP_W/8-1:0]  = unit_out_mask;
          pipe_out_res_flags_o.vreg_idx        = unit_out_ctrl.vreg_idx;
          pipe_out_res_flags_o.first_cycle     = unit_out_ctrl.first_cycle;
          pipe_out_res_flags_o.last_cycle      = unit_out_ctrl.last_cycle;
          pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
      end

      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;
    end else if (UNIT == UNIT_FPU) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      logic                   unit_out_valid;
      logic                   unit_out_ready;

      vproc_fpu #(
          .FPU_OP_W(MAX_OP_W),
          .CTRL_T  (CTRL_T)
          //TODO: PASS IN FP_NEW CONFIG HERE
      ) fpu (
          .clk_i           (clk_i),
          .async_rst_ni    (async_rst_ni),
          .sync_rst_ni     (sync_rst_ni),
          .pipe_in_valid_i (pipe_in_valid_i),
          .pipe_in_ready_o (pipe_in_ready_o),
          .pipe_in_ctrl_i  (pipe_in_ctrl_i),
          .pipe_in_op1_i   (pipe_in_op_data_i[1]),
          .pipe_in_op2_i   (pipe_in_op_data_i[0]),
          .pipe_in_op3_i   (pipe_in_op_data_i[2]),
          .pipe_in_mask_i  (pipe_in_op_data_i[OP_CNT-1][MAX_OP_W/8-1:0]),
          .pipe_out_valid_o(unit_out_valid),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );

      // Unit control for reduction operations.  Ignored for normal FPU operations
      // output buffer signals
      logic is_reduction_q, is_reduction_d;
      logic has_valid_result_q, has_valid_result_d;
      COUNTER_T vd_count_q, vd_count_d;
      logic flushing_q, flushing_d;
      logic [XIF_ID_W-1:0] flushing_id_q, flushing_id_d;
      vproc_pkg::cfg_vsew flushing_eew_q, flushing_eew_d;
      vproc_pkg::cfg_emul flushing_emul_q, flushing_emul_d;
      logic [4:0] flushing_vaddr_q, flushing_vaddr_d;
      always_ff @(posedge clk_i) begin
        if (pipe_out_ready_i) begin
          vd_count_q         <= vd_count_d;
          has_valid_result_q <= has_valid_result_d;
          flushing_id_q      <= flushing_id_d;
          flushing_eew_q     <= flushing_eew_d;
          flushing_emul_q    <= flushing_emul_d;
          flushing_vaddr_q   <= flushing_vaddr_d;
          is_reduction_q     <= is_reduction_d;
        end
      end
      always_ff @(posedge clk_i or negedge async_rst_ni) begin
        if (~async_rst_ni) begin
          flushing_q <= 1'b0;
        end else if (~sync_rst_ni) begin
          flushing_q <= 1'b0;
        end else if (pipe_out_ready_i) begin
          flushing_q <= flushing_d;
        end
      end
      // track whether there are any valid results
      always_comb begin
        has_valid_result_d = has_valid_result_q;
        if (unit_out_ctrl.first_cycle) begin
          has_valid_result_d = 1'b0;
        end
        if (unit_out_valid) begin
          has_valid_result_d = 1'b1;
        end
      end
      //track if current op is a reduction
      always_comb begin
        if (unit_out_ctrl.mode.fpu.op_reduction) begin
          is_reduction_d = 1'b1;
        end else if (pipe_out_instr_done_o) begin
          is_reduction_d = 1'b0;
        end else begin
          is_reduction_d = is_reduction_q;
        end
      end
      // determine when we see the first valid result
      logic first_valid_result;
      assign first_valid_result = ~flushing_q & unit_out_valid & (unit_out_ctrl.first_cycle | ~has_valid_result_q);
      always_comb begin
        vd_count_d.val = DONT_CARE_ZERO ? '0 : 'x;
        unique case (flushing_q ? flushing_eew_q : unit_out_ctrl.eew)
          VSEW_16:
          vd_count_d.val = vd_count_q.val + {{(COUNTER_W-2){1'b0}}, flushing_q | pipe_out_valid_o, 1'b0};
          VSEW_32:
          vd_count_d.val = vd_count_q.val + {{(COUNTER_W-3){1'b0}}, flushing_q | pipe_out_valid_o, 2'b0};
          default: vd_count_d.val = '1;
        endcase
        if (first_valid_result) begin
          vd_count_d.val      = '0;
          vd_count_d.val[1:0] = DONT_CARE_ZERO ? '0 : 'x;
          unique case (unit_out_ctrl.eew)
            VSEW_16: vd_count_d.val[1:0] = 2'b01;
            VSEW_32: vd_count_d.val[1:0] = 2'b11;
            default: ;
          endcase
        end
      end

      logic instr_speculative, instr_committed;
      always_comb begin
        instr_speculative = DONT_CARE_ZERO ? '0 : 'x;
        instr_committed   = DONT_CARE_ZERO ? '0 : 'x;
        unique case (instr_state_i[unit_out_ctrl.id])
          INSTR_SPECULATIVE:             instr_speculative = 1'b1;
          INSTR_COMMITTED, INSTR_KILLED: instr_speculative = 1'b0;
          default:                       ;
        endcase
        unique case (instr_state_i[unit_out_ctrl.id])
          INSTR_SPECULATIVE, INSTR_KILLED: instr_committed = 1'b0;
          INSTR_COMMITTED:                 instr_committed = 1'b1;
          default:                         ;
        endcase
      end

      // flush the downstream part of the pipeline after the last cycle if needed
      logic flushing_last_cycle;
      always_comb begin
        flushing_d          = flushing_q;
        flushing_id_d       = flushing_id_q;
        flushing_eew_d      = flushing_eew_q;
        flushing_emul_d     = flushing_emul_q;
        flushing_vaddr_d    = flushing_vaddr_q;
        flushing_last_cycle = 1'b0;
        if (~flushing_q & unit_out_valid & unit_out_ctrl.last_cycle & unit_out_ctrl.requires_flush) begin
          flushing_d       = 1'b1;
          flushing_id_d    = unit_out_ctrl.id;
          flushing_eew_d   = unit_out_ctrl.eew;
          flushing_emul_d  = unit_out_ctrl.emul;
          flushing_vaddr_d = unit_out_ctrl.res_vaddr;
        end
        if (flushing_q & (vd_count_d.part.low == '1)) begin
          flushing_d          = 1'b0;
          flushing_last_cycle = 1'b1;
        end
      end


      assign pipe_out_valid_o = (unit_out_valid) | flushing_q;
      assign unit_out_ready   = pipe_out_ready_i & ~flushing_q;
      //unit out stall signal missing.  Needed for ELEM operation?
      //assign pipe_out_valid_o = (unit_out_valid & ~unit_out_stall) | flushing_q;
      //assign unit_out_ready   = pipe_out_ready_i & ~flushing_q & ~unit_out_stall;

      logic [4:0] base_vaddr;
      assign base_vaddr = flushing_q ? flushing_vaddr_q : unit_out_ctrl.res_vaddr;
      logic res_flag_shift_vsew32;
      if (MAX_RES_W > 32) begin
        assign res_flag_shift_vsew32 = vd_count_d.val[$clog2(MAX_RES_W/8)-1:2] == '0;
      end else begin
        assign res_flag_shift_vsew32 = 1'b1;
      end
      always_comb begin

        if (is_reduction_q | unit_out_ctrl.mode.fpu.op_reduction) begin

          pipe_out_instr_id_o = flushing_q ? flushing_id_q : unit_out_ctrl.id;
          pipe_out_eew_o      = flushing_q ? flushing_eew_q : unit_out_ctrl.eew;
          pipe_out_vaddr_o    = DONT_CARE_ZERO ? '0 : 'x;
          unique case (flushing_q ? flushing_emul_q : unit_out_ctrl.emul)
            EMUL_1:  pipe_out_vaddr_o = base_vaddr;
            EMUL_2:  pipe_out_vaddr_o = base_vaddr | {4'b0, vd_count_d.part.mul[0:0]};
            EMUL_4:  pipe_out_vaddr_o = base_vaddr | {3'b0, vd_count_d.part.mul[1:0]};
            EMUL_8:  pipe_out_vaddr_o = base_vaddr | {2'b0, vd_count_d.part.mul[2:0]};
            default: ;
          endcase
          pipe_out_res_store_o = '0;
          pipe_out_res_valid_o = '0;
          pipe_out_res_flags_o = '{default: pack_flags'('0)};
          pipe_out_res_data_o = '0;
          pipe_out_res_mask_o = '0;
          pipe_out_res_flags_o[0].shift = DONT_CARE_ZERO ? '0 : 'x;
          unique case (flushing_q ? flushing_eew_q : unit_out_ctrl.eew)
            VSEW_8:  pipe_out_res_flags_o[0].shift = vd_count_d.val[$clog2(MAX_RES_W/8)-1:0] == '0;
            VSEW_16: pipe_out_res_flags_o[0].shift = vd_count_d.val[$clog2(MAX_RES_W/8)-1:1] == '0;
            VSEW_32: pipe_out_res_flags_o[0].shift = res_flag_shift_vsew32;
            default: ;
          endcase
          pipe_out_res_flags_o[0].elemwise = 1'b1;
          pipe_out_res_store_o[0] = ((unit_out_valid) | flushing_q) & (vd_count_d.part.low == '1);
          pipe_out_res_valid_o[0] = flushing_q | unit_out_valid;
          pipe_out_res_data_o[0] = unit_out_res;
          pipe_out_res_mask_o[0][3:0] = flushing_q ? '0 : unit_out_mask;

          pipe_out_instr_done_o     = (~flushing_q & unit_out_ctrl.last_cycle & ~unit_out_ctrl.requires_flush ) | flushing_last_cycle;
          pipe_out_pend_clear_o     = (~flushing_q & unit_out_ctrl.last_cycle & ~unit_out_ctrl.requires_flush ) | flushing_last_cycle;
          pipe_out_pend_clear_cnt_o = flushing_emul_q; // TODO reductions always have destination EMUL == 1
          pipe_out_res_flags_o[0].vreg_idx = unit_out_ctrl.vreg_idx;


        end else begin
          //Normal Connections for not reduction operations
          pipe_out_instr_id_o                    = unit_out_ctrl.id;
          pipe_out_eew_o                         = unit_out_ctrl.eew;
          pipe_out_vaddr_o                       = unit_out_ctrl.res_vaddr;
          pipe_out_res_store_o                   = '0;
          pipe_out_res_valid_o                   = '0;
          pipe_out_res_flags_o                   = '{default: pack_flags'('0)};
          pipe_out_res_data_o                    = '0;
          pipe_out_res_mask_o                    = '0;
          pipe_out_res_flags_o[0].shift          = 1'b1;
          pipe_out_res_store_o[0]                = unit_out_ctrl.res_store;
          pipe_out_res_valid_o[0]                = unit_out_valid;
          pipe_out_res_data_o[0]                 = unit_out_res;
          pipe_out_res_mask_o[0][MAX_OP_W/8-1:0] = unit_out_mask;
          pipe_out_pend_clear_o                  = unit_out_ctrl.res_store;
          pipe_out_pend_clear_cnt_o              = '0;
          pipe_out_instr_done_o                  = unit_out_ctrl.last_cycle;
          pipe_out_res_flags_o[0].elemwise       = 1'b0;
          pipe_out_res_flags_o[0].vreg_idx       = unit_out_ctrl.vreg_idx;


        end
      end
    end else if (UNIT == UNIT_ZVBB) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      vproc_zvbb #(
          .ZVBB_OP_W     (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) zvbb (
          .clk_i           (clk_i),
          .async_rst_ni    (async_rst_ni),
          .sync_rst_ni     (sync_rst_ni),
          .pipe_in_valid_i (pipe_in_valid_i),
          .pipe_in_ready_o (pipe_in_ready_o),
          .pipe_in_ctrl_i  (pipe_in_ctrl_i),
          .pipe_in_op1_i   (pipe_in_op_data_i[1]),
          .pipe_in_op2_i   (pipe_in_op_data_i[0]),
          .pipe_in_mask_i  (pipe_in_op_data_i[OP_CNT-1][MAX_OP_W/8-1:0]),
          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                    = unit_out_ctrl.id;
        pipe_out_eew_o                         = unit_out_ctrl.eew;
        pipe_out_vaddr_o                       = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                   = '0;
        pipe_out_res_valid_o                   = '0;
        pipe_out_res_flags_o                   = '{default: pack_flags'('0)};
        pipe_out_res_data_o                    = '0;
        pipe_out_res_mask_o                    = '0;
        pipe_out_res_flags_o[0].shift          = 1'b1;
        pipe_out_res_store_o[0]                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o[0]                = pipe_out_valid_o;
        pipe_out_res_data_o[0]                 = unit_out_res;
        pipe_out_res_mask_o[0][MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o[0].vreg_idx       = unit_out_ctrl.vreg_idx;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;
    end else if (UNIT == UNIT_ZVBC) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      vproc_zvbc #(
          .ZVBC_OP_W     (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) zvbc (
          .clk_i           (clk_i),
          .async_rst_ni    (async_rst_ni),
          .sync_rst_ni     (sync_rst_ni),
          .pipe_in_valid_i (pipe_in_valid_i),
          .pipe_in_ready_o (pipe_in_ready_o),
          .pipe_in_ctrl_i  (pipe_in_ctrl_i),
          .pipe_in_op1_i   (pipe_in_op_data_i[1]),
          .pipe_in_op2_i   (pipe_in_op_data_i[0]),
          .pipe_in_mask_i  (pipe_in_op_data_i[OP_CNT-1][MAX_OP_W/8-1:0]),
          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                    = unit_out_ctrl.id;
        pipe_out_eew_o                         = unit_out_ctrl.eew;
        pipe_out_vaddr_o                       = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                   = '0;
        pipe_out_res_valid_o                   = '0;
        pipe_out_res_flags_o                   = '{default: pack_flags'('0)};
        pipe_out_res_data_o                    = '0;
        pipe_out_res_mask_o                    = '0;
        pipe_out_res_flags_o[0].shift          = 1'b1;
        pipe_out_res_store_o[0]                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o[0]                = pipe_out_valid_o;
        pipe_out_res_data_o[0]                 = unit_out_res;
        pipe_out_res_mask_o[0][MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o[0].vreg_idx       = unit_out_ctrl.vreg_idx;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;
    end else if (UNIT == UNIT_REDSUM) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;

      //For REDSUM, only signal ready when all necessary operands are valid
      logic  [    OP_CNT-1:0] necessary_ops;
      for (genvar i = 0; i < OP_CNT; i++) begin
        assign necessary_ops[i] = pipe_in_ctrl_i.decode_metadata.operands[i].xreg || pipe_in_ctrl_i.decode_metadata.operands[i].vreg;
      end

      logic unit_in_valid_i;
      assign unit_in_valid_i = &(~(pipe_in_valid_i ^ necessary_ops)) & (|pipe_in_valid_i | pipe_in_mask_valid_i); //Input valid only if all necessary ops are valid (including mask)

      logic unit_ready_in_o;
      for (genvar i = 0; i < OP_CNT; i++) begin
        assign pipe_in_ready_o[i] = unit_ready_in_o & unit_in_valid_i; //Unit ready only if all necessary ops are valid
      end
      assign pipe_in_mask_ready_o = unit_ready_in_o & unit_in_valid_i; //Mask ready synchronized with other arguments

      vproc_vredsum #(
          .OP_W          (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) vproc_redsum (
          .clk_i       (clk_i),
          .async_rst_ni(async_rst_ni),
          .sync_rst_ni (sync_rst_ni),

          .pipe_in_valid_i(unit_in_valid_i),
          .pipe_in_ready_o(unit_ready_in_o),
          .pipe_in_ctrl_i (pipe_in_ctrl_i),
          .pipe_in_op1_i  (pipe_in_op_data_i[1]),
          .pipe_in_op2_i  (pipe_in_op_data_i[0]),
          .pipe_in_mask_i (pipe_in_mask_data_i),

          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        pipe_out_eew_o                      = unit_out_ctrl.eew;
        pipe_out_vaddr_o                    = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                = '0;
        pipe_out_res_valid_o                = '0;
        pipe_out_res_flags_o                = '{default: pack_flags'('0)};
        pipe_out_res_data_o                 = '0;
        pipe_out_res_mask_o                 = '0;
        pipe_out_res_flags_o.shift          = 1'b1;
        pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o                = pipe_out_valid_o;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask[MAX_OP_W/8-1:0];
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
        //Single cycle valid, so both first and last cycle are high
        pipe_out_res_flags_o.first_cycle    = pipe_out_valid_o;
        pipe_out_res_flags_o.last_cycle     = pipe_out_valid_o;
        pipe_out_res_flags_o.single_elem_res = pipe_out_valid_o;
        pipe_out_res_flags_o.dest_frac      = unit_out_ctrl.decode_metadata.dest_frac;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;

    end else if (UNIT == UNIT_GATHER) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;

      //For GATHER, only mask and op2 are required, synchronized inside of the functional unit

      vproc_gather #(
          .OP_W          (MAX_OP_W),
          .METADATA_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) vproc_gather (
          .clk_i       (clk_i),
          .async_rst_ni(async_rst_ni),
          .sync_rst_ni (sync_rst_ni),

          .pipe_in_valid_i(pipe_in_valid_i[1]),
          .pipe_in_ready_o(pipe_in_ready_o[1]),
          .pipe_in_ctrl_i (pipe_in_ctrl_i),
          .pipe_in_op_i  (pipe_in_op_data_i[1]),
          .pipe_in_mask_valid_i(pipe_in_mask_valid_i),
          .pipe_in_mask_ready_o(pipe_in_mask_ready_o),
          .pipe_in_mask_i (pipe_in_mask_data_i),

          .vreg_rd_req_o(vreg_rd_req_o),
          .vreg_rd_gnt_i(vreg_rd_gnt_i),
          .vreg_rd_addr_o(vreg_rd_addr_o),
          .vreg_rd_id_o(vreg_rd_id_o),
          .vreg_rd_data_i(vreg_rd_data_i),

          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                 = unit_out_ctrl.id;
        pipe_out_eew_o                      = unit_out_ctrl.eew;
        pipe_out_vaddr_o                    = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                = '0;
        pipe_out_res_valid_o                = '0;
        pipe_out_res_flags_o                = '{default: pack_flags'('0)};
        pipe_out_res_data_o                 = '0;
        pipe_out_res_mask_o                 = '0;
        pipe_out_res_flags_o.shift          = 1'b1;
        pipe_out_res_store_o                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o                = pipe_out_valid_o;
        pipe_out_res_data_o                 = unit_out_res;
        pipe_out_res_mask_o[MAX_OP_W/8-1:0] = unit_out_mask[MAX_OP_W/8-1:0];
        pipe_out_res_flags_o.vreg_idx       = unit_out_ctrl.vreg_idx;
        //Single cycle valid, so both first and last cycle are high
        pipe_out_res_flags_o.first_cycle    = unit_out_ctrl.first_cycle;
        pipe_out_res_flags_o.last_cycle     = unit_out_ctrl.last_cycle;
        pipe_out_res_flags_o.dest_frac       = unit_out_ctrl.decode_metadata.dest_frac;
        pipe_out_res_flags_o.shift_rate      = RES_ELEMWISE_WIDTH;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;

    end else if (UNIT == UNIT_CUSTOM) begin
      CTRL_T                  unit_out_ctrl;
      logic  [MAX_OP_W  -1:0] unit_out_res;
      logic  [MAX_OP_W/8-1:0] unit_out_mask;
      vproc_custom_vfu #(
          .OP_W          (MAX_OP_W),
          .CTRL_T        (CTRL_T),
          .DONT_CARE_ZERO(DONT_CARE_ZERO)
      ) vproc_custom_vfu (
          .clk_i           (clk_i),
          .async_rst_ni    (async_rst_ni),
          .sync_rst_ni     (sync_rst_ni),
          .pipe_in_valid_i (pipe_in_valid_i),
          .pipe_in_ready_o (pipe_in_ready_o),
          .pipe_in_ctrl_i  (pipe_in_ctrl_i),
          .pipe_in_op1_i   (pipe_in_op_data_i[1]),
          .pipe_in_op2_i   (pipe_in_op_data_i[0]),
          .pipe_in_op3_i   (pipe_in_op_data_i[2]),
          .pipe_in_mask_i  (pipe_in_op_data_i[OP_CNT-1][MAX_OP_W/8-1:0]),
          .pipe_out_valid_o(pipe_out_valid_o),
          .pipe_out_ready_i(pipe_out_ready_i),
          .pipe_out_ctrl_o (unit_out_ctrl),
          .pipe_out_res_o  (unit_out_res),
          .pipe_out_mask_o (unit_out_mask)
      );
      always_comb begin
        pipe_out_instr_id_o                    = unit_out_ctrl.id;
        pipe_out_eew_o                         = unit_out_ctrl.eew;
        pipe_out_vaddr_o                       = unit_out_ctrl.res_vaddr;
        pipe_out_res_store_o                   = '0;
        pipe_out_res_valid_o                   = '0;
        pipe_out_res_flags_o                   = '{default: pack_flags'('0)};
        pipe_out_res_data_o                    = '0;
        pipe_out_res_mask_o                    = '0;
        pipe_out_res_flags_o[0].shift          = 1'b1;
        pipe_out_res_store_o[0]                = unit_out_ctrl.res_store;
        pipe_out_res_valid_o[0]                = pipe_out_valid_o;
        pipe_out_res_data_o[0]                 = unit_out_res;
        pipe_out_res_mask_o[0][MAX_OP_W/8-1:0] = unit_out_mask;
        pipe_out_res_flags_o[0].vreg_idx       = unit_out_ctrl.vreg_idx;
      end
      assign pipe_out_pend_clear_o     = unit_out_ctrl.res_store;
      assign pipe_out_pend_clear_cnt_o = '0;
      assign pipe_out_instr_done_o     = unit_out_ctrl.last_cycle;
    end
    // TODO: Add new units here to pipeline
  endgenerate
endmodule
