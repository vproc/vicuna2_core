// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_unit_mux import vproc_pkg::*, obi_pkg::*; #(
        parameter bit [UNIT_CNT-1:0]                 UNITS           = '0,
        parameter int unsigned                       XIF_ID_W        = 3,
        parameter int unsigned                       XIF_ID_CNT      = 8,
        parameter int unsigned                       VREG_W          = 128,
        parameter int unsigned                       OP_CNT          = 2,
        parameter int unsigned                       MAX_OP_W        = 32,
        parameter int unsigned                       MEM_W           = 0,
        parameter int unsigned                       RES_CNT         = 2,
        parameter int unsigned                       MAX_RES_W       = 32,
        parameter int unsigned                       VLSU_QUEUE_SZ   = 4,
        parameter bit [VLSU_FLAGS_W-1:0]             VLSU_FLAGS      = '0,
        parameter mul_type                           MUL_TYPE        = MUL_GENERIC,
        parameter type                               CTRL_T          = logic,
        parameter type                               COUNTER_T       = logic,
        parameter int unsigned                       COUNTER_W       = 0,
        parameter int unsigned                       MEM_PORTS       = 1,
        parameter obi_cfg_t                          OBI_CFG         = ObiDefaultConfig,
        parameter int unsigned                       PORT_QUEUE_DEPTH         = 1,
        parameter bit                                DONT_CARE_ZERO  = 1'b0
    )
    (
        input  logic                                 clk_i,
        input  logic                                 async_rst_ni,
        input  logic                                 sync_rst_ni,

        input  logic                   [OP_CNT -1:0] pipe_in_valid_i,
        output logic                   [OP_CNT -1:0] pipe_in_ready_o,
        input  CTRL_T                                pipe_in_ctrl_i,
        input  logic    [OP_CNT -1:0][MAX_OP_W -1:0] pipe_in_op_data_i,

        input  logic                   [OP_CNT -1:0] pipe_in_mask_valid_i,
        output logic                   [OP_CNT -1:0] pipe_in_mask_ready_o,
        input  logic               [MAX_OP_W/8 -1:0] pipe_in_mask_data_i,

        output logic                                 pipe_out_valid_o,
        input  logic                                 pipe_out_ready_i,
        output logic    [XIF_ID_W              -1:0] pipe_out_instr_id_o,
        output cfg_vsew                              pipe_out_eew_o,
        output logic    [4:0]                        pipe_out_vaddr_o,
        output logic    [RES_CNT-1:0]                pipe_out_res_store_o,
        output logic    [RES_CNT-1:0]                pipe_out_res_valid_o,
        output pack_flags            [RES_CNT  -1:0] pipe_out_res_flags_o,
        output logic    [RES_CNT-1:0][MAX_RES_W-1:0] pipe_out_res_data_o,
        output logic    [RES_CNT-1:0][MAX_RES_W-1:0] pipe_out_res_mask_o,
        output logic                                 pipe_out_pend_clear_o,
        output logic    [1:0]                        pipe_out_pend_clear_cnt_o,
        output logic                                 pipe_out_instr_done_o,

        output logic                                 pending_load_o,
        output logic                                 pending_store_o,

        input  logic    [31:0]                       vreg_pend_rd_i,

        input  instr_state [XIF_ID_CNT         -1:0] instr_state_i,

        OBI_BUS.Manager                              obi_bus [MEM_PORTS-1:0],

        output logic                                 trans_complete_valid_o,
        input  logic                                 trans_complete_ready_i,
        output logic    [XIF_ID_W              -1:0] trans_complete_id_o,
        output logic                                 trans_complete_exc_o,
        output logic    [5:0]                        trans_complete_exccode_o,

        `ifdef RISCV_ZVE32F
        output logic                                 freg_res,
        `endif 
        output logic                                 xreg_valid_o,
        input  logic                                 xreg_ready_i,
        output logic    [XIF_ID_W              -1:0] xreg_id_o,
        output logic    [4:0]                        xreg_addr_o,
        output logic    [31:0]                       xreg_data_o
    );

    // Ready signal
    logic [UNIT_CNT-1:0][OP_CNT -1:0] unit_in_ready;
    always_comb begin
        pipe_in_ready_o = '0;
        for (int i = 0; i < UNIT_CNT; i++) begin
            if (UNITS[i] & |pipe_in_valid_i & (op_unit'(i) == pipe_in_ctrl_i.unit)) begin
                pipe_in_ready_o = unit_in_ready[i];
            end
        end
    end

    // Output Signals
    logic      [UNIT_CNT-1:0]                             unit_out_valid;
    logic      [UNIT_CNT-1:0]                             unit_out_ready;
    logic      [UNIT_CNT-1:0][XIF_ID_W              -1:0] unit_out_instr_id;
    cfg_vsew   [UNIT_CNT-1:0]                             unit_out_eew;
    logic      [UNIT_CNT-1:0][4:0]                        unit_out_vaddr;
    logic      [UNIT_CNT-1:0][RES_CNT-1:0]                unit_out_res_store;
    logic      [UNIT_CNT-1:0][RES_CNT-1:0]                unit_out_res_valid;
    pack_flags [UNIT_CNT-1:0][RES_CNT-1:0]                unit_out_res_flags;
    logic      [UNIT_CNT-1:0][RES_CNT-1:0][MAX_RES_W-1:0] unit_out_res_data;
    logic      [UNIT_CNT-1:0][RES_CNT-1:0][MAX_RES_W-1:0] unit_out_res_mask;
    logic      [UNIT_CNT-1:0]                             unit_out_pend_clear;
    logic      [UNIT_CNT-1:0][1:0]                        unit_out_pend_clear_cnt;
    logic      [UNIT_CNT-1:0]                             unit_out_instr_done;
    logic      [2:0]                                      unit_out_field_counter;

    generate
        for (genvar i = 0; i < UNIT_CNT; i++) begin
            if (UNITS[i]) begin
                // Input logic
                logic [OP_CNT -1:0] unit_valid;
                for (genvar j = 0; j < OP_CNT; j++) begin
                    assign unit_valid[j] = pipe_in_valid_i[j] & (pipe_in_ctrl_i.unit == op_unit'(i));
                end
                // LSU-related signals
                OBI_BUS #(
                    .OBI_CFG     ( OBI_CFG   )
                ) unit_obi_bus [MEM_PORTS-1:0] ();
                logic                pending_load;
                logic                pending_store;
                logic                trans_complete_valid;
                logic                trans_complete_ready;
                logic [XIF_ID_W-1:0] trans_complete_id;
                logic                trans_complete_exc;
                logic [5:0]          trans_complete_exccode;

                // ELEM-related signals (for XREG writeback)
                logic                xreg_valid;
                logic                xreg_ready;
                logic [XIF_ID_W-1:0] xreg_id;
                logic [4:0]          xreg_addr;
                logic [31:0]         xreg_data;

                vproc_unit_wrapper #(
                    .UNIT                      ( op_unit'(i)                ),
                    .XIF_ID_W                  ( XIF_ID_W                   ),
                    .XIF_ID_CNT                ( XIF_ID_CNT                 ),
                    .VREG_W                    ( VREG_W                     ),
                    .OP_CNT                    ( OP_CNT                     ),
                    .MAX_OP_W                  ( MAX_OP_W                   ),
                    .MEM_W                     ( MEM_W                      ),
                    .RES_CNT                   ( RES_CNT                    ),
                    .MAX_RES_W                 ( MAX_RES_W                  ),
                    .VLSU_QUEUE_SZ             ( VLSU_QUEUE_SZ              ),
                    .VLSU_FLAGS                ( VLSU_FLAGS                 ),
                    .MUL_TYPE                  ( MUL_TYPE                   ),
                    .CTRL_T                    ( CTRL_T                     ),
                    .COUNTER_T                 ( COUNTER_T                  ),
                    .COUNTER_W                 ( COUNTER_W                  ),
                    .MEM_PORTS                 ( MEM_PORTS                  ),
                    .PORT_QUEUE_DEPTH          ( PORT_QUEUE_DEPTH           ),
                    .DONT_CARE_ZERO            ( DONT_CARE_ZERO             )
                ) unit (
                    .clk_i                     ( clk_i                      ),
                    .async_rst_ni              ( async_rst_ni               ),
                    .sync_rst_ni               ( sync_rst_ni                ),
                    .pipe_in_valid_i           ( unit_valid                 ),
                    .pipe_in_ready_o           ( unit_in_ready          [i] ),
                    .pipe_in_ctrl_i            ( pipe_in_ctrl_i             ),
                    .pipe_in_op_data_i         ( pipe_in_op_data_i          ),
                    .pipe_in_mask_valid_i      ( pipe_in_mask_valid_i       ),
                    .pipe_in_mask_ready_o      ( pipe_in_mask_ready_o       ),
                    .pipe_in_mask_data_i       ( pipe_in_mask_data_i        ),
                    .pipe_out_valid_o          ( unit_out_valid         [i] ),
                    .pipe_out_ready_i          ( pipe_out_ready_i           ),
                    .pipe_out_instr_id_o       ( unit_out_instr_id      [i] ),
                    .pipe_out_eew_o            ( unit_out_eew           [i] ),
                    .pipe_out_vaddr_o          ( unit_out_vaddr         [i] ),
                    .pipe_out_res_store_o      ( unit_out_res_store     [i] ),
                    .pipe_out_res_valid_o      ( unit_out_res_valid     [i] ),
                    .pipe_out_res_flags_o      ( unit_out_res_flags     [i] ),
                    .pipe_out_res_data_o       ( unit_out_res_data      [i] ),
                    .pipe_out_res_mask_o       ( unit_out_res_mask      [i] ),
                    .pipe_out_pend_clear_o     ( unit_out_pend_clear    [i] ),
                    .pipe_out_pend_clear_cnt_o ( unit_out_pend_clear_cnt[i] ),
                    .pipe_out_instr_done_o     ( unit_out_instr_done    [i] ),
                    .pending_load_o            ( pending_load               ),
                    .pending_store_o           ( pending_store              ),
                    .vreg_pend_rd_i            ( vreg_pend_rd_i             ),
                    .instr_state_i             ( instr_state_i              ),
                    .obi_bus                   ( unit_obi_bus               ),
                    .trans_complete_valid_o    ( trans_complete_valid       ),
                    .trans_complete_ready_i    ( trans_complete_ready       ),
                    .trans_complete_id_o       ( trans_complete_id          ),
                    .trans_complete_exc_o      ( trans_complete_exc         ),
                    .trans_complete_exccode_o  ( trans_complete_exccode     ),
                    `ifdef RISCV_ZVE32F
                    .freg_res                  ( freg_res                   ),
                     `endif 
                    .xreg_valid_o              ( xreg_valid                 ),
                    .xreg_ready_i              ( xreg_ready                 ),
                    .xreg_id_o                 ( xreg_id                    ),
                    .xreg_addr_o               ( xreg_addr                  ),
                    .xreg_data_o               ( xreg_data                  )
                );

                if (op_unit'(i) == UNIT_LSU) begin
                    assign pending_load_o            = pending_load;
                    assign pending_store_o           = pending_store;

                    for (genvar j = 0; j < MEM_PORTS; j++) begin
                        assign obi_bus[j].req               = unit_obi_bus[j].req;
                        assign obi_bus[j].reqpar            = unit_obi_bus[j].reqpar;
                        assign unit_obi_bus[j].gnt          = obi_bus[j].gnt;
                        assign unit_obi_bus[j].gntpar       = obi_bus[j].gntpar;
                        assign obi_bus[j].addr              = unit_obi_bus[j].addr;
                        assign obi_bus[j].we                = unit_obi_bus[j].we;
                        assign obi_bus[j].be                = unit_obi_bus[j].be;
                        assign obi_bus[j].wdata             = unit_obi_bus[j].wdata;
                        assign obi_bus[j].aid               = unit_obi_bus[j].aid;
                        assign obi_bus[j].a_optional        = unit_obi_bus[j].a_optional;
                        assign unit_obi_bus[j].rvalid       = obi_bus[j].rvalid;
                        assign unit_obi_bus[j].rvalidpar    = obi_bus[j].rvalidpar;
                        assign obi_bus[j].rready            = unit_obi_bus[j].rready;
                        assign obi_bus[j].rreadypar         = unit_obi_bus[j].rreadypar;
                        assign unit_obi_bus[j].rdata        = obi_bus[j].rdata;
                        assign unit_obi_bus[j].rid          = obi_bus[j].rid;
                        assign unit_obi_bus[j].err          = obi_bus[j].err;
                        assign unit_obi_bus[j].r_optional   = obi_bus[j].r_optional;
                    end

                    assign trans_complete_valid_o    = trans_complete_valid;
                    assign trans_complete_ready      = trans_complete_ready_i;
                    assign trans_complete_id_o       = trans_complete_id;
                    assign trans_complete_exc_o      = trans_complete_exc;
                    assign trans_complete_exccode_o  = trans_complete_exccode;
                end
                if (op_unit'(i) == UNIT_ELEM) begin
                    assign xreg_valid_o = xreg_valid;
                    assign xreg_ready   = xreg_ready_i;
                    assign xreg_id_o    = xreg_id;
                    assign xreg_addr_o  = xreg_addr;
                    assign xreg_data_o  = xreg_data;
                end
            end
        end
    endgenerate

    op_unit unit_queue_deq_unit;
    logic [UNIT_CNT-1:0 ] unit_queue_deq_valid;
    for (genvar i = 0; i < UNIT_CNT; i++) begin
        if (UNITS[i]) begin
            assign unit_queue_deq_valid[i] = unit_out_res_flags[i][0].last_cycle & unit_out_valid[i];
        end
    end

    fifo_v3 #(
        .FALL_THROUGH (1'b0        ),
        .dtype        (op_unit),
        .DEPTH        (2           )   //might need to be bigger?
    ) unit_queue (
        .clk_i,
        .rst_ni     (sync_rst_ni),
        .flush_i    (1'b0                                                   ),
        .data_i     (pipe_in_ctrl_i.unit                                    ),
        .push_i     (pipe_in_ctrl_i.first_cycle),
        .data_o     (unit_queue_deq_unit                                    ),
        .pop_i      (|unit_queue_deq_valid),
        .empty_o    (),
        .full_o     ()
    );

    // Output logic
    always_comb begin
        pipe_out_valid_o          = '0;
        pipe_out_instr_id_o       =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_eew_o            =          DONT_CARE_ZERO ? cfg_vsew'  ('0) : cfg_vsew'  ('x)  ;
        pipe_out_vaddr_o          =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_res_store_o      =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_res_valid_o      =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_res_flags_o      = {RES_CNT{DONT_CARE_ZERO ? pack_flags'('0) : pack_flags'('x)}};
        pipe_out_res_data_o       =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_res_mask_o       =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_pend_clear_o     =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_pend_clear_cnt_o =          DONT_CARE_ZERO ?             '0  :             'x   ;
        pipe_out_instr_done_o     =          DONT_CARE_ZERO ?             '0  :             'x   ;
        for (int i = 0; i < UNIT_CNT; i++) begin
            if (UNITS[i] & (op_unit'(i) == unit_queue_deq_unit)) begin
                pipe_out_valid_o          = unit_out_valid         [i];
                pipe_out_instr_id_o       = unit_out_instr_id      [i];
                pipe_out_eew_o            = unit_out_eew           [i];
                pipe_out_vaddr_o          = unit_out_vaddr         [i];
                pipe_out_res_store_o      = unit_out_res_store     [i];
                pipe_out_res_valid_o      = unit_out_res_valid     [i];
                pipe_out_res_flags_o      = unit_out_res_flags     [i];
                pipe_out_res_data_o       = unit_out_res_data      [i];
                pipe_out_res_mask_o       = unit_out_res_mask      [i];
                pipe_out_pend_clear_o     = unit_out_pend_clear    [i];
                pipe_out_pend_clear_cnt_o = unit_out_pend_clear_cnt[i];
                pipe_out_instr_done_o     = unit_out_instr_done    [i];
            end
        end
    end

endmodule
