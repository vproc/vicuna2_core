module vproc_lsu_extension import vproc_pkg::*; #(
        parameter int unsigned        VMEM_W          = 32,   // width in bits of the vector memory interface
        parameter bit                 BUF_REQUEST     = 1'b1, // insert pipeline stage before issuing request
        parameter bit                 BUF_RDATA       = 1'b1, // insert pipeline stage after memory read
        parameter type                LSU_STATE_RED_T = logic,
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

        input  logic [31:0]           vreg_pend_rd_i,
        input  LSU_STATE_RED_T        state_req_red_i,

        output logic                  state_rdata_valid_o,
        output logic                  state_req_ready_o,
        output LSU_STATE_RED_T        state_rdata_o,
        output logic [       VMEM_W   -1:0] rdata_buf_o,
        output logic [$clog2(VMEM_W/8)-1:0] rdata_off_o,
        output logic [       VMEM_W/8 -1:0] rmask_buf_o,

        input  instr_state [XIF_ID_CNT-1:0] instr_state_i,

        output logic                  trans_complete_valid_o,
        input  logic                  trans_complete_ready_i,
        output logic [XIF_ID_W-1:0]   trans_complete_id_o,
        output logic                  trans_complete_exc_o,
        output logic [5:0]            trans_complete_exccode_o,

        vproc_xif.coproc_mem          xif_mem_if,
        vproc_xif.coproc_mem_result   xif_memres_if
    );

    logic            state_req_stall; 
    logic            state_rdata_valid_q, state_rdata_valid_d;

    logic            state_req_ready,   lsu_input_queue_ready, lsu_output_queue_ready;

    LSU_STATE_RED_T  state_rdata_q, state_rdata_d;

    // memory request caused an exception:
    logic mem_exc_q, mem_exc_d;

    // memory request caused an error (exception or bus error):
    logic       mem_err_q,     mem_err_d;
    logic [5:0] mem_exccode_q, mem_exccode_d;

    // load data, offset and mask buffers:
    logic [       VMEM_W   -1:0] rdata_buf_q, rdata_buf_d;
    logic [$clog2(VMEM_W/8)-1:0] rdata_off_q, rdata_off_d;
    logic [       VMEM_W/8 -1:0] rmask_buf_q, rmask_buf_d;

    generate
        if (BUF_REQUEST) begin
            always_ff @(posedge clk_i) begin : vproc_lsu_stage_req
                if (state_req_ready & state_req_red.state_req_valid_d) begin
                    mem_exc_q   <= mem_exc_d;
                end
            end
            assign state_req_ready = ~state_req_red.state_req_valid_q | (xif_mem_if.mem_valid & xif_mem_if.mem_ready) | (~state_req_stall & ~xif_mem_if.mem_valid);
        end else begin
            always_ff @(posedge clk_i) begin
                // always need a flip-flop for the exception flag
                mem_exc_q <= mem_exc_d;
            end
            assign state_req_ready = (xif_mem_if.mem_valid & xif_mem_if.mem_ready) | (~state_req_stall & ~xif_mem_if.mem_valid);
        end

        // Note: The stages receiving memory data and writing it to vector
        // registers cannot stall, since there is no way to pause memory read
        // data once the memory requests have been issued.  Therefore, any
        // checks which might stall the pipeline (destination vector register
        // available, instruction committed) must be done *before* generating
        // the memory requests.
        if (BUF_RDATA) begin
            always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_lsu_stage_rdata_valid
                if (~async_rst_ni) begin
                    state_rdata_valid_q <= 1'b0;
                end
                else if (~sync_rst_ni) begin
                    state_rdata_valid_q <= 1'b0;
                end
                else begin
                    state_rdata_valid_q <= state_rdata_valid_d;
                end
            end
            always_ff @(posedge clk_i) begin : vproc_lsu_stage_rdata
                if (state_rdata_valid_d) begin
                    state_rdata_q <= state_rdata_d;
                    rdata_buf_q   <= rdata_buf_d;
                    rdata_off_q   <= rdata_off_d;
                    rmask_buf_q   <= rmask_buf_d;
                    mem_err_q     <= mem_err_d;
                    mem_exccode_q <= mem_exccode_d;
                end
            end
        end else begin
            always_comb begin
                state_rdata_valid_q = state_rdata_valid_d;
                state_rdata_q       = state_rdata_d;
                rdata_buf_q         = rdata_buf_d;
                rdata_off_q         = rdata_off_d;
                rmask_buf_q         = rmask_buf_d;
            end
            always_ff @(posedge clk_i) begin
                // always need a flip-flop for the error flag and exception code
                mem_err_q     <= mem_err_d;
                mem_exccode_q <= mem_exccode_d;
            end
        end
    endgenerate

    // Stall vreg writes until pending reads of the destination register are
    // complete and while the instruction is speculative; for the LSU stalling
    // has to happen at the request stage, since later stalling is not possible
    // Also stall if incoming instruction is speculative OR a current instruction has not finished
    assign state_req_stall = (~state_req_red.mode.store & state_req_red.res_store & vreg_pend_rd_i[state_req_red.res_vaddr]) |
                             ((instr_state_i[state_req_red.id] == INSTR_SPECULATIVE) | ~(state_req_red.id == deq_state.id)) | 
                             ~lsu_input_queue_ready | ~lsu_output_queue_ready;

    // memory request (keep requesting next access while addressing is not complete)
    assign xif_mem_if.mem_valid     = state_req_red.state_req_valid_q & ~state_req_red.suppressed & ~state_req_stall & (~mem_exc_q | state_req_red.first_cycle) & state_req_red_valid;
    assign xif_mem_if.mem_req.id    = state_req_red.id;
    assign xif_mem_if.mem_req.addr  = VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE] ? {state_req_red.req_addr_q[31:$clog2(VMEM_W/8)], {$clog2(VMEM_W/8){1'b0}}} : state_req_red.req_addr_q;
    assign xif_mem_if.mem_req.mode  = '0;
    assign xif_mem_if.mem_req.we    = state_req_red.mode.store;
    assign xif_mem_if.mem_req.size  = {1'b0, state_req_red.mode.eew};
    assign xif_mem_if.mem_req.be    = state_req_red.wmask_buf_q;
    assign xif_mem_if.mem_req.attr  = '0;
    assign xif_mem_if.mem_req.wdata = state_req_red.wdata_buf_q;
    assign xif_mem_if.mem_req.last  = state_req_red.last_cycle;
    assign xif_mem_if.mem_req.spec  = '0;

    // monitor the memory response for exceptions
    always_comb begin
        mem_exc_d = mem_exc_q;
        if (state_req_red.first_cycle | ~mem_exc_q) begin
            // reset the exception flag in the first cycle, unless there is an
            // exception
            mem_exc_d = xif_mem_if.mem_valid & xif_mem_if.mem_ready & xif_mem_if.mem_resp.exc;
        end
    end

    // input queue
    logic         state_req_red_valid; // LSU queue dequeue valid signal
    logic         state_req_red_ready;
    LSU_STATE_RED_T state_req_red;
    vproc_queue #(
        .WIDTH        ( $bits(LSU_STATE_RED_T)                                        ),
        .DEPTH        ( VLSU_QUEUE_SZ                                                 ),
        .FLOW         ( 1'b1                                                          )
    ) lsu_input_queue (
        .clk_i        ( clk_i                                                         ),
        .async_rst_ni ( async_rst_ni                                                  ),
        .sync_rst_ni  ( sync_rst_ni                                                   ),
        .enq_ready_o  ( lsu_input_queue_ready                                         ),
        .enq_valid_i  ( state_req_red_i.state_req_valid_q & ~state_req_stall          ),
        .enq_data_i   ( state_req_red_i                                               ),
        .deq_ready_i  ( state_req_red_ready                                           ),
        .deq_valid_o  ( state_req_red_valid                                           ),
        .deq_data_o   ( state_req_red                                                 ),
        .flags_any_o  (                                                               ),
        .flags_all_o  (                                                               )
    );

    // output queue -> queue after sending memory request
    logic         deq_valid; // LSU queue dequeue valid signal
    logic         deq_ready;
    LSU_STATE_RED_T deq_state;
    vproc_queue #(
        .WIDTH        ( $clog2(VMEM_W/8) + VMEM_W/8 + $bits(LSU_STATE_RED_T)                                      ),
        .DEPTH        ( VLSU_QUEUE_SZ                                                                             ),
        .FLOW         ( 1'b1                                                                                      )
    ) lsu_output_queue (
        .clk_i        ( clk_i                                                                                     ),
        .async_rst_ni ( async_rst_ni                                                                              ),
        .sync_rst_ni  ( sync_rst_ni                                                                               ),
        .enq_ready_o  ( lsu_output_queue_ready                                                                    ),
        .enq_valid_i  ( state_req_red.state_req_valid_q & state_req_ready & state_req_red_valid                   ),
        .enq_data_i   ( {state_req_red.req_addr_q[$clog2(VMEM_W/8)-1:0], state_req_red.vmsk_tmp_q, state_req_red} ),
        .deq_ready_i  ( deq_ready                                                                                 ),
        .deq_valid_o  ( deq_valid                                                                                 ),
        .deq_data_o   ( {rdata_off_d, rmask_buf_d, deq_state}                                                     ),
        .flags_any_o  (                                                                                           ),
        .flags_all_o  (                                                                                           )
    );

    assign state_req_red_ready = state_req_ready & lsu_output_queue_ready;

    // XIF mem_result_valid is asserted and the memory result's instruction ID matches and transaction is not suppressed(MIGHT BE AN ISSUE TODO)
    logic xif_mem_result_id_valid;
    assign xif_mem_result_id_valid = xif_memres_if.mem_result_valid &
                                    //(xif_memres_if.mem_result.id == deq_state.id) & !deq_state.suppressed; //XIF mem_result_id has been deprecated.  Remove check for this
                                    !deq_state.suppressed;

    assign deq_ready           = xif_mem_result_id_valid | deq_state.suppressed | mem_err_d;
    assign state_rdata_valid_d = deq_valid & deq_ready;

    // monitor the memory result for bus errors and the queue for exceptions
    always_comb begin
        mem_err_d     = mem_err_q;
        mem_exccode_d = mem_exccode_q;
        if (deq_valid & (deq_state.first_cycle | ~mem_err_q)) begin
            // reset the error flag in the first cycle, unless there is a bus
            // error or an exception occured during the request
            mem_err_d     = deq_state.exc | (xif_mem_result_id_valid & xif_memres_if.mem_result.err);
            mem_exccode_d = deq_state.exc ? deq_state.exccode : (
                // bus error translates to a load/store access fault exception
                deq_state.mode.store ? 6'h07 : 6'h05
            );
        end
    end

    // LSU transaction complete queue, result indicates potential exceptions
    logic trans_complete_valid, trans_complete_ready;
    assign trans_complete_valid = deq_valid & deq_ready & deq_state.last_cycle &
                                  (instr_state_i[deq_state.id] == INSTR_COMMITTED);

    vproc_queue #(
        .WIDTH        ( XIF_ID_W + 7                                                          ),
        .DEPTH        ( 2                                                                     )
    ) trans_complete_queue (
        .clk_i        ( clk_i                                                                 ),
        .async_rst_ni ( async_rst_ni                                                          ),
        .sync_rst_ni  ( sync_rst_ni                                                           ),
        .enq_ready_o  ( trans_complete_ready                                                  ),
        .enq_valid_i  ( trans_complete_valid                                                  ),
        .enq_data_i   ( {deq_state.id, mem_err_d, mem_exccode_d}                              ),
        .deq_ready_i  ( trans_complete_ready_i                                                ),
        .deq_valid_o  ( trans_complete_valid_o                                                ),
        .deq_data_o   ( {trans_complete_id_o, trans_complete_exc_o, trans_complete_exccode_o} ),
        .flags_any_o  (                                                                       ),
        .flags_all_o  (                                                                       )
    );

    // load data state
    always_comb begin
        state_rdata_d            = deq_state;
        state_rdata_d.exc        = mem_err_d;
        state_rdata_d.res_store &= ~state_rdata_d.mode.store; // inhibit vreg store for vector store
    end

    // load data:
    assign rdata_buf_d = xif_memres_if.mem_result.rdata;

    assign state_rdata_valid_o = state_rdata_valid_q;
    assign state_req_ready_o = state_req_ready;
    assign state_rdata_o = state_rdata_q;

    assign rdata_buf_o = rdata_buf_q;
    assign rdata_off_o = rdata_off_q;
    assign rmask_buf_o = rmask_buf_q;

`ifdef VPROC_SVA
`include "vproc_lsu_extension_sva.svh"
`endif

endmodule