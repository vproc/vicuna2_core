// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_lsu import vproc_pkg::*; #(
        parameter int unsigned        VMEM_W          = 32,   // width in bits of the vector memory interface
        parameter bit                 BUF_REQUEST     = 1'b1, // insert pipeline stage before issuing request
        parameter bit                 BUF_RDATA       = 1'b1, // insert pipeline stage after memory read
        parameter type                CTRL_T          = logic,
        parameter int unsigned        XIF_ID_W        = 3,    // width in bits of instruction IDs
        parameter int unsigned        XIF_ID_CNT      = 8,    // total count of instruction IDs
        parameter int unsigned           VLSU_QUEUE_SZ = 4,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS    = '0,
        parameter bit                 DONT_CARE_ZERO  = 1'b0  // initialize don't care values to zero
    )
    (
        input  logic                  clk_i,
        input  logic                  async_rst_ni,
        input  logic                  sync_rst_ni,

        input  logic                  pipe_in_valid_i,
        output logic                  pipe_in_ready_o,
        input  CTRL_T                 pipe_in_ctrl_i,
        input  logic [31          :0] pipe_in_op1_i,
        input  logic [VMEM_W    -1:0] pipe_in_op2_i,
        input  logic [VMEM_W/8  -1:0] pipe_in_mask_i,

        output logic                  pipe_out_valid_o,
        input  logic                  pipe_out_ready_i,
        output CTRL_T                 pipe_out_ctrl_o,
        output logic                  pipe_out_pend_clr_o,
        output logic [VMEM_W    -1:0] pipe_out_res_o,
        output logic [VMEM_W/8  -1:0] pipe_out_mask_o,

        output logic                  pending_load_o,
        output logic                  pending_store_o,

        input  logic [31:0]           vreg_pend_rd_i,

        input  instr_state [XIF_ID_CNT-1:0] instr_state_i,

        output logic                  trans_complete_valid_o,
        input  logic                  trans_complete_ready_i,
        output logic [XIF_ID_W-1:0]   trans_complete_id_o,
        output logic                  trans_complete_exc_o,
        output logic [5:0]            trans_complete_exccode_o,

        vproc_xif.coproc_mem          xif_mem_if,
        vproc_xif.coproc_mem_result   xif_memres_if
    );

    // reduced LSU state for passing through the queue
    typedef struct packed {
        logic                        first_cycle;
        logic                        last_cycle;
        logic [XIF_ID_W-1:0]         id;
        op_mode_lsu                  mode;
        logic [$clog2(VMEM_W/8)-1:0] vl_part;
        logic                        vl_part_0;
        logic                        last_vl_part;
        logic [4:0]                  res_vaddr;
        logic                        res_store;
        logic                        res_shift;
        logic                        suppressed;
        logic                        exc;
        logic [5:0]                  exccode;
        logic [5:0]                  vreg_idx; //Needed for PACK
    } lsu_state_red;

    ///////////////////////////////////////////////////////////////////////////
    // LSU BUFFERS
    
    logic         state_req_ready,   lsu_queue_ready;
    logic         state_req_stall;
    logic         state_req_valid_q, state_req_valid_d, state_rdata_valid;
    CTRL_T        state_req_q,       state_req_d;
    lsu_state_red state_rdata;

    assign pending_load_o  = state_req_valid_q & ~state_req_q.mode.lsu.store;
    assign pending_store_o = state_req_valid_q &  state_req_q.mode.lsu.store;

    // request address:
    logic [31:0] req_addr_q, req_addr_d;

    // store data and mask buffers:
    logic [VMEM_W  -1:0] wdata_buf_q, wdata_buf_d;
    logic [VMEM_W/8-1:0] wmask_buf_q, wmask_buf_d;

    // temporary buffer for byte mask during request:
    logic [VMEM_W/8-1:0] vmsk_tmp_q, vmsk_tmp_d;

    generate
        if (BUF_REQUEST) begin
             always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_lsu_stage_req_valid
                if (~async_rst_ni) begin
                    state_req_valid_q <= 1'b0;
                end
                else if (~sync_rst_ni) begin
                    state_req_valid_q <= 1'b0;
                end
                else if (state_req_ready) begin
                    state_req_valid_q <= state_req_valid_d;
                end
            end
            always_ff @(posedge clk_i) begin : vproc_lsu_stage_req
                if (state_req_ready & state_req_valid_d) begin
                    state_req_q <= state_req_d;
                    req_addr_q  <= req_addr_d;
                    wdata_buf_q <= wdata_buf_d;
                    wmask_buf_q <= wmask_buf_d;
                    vmsk_tmp_q  <= vmsk_tmp_d;
                end
            end
        end else begin
            always_comb begin
                state_req_valid_q = state_req_valid_d;
                state_req_q       = state_req_d;
                req_addr_q        = req_addr_d;
                wdata_buf_q       = wdata_buf_d;
                wmask_buf_q       = wmask_buf_d;
                vmsk_tmp_q        = vmsk_tmp_d;
            end
        end

    endgenerate

    // Stall vreg writes until pending reads of the destination register are
    // complete and while the instruction is speculative; for the LSU stalling
    // has to happen at the request stage, since later stalling is not possible
    // Also stall if incoming instruction is speculative OR a current instruction has not finished
    assign state_req_stall = (~state_req_q.mode.lsu.store & state_req_q.res_store & vreg_pend_rd_i[state_req_q.res_vaddr]) |
                             ((instr_state_i[state_req_q.id] == INSTR_SPECULATIVE) | ~(state_req_q.id == deq_state.id)) | ~lsu_queue_ready;

    ///////////////////////////////////////////////////////////////////////////
    // LSU READ/WRITE

    assign state_req_valid_d = pipe_in_valid_i;
    assign state_req_d       = pipe_in_ctrl_i;
    assign pipe_in_ready_o   = state_req_ready;

    logic [31        :0] vs2_data;
    logic [VMEM_W  -1:0] vs3_data;
    logic [VMEM_W/8-1:0] vmsk_data;
    assign vs2_data  = pipe_in_op1_i;
    assign vs3_data  = pipe_in_op2_i;
    assign vmsk_data = pipe_in_mask_i;

    // compose memory address:
    always_comb begin
        req_addr_d = DONT_CARE_ZERO ? '0 : 'x;
        unique case (pipe_in_ctrl_i.mode.lsu.stride)
            // For (unit-)strided memory requests, the address is initialized with the X register
            // value during the first cycle and incremented during later cycles, but it is left
            // unchanged in case the input is invalid (avoids corrupting the address).  Note that
            // for strided loads, the X register value holds the base address in the first cycle
            // and then switches to the increment value.
            LSU_UNITSTRIDE: req_addr_d = pipe_in_valid_i ? (pipe_in_ctrl_i.init_addr ?
                pipe_in_ctrl_i.xval : req_addr_q + 32'(VMEM_W / 8)
            ) : req_addr_q;
            LSU_STRIDED:    req_addr_d = pipe_in_valid_i ? (pipe_in_ctrl_i.init_addr ?
                pipe_in_ctrl_i.xval : req_addr_q + pipe_in_ctrl_i.xval
            ) : req_addr_q;
            LSU_INDEXED: begin
                // note: the index is multiplied by the element byte width and the field count
                unique case (pipe_in_ctrl_i.mode.lsu.alt_eew)
                    VSEW_8:  req_addr_d = pipe_in_ctrl_i.xval +  32'(vs2_data[7 :0]);
                    VSEW_16: req_addr_d = pipe_in_ctrl_i.xval + 32'(vs2_data[15:0]);
                    VSEW_32: req_addr_d = pipe_in_ctrl_i.xval + 32'(vs2_data[31:0]);
                    default: ;
                endcase
            end
            default: ;
        endcase
    end

    assign vmsk_tmp_d = vmsk_data;

    // write data conversion and masking:
    logic [VMEM_W/8-1:0] wdata_unit_vl_mask;
    logic                wdata_stri_mask;
    assign wdata_unit_vl_mask = ~pipe_in_ctrl_i.vl_part_0 ? ({(VMEM_W/8){1'b1}} >> (~pipe_in_ctrl_i.vl_part)) : '0;
    assign wdata_stri_mask    = ~pipe_in_ctrl_i.vl_part_0 &
                                (pipe_in_ctrl_i.mode.lsu.masked ? vmsk_data[0] : 1'b1);
    always_comb begin
        wdata_buf_d = DONT_CARE_ZERO ? '0 : 'x;
        wmask_buf_d = DONT_CARE_ZERO ? '0 : 'x;
        if (pipe_in_ctrl_i.mode.lsu.stride == LSU_UNITSTRIDE) begin
            wdata_buf_d = vs3_data[VMEM_W-1:0];
            wmask_buf_d = (pipe_in_ctrl_i.mode.lsu.masked ? vmsk_data : '1) & wdata_unit_vl_mask;
        end else begin
            unique case (pipe_in_ctrl_i.mode.lsu.eew)
                VSEW_8: begin
                    for (int i = 0; i < VMEM_W / 8 ; i++)
                        wdata_buf_d[i*8  +: 8 ] = vs3_data[7 :0];
                    wmask_buf_d = {{VMEM_W/8-1{1'b0}},    wdata_stri_mask  } <<  req_addr_d[$clog2(VMEM_W/8)-1:0]                                    ;
                end
                VSEW_16: begin
                    for (int i = 0; i < VMEM_W / 16; i++)
                        wdata_buf_d[i*16 +: 16] = vs3_data[15:0];
                    wmask_buf_d = {{VMEM_W/8-2{1'b0}}, {2{wdata_stri_mask}}} << (req_addr_d[$clog2(VMEM_W/8)-1:0] & ({$clog2(VMEM_W/8){1'b1}} << 1));
                end
                VSEW_32: begin
                    for (int i = 0; i < VMEM_W / 32; i++)
                        wdata_buf_d[i*32 +: 32] = vs3_data[31:0];
                    wmask_buf_d = {{VMEM_W/8-4{1'b0}}, {4{wdata_stri_mask}}} << (req_addr_d[$clog2(VMEM_W/8)-1:0] & ({$clog2(VMEM_W/8){1'b1}} << 2));
                end
                default: ;
            endcase
            if (~VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE]) begin
                wdata_buf_d = vs3_data[VMEM_W-1:0];
                unique case (pipe_in_ctrl_i.mode.lsu.eew)
                    VSEW_8:  wmask_buf_d = {{VMEM_W/8-1{1'b0}},    wdata_stri_mask  };
                    VSEW_16: wmask_buf_d = {{VMEM_W/8-2{1'b0}}, {2{wdata_stri_mask}}};
                    VSEW_32: wmask_buf_d = {{VMEM_W/8-4{1'b0}}, {4{wdata_stri_mask}}};
                    default: ;
                endcase
            end
        end
    end


    vproc_lsu_extension #(
        .VMEM_W                   ( VMEM_W                                      ),
        .BUF_REQUEST              ( BUF_REQUEST                                 ),
        .BUF_RDATA                ( BUF_RDATA                                   ),
        .LSU_STATE_RED_T          ( lsu_state_red                               ),
        .XIF_ID_W                 ( XIF_ID_W                                    ),
        .XIF_ID_CNT               ( XIF_ID_CNT                                  ),
        .VLSU_QUEUE_SZ            ( VLSU_QUEUE_SZ                               ),
        .VLSU_FLAGS               ( VLSU_FLAGS                                  ),
        .DONT_CARE_ZERO           ( DONT_CARE_ZERO                              )
    ) lsu_extension (
        .clk_i                    ( clk_i                                       ),
        .async_rst_ni             ( async_rst_ni                                ),
        .sync_rst_ni              ( sync_rst_ni                                 ),
        .state_req_valid_q_i      ( state_req_valid_q                           ),
        .state_req_valid_d_i      ( state_req_valid_d                           ),
        .state_req_stall_i        ( state_req_stall                             ),
        .state_rdata_valid_o      ( state_rdata_valid                           ),
        .state_req_ready_o        ( state_req_ready                             ),
        .lsu_queue_ready_o        ( lsu_queue_ready                             ),
        .state_rdata_o            ( state_rdata                                 ),
        .instr_state_i            ( instr_state_i                               ),
        .trans_complete_valid_o   ( trans_complete_valid_o                      ),
        .trans_complete_ready_i   ( trans_complete_ready_i                      ),
        .trans_complete_id_o      ( trans_complete_id_o                         ),
        .trans_complete_exc_o     ( trans_complete_exc_o                        ),
        .trans_complete_exccode_o ( trans_complete_exccode_o                    ),
        .xif_mem_if               ( xif_mem_if                                  ),
        .xif_memres_if            ( xif_memres_if                               )
    );


    // load data conversion:
    logic [VMEM_W/8-1:0] rdata_unit_vl_mask, rdata_unit_vdmsk;
    logic rdata_stri_vdmsk;
    assign rdata_unit_vl_mask = ~state_rdata.vl_part_0 ? ({(VMEM_W/8){1'b1}} >> (~state_rdata.vl_part)) : '0;
    assign rdata_unit_vdmsk   = (state_rdata.mode.masked ? rmask_buf_q : {VMEM_W/8{1'b1}}) & rdata_unit_vl_mask;
    assign rdata_stri_vdmsk   = ~state_rdata.vl_part_0 & (state_rdata.mode.masked ? rmask_buf_q[0] : 1'b1);

    assign pipe_out_valid_o = state_rdata_valid;

    always_comb begin
        pipe_out_ctrl_o              = DONT_CARE_ZERO ? '0 : 'x;
        pipe_out_ctrl_o.first_cycle  = state_rdata.first_cycle;
        pipe_out_ctrl_o.last_cycle   = state_rdata.last_cycle;
        pipe_out_ctrl_o.id           = state_rdata.id;
        pipe_out_ctrl_o.mode.lsu     = state_rdata.mode;
        pipe_out_ctrl_o.eew          = state_rdata.mode.eew;
        pipe_out_ctrl_o.vl_part      = state_rdata.vl_part;
        pipe_out_ctrl_o.vl_part_0    = state_rdata.vl_part_0;
        pipe_out_ctrl_o.last_vl_part = state_rdata.last_vl_part & state_rdata.res_store; //only pass last_vl_part if storing to vreg
        pipe_out_ctrl_o.vreg_idx     = state_rdata.vreg_idx;
        pipe_out_ctrl_o.res_vaddr    = state_rdata.res_vaddr;
        pipe_out_ctrl_o.res_store    = state_rdata.res_store & ~state_rdata.exc;
        pipe_out_ctrl_o.res_shift    = state_rdata.res_shift;
    end
    assign pipe_out_pend_clr_o = state_rdata.res_store;
    always_comb begin
        if (state_rdata.mode.stride == LSU_UNITSTRIDE) begin
            pipe_out_res_o = rdata_buf_q;
        end else begin
            pipe_out_res_o = DONT_CARE_ZERO ? '0 : 'x;
            unique case (state_rdata.mode.eew)
                VSEW_8:  pipe_out_res_o[7 :0] = rdata_buf_q[{3'b000, rdata_off_q                                  } * 8 +: 8 ];
                VSEW_16: pipe_out_res_o[15:0] = rdata_buf_q[{3'b000, rdata_off_q & ({$clog2(VMEM_W/8){1'b1}} << 1)} * 8 +: 16];
                VSEW_32: pipe_out_res_o[31:0] = rdata_buf_q[{3'b000, rdata_off_q & ({$clog2(VMEM_W/8){1'b1}} << 2)} * 8 +: 32];
                default: ;
            endcase
            if (~VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE]) begin
                pipe_out_res_o = rdata_buf_q;
            end
        end
        pipe_out_mask_o = (state_rdata.mode.stride == LSU_UNITSTRIDE) ? rdata_unit_vdmsk : {(VMEM_W/8){rdata_stri_vdmsk}};
    end


`ifdef VPROC_SVA
`include "vproc_lsu_sva.svh"
`endif

endmodule
