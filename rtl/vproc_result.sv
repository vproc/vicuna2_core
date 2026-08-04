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

        output logic                result_fifo_full_stall_o,

        vproc_xif.coproc_result     xif_result_if,
        vproc_xif.coproc_commit     xif_commit_if
    );



  /////////////////
  // FIFO of committed XIF IDs.  Vicuna must signal result in the order in which the instructions were committed
  // additional signals are available (full/empty signalling) which can be used to stall the pipeline if necessary.  Tie these to issue interface? (Commit cannot stall)
  ////////////////
  logic [XIF_ID_W-1:0] res_id_fifo_out;
  logic                res_id_fifo_empty;
  logic                res_id_fifo_full;
  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (logic [XIF_ID_W-1:0]),
    .DEPTH        (4           )   //might need to be bigger?
  ) commit_id_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                                                   ),
    .data_i     (xif_commit_if.commit.id                                ),
    .push_i     (xif_commit_if.commit_valid & !xif_commit_if.commit.commit_kill),
    .data_o     (res_id_fifo_out                                        ),
    .pop_i      (xif_result_if.result_valid & xif_result_if.result_ready),
    .empty_o    (res_id_fifo_empty                                      ),
    .full_o     (res_id_fifo_full                                       )  // Commit interface cannot stall, stall issue interface instead.  For CVA6, this prevents offloading.  For CV32E40X, TODO: investigate this
  );

  assign result_fifo_full_stall_o = res_id_fifo_full;
  ////////////////
  // FIFO of results from each source.
  // Each source is guarunteed to signal in order, but might not be in order relative to each other (i.e. load vector load followed by an independent vector alu operation)
  // Buffering only necessary for most fifos if scalar core is not ready to receive the result (Use fallthrough mode)
  ///////////////

  // FIFO for empty result signalling.
  logic                pop_empty_id;
  logic [XIF_ID_W-1:0] empty_res_fifo_out;
  logic                empty_res_fifo_empty;

  fifo_v3 #(
    .FALL_THROUGH (1'b0       ), //FOR CVA6 CANNOT HAVE FALLTHROUGH ENABLED (Result must come at least one cycle after commit/issue)
    .dtype        (logic [XIF_ID_W-1:0]),
    .DEPTH        (4           )   //might need to be bigger?
  ) res_empty_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (result_empty_id_i             ),
    .push_i     (result_empty_valid_i          ),
    .data_o     (empty_res_fifo_out            ),
    .pop_i      (pop_empty_id                  ),
    .empty_o    (empty_res_fifo_empty          )
  );

  assign pop_empty_id = ((empty_res_fifo_out == res_id_fifo_out) & xif_result_if.result_ready) & !empty_res_fifo_empty;

  //FIFO for xreg result signalling : TODO: Extend to support floating point results  (Might need its own fifo since xreg result and freg result might not be signalled in order?)
  logic                pop_xreg_id;
  logic                xreg_res_fifo_empty;
  logic                xreg_res_fifo_full;

  typedef struct packed {
    logic [XIF_ID_W -     1:0] id;
    logic [              31:0] data;
    logic [               4:0] rd;
  } res_xreg_fifo_data;

  res_xreg_fifo_data xreg_res_fifo_in, xreg_res_fifo_out;

  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (res_xreg_fifo_data),
    .DEPTH        (4           )   //Can possibly be smaller?  (Likely impossible to have this many stalled XREG results since these must wait for the vector operation to complete)
  ) res_xreg_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (xreg_res_fifo_in              ),
    .push_i     (result_xreg_valid_i           ),
    .data_o     (xreg_res_fifo_out             ),
    .pop_i      (pop_xreg_id                   ),
    .empty_o    (xreg_res_fifo_empty           ),
    .full_o     (xreg_res_fifo_full            )
  );

  assign xreg_res_fifo_in.id = result_xreg_id_i;
  assign xreg_res_fifo_in.data = result_xreg_data_i;
  assign xreg_res_fifo_in.rd = result_xreg_addr_i;

  assign pop_xreg_id = ((xreg_res_fifo_out.id == res_id_fifo_out) & xif_result_if.result_ready) & !xreg_res_fifo_empty;

  assign result_xreg_ready_o = !xreg_res_fifo_full;

  // FIFO for VLSU result signalling
  logic                pop_vlsu_id;
  logic                vlsu_res_fifo_empty;
  logic                vlsu_res_fifo_full;

  typedef struct packed {
    logic [XIF_ID_W -     1:0] id;
    logic                      exc;
    logic [               5:0] exccode;
  } res_vlsu_fifo_data;

  res_vlsu_fifo_data vlsu_res_fifo_in, vlsu_res_fifo_out;
  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (res_vlsu_fifo_data),
    .DEPTH        (4           )   //Can possibly be smaller (likely impossible to have this many stalled VLSU results, these are often the oldest instructions with the longest time required to signal result)
  ) res_vlsu_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (vlsu_res_fifo_in              ),
    .push_i     (result_lsu_valid_i            ),
    .data_o     (vlsu_res_fifo_out             ),
    .pop_i      (pop_vlsu_id                   ),
    .empty_o    (vlsu_res_fifo_empty           ),
    .full_o     (vlsu_res_fifo_full            )
  );

  assign vlsu_res_fifo_in.id = result_lsu_id_i;
  assign vlsu_res_fifo_in.exc = result_lsu_exc_i;
  assign vlsu_res_fifo_in.exccode = result_lsu_exccode_i;

  assign pop_vlsu_id = ((vlsu_res_fifo_out.id == res_id_fifo_out) & xif_result_if.result_ready) & !vlsu_res_fifo_empty;

  assign result_lsu_ready_o = !vlsu_res_fifo_full;

  // Fifo for CSR signalling results.  Fall Through mode disabled here, since csr results must be buffered for at least one cycle
  logic                pop_csr_id;
  logic                csr_res_fifo_empty;
  logic                csr_res_fifo_full;

  logic                csr_fifo_push;

  logic                      csr_res_delay_q;
  logic [               4:0] csr_res_delay_addr_q;
  logic [XIF_ID_W -     1:0] csr_res_delay_id_q;

  typedef struct packed {
    logic [XIF_ID_W -     1:0] id;
    logic [              31:0] data;
    logic [               4:0] addr;
  } res_csr_fifo_data;

  res_csr_fifo_data csr_res_fifo_in, csr_res_fifo_out;
  fifo_v3 #(
    .FALL_THROUGH (1'b0        ),
    .dtype        (res_csr_fifo_data),
    .DEPTH        (4           )
  ) res_csr_fifo (
    .clk_i,
    .rst_ni     (sync_rst_ni),
    .flush_i    (1'b0                          ),
    .data_i     (csr_res_fifo_in               ),
    .push_i     (csr_fifo_push                 ),
    .data_o     (csr_res_fifo_out              ),
    .pop_i      (pop_csr_id                    ),
    .empty_o    (csr_res_fifo_empty            ),
    .full_o     (csr_res_fifo_full             )
  );

  assign csr_fifo_push = csr_res_delay_q | (result_csr_valid_i & !result_csr_delayed_i);

  assign csr_res_fifo_in.id = csr_res_delay_q ? csr_res_delay_id_q : result_csr_id_i;
  assign csr_res_fifo_in.data = csr_res_delay_q ? result_csr_data_delayed_i : result_csr_data_i;
  assign csr_res_fifo_in.addr = csr_res_delay_q ? csr_res_delay_addr_q : result_csr_addr_i;

  assign pop_csr_id = ((csr_res_fifo_out.id == res_id_fifo_out) & xif_result_if.result_ready) & !csr_res_fifo_empty;

  assign result_csr_ready_o = !csr_res_fifo_full & !csr_res_delay_q;

  always_ff @(posedge clk_i) begin
    if (~sync_rst_ni) begin
        csr_res_delay_q <= '0;
        csr_res_delay_addr_q <= '0;
        csr_res_delay_id_q <= '0;
    end else begin
        csr_res_delay_q <= result_csr_delayed_i;
        csr_res_delay_addr_q <= result_csr_addr_i;
        csr_res_delay_id_q <= result_csr_id_i;
    end
  end

  /////////////
  // Mux FIFO outputs to XIF_RESULT
  ////////////

  always_comb begin
    xif_result_if.result_valid = 1'b0;
    xif_result_if.result.id = res_id_fifo_out;
    xif_result_if.result.data = '0;
    xif_result_if.result.rd = '0;
    xif_result_if.result.we = '0;
    xif_result_if.result.exc = '0;
    xif_result_if.result.exccode = '0;
    xif_result_if.result.err = '0;
    xif_result_if.result.dbg = '0;

    if (pop_empty_id) begin
        xif_result_if.result_valid = 1'b1;

    end else if (pop_xreg_id) begin
        xif_result_if.result_valid = 1'b1;

        xif_result_if.result.data = xreg_res_fifo_out.data;
        xif_result_if.result.rd = xreg_res_fifo_out.rd;
        xif_result_if.result.we = 1'b1;

    end else if (pop_vlsu_id) begin
        xif_result_if.result_valid = 1'b1;

        xif_result_if.result.exc = vlsu_res_fifo_out.exc;
        xif_result_if.result.exccode = vlsu_res_fifo_out.exccode;

    end else if (pop_csr_id) begin
        xif_result_if.result_valid = 1'b1;

        xif_result_if.result.data = csr_res_fifo_out.data;
        xif_result_if.result.rd = csr_res_fifo_out.addr;
        xif_result_if.result.we = 1'b1;
    end
  end



`ifdef VPROC_SVA
`include "vproc_result_sva.svh"
`endif

endmodule
