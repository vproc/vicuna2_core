// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
import vproc_pkg::*;
module vproc_mem_port #(
    parameter int unsigned        PORT_WIDTH          = 32,
    parameter int unsigned        OUTSTANDING_REQ     = 1,
    parameter int unsigned        NUM_PORTS           = 1
)(
        input  logic                    clk_i,
        input  logic                    async_rst_ni,
        input  logic                    sync_rst_ni,

        input  logic                    valid_i,
        input  logic                    store_i,
        input  logic[PORT_WIDTH-1:0]    data_i,
        output logic                    ready_o,

        input  logic                    first_cycle_i,

        input  logic[31:0]              base_addr_i,
        input  logic[PORT_WIDTH/8-1:0]  mask_i,
        input  lsu_stride               stride_i,
        input  logic[31:0]              stride_val_i,

        OBI_BUS.Manager                 obi_bus,

        output logic                    valid_o,
        input  logic                    ready_i,
        output logic[PORT_WIDTH-1:0]    data_o,
        output logic[PORT_WIDTH/8-1:0]  mask_o
);
    //////////
    // Input Buffer and Calculation of the request addr
    //TODO: Generation of multiple requests to enforce word aligment for reads/writes
    //////////
    //TODO: Combine these into a metadata struct
    logic[31:0] req_addr_d, req_addr_q;
    logic[31:0] base_addr_d, base_addr_q;
    logic       valid_d, valid_q;
    logic[PORT_WIDTH/8-1:0] mask_d, mask_q;
    logic       store_d, store_q;
    logic[PORT_WIDTH-1:0] data_d, data_q;
    lsu_stride            stride_d, stride_q;
    logic[31:0] stride_val_d, stride_val_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            req_addr_q <= '0;
            valid_q <= '0;
            mask_q <= '0;
            store_q <= '0;
            data_q <= '0;
            stride_q <= LSU_UNITSTRIDE;
            stride_val_q <= '0;
            base_addr_q <= '0;
        end else begin
            req_addr_q <= req_addr_d;
            valid_q <= valid_d;
            mask_q <= mask_d;
            store_q <= store_d;
            data_q <= data_d;
            stride_q <= stride_d;
            stride_val_q <= stride_val_d;
            base_addr_q <= base_addr_d;
        end
    end

    always_comb begin 
        req_addr_d = req_addr_q;
        mask_d = mask_q;
        store_d = store_q;
        data_d = data_q;
        stride_d = stride_q;
        stride_val_d = stride_val_q;
        base_addr_d = base_addr_q;

        if (valid_i & ready_o) begin
            mask_d = mask_i;
            data_d = data_i;
            if (first_cycle_i) begin
                req_addr_d = (stride_i == LSU_INDEXED) ? base_addr_i + stride_val_i: base_addr_i;
                base_addr_d = base_addr_i;
                store_d = store_i;
                stride_d = stride_i;
                stride_val_d = stride_val_i;
            end else begin
                unique case (stride_q)
                    LSU_UNITSTRIDE: req_addr_d = req_addr_q + PORT_WIDTH/8 * NUM_PORTS; //Stride between requests split between number of ports
                    LSU_STRIDED:    req_addr_d = req_addr_q + stride_val_q * NUM_PORTS;
                    LSU_INDEXED:    req_addr_d = base_addr_q + stride_val_i;                //Indexed ops use stride input as an offset
                endcase
            end
        end

        valid_d = valid_i & ready_o;
    end

    ///////////
    // Queue of Outstanding requests
    ///////////

    typedef struct packed {
        logic[PORT_WIDTH/8-1:0] mask;
        logic[$bits(obi_bus.rid)-1:0] req_id; //TODO: support out of order response of requests
    } req_metadata_t;

    req_metadata_t req_queue_data_in, req_queue_data_out;
    assign req_queue_data_in.mask = mask_q;
    assign req_queue_data_in.req_id = '0;

    logic req_queue_full;
    fifo_v3 #(
    .FALL_THROUGH (1'b0      ),
    .dtype        (req_metadata_t),
    .DEPTH        (OUTSTANDING_REQ)
    ) outstanding_req_queue (
        .clk_i,
        .rst_ni     (sync_rst_ni),
        .flush_i    (1'b0       ),
        .data_i     ( req_queue_data_in ),
        .push_i     ( obi_bus.req & obi_bus.gnt ),
        .data_o     ( req_queue_data_out        ),
        .pop_i      ( ((!resp_queue_empty | obi_bus.rvalid)) & (req_queue_data_out.req_id == resp_queue_data_out.req_id) & ready_i),
        .empty_o    (),
        .full_o     ( req_queue_full )
    );

    ///////////
    // Input handshake signals
    //////////
    assign ready_o = !req_queue_full; //Ready for next input if queue is ready and obi bus is granted

    ///////////
    // Generation of OBI memory request
    ///////////

    assign obi_bus.req = !req_queue_full & valid_q; //TODO: Suppress requests if past end of vl or completely masked off
    assign obi_bus.addr = |mask_q ? req_addr_q : '0;               //TODO: For above, adjust this line.  Currently set to force a valid address if masked out access is attempted
    assign obi_bus.we   = store_q;
    assign obi_bus.be   = mask_q;
    assign obi_bus.wdata = data_q;
    assign obi_bus.aid = '0; //TODO: Support multiple outstanding requests

    //////////
    // Queue of Responses //TODO: Buffer responses in case they return out of order using IDs
    //////////
    typedef struct packed {
        logic[$bits(obi_bus.rid)-1:0] req_id; //TODO: support out of order response of requests
        logic[PORT_WIDTH-1:0] data;
    } resp_data_t;

    resp_data_t resp_queue_data_in, resp_queue_data_out;

    assign resp_queue_data_in.req_id = obi_bus.rid;
    assign resp_queue_data_in.data = obi_bus.rdata;

    logic resp_queue_push, resp_queue_pop, resp_queue_empty;

    fifo_v3 #(
    .FALL_THROUGH (1'b1      ),  //Fallthrough mode allowed for responses?
    .dtype        (resp_data_t),
    .DEPTH        (OUTSTANDING_REQ)
    ) response_queue (
        .clk_i,
        .rst_ni     (sync_rst_ni),
        .flush_i    (1'b0       ),
        .data_i     ( resp_queue_data_in ),
        .push_i     ( obi_bus.rvalid ),
        .data_o     ( resp_queue_data_out        ),
        .pop_i      ( (!resp_queue_empty | obi_bus.rvalid) & (req_queue_data_out.req_id == resp_queue_data_out.req_id) & ready_i),
        .empty_o    ( resp_queue_empty ),
        .full_o     ( )
    );

    //////////
    // Output assignments
    //////////

    assign valid_o = (!resp_queue_empty | obi_bus.rvalid) & (req_queue_data_out.req_id == resp_queue_data_out.req_id);
    assign mask_o = req_queue_data_out.mask;
    assign data_o = resp_queue_data_out.data;

endmodule


module vproc_lsu #(
        parameter int unsigned        MAX_OP_W        = 32,
        parameter int unsigned        VMEM_W          = 32,   // width in bits of the vector memory interface
        parameter int unsigned        VLEN            = 128,   // width in bits of a vector register
        parameter int unsigned        MEM_PORTS       = 1,
        parameter bit                 BUF_REQUEST     = 1'b1, // insert pipeline stage before issuing request
        parameter bit                 BUF_RDATA       = 1'b1, // insert pipeline stage after memory read
        parameter type                CTRL_T          = logic,
        parameter int unsigned        XIF_ID_W        = 3,    // width in bits of instruction IDs
        parameter int unsigned        XIF_ID_CNT      = 8,    // total count of instruction IDs
        parameter int unsigned           VLSU_QUEUE_SZ = 4,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS    = '0,
        parameter int unsigned        PORT_QUEUE_DEPTH = 2,
        parameter int unsigned        OUTSTANDING_REQ  = 2,
        parameter bit                 DONT_CARE_ZERO  = 1'b0  // initialize don't care values to zero,
    )
    (
        input  logic                  clk_i,
        input  logic                  async_rst_ni,
        input  logic                  sync_rst_ni,

        input  logic                  pipe_in_valid_i,
        output logic                  pipe_in_ready_o,
        input  CTRL_T                 pipe_in_ctrl_i,
        input  logic [MAX_OP_W-1:0]   pipe_in_op1_i,
        input  logic [MAX_OP_W-1:0]   pipe_in_op2_i,
        input  logic [MAX_OP_W-1:0]   pipe_in_op3_i,
        input logic                   pipe_in_op3_valid_i,
        output logic                  pipe_in_op3_ready_o,
        input  logic [MAX_OP_W/8  -1:0] pipe_in_mask_i,

        output logic [MEM_PORTS-1:0]  pipe_out_valid_o,
        input  logic                  pipe_out_ready_i,
        output CTRL_T                 pipe_out_ctrl_o,
        output logic                  pipe_out_pend_clr_o,
        output logic [MAX_OP_W-1:0]   pipe_out_res_o,
        output logic [MAX_OP_W/8-1:0] pipe_out_mask_o,

        output logic                  pending_load_o,
        output logic                  pending_store_o,

        input  logic [31:0]           vreg_pend_rd_i,

        input  instr_state [XIF_ID_CNT-1:0] instr_state_i,

        output logic                  trans_complete_valid_o,
        input  logic                  trans_complete_ready_i,
        output logic [XIF_ID_W-1:0]   trans_complete_id_o,
        output logic                  trans_complete_exc_o,
        output logic [5:0]            trans_complete_exccode_o,

        OBI_BUS.Manager               obi_bus [MEM_PORTS-1:0]
    );


    logic [MEM_PORTS-1:0] ports_ready_i, ports_valid_o;

    assign pipe_in_ready_o = &ports_ready_i;
    assign pipe_out_valid_o = &ports_valid_o;


    /////////
    // Top level control of memory ports
    /////////

    typedef struct packed {
    logic [31:0]            next_base_addr;
    logic [31:0]            stride;
    logic [2:0]             nfields_remaining;
    logic [$clog2(VLEN*8/8) :0] vl_remaining;  //maximum value is LMUL8 SEW8 elements
    cfg_vsew                eew;
    logic                   indexed_op_clear;
    } vlsu_ctrl;

    vlsu_ctrl lsu_ctrl_d, lsu_ctrl_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            lsu_ctrl_q <= '0;
        end else begin
            lsu_ctrl_q <= lsu_ctrl_d;
        end
    end

    //Buffer for pipeline metadata

    CTRL_T metadata_d, metadata_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            metadata_q <= CTRL_T'(DONT_CARE_ZERO ? '0 : 'x);;
        end else begin
            metadata_q <= metadata_d;
        end
    end

    always_comb begin
        metadata_d = metadata_q;
        if (pipe_in_valid_i & pipe_out_ready_i) begin
            metadata_d = pipe_in_ctrl_i;
        end
    end

    /////////
    //  op3 handling for indexed ops
    //  index might have extra data that is not processed, needs to be cleared
    //  this signal is in parallel to the main ready signal handled in unit_wrapper
    ////////

    assign pipe_in_op3_ready_o = lsu_ctrl_q.indexed_op_clear;

    /////////
    // Top level signal control for ports
    // These signals are only relevant for segmented operation, so input operands are assumed to be elemwise
    /////////

    //stride value calculation //TODO: Will need to scale for multiple ports in indexed case
    logic [31:0] stride_val_i;
    always_comb begin
        stride_val_i = pipe_in_ctrl_i.op_xval[0];
        if (pipe_in_ctrl_i.mode.lsu.stride == LSU_INDEXED) begin //indexed takes stride values from vreg op3
            case (pipe_in_ctrl_i.decode_metadata.operands[2].sew)
                VSEW_32: stride_val_i = pipe_in_op3_i[31:0];
                VSEW_16: stride_val_i = {{(16){1'b0}}, pipe_in_op3_i[15:0]};
                VSEW_8:  stride_val_i = {{(24){1'b0}}, pipe_in_op3_i[7:0]};
            endcase
        end
    end

    always_comb begin
        lsu_ctrl_d = lsu_ctrl_q;
        lsu_ctrl_d.indexed_op_clear = (pipe_in_ctrl_i.last_cycle & pipe_in_ctrl_i.mode.lsu.stride == LSU_INDEXED) | lsu_ctrl_q.indexed_op_clear & pipe_in_op3_valid_i;
        if (pipe_in_ctrl_i.first_cycle & !(pipe_in_ctrl_i.mode.lsu.nfields == '0)) begin //Latch values on first cycle for segmented operation
            lsu_ctrl_d.nfields_remaining = pipe_in_ctrl_i.mode.lsu.nfields;
            lsu_ctrl_d.eew = pipe_in_ctrl_i.decode_metadata.operands[1].sew; //take eew of one of the data operands (all are the same)
            lsu_ctrl_d.stride = stride_val_i;
            //VLMAX given in number of elements, fractional lmuls need to be raised to one whole register
            unique case (pipe_in_ctrl_i.decode_metadata.operands[1].sew)
                    VSEW_32: begin
                            lsu_ctrl_d.vl_remaining = pipe_in_ctrl_i.vlmax - (MEM_PORTS); //TODO: Allow VREGUNPACK to scale amount of data per port
                            lsu_ctrl_d.next_base_addr = pipe_in_ctrl_i.op_xval[1] + 4;
                    end
                    VSEW_16: begin
                            lsu_ctrl_d.vl_remaining = pipe_in_ctrl_i.vlmax - (MEM_PORTS);
                            lsu_ctrl_d.next_base_addr = pipe_in_ctrl_i.op_xval[1] + 2;
                    end
                    VSEW_8:  begin
                        //lsu_ctrl_d.vl_remaining = (pipe_in_ctrl_i.vlmax > VLEN/8)  ? pipe_in_ctrl_i.vlmax - (MEM_PORTS) : VLEN/8  - (MEM_PORTS);
                        lsu_ctrl_d.vl_remaining = pipe_in_ctrl_i.vlmax - (MEM_PORTS);
                        lsu_ctrl_d.next_base_addr = pipe_in_ctrl_i.op_xval[1] + 1;
                    end
            endcase
        end else if (pipe_in_valid_i & pipe_in_ready_o) begin //On a port accepting a memory transaction, decrement total number of elems left to process, or reset value for next segment
            if (lsu_ctrl_q.vl_remaining == 0) begin
                unique case (pipe_in_ctrl_i.decode_metadata.operands[1].sew)
                    VSEW_32: begin
                            lsu_ctrl_d.vl_remaining = metadata_q.vlmax - (MEM_PORTS); //TODO: Allow VREGUNPACK to scale amount of data per port
                            lsu_ctrl_d.next_base_addr = lsu_ctrl_q.next_base_addr + 4;
                    end
                    VSEW_16: begin
                            lsu_ctrl_d.vl_remaining = metadata_q.vlmax - (MEM_PORTS);
                            lsu_ctrl_d.next_base_addr = lsu_ctrl_q.next_base_addr + 2;
                    end
                    VSEW_8:  begin
                            lsu_ctrl_d.vl_remaining = metadata_q.vlmax - (MEM_PORTS);
                            lsu_ctrl_d.next_base_addr = lsu_ctrl_q.next_base_addr + 1;
                    end
                endcase
            end else begin
                lsu_ctrl_d.vl_remaining = lsu_ctrl_q.vl_remaining - (MEM_PORTS);
            end
        end
    end


    /////////
    //  Input routing for standard vs optimized segmented operations
    /////////

    logic [MEM_PORTS-1:0][VMEM_W-1:0] port_data_in;
    logic [MEM_PORTS-1:0][VMEM_W/8-1:0] port_mask_in;

    generate
        for (genvar i = 0; i < MEM_PORTS; i++) begin
            always_comb begin
                unique case (pipe_in_ctrl_i.mode.lsu.nfields)
                    default: begin
                    //3'b000: begin
                            //Non-Segmented Case
                            port_data_in[i][VMEM_W-1:0] = pipe_in_op2_i[(i * VMEM_W) +: VMEM_W];
                            port_mask_in[i][VMEM_W/8-1:0] = pipe_in_mask_i[(i * VMEM_W/8) +: VMEM_W/8];

                    end

                    //TODO: Reenable the optimized cases for segment operations based on MEM_W + NFIELDS
                    // //For segmented cases, 1 element from each input op per register group (TODO: Can potentially scale to multiple ports this way by loading/shifting more data per cycle)
                    // 3'b001: begin //2 segments
                    //         unique case (pipe_in_ctrl_i.eew)
                    //             VSEW_8: begin
                    //                 port_data_in[i][VMEM_W-1:0] = {{(VMEM_W-(2*8)){1'b0}}, pipe_in_op1_i[i * 8 +: 8], pipe_in_op2_i[i * 8 +: 8]};
                    //                 port_mask_in[i][VMEM_W/8-1:0] = {{(VMEM_W/8-2){1'b0}}, {(2){pipe_in_mask_i[i]}}}; //Mask applies to both elements being loaded/stored
                    //             end
                    //             VSEW_16: begin
                    //                 port_data_in[i][VMEM_W-1:0] = {{(VMEM_W-(2*16)){1'b0}}, pipe_in_op1_i[i * 16 +: 16], pipe_in_op2_i[i * 16 +: 16]};
                    //                 port_mask_in[i][VMEM_W/8-1:0] = {{(VMEM_W/8-(2*2)){1'b0}}, {(4){pipe_in_mask_i[i*2 +: 2]}}}; //Mask applies to both elements being loaded/stored
                    //             end
                    //             //TODO: 32 bit case depends on VMEM_W
                    //             default: begin
                    //                 port_data_in[i] = '0;
                    //                 port_mask_in[i] = '0;
                    //             end
                    //         endcase
                    // end
                    // 3'b010: begin //3 segments
                    //         unique case (pipe_in_ctrl_i.eew)
                    //             VSEW_8: begin
                    //                 port_data_in[i][VMEM_W-1:0] = {{(VMEM_W-(3*8)){1'b0}}, pipe_in_op3_i[i * 8 +: 8], pipe_in_op1_i[i * 8 +: 8], pipe_in_op2_i[i * 8 +: 8]};
                    //                 port_mask_in[i][VMEM_W/8-1:0] = {{(VMEM_W/8-3){1'b0}}, {(3){pipe_in_mask_i[i]}}}; //Mask applies to both elements being loaded/stored
                    //             end
                    //             //TODO: 16 and 32 bit case depends on VMEM_W
                    //             // VSEW_16: begin
                    //             //     port_data_in[i][VMEM_W-1:0] = {{(VMEM_W-2*16){1'b0}}, pipe_in_op1_i[i * 16 +: 16], pipe_in_op2_i[i * 16 +: 16]};
                    //             //     port_mask_in[i][VMEM_W/8-1:0] = {{(VMEM_W/8-2*2){1'b0}}, {(4){pipe_in_mask_i[i*2 +: 2]}}}; //Mask applies to both elements being loaded/stored
                    //             // end
                    //             default: begin
                    //                 port_data_in[i] = '0;
                    //                 port_mask_in[i] = '0;
                    //             end
                    //         endcase
                    // end
                    //TODO: Cases for additional fields here
                    // default: begin //TODO: Should be possible to remove this case
                    //             port_data_in[i] = '0;
                    //             port_mask_in[i] = '0;
                    // end
                endcase
            end
        end
    endgenerate

    ////////
    // Instantiation of memory ports
    ////////

    logic port_first_cycle;
    assign port_first_cycle = pipe_in_ctrl_i.first_cycle | !(pipe_in_ctrl_i.mode.lsu.nfields == '0) & (lsu_ctrl_q.vl_remaining == '0);

    //TODO: Will need a different base address for every memory port
    logic [31:0] base_addr, stride_val;

    assign base_addr = pipe_in_ctrl_i.first_cycle ? pipe_in_ctrl_i.op_xval[1] : lsu_ctrl_q.next_base_addr;
    assign stride_val = (pipe_in_ctrl_i.first_cycle | pipe_in_ctrl_i.mode.lsu.stride == LSU_INDEXED) ? stride_val_i : lsu_ctrl_q.stride;

    generate
        for (genvar i = 0; i < MEM_PORTS; i++) begin //TODO: Definitely issues with signalling with multiple ports, untested
            vproc_mem_port #(
                .PORT_WIDTH(VMEM_W),
                .OUTSTANDING_REQ(OUTSTANDING_REQ),
                .NUM_PORTS(MEM_PORTS)
            ) mem_port (
                .clk_i(clk_i),
                .sync_rst_ni(sync_rst_ni),
                .valid_i(pipe_in_valid_i),
                .store_i(pipe_in_ctrl_i.mode.lsu.store),
                .data_i(port_data_in[i]),
                .ready_o(ports_ready_i[i]),
                .first_cycle_i(port_first_cycle),
                .base_addr_i(base_addr),
                .mask_i(port_mask_in[i]),
                .stride_i(pipe_in_ctrl_i.mode.lsu.stride),
                .stride_val_i(stride_val),
                .obi_bus(obi_bus[i]),
                .valid_o(ports_valid_o[i]),
                .ready_i(pipe_out_ready_i),
                .data_o(pipe_out_res_o[(VMEM_W)*i +: VMEM_W]),
                .mask_o(pipe_out_mask_o[(VMEM_W/8)*i +:VMEM_W/8])
            );
        end
    endgenerate




    // Buffer for first/last cycle signals
    logic[1:0] metadata_in, metadata_out;

    assign metadata_in[0] = pipe_in_ctrl_i.first_cycle;
    assign metadata_in[1] = pipe_in_ctrl_i.last_cycle;


    fifo_v3 #(
    .FALL_THROUGH (1'b0      ),
    .dtype        (logic[1:0]), //TODO: Likely only need to buffer first/last_cycle signals
    .DEPTH        (OUTSTANDING_REQ + 1) //due to latching of addresses in each port, an extra entry of metadata storage is required
    ) metadata_queue (
        .clk_i,
        .rst_ni     (sync_rst_ni),
        .flush_i    (1'b0       ),
        .data_i     ( metadata_in ),
        .push_i     ( pipe_in_valid_i & pipe_in_ready_o ),
        .data_o     ( metadata_out        ),
        .pop_i      ( pipe_out_valid_o & pipe_out_ready_i),
        .empty_o    (),
        .full_o     ()
    );


    always_comb begin
        pipe_out_ctrl_o = metadata_q;
        pipe_out_ctrl_o.first_cycle = metadata_out[0];
        pipe_out_ctrl_o.last_cycle = metadata_out[1];
    end

    //Transaction complete signalling for the result interface
    always_comb begin
        trans_complete_valid_o = pipe_out_ctrl_o.last_cycle & pipe_out_valid_o;
        trans_complete_exc_o = '0; //TODO: Currently, memory system cannot fault
        trans_complete_exccode_o = '0; //TODO: Currently, memory system cannot fault
        trans_complete_id_o = pipe_out_ctrl_o.id;

    end
endmodule
