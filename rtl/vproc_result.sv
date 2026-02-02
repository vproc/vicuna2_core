// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_result #(
        parameter int unsigned      XIF_ID_W       = 3,    // width in bits of instruction IDs
        parameter bit               DONT_CARE_ZERO = 1'b0  // initialize don't care values to zero
    )(
        input  logic                clk_i,
        input  logic                async_rst_ni,
        input  logic                sync_rst_ni,

        input  logic                result_empty_valid_i,
        input  logic [XIF_ID_W-1:0] result_empty_id_i,

        input  logic                result_lsu_valid_i,
        output logic                result_lsu_ready_o,
        input  logic [XIF_ID_W-1:0] result_lsu_id_i,
        input  logic                result_lsu_exc_i,
        input  logic [5:0]          result_lsu_exccode_i,

        input  logic                result_xreg_valid_i,
        output logic                result_xreg_ready_o,
        input  logic [XIF_ID_W-1:0] result_xreg_id_i,
        input  logic [4:0]          result_xreg_addr_i,
        input  logic [31:0]         result_xreg_data_i,

        `ifdef RISCV_ZVE32F
        input  logic                result_freg_i,
        output logic                result_freg_o,

        input logic                 fpu_res_acc,
        input logic [XIF_ID_W-1:0]  fpu_res_id,

        `endif

        input  logic                result_csr_valid_i,
        output logic                result_csr_ready_o,
        input  logic [XIF_ID_W-1:0] result_csr_id_i,
        input  logic [4:0]          result_csr_addr_i,
        input  logic                result_csr_delayed_i,
        input  logic [31:0]         result_csr_data_i,
        input  logic [31:0]         result_csr_data_delayed_i,

        vproc_xif.coproc_issue      xif_issue_if,
        vproc_xif.coproc_result     xif_result_if,
        vproc_xif.coproc_commit     xif_commit_if
    );

    // Total count of instruction IDs used by the extension interface
    localparam int unsigned XIF_ID_CNT = 1 << XIF_ID_W;

    // buffer IDs for which an empty result shall be generated
    logic [XIF_ID_CNT-1:0] instr_result_empty_q, instr_result_empty_d;

    // CSR result buffer
    logic                result_csr_valid_q,   result_csr_valid_d;
    logic [XIF_ID_W-1:0] result_csr_id_q,      result_csr_id_d;
    logic [4:0]          result_csr_addr_q,    result_csr_addr_d;
    logic                result_csr_delayed_q, result_csr_delayed_d;
    logic [31:0]         result_csr_data_q,    result_csr_data_d;

    always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_result_buffer
        if (~async_rst_ni) begin
            instr_result_empty_q <= '0;
            result_csr_valid_q   <= 1'b0;
        end
        else if (~sync_rst_ni) begin
            instr_result_empty_q <= '0;
            result_csr_valid_q   <= 1'b0;
        end
        else begin
            instr_result_empty_q <= instr_result_empty_d;
            result_csr_valid_q   <= result_csr_valid_d;
        end
    end
    always_ff @(posedge clk_i) begin : vproc_result
        result_csr_id_q      <= result_csr_id_d;
        result_csr_addr_q    <= result_csr_addr_d;
        result_csr_delayed_q <= result_csr_delayed_d;
        result_csr_data_q    <= result_csr_data_d;
    end

    logic [XIF_ID_W-1:0] next_id_q, next_id_d;


  //FIFO of XIF IDs to verify instructions are result signalled in the order they are issued
  //need to handle case for killed IDs?  CVA6 doesnt have this problem since issued instructions are always non-speculative (use commit if? should work for all cases except csrs for cv32e40x?)
  fifo_v3 #(
    .FALL_THROUGH (1'b1        ),
    .dtype        (logic [XIF_ID_W-1:0]),
    .DEPTH        (4           )   //
  ) next_xif_id_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                    ), //additional signals are available (full/empty signalling) which can be used to stall the pipeline if necessary.  However, full depth should never be reached because only LSU instructions and vector-> scalar move instructions can stall long enough
    .data_i     (xif_commit_if.commit.id),
    .push_i     (xif_commit_if.commit_valid & !xif_commit_if.commit.commit_kill),
    .data_o     (next_id_q        ),
    .pop_i      (xif_result_if.result_valid & xif_result_if.result_ready)
  );
  
    typedef enum logic [2:0] {
        RESULT_SOURCE_EMPTY,
        RESULT_SOURCE_EMPTY_BUF,
        RESULT_SOURCE_LSU,
        RESULT_SOURCE_XREG,
        RESULT_SOURCE_CSR_BUF,
        RESULT_SOURCE_NONE
    } result_source_e;
    logic                result_source_hold_q, result_source_hold_d;
    result_source_e      result_source_q,      result_source_d;
    logic [XIF_ID_W-1:0] result_empty_id_q,    result_empty_id_d;
    always_ff @(posedge clk_i or negedge async_rst_ni) begin
        if (~async_rst_ni) begin
            result_source_hold_q <= 1'b0;
        end
        else if (~sync_rst_ni) begin
            result_source_hold_q <= 1'b0;
        end else begin
            result_source_hold_q <= result_source_hold_d;
        end
    end

    always_ff @(posedge clk_i) begin
        result_source_q   <= result_source_d;
        result_empty_id_q <= result_empty_id_d;
    end
    
    result_source_e      result_source;
    logic [XIF_ID_W-1:0] result_empty_id;
    always_comb begin
        result_source   = RESULT_SOURCE_NONE;
        result_empty_id = DONT_CARE_ZERO ? '0 : 'x;

        // LSU always takes precedence (potentially oldest instruction)
        if (result_lsu_valid_i) begin
            result_source = RESULT_SOURCE_LSU;
        end
        // XREG goes second (usually also old instruction)
        else if (result_xreg_valid_i) begin
            result_source = RESULT_SOURCE_XREG;
        end
        // CSR goes third
        else if (result_csr_valid_q) begin
            result_source = RESULT_SOURCE_CSR_BUF;
        end
        // buffered empty results follow
        else if (instr_result_empty_q != '0) begin
            result_source = RESULT_SOURCE_EMPTY_BUF;
        end
        // incoming empty result goes last (since it is always the most recent instruction)
        else if (result_empty_valid_i) begin
            result_source = RESULT_SOURCE_EMPTY;
        end

        // select the lowest instruction ID for which an empty result must be returned //possible issue on overflow/wraparound to id 0
        for (int i = 0; i < XIF_ID_CNT; i++) begin
            if (instr_result_empty_q[i]) begin
                result_empty_id = XIF_ID_W'(i);
                break;
            end
        end

        // always keep the current result source during an ongoing result transaction; since the
        // ID for empty results is taken from a set, it must also be buffered to remain stable
        if (result_source_hold_q) begin
            result_source   = result_source_q;
            result_empty_id = result_empty_id_q;
        end
    end
    assign result_source_hold_d = xif_result_if.result_valid & ~xif_result_if.result_ready;
    always_comb begin
        result_source_d   = result_source;
        result_empty_id_d = result_empty_id;
        if (result_source == RESULT_SOURCE_EMPTY) begin
            result_source_d   = RESULT_SOURCE_EMPTY_BUF;
            result_empty_id_d = result_empty_id_i;
        end
    end

    always_comb begin
        instr_result_empty_d = instr_result_empty_q;
        result_csr_valid_d   = result_csr_valid_q;
        result_csr_id_d      = result_csr_id_q;
        result_csr_addr_d    = result_csr_addr_q;
        result_csr_delayed_d = result_csr_delayed_q;
        result_csr_data_d    = result_csr_data_q;

        // for a delayed result the data is always available in the cycle after the result was
        // received, but if the interface is not ready to return that result yet, the data has to
        // be buffered as well
        if (result_csr_delayed_q) begin
            result_csr_delayed_d = 1'b0;
            result_csr_data_d    = result_csr_data_delayed_i;
        end

        if (result_source == RESULT_SOURCE_EMPTY_BUF) begin
            // clear the selected ID if the XIF interface is ready and instruction is next to be retired
            instr_result_empty_d[result_empty_id] = ~(xif_result_if.result_ready &^ (result_empty_id == next_id_q));
        end
        if (result_source == RESULT_SOURCE_CSR_BUF) begin
            result_csr_valid_d = ~xif_result_if.result_ready || !(result_csr_id_q == next_id_q);
        end
        // instr ID is added to buffer if another result takes precedence or XIF iface is not ready or current instruction is not the next one to be retired
        `ifdef COMMIT_AND_ISSUE
        if ( (result_source == RESULT_SOURCE_EMPTY) | result_empty_valid_i & ((result_source != RESULT_SOURCE_EMPTY) | ~xif_result_if.result_ready | result_empty_id_i != next_id_q)) begin //need to buffer all empty results
        `else
        if (result_empty_valid_i & ((result_source != RESULT_SOURCE_EMPTY) | ~xif_result_if.result_ready | result_empty_id_i != next_id_q)) begin
        `endif
            instr_result_empty_d[result_empty_id_i] = 1'b1;
        end
        // CSR result is always buffered
        if (result_csr_valid_i & result_csr_ready_o) begin
            result_csr_valid_d   = 1'b1;
            result_csr_id_d      = result_csr_id_i;
            result_csr_addr_d    = result_csr_addr_i;
            result_csr_delayed_d = result_csr_delayed_i;
            result_csr_data_d    = result_csr_data_i;
        end
    end

    assign result_lsu_ready_o  =  (result_source == RESULT_SOURCE_LSU    ) & xif_result_if.result_ready;
    assign result_xreg_ready_o =  (result_source == RESULT_SOURCE_XREG   ) & xif_result_if.result_ready;
    assign result_csr_ready_o  = ((result_source == RESULT_SOURCE_CSR_BUF) & xif_result_if.result_ready) | ~result_csr_valid_q;

    logic fpu_res_accepted;

    `ifdef RISCV_ZVE32F
    assign result_freg_o = result_xreg_ready_o & result_freg_i;
    assign fpu_res_accepted = fpu_res_acc;
    `else
    assign fpu_res_accepted = 1'b0;
    `endif


    always_comb begin
        `ifdef COMMIT_AND_ISSUE
        next_id_d = next_id_q;
        if ((xif_result_if.result_valid && xif_result_if.result_ready) || fpu_res_accepted) begin
        `else 
        next_id_d = next_id_q; //Possible for a ready result and killed commit at the same time?
        if ((xif_result_if.result_valid && xif_result_if.result_ready) || fpu_res_accepted || xif_commit_if.commit.commit_kill && xif_commit_if.commit_valid) begin
        `endif
            next_id_d = next_id_q + 1;
        end
    end


    always_comb begin
        xif_result_if.result_valid   = '0;
        xif_result_if.result.id      = DONT_CARE_ZERO ? '0 : 'x; // always set if result_valid = 1

        // note: the signals below are all '0 if not used to ensure that they remain stable during
        // a transaction
        xif_result_if.result.data    = '0;
        xif_result_if.result.rd      = '0;
        xif_result_if.result.we      = '0;
        xif_result_if.result.exc     = '0;
        xif_result_if.result.exccode = '0;
        xif_result_if.result.err     = '0;
        xif_result_if.result.dbg     = '0;

        unique case (result_source)
            RESULT_SOURCE_EMPTY: begin
                `ifdef COMMIT_AND_ISSUE
                xif_result_if.result_valid = '0; //for CVA6 need to buffer result empty for one cycle
                `else
                xif_result_if.result_valid = result_empty_id_i == next_id_q; //only raise result valid if current instruction is the one the scalar core is waiting for (no out of order retiring)
                `endif
                xif_result_if.result.id    = result_empty_id_i;
            end
            RESULT_SOURCE_EMPTY_BUF: begin
                xif_result_if.result_valid = result_empty_id == next_id_q;
                //xif_result_if.result_valid = '1;
                xif_result_if.result.id    = result_empty_id;
            end
            RESULT_SOURCE_LSU: begin
                xif_result_if.result_valid   = result_lsu_id_i == next_id_q;
                //xif_result_if.result_valid = '1;
                xif_result_if.result.id      = result_lsu_id_i;
                xif_result_if.result.exc     = result_lsu_exc_i;
                xif_result_if.result.exccode = result_lsu_exccode_i;
            end
            RESULT_SOURCE_XREG: begin
                xif_result_if.result_valid = result_xreg_id_i == next_id_q;
                //xif_result_if.result_valid = '1;
                xif_result_if.result.id    = result_xreg_id_i;
                xif_result_if.result.data  = result_xreg_data_i;
                xif_result_if.result.rd    = result_xreg_addr_i;
                xif_result_if.result.we    = 1'b1;
            end
            RESULT_SOURCE_CSR_BUF: begin
                xif_result_if.result_valid = result_csr_id_q == next_id_q;
                //xif_result_if.result_valid = '1;
                xif_result_if.result.id    = result_csr_id_q;
                xif_result_if.result.data  = result_csr_delayed_q ? result_csr_data_delayed_i : result_csr_data_q;
                xif_result_if.result.rd    = result_csr_addr_q;
                xif_result_if.result.we    = 1'b1;
            end
            default: ;
        endcase
    end


`ifdef VPROC_SVA
`include "vproc_result_sva.svh"
`endif

endmodule
