// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_core import vproc_pkg::*, obi_pkg::*; #(
        // XIF interface configuration (must be provided when instantiating this module)
        parameter int unsigned           XIF_ID_W                 = 0, // width of instruction IDs
        parameter int unsigned           XIF_MEM_W                = 0, // memory interface width

        // Vector register file configuration
        parameter vreg_type              VREG_TYPE                = vproc_config::VREG_TYPE,
        parameter int unsigned           VREG_W                   = vproc_config::VREG_W,
        parameter int unsigned           VPORT_RD_CNT             = vproc_config::VPORT_RD_CNT,
        parameter int unsigned           VPORT_RD_W[VPORT_RD_CNT] = vproc_config::VPORT_RD_W,
        parameter int unsigned           VPORT_WR_CNT             = vproc_config::VPORT_WR_CNT,
        parameter int unsigned           VPORT_WR_W[VPORT_WR_CNT] = vproc_config::VPORT_WR_W,

        // Vector pipeline configuration
        parameter int unsigned           PIPE_CNT                 = vproc_config::PIPE_CNT,
        parameter bit [UNIT_CNT-1:0]     PIPE_UNITS    [PIPE_CNT] = vproc_config::PIPE_UNITS,
        parameter int unsigned           PIPE_W        [PIPE_CNT] = vproc_config::PIPE_W,
        parameter int unsigned           PIPE_VPORT_CNT[PIPE_CNT] = vproc_config::PIPE_VPORT_CNT,
        parameter int unsigned           PIPE_VPORT_IDX[PIPE_CNT] = vproc_config::PIPE_VPORT_IDX,
        parameter int unsigned           PIPE_VPORT_WR [PIPE_CNT] = vproc_config::PIPE_VPORT_WR,

        // Unit-specific configuration
        parameter int unsigned           VLSU_QUEUE_SZ            = vproc_config::VLSU_QUEUE_SZ,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS               = vproc_config::VLSU_FLAGS,
        parameter mul_type               MUL_TYPE                 = vproc_config::MUL_TYPE,

        // Miscellaneous configuration
        parameter int unsigned           INSTR_QUEUE_SZ           = vproc_config::INSTR_QUEUE_SZ,
        parameter bit [BUF_FLAGS_W-1:0]  BUF_FLAGS                = vproc_config::BUF_FLAGS,

        parameter int unsigned           MEM_PORTS                = 1,
        parameter obi_cfg_t              OBI_CFG                  = ObiDefaultConfig,
        parameter int unsigned           PORT_QUEUE_DEPTH         = 1,

        parameter bit                    DONT_CARE_ZERO           = 1'b0, // init don't cares to 0
        parameter bit                    ASYNC_RESET              = 1'b0  // rst_ni is async
    )(
        input  logic                     clk_i,
        input  logic                     rst_ni,

        // eXtension interface
        vproc_xif.coproc_issue           xif_issue_if,
        vproc_xif.coproc_commit          xif_commit_if,
        vproc_xif.coproc_result          xif_result_if,

        OBI_BUS.Manager                  obi_bus [MEM_PORTS-1:0],

        output logic                     pending_load_o,
        output logic                     pending_store_o,

        // CSR connections
        output logic [31:0]              csr_vtype_o,
        output logic [31:0]              csr_vl_o,
        output logic [31:0]              csr_vlenb_o,
        output logic [31:0]              csr_vstart_o,
        input  logic [31:0]              csr_vstart_i,
        input  logic                     csr_vstart_set_i,
        output logic [1:0]               csr_vxrm_o,
        input  logic [1:0]               csr_vxrm_i,
        input  logic                     csr_vxrm_set_i,
        output logic                     csr_vxsat_o,
        input  logic                     csr_vxsat_i,
        input  logic                     csr_vxsat_set_i,

        `ifdef RISCV_ZVE32F
        output logic fpr_wr_req_valid,
        output logic [4:0] fpr_wr_req_addr_o,

        output  logic fpr_res_valid,

        input fpnew_pkg::roundmode_e float_round_mode_i,

        input logic fpu_res_acc,
        input logic[XIF_ID_W-1:0] fpu_res_id,

        `endif

        output logic [31:0]              pend_vreg_wr_map_o
    );

    if ((VREG_W & (VREG_W - 1)) != 0 || VREG_W < 64) begin
        $fatal(1, "The vector register width VREG_W must be at least 64 and a power of two.  ",
                  "The current value of %d is invalid.", VREG_W);
    end

    generate
        for (genvar i = 0; i < VPORT_RD_CNT; i++) begin
            if ((VPORT_RD_W[i] & (VPORT_RD_W[i] - 1)) != 0 || VPORT_RD_W[i] < 32) begin
                $fatal(1, "Vector register read port %d is %d bits wide, ", i, VPORT_RD_W[i],
                          "but a power of two between 32 and %d is required.", VREG_W);
            end
            if (VPORT_RD_W[i] > VREG_W) begin
                $fatal(1, "Vector register read port %d is %d bits wide, ", i, VPORT_RD_W[i],
                          "exceeds vector register width of %d bits.", VREG_W);
            end
        end
        for (genvar i = 0; i < VPORT_WR_CNT; i++) begin
            if ((VPORT_WR_W[i] & (VPORT_WR_W[i] - 1)) != 0 || VPORT_WR_W[i] < 32) begin
                $fatal(1, "Vector register write port %d is %d bits wide, ", i, VPORT_WR_W[i],
                          "but a power of two between 32 and %d is required.", VREG_W);
            end
            if (VPORT_WR_W[i] > VREG_W) begin
                $fatal(1, "Vector register write port %d is %d bits wide, ", i, VPORT_WR_W[i],
                          "exceeds vector register width of %d bits.", VREG_W);
            end
        end
    endgenerate

    generate
        for (genvar i = 0; i < PIPE_CNT; i++) begin
            if (PIPE_UNITS[i][UNIT_LSU] & (PIPE_W[i] != MEM_PORTS*XIF_MEM_W)) begin
                $fatal(1, "The vector pipeline containing the VLSU must have a datapath width ",
                          "equal to the memory interface width divided by memory ports.  However, pipeline %d ", i,
                          "containing the VLSU has a width of %d bits ", PIPE_W[i],
                          "while the memory interface is %d bits wide ", XIF_MEM_W,
                          "and we have %d memory port.", MEM_PORTS);
            end
            if ((PIPE_VPORT_IDX[i] >= VPORT_RD_CNT) |
                (PIPE_VPORT_IDX[i] + PIPE_VPORT_CNT[i] > VPORT_RD_CNT)
            ) begin
                $fatal(1, "Vector pipeline %d uses vector register read port %d through %d, ", i,
                          PIPE_VPORT_IDX[i], PIPE_VPORT_IDX[i] + PIPE_VPORT_CNT[i] - 1,
                          "but the valid range is 0 through %d.", VPORT_RD_CNT - 1);
            end
            for (genvar j = i + 1; j < PIPE_CNT; j++) begin
                if (((PIPE_VPORT_IDX[i] < PIPE_VPORT_IDX[j]) &
                    (PIPE_VPORT_IDX[i] + PIPE_VPORT_CNT[i] > PIPE_VPORT_IDX[j])) |
                    ((PIPE_VPORT_IDX[i] >= PIPE_VPORT_IDX[j]) &
                    (PIPE_VPORT_IDX[j] + PIPE_VPORT_CNT[j] > PIPE_VPORT_IDX[i]))
                ) begin
                    $fatal(1, "Vector register read ports of vector pipeline %d overlap ", i,
                              "with the vector register read ports of vector pipeline %d ", j,
                              "(pipeline %d uses ports %d through %d ", i,
                              PIPE_VPORT_IDX[i], PIPE_VPORT_IDX[i] + PIPE_VPORT_CNT[i] - 1,
                              "and pipeline %d uses ports %d through %d).", j,
                              PIPE_VPORT_IDX[j], PIPE_VPORT_IDX[j] + PIPE_VPORT_CNT[j] - 1);
                end
            end
        end
    endgenerate

    typedef int unsigned ASSIGN_VADDR_RD_W_RET_T[VPORT_RD_CNT];
    typedef int unsigned ASSIGN_VADDR_WR_W_RET_T[VPORT_WR_CNT];
    function static ASSIGN_VADDR_RD_W_RET_T ASSIGN_VADDR_RD_W();
        for (int i = 0; i < VPORT_RD_CNT; i++) begin
            ASSIGN_VADDR_RD_W[i] = 5 + $clog2(VREG_W / VPORT_RD_W[i]);
        end
    endfunction
    function static ASSIGN_VADDR_WR_W_RET_T ASSIGN_VADDR_WR_W();
        for (int i = 0; i < VPORT_WR_CNT; i++) begin
            ASSIGN_VADDR_WR_W[i] = 5 + $clog2(VREG_W / VPORT_WR_W[i]);
        end
    endfunction

    localparam int unsigned VADDR_RD_W[VPORT_RD_CNT] = ASSIGN_VADDR_RD_W();
    localparam int unsigned VADDR_WR_W[VPORT_WR_CNT] = ASSIGN_VADDR_WR_W();

    function static int unsigned MAX_VPORT_RD_SLICE(
        int unsigned SRC[VPORT_RD_CNT], int unsigned OFFSET, int unsigned CNT
    );
        MAX_VPORT_RD_SLICE = 0;
        for (int i = 0; i < CNT; i++) begin
            if (SRC[i] > MAX_VPORT_RD_SLICE) begin
                MAX_VPORT_RD_SLICE = SRC[OFFSET + i];
            end
        end
    endfunction
    function static int unsigned MAX_VPORT_WR_SLICE(
        int unsigned SRC[VPORT_WR_CNT], int unsigned OFFSET, int unsigned CNT
    );
        MAX_VPORT_WR_SLICE = 0;
        for (int i = 0; i < CNT; i++) begin
            if (SRC[OFFSET + i] > MAX_VPORT_WR_SLICE) begin
                MAX_VPORT_WR_SLICE = SRC[OFFSET + i];
            end
        end
    endfunction

    localparam int unsigned MAX_VPORT_RD_W = MAX_VPORT_RD_SLICE(VPORT_RD_W, 0, VPORT_RD_CNT);
    localparam int unsigned MAX_VADDR_RD_W = MAX_VPORT_RD_SLICE(VADDR_RD_W, 0, VPORT_RD_CNT);
    localparam int unsigned MAX_VPORT_WR_W = MAX_VPORT_WR_SLICE(VPORT_WR_W, 0, VPORT_WR_CNT);
    localparam int unsigned MAX_VADDR_WR_W = MAX_VPORT_WR_SLICE(VADDR_WR_W, 0, VPORT_WR_CNT);
    localparam int unsigned MAX_VPORT_W    = (MAX_VPORT_RD_W > MAX_VPORT_WR_W) ? MAX_VPORT_RD_W : MAX_VPORT_WR_W;
    localparam int unsigned MAX_VADDR_W    = (MAX_VADDR_RD_W > MAX_VPORT_WR_W) ? MAX_VADDR_RD_W : MAX_VADDR_WR_W;

    // The current vector length (VL) actually counts bytes instead of elements.
    // Also, the vector lenght is actually one more element than what VL suggests;
    // hence, when VSEW = 8, the value in VL is the current length - 1,
    // when VSEW = 16 the actual vector length is VL / 2 + 1 and when VSEW = 32
    // the actual vector lenght is VL / 4 + 1. Due to this
    // encoding the top 3 bits of VL are only used when LMUL > 1.
    localparam int unsigned CFG_VL_W = $clog2(VREG_W); // width of the vl config register

    // Total count of instruction IDs used by the extension interface
    localparam int unsigned XIF_ID_CNT = 1 << XIF_ID_W;

    // define asynchronous and synchronous reset signals
    logic async_rst_n, sync_rst_n;
    assign async_rst_n = ASYNC_RESET ? rst_ni : 1'b1  ;
    assign sync_rst_n  = ASYNC_RESET ? 1'b1   : rst_ni;

    ///////////////////////////////////////////////////////////////////////////
    // VECTOR INSTRUCTION DECODER INTERFACE

    typedef struct packed {
        logic [XIF_ID_W-1:0] id;
        cfg_vsew             vsew;
        cfg_emul             emul;
        cfg_vxrm             vxrm;
        logic                vl_0;
        logic [CFG_VL_W-1:0] vl;
        logic [CFG_VL_W  :0] vlmax;
        op_unit              unit;
        op_mode              mode;
        op_widenarrow        widenarrow;
        logic                narrow_frac;
        op_regs              rs1;
        op_regs              rs2;
        op_regd              rd;
        logic                pend_load;
        logic                pend_store;
        decode_metadata      decode_metadata; //TODO: This struct should encompass all relevant signals from decoder_data and replace it
    } decoder_data;

    // signals for decoder and for decoder buffer
    logic        dec_ready,       dec_valid,       dec_clear;
    logic        dec_buf_valid_q, dec_buf_valid_d;
    decoder_data dec_data_q,      dec_data_d;

    assign dec_buf_valid_d = (~dec_ready | dec_valid) & ~dec_clear;

    // Check if scalar source operands are valid
    logic source_xreg_valid;
    assign source_xreg_valid = (!dec_data_d.rs1.xreg | xif_issue_if.issue_req.rs_valid[0]) & (!dec_data_d.rs2.xreg | xif_issue_if.issue_req.rs_valid[1]);

    // Stall instruction offloading in case the instruction ID is already used
    // by another instruction which is not complete
    logic instr_valid, issue_id_used;
    assign instr_valid = xif_issue_if.issue_valid & ~issue_id_used & source_xreg_valid & !result_fifo_full_stall;

    logic dec_vl_override;

    op_unit instr_unit;
    op_mode instr_mode;

    //Signals between CSRs and Decode
    logic [CFG_VL_W-1:0]     vl;
    logic                    vl_0;
    //logic [CFG_VL_W:0]       vlmax; TODO: Currently computed in decode
    cfg_lmul                 lmul;
    cfg_vsew                 sew;
    cfg_vxrm                 vxrm;
    logic                    illegal_cfg_o;

    vproc_decoder #(
        .VREG_W             ( VREG_W                              ),
        .CFG_VL_W           ( CFG_VL_W                            ),
        .XIF_MEM_W          ( XIF_MEM_W                           ),
        .ALIGNED_UNITSTRIDE ( VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE] ),
        .DONT_CARE_ZERO     ( DONT_CARE_ZERO                      )
    ) dec (
        .instr_i            ( xif_issue_if.issue_req.instr        ),
        .instr_valid_i      ( instr_valid                         ),
        .x_rs1_i            ( xif_issue_if.issue_req.rs[0]        ),
        .x_rs2_i            ( xif_issue_if.issue_req.rs[1]        ),
        .vsew_i             ( sew                                 ),
        .lmul_i             ( lmul                                ),
        .vxrm_i             ( vxrm                                ),
        .vl_i               ( vl                                  ),
        `ifdef RISCV_ZVE32F
        .fpr_wr_req_valid   ( fpr_wr_req_valid                    ),
        .fpr_wr_req_addr_o  ( fpr_wr_req_addr_o                   ),
        .float_round_mode_i ( float_round_mode_i                  ),
        `endif
        .valid_o            ( dec_valid                           ),
        .vsew_o             ( dec_data_d.vsew                     ),
        .emul_o             ( dec_data_d.emul                     ),
        .vxrm_o             ( dec_data_d.vxrm                     ),
        .vl_o               ( dec_data_d.vl                       ),
        .vlmax_o            ( dec_data_d.vlmax                    ),
        .unit_o             ( instr_unit                          ),
        .mode_o             ( instr_mode                          ),
        .widenarrow_o       ( dec_data_d.widenarrow               ),
        .narrow_frac_o      ( dec_data_d.narrow_frac              ),
        .rs1_o              ( dec_data_d.rs1                      ),
        .rs2_o              ( dec_data_d.rs2                      ),
        .rd_o               ( dec_data_d.rd                       ),
        .vl_override_o      ( dec_vl_override                     ),
        .decode_metadata_o  ( dec_data_d.decode_metadata          )
    );
    assign dec_data_d.id         = xif_issue_if.issue_req.id;
    assign dec_data_d.vl_0       = vl_0 & ~dec_vl_override;
    assign dec_data_d.unit       = instr_unit;
    assign dec_data_d.mode       = instr_mode;
    assign dec_data_d.pend_load  = (instr_unit == UNIT_LSU) & ~instr_mode.lsu.store;
    assign dec_data_d.pend_store = (instr_unit == UNIT_LSU) &  instr_mode.lsu.store;

    // Note: The decoder is not ready if the decode buffer is not ready, even
    // if an offloaded instruction is illegal.  The decode buffer could hold a
    // vset[i]vl[i] instruction that will change the configuration in the next
    // cycle and any subsequent offloaded instruction must be validated w.r.t.
    // the new configuration.

    logic result_fifo_full_stall; //Stall issue in case another committed instruction cannot be accepted since commit cannot stall

    assign xif_issue_if.issue_ready          = dec_ready & ~issue_id_used & source_xreg_valid & !result_fifo_full_stall;

    assign xif_issue_if.issue_resp.accept    = dec_valid;
    assign xif_issue_if.issue_resp.writeback = dec_valid & (((instr_unit == UNIT_XRESULT) & instr_mode.elem.xreg) | (instr_unit == UNIT_CFG));
    assign xif_issue_if.issue_resp.dualwrite = '0;
    assign xif_issue_if.issue_resp.dualread  = '0;
    assign xif_issue_if.issue_resp.loadstore = dec_valid & (instr_unit == UNIT_LSU);
    assign xif_issue_if.issue_resp.exc       = dec_valid & (instr_unit == UNIT_LSU);


    ///////////////////////////////////////////////////////////////////////////
    // VECTOR INSTRUCTION COMMIT STATE

    // The instruction state tracks whether a vector instruction is invalid,
    // speculative, committed, or killed.  First, any instruction ID is
    // invalid, which indicates that no instruction with that ID has been
    // offloaded yet.  Once an instruction has been accepted, it becomes
    // speculative until there is a corresponding commit transaction.  The
    // commit transaction changes the instruction's state to either committed
    // or killed, depending on the corresponding bit in the commit transaction.
    // The instruction remains in that state until it is complete.   
    // TODO: Handle below condition with a new pipeline ID 
    // Note that an instruction may be incomplete despite having been retired (by
    // providing a result to the host CPU via the XIF result interface).
    // Hence, the host CPU might attempt to reuse the ID of an incomplete
    // instruction.  To avoid this, the decoder stalls in case the instruction
    // ID of a new instruction is still valid.
    instr_state [XIF_ID_CNT-1:0] instr_state_q,     instr_state_d;     // instruction state
    logic       [XIF_ID_CNT-1:0] instr_empty_res_q, instr_empty_res_d; // empty result mask
    always_ff @(posedge clk_i or negedge async_rst_n) begin : vproc_commit_buf
        if (~async_rst_n) begin
            instr_state_q    <= '{default: INSTR_INVALID};
        end
        else if (~sync_rst_n) begin
            instr_state_q    <= '{default: INSTR_INVALID};
        end else begin
            instr_state_q    <= instr_state_d;
        end
    end
    always_ff @(posedge clk_i) begin
        instr_empty_res_q <= instr_empty_res_d;
    end

    //Update issue/commit status
    always_comb begin
        instr_state_d = instr_state_q;
        if ((xif_commit_if.commit.id == xif_issue_if.issue_req.id) & xif_commit_if.commit_valid & xif_issue_if.issue_valid) begin //If the same instruction is committed and issued in the same cycle
            //Mark offloaded and comitted instructions as comitted (in this mode, instructions are offloaded non-speculatively and cannot be killed)
            if (xif_issue_if.issue_valid & xif_issue_if.issue_ready & xif_commit_if.commit_valid) begin
                instr_state_d[xif_issue_if.issue_req.id] = INSTR_COMMITTED;
            end
            //Mark instructions invalid once result is signalled
            if (xif_result_if.result_valid & xif_result_if.result_ready) begin
                instr_state_d[xif_result_if.result.id] = INSTR_INVALID;
            end
        end else begin
            if (xif_issue_if.issue_valid & xif_issue_if.issue_ready) begin
                instr_state_d[xif_issue_if.issue_req.id] = INSTR_SPECULATIVE;
            end
            if (xif_commit_if.commit_valid) begin
                if (xif_commit_if.commit.commit_kill) begin
                    instr_state_d[xif_commit_if.commit.id] = INSTR_KILLED;
                end else begin
                    instr_state_d[xif_commit_if.commit.id] = INSTR_COMMITTED;
                end
            end
            if (xif_result_if.result_valid & xif_result_if.result_ready) begin
                instr_state_d[xif_result_if.result.id] = INSTR_INVALID;
            end
        end
    end

    assign issue_id_used = instr_state_q[xif_issue_if.issue_req.id] != INSTR_INVALID; //TODO: This condition should no longer occur.  Scalar core should not be able to offload the same ID twice
    ////////

    // Instruction complete signal for each pipeline
    logic [PIPE_CNT-1:0]               instr_complete_valid;
    logic [PIPE_CNT-1:0][XIF_ID_W-1:0] instr_complete_id;

    // return an empty result or VL as result
    logic                result_empty_valid, result_csr_valid;
    logic                                    result_csr_ready;
    logic [XIF_ID_W-1:0] result_empty_id,    result_csr_id;
    logic [4:0]                              result_csr_addr;
    logic                                    result_csr_delayed;
    logic [31:0]                             result_csr_data;
    logic                                    result_csr_we;

    logic queue_ready, queue_push; // instruction queue ready and push signals (enqueue handshake)
    assign queue_push = dec_buf_valid_q & (dec_data_q.unit != UNIT_CFG);

    // decode buffer is vacated either by enqueueing an instruction or for
    // vset[i]vl[i] once the instruction has been committed; for vset[i]vl[i]
    // it will take an additional cycle until the CSR values are updated, hence
    // the decode buffer is cleared without asserting dec_ready
    assign dec_ready = ~dec_buf_valid_q | (queue_ready & queue_push);

    // XIF instruction successfully offloaded
    logic instr_offload;
    assign instr_offload = xif_issue_if.issue_valid & xif_issue_if.issue_ready &
                           xif_issue_if.issue_resp.accept;

    ///////////////////////////////
    // DISPATCH QUEUES
    //
    // TODO: Instructions are dispatched to the pipeline strictly in order, only after they are committed, or eliminated from the queue when killed
    // TODO: Separate queue for CSR operations, since these go to the TODO: CSR unit and not the pipeline
    // TODO: Fallthrough mode enabled to improve performance in the case where offloaded instructions are non-speculative (i.e. committed immediately as in the CVA6).  TODO: Confirm this has no effect on FMAX
    // TODO: For improved performance, a new ID (pipeline ID) is assigned for regfile arbitration purposes to prevent unneccesary stalls from instructions having the same XIF ID
    ///////////////////////////////

    logic push_pipeline_disp, pop_pipeline_disp;
    logic pipeline_disp_full, pipeline_disp_empty;

    logic pipeline_ready;

    decoder_data pipeline_disp_data;

    assign push_pipeline_disp = dec_valid & (instr_unit != UNIT_CFG); //Push on valid instruction decode for vector pipeline
    assign pop_pipeline_disp = ((!pipeline_disp_empty & ((pipeline_disp_data.id == xif_commit_if.commit.id) & xif_commit_if.commit_valid)) | (!pipeline_disp_empty & (instr_state_q[pipeline_disp_data.id] != INSTR_SPECULATIVE))) & pipeline_ready;

    //Signal empty result on sucessful dispatch when not LSU or XRESULT instructions
    assign result_empty_valid = pop_pipeline_disp & (pipeline_disp_data.unit != UNIT_LSU) & (pipeline_disp_data.unit != UNIT_XRESULT);
    assign result_empty_id = pipeline_disp_data.id;

    fifo_v3 #(
    .FALL_THROUGH (1'b1        ),
    .dtype        (decoder_data),
    .DEPTH        (4           )
    ) pipeline_dispatch_queue (
        .clk_i,
        .rst_ni     (sync_rst_n),
        .flush_i    (1'b0                          ),
        .data_i     ( dec_data_d                   ),
        .push_i     ( push_pipeline_disp           ),
        .data_o     ( pipeline_disp_data           ),
        .pop_i      ( pop_pipeline_disp            ),
        .empty_o    ( pipeline_disp_empty          ),
        .full_o     ( pipeline_disp_full           )
    );

    //CSR operations have a separate dispatch queue for improved performance.  Each committed vsetvli instruction can be applied immediately to allow offloading of next standard vector instruction

    //Reduced struct just for csr accesses
    typedef struct packed {
        logic [XIF_ID_W-1:0]   id;
        logic[31:0]           val;
        op_mode_cfg           cfg;
        logic[4:0]            dest_addr;
    } csr_dec_data;

    csr_dec_data csr_fifo_input;

    assign csr_fifo_input.id = dec_data_d.id;
    assign csr_fifo_input.cfg = dec_data_d.mode.cfg;
    assign csr_fifo_input.val = dec_data_d.rs1.r.xval;
    assign csr_fifo_input.dest_addr = dec_data_d.rd.addr;

    logic push_csr_disp, pop_csr_disp;
    logic csr_disp_full, csr_disp_empty;
    logic csr_ready;

    csr_dec_data csr_disp_data;

    assign push_csr_disp = dec_valid & (instr_unit == UNIT_CFG); //Push on valid instruction decode for vector pipeline
    assign pop_csr_disp = ((!csr_disp_empty & ((csr_disp_data.id == xif_commit_if.commit.id) & xif_commit_if.commit_valid)) | (!csr_disp_empty & (instr_state_q[csr_disp_data.id] != INSTR_SPECULATIVE))) & csr_ready;                       //Pop CSR instruction if csr instruction is committed or killed.

    //TODO: Need to discard killed instructions without signalling + reset ID value
    fifo_v3 #(
    .FALL_THROUGH (1'b1        ),
    .dtype        (csr_dec_data),
    .DEPTH        (1           )   //Likely only needs one slot here?
    ) csr_dispatch_queue (
        .clk_i,
        .rst_ni     (sync_rst_n),
        .flush_i    (1'b0                          ),
        .data_i     ( csr_fifo_input               ),
        .push_i     ( push_csr_disp                ),
        .data_o     ( csr_disp_data                ),
        .pop_i      ( pop_csr_disp                 ),
        .empty_o    ( csr_disp_empty               ),
        .full_o     ( csr_disp_full                )
    );


    ////////
    // potential vector register hazards of the currently dequeued instruction
    ////////
    logic [31:0] pending_wr_disp;
    vproc_pending_wr #(
        .CFG_VL_W       ( CFG_VL_W                ),
        .VREG_W         ( VREG_W                  ),
        .DONT_CARE_ZERO ( DONT_CARE_ZERO          )
    ) queue_pending_wr (
        .vsew_i         ( pipeline_disp_data.vsew       ),
        .emul_i         ( pipeline_disp_data.emul       ),
        .vl_i           ( pipeline_disp_data.vl         ),
        .unit_i         ( pipeline_disp_data.unit       ),
        .mode_i         ( pipeline_disp_data.mode       ),
        .widenarrow_i   ( pipeline_disp_data.widenarrow ),
        .rd_i           ( pipeline_disp_data.rd         ),
        .pending_wr_o   ( pending_wr_disp               )
    );

    ///////////////////////////////////////////////////////////////////////////
    // DISPATCHER

    logic [PIPE_CNT-1:0] pipe_instr_valid;
    logic [PIPE_CNT-1:0] pipe_instr_ready;
    decoder_data         pipe_instr_data;
    logic [31:0]         pend_vreg_wr_map;
    logic [31:0]         pend_vreg_wr_clr;
    vproc_dispatcher #(
        .PIPE_CNT           ( PIPE_CNT           ),
        .PIPE_UNITS         ( PIPE_UNITS         ),
        .MAX_VADDR_W        ( 5                  ),
        .DECODER_DATA_T     ( decoder_data       ),
        .DONT_CARE_ZERO     ( DONT_CARE_ZERO     )
    ) dispatcher (
        .clk_i              ( clk_i              ),
        .async_rst_ni       ( async_rst_n        ),
        .sync_rst_ni        ( sync_rst_n         ),
        .instr_valid_i      ( !pipeline_disp_empty ),
        .instr_ready_o      ( pipeline_ready     ),
        .instr_data_i       ( pipeline_disp_data ),
        .instr_vreg_wr_i    ( pending_wr_disp    ),
        .dispatch_valid_o   ( pipe_instr_valid   ),
        .dispatch_ready_i   ( pipe_instr_ready   ),
        .dispatch_data_o    ( pipe_instr_data    ),
        .pend_vreg_wr_map_o ( pend_vreg_wr_map   ),
        .pend_vreg_wr_clr_i ( pend_vreg_wr_clr   )
    );
    assign pend_vreg_wr_map_o = pend_vreg_wr_map;


    ///////////////////////////////////////////////////////////////////////////
    // REGISTER FILE AND EXECUTION UNITS

    //////////////// write signals
    logic [PIPE_CNT-1:0]               vreg_wr_req;
    logic [PIPE_CNT-1:0]               vreg_wr_gnt;
    logic [PIPE_CNT-1:0][XIF_ID_W-1:0] vreg_wr_id;
    logic [PIPE_CNT-1:0][4:0]          pipe_vreg_wr_addr;
    logic [PIPE_CNT-1:0][VREG_W  -1:0] pipe_vreg_wr_data;
    logic [PIPE_CNT-1:0][VREG_W/8-1:0] pipe_vreg_wr_be;
    logic [PIPE_CNT-1:0]               pipe_vreg_wr_clr;
    logic [PIPE_CNT-1:0][1:0]          pipe_vreg_wr_clr_cnt;

    // register file: //TODO: Cleanup these signals to make them clearer
   logic [VPORT_WR_CNT-1:0]               vregfile_wr_en_q /* verilator public */;
    logic [VPORT_WR_CNT-1:0]               vregfile_wr_en_d;
    logic [VPORT_WR_CNT-1:0][4:0]          vregfile_wr_addr_q /* verilator public */;
    logic [VPORT_WR_CNT-1:0][4:0]          vregfile_wr_addr_d;
    logic [VPORT_WR_CNT-1:0][VREG_W  -1:0] vregfile_wr_data_q /* verilator public */;
    logic [VPORT_WR_CNT-1:0][VREG_W  -1:0] vregfile_wr_data_d;
    logic [VPORT_WR_CNT-1:0][VREG_W/8-1:0] vregfile_wr_mask_q /* verilator public */;
    logic [VPORT_WR_CNT-1:0][VREG_W/8-1:0] vregfile_wr_mask_d;
    logic [VPORT_RD_CNT:0][4:0]          vregfile_rd_addr; //
    logic [VPORT_RD_CNT:0][VREG_W  -1:0] vregfile_rd_data;
    vproc_vregfile #(
        .VREG_W       ( VREG_W             ),
        .MAX_PORT_W   ( MAX_VPORT_W        ),
        .MAX_ADDR_W   ( MAX_VADDR_W        ),
        .PORT_RD_CNT  ( VPORT_RD_CNT  + 1  ), //extra dedicated v0 port
        .PORT_WR_CNT  ( VPORT_WR_CNT       ),
        .PORT_WR_W    ( VPORT_WR_W         ),
        .VREG_TYPE    ( VREG_TYPE          )
    ) vregfile (
        .clk_i        ( clk_i              ),
        .async_rst_ni ( async_rst_n        ),
        .sync_rst_ni  ( sync_rst_n         ),
        .wr_addr_i    ( vregfile_wr_addr_q ),
        .wr_data_i    ( vregfile_wr_data_q ),
        .wr_be_i      ( vregfile_wr_mask_q ),
        .wr_we_i      ( vregfile_wr_en_q   ),
        .rd_addr_i    ( vregfile_rd_addr   ),
        .rd_data_o    ( vregfile_rd_data   )
    );

    logic [VREG_W-1:0] vreg_mask;
    assign vreg_mask           = vregfile_rd_data[VPORT_RD_CNT];
    assign vregfile_rd_addr[VPORT_RD_CNT] = 5'b0;

    //Regfile arbiter has ensured only one pipeline can access each port in a single cycle (only one grant signal is given)
    //generate  //TODO: Currently hardcoded to only one write port - Possible optimization for segmented loads to have more
        //for (genvar port = 0; port < NUM_PORTS_WR; port++) begin 
            always_comb begin
                vregfile_wr_addr_q = '0;
                vregfile_wr_en_q = '0;
                vregfile_wr_data_q = '0;
                vregfile_wr_mask_q = '0;
                for (int i = 0; i < PIPE_CNT; i ++) begin
                    if (arb_wr_gnt_o == (1 << i)) begin
                        vregfile_wr_addr_q = pipe_vreg_wr_addr[i];
                        vregfile_wr_en_q = arb_wr_gnt_o[i];
                        vregfile_wr_data_q = pipe_vreg_wr_data[i];
                        vregfile_wr_mask_q = pipe_vreg_wr_be[i];
                    end
                end
            end
        //end
    //endgenerate

    generate
        for (genvar port = 0; port < VPORT_RD_CNT; port++) begin 
            always_comb begin
                vregfile_rd_addr[port] = '0;
                for (int pipe = 0; pipe < PIPE_CNT; pipe ++) begin
                    vreg_rd_data[pipe][port] = vregfile_rd_data[port];
                    if (|(arb_rd_gnt_o[pipe] & (1 << port))) begin
                        vregfile_rd_addr[port] = vreg_rd_addr[pipe][port];
                    end
                end
            end
        end
    endgenerate
    /////////////////////  Why does this exist
    // Pending reads
    logic [PIPE_CNT-1:0][31:0] pipe_vreg_pend_rd_by_q, pipe_vreg_pend_rd_by_d;
    logic [PIPE_CNT-1:0][31:0] pipe_vreg_pend_rd_to_q, pipe_vreg_pend_rd_to_d;
    generate
        if (BUF_FLAGS[BUF_VREG_PEND]) begin
            // Note: A vreg write cannot happen within the first two cycles of
            // an instruction, hence delaying the pending vreg reads signals by
            // two cycles should cause no issues. This adds two unnecessary
            // extra stall cycles in case a write is blocked by a pending read
            // but that should happen rarely anyways.
            // TODO: This should be unecessary
            always_ff @(posedge clk_i) begin
                pipe_vreg_pend_rd_by_q <= pipe_vreg_pend_rd_by_d;
                pipe_vreg_pend_rd_to_q <= pipe_vreg_pend_rd_to_d;
            end
        end else begin
            assign pipe_vreg_pend_rd_by_q = pipe_vreg_pend_rd_by_d;
            assign pipe_vreg_pend_rd_to_q = pipe_vreg_pend_rd_to_d;
        end
    endgenerate
    logic [PIPE_CNT-1:0][31:0] pipe_vreg_pend_rd_in, pipe_vreg_pend_rd_out;
    always_comb begin
        pipe_vreg_pend_rd_in   = pipe_vreg_pend_rd_to_q;
        pipe_vreg_pend_rd_by_d = pipe_vreg_pend_rd_out;
        pipe_vreg_pend_rd_to_d = '0;
        for (int i = 0; i < PIPE_CNT; i++) begin
            for (int j = 0; j < PIPE_CNT; j++) begin
                if (i != j) begin
                    pipe_vreg_pend_rd_to_d[i] |= pipe_vreg_pend_rd_by_q[j];
                end
            end
        end
    end

    ////////////////////
    // CSR Unit
    // CSR accesses are performed in parallel to the main pipelines, removing most stalls caused by vsetvl accesses
    // CSR Access Stalls must be generated in two cases:
    //  1. A Speculative VSETVL instruction exists in the dispatch buffer.  Decode must stall in this case
    //  2. VXSAT is accessed while a fixed point operation is still in progress. Decode can continue in this case
    ////////////////////

    logic csr_valid;

    assign csr_valid = !csr_disp_empty | push_csr_disp; //valid input to csr unit when csr dispatch is not empty OR a value is being pushed for fall through
    vproc_csr #(
        .VLEN(VREG_W),
        .CFG_VL_W($clog2(VREG_W)),
        .DEC_DATA_CSR_T(csr_dec_data),
        .XIF_ID_W(XIF_ID_W)
    ) vproc_csr (
        .clk_i(clk_i),
        .async_rst_ni(async_rst_n),
        .sync_rst_ni(sync_rst_n),

        //Interface to expose csrs to DECODE

        .vl_o(vl),    //TODO: currently passing old vl bytes
        .vl_0_o(vl_0),
        //.vlmax_o(), //TODO: currently passing old vlmax number of elements TODO: Currently computed in decode
        .lmul_o(lmul),
        .sew_o(sew),
        .illegal_cfg_o(illegal_cfg),
        .vxrm_o(vxrm),

        //TODO: Expose other relevant CSRs

        //Interface with CSR dispatch queue
        .dec_data_i(csr_disp_data),
        .valid_i(csr_valid),
        .ready_o(csr_ready),

        //Interface with Result Module
        .result_csr_valid_o(result_csr_valid),
        .result_csr_ready_i(result_csr_ready),
        .result_csr_id_o(result_csr_id),
        .result_csr_addr_o(result_csr_addr),
        .result_csr_data_o(result_csr_data),
        .result_csr_we_o(result_csr_we)

        //TODO: Interface to update VCSR for fixed point ops

        //TODO: Interface to update custom performance counter CSRs

    );
    //////

    logic                lsu_trans_complete_valid;
    logic                lsu_trans_complete_ready;
    logic [XIF_ID_W-1:0] lsu_trans_complete_id;
    logic                lsu_trans_complete_exc;
    logic [5:0]          lsu_trans_complete_exccode;

    logic                elem_xreg_valid;
    logic                elem_xreg_ready;
    logic [XIF_ID_W-1:0] elem_xreg_id;
    logic [4:0]          elem_xreg_addr;
    logic [31:0]         elem_xreg_data;

    logic [PIPE_CNT-1:0][VPORT_RD_CNT-1:0][4       :0] vreg_rd_addr;
    logic [PIPE_CNT-1:0][VPORT_RD_CNT-1:0][VREG_W-1:0] vreg_rd_data;
    logic [PIPE_CNT-1:0][VPORT_RD_CNT-1:0]             vreg_rd_gnt;
    logic [PIPE_CNT-1:0][VPORT_RD_CNT-1:0]             vreg_rd_req;
    logic [PIPE_CNT-1:0][XIF_ID_W-1:0]                 vreg_rd_id;

    `ifdef RISCV_ZVE32F
    logic                elem_freg;

    `endif

    generate
        for (genvar i = 0; i < PIPE_CNT; i++) begin

            localparam int unsigned PIPE_VADDR_W[PIPE_VPORT_CNT[i]]  = VADDR_RD_W[PIPE_VPORT_IDX[i] +: PIPE_VPORT_CNT[i]];
            localparam int unsigned PIPE_MAX_VPORT_W = MAX_VPORT_RD_SLICE(VPORT_RD_W, PIPE_VPORT_IDX[i], PIPE_VPORT_CNT[i]);
            localparam int unsigned PIPE_MAX_VADDR_W = MAX_VPORT_RD_SLICE(VADDR_RD_W, PIPE_VPORT_IDX[i], PIPE_VPORT_CNT[i]);

            localparam bit [PIPE_VPORT_CNT[i]-1:0] PIPE_VPORT_BUFFER = {{(PIPE_VPORT_CNT[i]-1){1'b0}}, 1'b1};

            // LSU-related signals
            OBI_BUS #(
                .OBI_CFG     ( OBI_CFG   )
            ) pipe_obi_bus [MEM_PORTS-1:0] ();

            logic                pending_load, pending_store;
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
            `ifdef RISCV_ZVE32F
            logic freg_res;
            `endif

            vproc_pipeline_wrapper #(
                .VREG_W                   ( VREG_W                     ),
                .CFG_VL_W                 ( CFG_VL_W                   ),
                .XIF_ID_W                 ( XIF_ID_W                   ),
                .XIF_ID_CNT               ( XIF_ID_CNT                 ),
                .UNITS                    ( PIPE_UNITS[i]              ),
                .MAX_VPORT_W              ( PIPE_MAX_VPORT_W           ),
                .MAX_VADDR_W              ( PIPE_MAX_VADDR_W           ),
                .VPORT_CNT                ( VPORT_RD_CNT               ),

                .VADDR_W                  ( PIPE_VADDR_W               ),

                .VPORT_BUFFER             ( PIPE_VPORT_BUFFER          ),
                .VPORT_V0                 ( 1'b1                       ),
                .MAX_OP_W                 ( PIPE_W[i]                  ),
                .MEM_W                    ( XIF_MEM_W                  ),
                .VLSU_QUEUE_SZ            ( VLSU_QUEUE_SZ              ),
                .VLSU_FLAGS               ( VLSU_FLAGS                 ),
                .MUL_TYPE                 ( MUL_TYPE                   ),
                .DECODER_DATA_T           ( decoder_data               ),
                .MEM_PORTS                ( MEM_PORTS                  ),
                .OBI_CFG                  ( OBI_CFG                    ),
                .PORT_QUEUE_DEPTH         ( PORT_QUEUE_DEPTH           ),
                .DONT_CARE_ZERO           ( DONT_CARE_ZERO             )
            ) pipe (
                .clk_i                    ( clk_i                      ),
                .async_rst_ni             ( async_rst_n                ),
                .sync_rst_ni              ( sync_rst_n                 ),
                .pipe_in_valid_i          ( pipe_instr_valid[i]        ),
                .pipe_in_ready_o          ( pipe_instr_ready[i]        ),
                .pipe_in_data_i           ( pipe_instr_data            ),
                .vreg_pend_wr_i           ( pend_vreg_wr_map           ),
                .vreg_pend_rd_o           ( pipe_vreg_pend_rd_out[i]   ),
                .vreg_pend_rd_i           ( pipe_vreg_pend_rd_in [i]   ),
                .instr_state_i            ( instr_state_q              ),
                .instr_done_valid_o       ( instr_complete_valid[i]    ),
                .instr_done_id_o          ( instr_complete_id   [i]    ),
                .vreg_rd_addr_o           ( vreg_rd_addr[i]            ),
                .vreg_rd_data_i           ( vreg_rd_data[i]            ),
                .vreg_rd_v0_i             ( vreg_mask                  ),
                .vreg_rd_gnt_i            ( vreg_rd_gnt[i]             ),
                .vreg_rd_req_o            ( vreg_rd_req[i]             ),
                .vreg_rd_id_o             ( vreg_rd_id[i]              ),
                .vreg_wr_req_o            ( vreg_wr_req  [i]           ),
                .vreg_wr_gnt_i            ( vreg_wr_gnt  [i]           ),
                .vreg_wr_addr_o           ( pipe_vreg_wr_addr   [i]    ),
                .vreg_wr_be_o             ( pipe_vreg_wr_be     [i]    ),
                .vreg_wr_data_o           ( pipe_vreg_wr_data   [i]    ),
                .vreg_wr_id_o             ( vreg_wr_id[i]              ),
                .pend_wr_clear_i          ( pend_vreg_wr_clr           ),
                .vreg_wr_clr_o            ( pipe_vreg_wr_clr    [i]    ),
                .vreg_wr_clr_cnt_o        ( pipe_vreg_wr_clr_cnt[i]    ),
                .pending_load_o           ( pending_load               ),
                .pending_store_o          ( pending_store              ),
                .obi_bus                  ( pipe_obi_bus               ),
                .trans_complete_valid_o   ( trans_complete_valid       ),
                .trans_complete_ready_i   ( trans_complete_ready       ),
                .trans_complete_id_o      ( trans_complete_id          ),
                .trans_complete_exc_o     ( trans_complete_exc         ),
                .trans_complete_exccode_o ( trans_complete_exccode     ),
                `ifdef RISCV_ZVE32F
                .freg_res                 ( freg_res                   ),
                `endif
                .xreg_valid_o             ( xreg_valid                 ),
                .xreg_ready_i             ( xreg_ready                 ),
                .xreg_id_o                ( xreg_id                    ),
                .xreg_addr_o              ( xreg_addr                  ),
                .xreg_data_o              ( xreg_data                  )
            );
            if (PIPE_UNITS[i][UNIT_LSU]) begin
                assign pending_load_lsu           = pending_load;
                assign pending_store_lsu          = pending_store;

                for (genvar j = 0; j < MEM_PORTS; j++) begin
                    assign obi_bus[j].req               = pipe_obi_bus[j].req;
                    assign obi_bus[j].reqpar            = pipe_obi_bus[j].reqpar;
                    assign pipe_obi_bus[j].gnt          = obi_bus[j].gnt;
                    assign pipe_obi_bus[j].gntpar       = obi_bus[j].gntpar;
                    assign obi_bus[j].addr              = pipe_obi_bus[j].addr;
                    assign obi_bus[j].we                = pipe_obi_bus[j].we;
                    assign obi_bus[j].be                = pipe_obi_bus[j].be;
                    assign obi_bus[j].wdata             = pipe_obi_bus[j].wdata;
                    assign obi_bus[j].aid               = pipe_obi_bus[j].aid;
                    assign obi_bus[j].a_optional        = pipe_obi_bus[j].a_optional;
                    assign pipe_obi_bus[j].rvalid       = obi_bus[j].rvalid;
                    assign pipe_obi_bus[j].rvalidpar    = obi_bus[j].rvalidpar;
                    assign obi_bus[j].rready            = pipe_obi_bus[j].rready;
                    assign obi_bus[j].rreadypar         = pipe_obi_bus[j].rreadypar;
                    assign pipe_obi_bus[j].rdata        = obi_bus[j].rdata;
                    assign pipe_obi_bus[j].rid          = obi_bus[j].rid;
                    assign pipe_obi_bus[j].err          = obi_bus[j].err;
                    assign pipe_obi_bus[j].r_optional   = obi_bus[j].r_optional;
                end

                assign lsu_trans_complete_valid   = trans_complete_valid;
                assign trans_complete_ready       = lsu_trans_complete_ready;
                assign lsu_trans_complete_id      = trans_complete_id;
                assign lsu_trans_complete_exc     = trans_complete_exc;
                assign lsu_trans_complete_exccode = trans_complete_exccode;
            end
            if (PIPE_UNITS[i][UNIT_XRESULT]) begin
                assign elem_xreg_valid = xreg_valid;
                assign xreg_ready      = elem_xreg_ready;
                assign elem_xreg_id    = xreg_id;
                assign elem_xreg_addr  = xreg_addr;
                assign elem_xreg_data  = xreg_data;
                `ifdef RISCV_ZVE32F
                assign elem_freg = freg_res;
                `endif
            end

        end
    endgenerate

    //Can remove this
    vproc_vreg_wr_mux #(
        .VREG_W             ( VREG_W                              ),
        .VPORT_WR_CNT       ( VPORT_WR_CNT                        ),
        .PIPE_CNT           ( PIPE_CNT                            ),
        .PIPE_UNITS         ( PIPE_UNITS                          ),
        .PIPE_VPORT_WR      ( PIPE_VPORT_WR                       ),
        .TIMEPRED           ( BUF_FLAGS[BUF_VREG_WR_MUX_TIMEPRED] ), //??
        .DONT_CARE_ZERO     ( DONT_CARE_ZERO                      )
    ) vreg_wr_mux (
        .clk_i              ( clk_i                               ),
        .async_rst_ni       ( async_rst_n                         ),
        .sync_rst_ni        ( sync_rst_n                          ),
        .vreg_wr_valid_i    ( pipe_vreg_wr_valid                  ),
        .vreg_wr_ready_o    ( pipe_vreg_wr_ready                  ),
        .vreg_wr_addr_i     ( pipe_vreg_wr_addr                   ),
        .vreg_wr_be_i       ( pipe_vreg_wr_be                     ),
        .vreg_wr_data_i     ( pipe_vreg_wr_data                   ),
        .vreg_wr_clr_i      ( pipe_vreg_wr_clr                    ),
        .vreg_wr_clr_cnt_i  ( pipe_vreg_wr_clr_cnt                ),
        //.pend_vreg_wr_clr_o ( pend_vreg_wr_clr                    ),
        .vregfile_wr_en_o   ( vregfile_wr_en_d                    ),
        .vregfile_wr_addr_o ( vregfile_wr_addr_d                  ),
        .vregfile_wr_be_o   ( vregfile_wr_mask_d                  ),
        .vregfile_wr_data_o ( vregfile_wr_data_d                  )
    );

    //Arbiter for vregfile read and write ports.  Ensures the oldest instruction always receives access in the event of simultaneous access attempts to maintain timing predictability
    logic arb_set_i;
    assign arb_set_i = |(pipe_instr_valid & pipe_instr_ready); //on sucessful dispatch

    logic arb_clear_i;
    logic [XIF_ID_W-1:0] arb_clear_id_i;
    assign arb_clear_i = |instr_complete_valid;
    //generate
        always_comb begin
            arb_clear_id_i = '0;
            for (integer i = 0; i < PIPE_CNT; i++) begin
                if (instr_complete_valid[i]) begin
                    arb_clear_id_i = instr_complete_id[i];
                end
            end
        end
    //endgenerate

    logic[PIPE_CNT-1:0][VPORT_RD_CNT-1:0]             arb_rd_req_i;
    logic[PIPE_CNT-1:0][XIF_ID_W-1:0]                 arb_rd_req_id_i;
    logic[PIPE_CNT-1:0][VPORT_RD_CNT-1:0]             arb_rd_gnt_o;

    logic[PIPE_CNT-1:0][VPORT_WR_CNT-1:0]             arb_wr_req_i;
    logic[PIPE_CNT-1:0][XIF_ID_W-1:0]                 arb_wr_req_id_i;
    logic[PIPE_CNT-1:0][VPORT_WR_CNT-1:0]             arb_wr_gnt_o;

    //VREG read port arbiter connections
    assign arb_rd_req_i    = vreg_rd_req;
    assign arb_rd_req_id_i = vreg_rd_id;
    assign vreg_rd_gnt     = arb_rd_gnt_o;

    //VREG write port arbiter connections
    assign arb_wr_req_i    = vreg_wr_req;
    assign arb_wr_req_id_i = vreg_wr_id;
    assign vreg_wr_gnt     = arb_wr_gnt_o;
    vproc_vreg_arbiter #(
        .ID_W               (XIF_ID_W),
        .REQUESTORS         (PIPE_CNT),
        .NUM_PORTS_RD       (VPORT_RD_CNT),
        .NUM_PORTS_WR       (VPORT_WR_CNT)
    ) vproc_vreg_arbiter (
        .clk_i(clk_i),
        .rst_ni(rst_ni),

        //add new entries when instruction is dispatched (max one per cycle)
        .set_i(arb_set_i),
        .set_id_i(pipe_instr_data.id),

        //clear entry when instruction is completed (max one per cycle)
        .clear_i(arb_clear_i),  //TODO: Confirm only one instruction is capable of signalling complete at once
        .clear_id_i(arb_clear_id_i),

        //Arbiter Interfaces
        .rd_req_i(arb_rd_req_i),
        .rd_req_id_i(arb_rd_req_id_i),
        .rd_gnt_o(arb_rd_gnt_o),

        .wr_req_i(arb_wr_req_i),
        .wr_req_id_i(arb_wr_req_id_i),
        .wr_gnt_o(arb_wr_gnt_o),

        .wr_addr_i(pipe_vreg_wr_addr),
        .pend_wr_clr_o(pend_vreg_wr_clr)
    );


    //On successful (granted) write, generate signal to clear pending writes for pipelines


    ///////////////////////////////////////////////////////////////////////////
    // RESULT INTERFACE

    vproc_result #(
        .XIF_ID_W                  ( XIF_ID_W                   ),
        .DONT_CARE_ZERO            ( DONT_CARE_ZERO             )
    ) result_if (
        .clk_i                     ( clk_i                      ),
        .async_rst_ni              ( async_rst_n                ),
        .sync_rst_ni               ( sync_rst_n                 ),
        .result_empty_valid_i      ( result_empty_valid         ),
        .result_empty_id_i         ( result_empty_id            ),
        .result_lsu_valid_i        ( lsu_trans_complete_valid   ),
        .result_lsu_ready_o        ( lsu_trans_complete_ready   ),
        .result_lsu_id_i           ( lsu_trans_complete_id      ),
        .result_lsu_exc_i          ( lsu_trans_complete_exc     ),
        .result_lsu_exccode_i      ( lsu_trans_complete_exccode ),
        .result_xreg_valid_i       ( elem_xreg_valid            ),
        .result_xreg_ready_o       ( elem_xreg_ready            ),
        .result_xreg_id_i          ( elem_xreg_id               ),
        .result_xreg_addr_i        ( elem_xreg_addr             ),
        .result_xreg_data_i        ( elem_xreg_data             ),
        `ifdef RISCV_ZVE32F
        .result_freg_i             ( elem_freg                  ),
        .result_freg_o             ( fpr_res_valid              ),
        .fpu_res_acc               ( fpu_res_acc                ),
        .fpu_res_id                ( fpu_res_id                 ),
        `endif
        .result_csr_valid_i        ( result_csr_valid           ),
        .result_csr_ready_o        ( result_csr_ready           ),
        .result_csr_id_i           ( result_csr_id              ),
        .result_csr_addr_i         ( result_csr_addr            ),
        .result_csr_delayed_i      ( 1'b0                       ),//TODO: delayed result no longer necessary
        .result_csr_data_i         ( result_csr_data            ),
        .result_csr_data_delayed_i ( csr_vl_o                   ),
        .result_fifo_full_stall_o  (result_fifo_full_stall      ),
        .xif_result_if             ( xif_result_if              ),
        .xif_commit_if             ( xif_commit_if              )

    );


`ifdef VPROC_SVA
`include "vproc_core_sva.svh"
`endif

endmodule
