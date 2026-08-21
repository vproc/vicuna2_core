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
    assign obi_bus.addr = req_addr_q;
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

    logic test_stride_cond;
    assign test_stride_cond = pipe_in_ctrl_i.mode.lsu.stride == LSU_INDEXED;


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
                            lsu_ctrl_d.vl_remaining = (pipe_in_ctrl_i.vlmax > VLEN/32) ? pipe_in_ctrl_i.vlmax - (MEM_PORTS) : VLEN/32 - (MEM_PORTS); //TODO: Allow VREGUNPACK to scale amount of data per port
                            lsu_ctrl_d.next_base_addr = pipe_in_ctrl_i.op_xval[1] + 4;
                    end
                    VSEW_16: begin
                            lsu_ctrl_d.vl_remaining = (pipe_in_ctrl_i.vlmax > VLEN/16) ? pipe_in_ctrl_i.vlmax - (MEM_PORTS) : VLEN/16 - (MEM_PORTS);
                            lsu_ctrl_d.next_base_addr = pipe_in_ctrl_i.op_xval[1] + 2;
                    end
                    VSEW_8:  begin
                        lsu_ctrl_d.vl_remaining = (pipe_in_ctrl_i.vlmax > VLEN/8)  ? pipe_in_ctrl_i.vlmax - (MEM_PORTS) : VLEN/8  - (MEM_PORTS);
                        lsu_ctrl_d.next_base_addr = pipe_in_ctrl_i.op_xval[1] + 1;
                    end
            endcase
        end else if (pipe_in_valid_i & pipe_in_ready_o) begin //On a port accepting a memory transaction, decrement total number of elems left to process, or reset value for next segment
            if (lsu_ctrl_q.vl_remaining == 0) begin
                unique case (pipe_in_ctrl_i.decode_metadata.operands[1].sew)
                    VSEW_32: begin
                            lsu_ctrl_d.vl_remaining = (metadata_q.vlmax > VLEN/32) ? metadata_q.vlmax - (MEM_PORTS) : VLEN/32 - (MEM_PORTS); //TODO: Allow VREGUNPACK to scale amount of data per port
                            lsu_ctrl_d.next_base_addr = lsu_ctrl_q.next_base_addr + 4;
                    end
                    VSEW_16: begin
                            lsu_ctrl_d.vl_remaining = (metadata_q.vlmax > VLEN/16) ? metadata_q.vlmax - (MEM_PORTS) : VLEN/16 - (MEM_PORTS);
                            lsu_ctrl_d.next_base_addr = lsu_ctrl_q.next_base_addr + 2;
                    end
                    VSEW_8:  begin
                            lsu_ctrl_d.vl_remaining = (metadata_q.vlmax > VLEN/8)  ? metadata_q.vlmax - (MEM_PORTS) : VLEN/8  - (MEM_PORTS);
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


//     // reduced LSU state for passing through the queue
//     typedef struct packed {
//         logic                        state_req_valid_q;
//         logic                        state_req_valid_d;
//         logic                        first_cycle;
//         logic                        last_cycle;
//         logic [XIF_ID_W-1:0]         id;
//         op_mode_lsu                  mode;
//         logic [$clog2(VMEM_W/8)-1:0] vl_part;
//         logic                        vl_part_0;
//         logic                        last_vl_part;
//         logic [4:0]                  res_vaddr;
//         logic                        res_store;
//         logic                        res_shift;
//         logic [MEM_PORTS-1:0]        suppressed;
//         logic                        exc;
//         logic [5:0]                  exccode;
//         logic [5:0]                  vreg_idx; //Needed for PACK
//         logic [MEM_PORTS-1:0][31:0]  req_addr_q;
//         logic [MEM_PORTS-1:0][VMEM_W-1:0]         wdata_buf_q;
//         logic [MEM_PORTS-1:0][VMEM_W/8-1:0]       wmask_buf_q;
//         logic [MEM_PORTS-1:0][VMEM_W/8-1:0]       vmsk_tmp_q;
//         logic [2:0]                  field_init_count;
//         logic [MEM_PORTS-1:0][2:0]   field_counter;
//         logic [MEM_PORTS-1:0][$clog2(VMEM_W/8)-1:0] mem_req_vl_part;
//         logic [MEM_PORTS-1:0]        mem_req_vl_part_0;
//         logic [MEM_PORTS-1:0]        mem_req_valid;
//         logic                        field_done;
//     } lsu_state_red;

//     ///////////////////////////////////////////////////////////////////////////
//     // LSU BUFFERS
    
//     logic         state_req_ready,   lsu_queue_ready;
//     logic         state_req_valid_q, state_req_valid_d, state_rdata_valid;
//     CTRL_T        state_req_q,       state_req_d;
//     lsu_state_red state_rdata;

//     logic fsm_load, fsm_store;

//     assign pending_load_o  = (state_req_valid_q & ~state_req_q.mode.lsu.store) | fsm_load;
//     assign pending_store_o = (state_req_valid_q &  state_req_q.mode.lsu.store) | fsm_store;

//     // request address:
//     logic [7:0][31:0] req_addr_save_q;
//     logic [7:0][31:0] req_addr_save_d;

//     logic [MEM_PORTS-1:0][31:0] req_addr_q;
//     logic [MEM_PORTS-1:0][31:0] req_addr_d;

//     // store data and mask buffers:
//     logic [MEM_PORTS-1:0][VMEM_W-1:0] wdata_buf_q; 
//     logic [MEM_PORTS-1:0][VMEM_W-1:0] wdata_buf_d;
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] wmask_buf_q;
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] wmask_buf_d;

//     // temporary buffer for byte mask during request:
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] vmsk_tmp_q;
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] vmsk_tmp_d;

//     logic [VMEM_W   -1:0] rdata_buf [MEM_PORTS-1:0];
//     logic [VMEM_W/8 -1:0] rmask_buf [MEM_PORTS-1:0];

//     generate
//         if (BUF_REQUEST) begin
//              always_ff @(posedge clk_i or negedge async_rst_ni) begin : vproc_lsu_stage_req_valid
//                 if (~async_rst_ni) begin
//                     state_req_valid_q <= 1'b0;
//                 end
//                 else if (~sync_rst_ni) begin
//                     state_req_valid_q <= 1'b0;
//                 end
//                 else if (state_req_ready) begin
//                     state_req_valid_q <= state_req_valid_d;
//                 end
//             end
//             always_ff @(posedge clk_i) begin : vproc_lsu_stage_req
//                 if (state_req_ready & state_req_valid_d) begin
//                     state_req_q <= state_req_d;
//                     req_addr_q  <= req_addr_d;
//                     req_addr_save_q  <= req_addr_save_d;
//                     wdata_buf_q <= wdata_buf_d;
//                     wmask_buf_q <= wmask_buf_d;
//                     vmsk_tmp_q  <= vmsk_tmp_d;
//                 end
//             end
//         end else begin
//             always_comb begin
//                 state_req_valid_q = state_req_valid_d;
//                 state_req_q       = state_req_d;
//                 req_addr_q        = req_addr_d;
//                 req_addr_save_q   = req_addr_save_d;
//                 wdata_buf_q       = wdata_buf_d;
//                 wmask_buf_q       = wmask_buf_d;
//                 vmsk_tmp_q        = vmsk_tmp_d;
//             end
//         end

//     endgenerate

//     ///////////////////////////////////////////////////////////////////////////
//     // LSU READ/WRITE

//     assign state_req_valid_d = pipe_in_valid_i;
//     assign state_req_d       = pipe_in_ctrl_i;
//     assign pipe_in_ready_o   = state_req_ready;

//     logic [MAX_OP_W-1:0] vs2_data;
//     logic [MAX_OP_W-1:0] vs3_data;
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] vmsk_data;
//     assign vs2_data  = pipe_in_op1_i;
//     assign vs3_data  = pipe_in_op2_i;

//     logic [31:0] test_x1;
//     assign test_x1 = pipe_in_ctrl_i.op_xval[1];

//     logic test_unitstride;

//     // compose memory address:
//     always_comb begin
//         req_addr_d = req_addr_q;
//         req_addr_save_d = req_addr_save_q;
//         test_unitstride = 1'b0;
//         unique case (pipe_in_ctrl_i.mode.lsu.stride)

//             LSU_UNITSTRIDE: begin
                
//                 for(int i = 0; i < MEM_PORTS; i++) begin
//                     if(pipe_in_ctrl_i.field_init_count == 0 & pipe_in_valid_i) begin
//                         if(pipe_in_ctrl_i.first_cycle & i == 0) begin
//                             req_addr_d[i] = pipe_in_ctrl_i.op_xval[1];
//                             test_unitstride = 1'b1;
//                         end else if (i == 0) begin
//                             req_addr_d[i] = req_addr_save_q[0];
//                         end else begin
//                             req_addr_d[i] = req_addr_d[i-1] + 32'(VMEM_W / 8);
//                         end

//                         req_addr_save_d[0] = req_addr_d[i] + 32'(VMEM_W / 8);  

//                     end else begin
//                         if(pipe_in_ctrl_i.first_cycle & pipe_in_valid_i) begin

//                             unique case (pipe_in_ctrl_i.eew)
//                                 VSEW_8:  req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(1 * pipe_in_ctrl_i.field_counter[i]);
//                                 VSEW_16: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(2 * pipe_in_ctrl_i.field_counter[i]);
//                                 VSEW_32: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(4 * pipe_in_ctrl_i.field_counter[i]);
//                                 default: ;
//                             endcase

//                             req_addr_save_d[pipe_in_ctrl_i.field_counter[i]] = req_addr_d[i];

//                         end else if(pipe_in_valid_i) begin
//                             req_addr_d[i] = req_addr_save_q[pipe_in_ctrl_i.field_counter[i]] + 32'(VMEM_W / 8);
//                             req_addr_save_d[pipe_in_ctrl_i.field_counter[i]] = req_addr_d[i];
//                         end
//                     end
//                 end 
//             end
//             LSU_STRIDED: begin   

//                 for(int i = 0; i < MEM_PORTS; i++) begin
//                     if(pipe_in_ctrl_i.field_init_count == 0 & pipe_in_valid_i) begin
//                         if(pipe_in_ctrl_i.first_cycle & i == 0) begin
//                             req_addr_d[i] = pipe_in_ctrl_i.op_xval[1];
//                         end else if (i == 0) begin
//                             req_addr_d[i] = req_addr_save_q[0];
//                         end else begin
//                             req_addr_d[i] = req_addr_d[i-1] + pipe_in_ctrl_i.op_xval[1];
//                         end

//                         req_addr_save_d[0] = req_addr_d[i] + pipe_in_ctrl_i.op_xval[1];  

//                     end else begin
//                         if(pipe_in_ctrl_i.first_cycle & pipe_in_valid_i) begin

//                             unique case (pipe_in_ctrl_i.eew)
//                                 VSEW_8:  req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(1 * pipe_in_ctrl_i.field_counter[i]);
//                                 VSEW_16: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(2 * pipe_in_ctrl_i.field_counter[i]);
//                                 VSEW_32: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(4 * pipe_in_ctrl_i.field_counter[i]);
//                                 default: ;
//                             endcase

//                             req_addr_save_d[pipe_in_ctrl_i.field_counter[i]] = req_addr_d[i];

//                         end else if(pipe_in_valid_i) begin
//                             req_addr_d[i] = req_addr_save_q[pipe_in_ctrl_i.field_counter[i]] + pipe_in_ctrl_i.op_xval[1];
//                             req_addr_save_d[pipe_in_ctrl_i.field_counter[i]] = req_addr_d[i];
//                         end
//                     end
//                 end 
//             end
//             LSU_INDEXED: begin
//                 // note: the index is multiplied by the element byte width and the field count
//                 for(int i = 0; i < MEM_PORTS; i++) begin
//                     if(pipe_in_ctrl_i.field_init_count == 0) begin
//                         unique case (pipe_in_ctrl_i.mode.lsu.alt_eew)
//                             VSEW_8:  req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(vs2_data[8*i +: 8]);
//                             VSEW_16: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(vs2_data[16*i +: 16]);
//                             VSEW_32: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(vs2_data[32*i +: 32]);
//                             default: ;
//                         endcase
//                     end else begin
//                         logic [MEM_PORTS-1:0][31:0] segment_offset;
//                         segment_offset = '{default: '0};

//                         unique case (pipe_in_ctrl_i.eew)
//                             VSEW_8:  segment_offset[i] = 32'(1 * pipe_in_ctrl_i.field_counter[i]);
//                             VSEW_16: segment_offset[i] = 32'(2 * pipe_in_ctrl_i.field_counter[i]);
//                             VSEW_32: segment_offset[i] = 32'(4 * pipe_in_ctrl_i.field_counter[i]);
//                             default: ;
//                         endcase

//                         unique case (pipe_in_ctrl_i.mode.lsu.alt_eew)
//                             VSEW_8:  req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(vs2_data[7 : 0]) + segment_offset[i];
//                             VSEW_16: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(vs2_data[15: 0]) + segment_offset[i];
//                             VSEW_32: req_addr_d[i] = pipe_in_ctrl_i.op_xval[1] + 32'(vs2_data[31: 0]) + segment_offset[i];
//                             default: ;
//                         endcase
//                     end
//                 end
//             end
//             default: ;
//         endcase
//     end

//     generate
//         for (genvar i = 0; i < MEM_PORTS; i++) begin
//             // write data conversion and masking:
//             logic [VMEM_W/8-1:0] wdata_unit_vl_mask;
//             logic wdata_stri_mask;
//             logic element_active;

//             always_comb begin
//                 wdata_buf_d[i] = DONT_CARE_ZERO ? '0 : 'x;
//                 wmask_buf_d[i] = DONT_CARE_ZERO ? '0 : 'x;

//                 //just pass mask
//                 wdata_unit_vl_mask = pipe_in_mask_i[VMEM_W/8-1:0];

//                 vmsk_data[i] = pipe_in_mask_i[VMEM_W/8-1:0];

//                 if(pipe_in_ctrl_i.field_init_count == 0 & pipe_in_ctrl_i.mode.lsu.stride != LSU_UNITSTRIDE) begin
//                     unique case (pipe_in_ctrl_i.mode.lsu.eew)
//                         VSEW_8:  vmsk_data[i][0] = pipe_in_mask_i[i];
//                         VSEW_16: vmsk_data[i][1:0] = pipe_in_mask_i[2*i +: 2];
//                         VSEW_32: vmsk_data[i][3:0] = pipe_in_mask_i[4*i +: 4];
//                         default: ;
//                     endcase
//                 end else if(pipe_in_ctrl_i.field_init_count == 0) begin
//                     vmsk_data[i][VMEM_W/8-1:0] = pipe_in_mask_i[VMEM_W/8*i +: VMEM_W/8];
//                 end

//                 element_active = vmsk_data[i];

//                 wdata_stri_mask    = ~pipe_in_ctrl_i.mem_req_vl_part_0[i] &
//                                         (pipe_in_ctrl_i.mode.lsu.masked ? element_active : 1'b1);


//                 if (pipe_in_ctrl_i.mode.lsu.stride == LSU_UNITSTRIDE) begin
//                     wdata_buf_d[i] = vs3_data[i*VMEM_W +: VMEM_W];
//                     wmask_buf_d[i] = (pipe_in_ctrl_i.mode.lsu.masked ? vmsk_data[i] : '1) & wdata_unit_vl_mask;
//                 end else begin
//                     unique case (pipe_in_ctrl_i.mode.lsu.eew)
//                         VSEW_8:  begin
//                             wdata_buf_d[i] = vs3_data[i*8 +: 8];
//                             wmask_buf_d[i] = {{VMEM_W/8-1{1'b0}},    wdata_stri_mask  };
//                         end
//                         VSEW_16: begin
//                             wdata_buf_d[i] = vs3_data[i*16 +: 16];
//                             wmask_buf_d[i] = {{VMEM_W/8-2{1'b0}}, {2{wdata_stri_mask}}};
//                         end
//                         VSEW_32: begin
//                             wdata_buf_d[i] = vs3_data[i*32 +: 32];
//                             wmask_buf_d[i] = {{VMEM_W/8-4{1'b0}}, {4{wdata_stri_mask}}};
//                         end
//                         default: ;
//                     endcase
//                 end
//             end
//         end
//     endgenerate

//     assign vmsk_tmp_d = vmsk_data;

//     // suppress memory request if all data elements are invalid (have indices greater than VL)
//     // TODO: memory requests should probably also be suppressed if all elements are masked off, but
//     // that could be tricky because the LSU cannot accept a memory response transaction while
//     // dequeueing a suppressed request  //?
//     logic [MEM_PORTS-1:0] req_suppress;
//     CTRL_T state_req_sel;
//     logic [MEM_PORTS-1:0][31:0] req_addr_sel;
//     logic [MEM_PORTS-1:0][VMEM_W-1:0] wdata_buf_sel;
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] wmask_buf_sel;
//     logic [MEM_PORTS-1:0][VMEM_W/8-1:0] vmsk_tmp_sel;

//     always_comb begin
//         state_req_sel = state_req_valid_q ? state_req_q : state_req_d;
//         req_addr_sel  = state_req_valid_q ? req_addr_q : req_addr_d;
//         wdata_buf_sel = state_req_valid_q ? wdata_buf_q : wdata_buf_d;
//         wmask_buf_sel = state_req_valid_q ? wmask_buf_q : wmask_buf_d;
//         vmsk_tmp_sel  = state_req_valid_q ? vmsk_tmp_q : vmsk_tmp_d;
//     end

//     always_comb begin
//         for(int i = 0; i < MEM_PORTS; i++) begin
//             req_suppress[i] = (instr_state_i[state_req_sel.id] == INSTR_KILLED) | state_req_sel.mem_req_vl_part_0[i];
//         end
//     end


//     // queue for storing masks and offsets until the memory system fulfills the request: //Might need to add here
//     lsu_state_red state_req_red;
//     always_comb begin
//         state_req_red              = DONT_CARE_ZERO ? '0 : 'x;
//         state_req_red.state_req_valid_q = state_req_valid_q;
//         state_req_red.state_req_valid_d = state_req_valid_d;
//         state_req_red.first_cycle  = state_req_sel.first_cycle;
//         state_req_red.last_cycle   = state_req_sel.last_cycle;
//         state_req_red.id           = state_req_sel.id;
//         state_req_red.mode         = state_req_sel.mode.lsu;
//         state_req_red.vl_part      = state_req_sel.vl_part;
//         state_req_red.vl_part_0    = state_req_sel.vl_part_0;
//         state_req_red.last_vl_part = state_req_sel.last_vl_part;
//         state_req_red.res_vaddr    = state_req_sel.res_vaddr;
//         state_req_red.res_store    = state_req_sel.res_store;
//         state_req_red.res_shift    = state_req_sel.res_shift;
//         state_req_red.vreg_idx     = state_req_sel.vreg_idx;
//         state_req_red.suppressed   = req_suppress;
//         state_req_red.exc          = '0; // xif_mem_if.mem_resp.exc & ~req_suppress; TODO handle exception
//         state_req_red.exccode      = '0; // xif_mem_if.mem_resp.exccode;
//         state_req_red.req_addr_q   = req_addr_sel;
//         state_req_red.wdata_buf_q  = wdata_buf_sel;
//         state_req_red.wmask_buf_q  = wmask_buf_sel;
//         state_req_red.vmsk_tmp_q   = vmsk_tmp_sel;
//         state_req_red.field_init_count = state_req_sel.field_init_count;
//         state_req_red.field_counter = state_req_sel.field_counter;
//         state_req_red.mem_req_vl_part = state_req_sel.mem_req_vl_part;
//         state_req_red.mem_req_vl_part_0 = state_req_sel.mem_req_vl_part_0;
//         state_req_red.mem_req_valid = state_req_sel.mem_req_valid;
//         state_req_red.field_done = state_req_sel.field_done;
//     end


//     vproc_lsu_extension #(
//         .MAX_OP_W                 ( MAX_OP_W                                    ),
//         .VMEM_W                   ( VMEM_W                                      ),
//         .VREG_W                   ( VREG_W                                      ),
//         .MEM_PORTS                ( MEM_PORTS                                   ),
//         .BUF_RDATA                ( BUF_RDATA                                   ),
//         .LSU_STATE_RED_T          ( lsu_state_red                               ),
//         .XIF_ID_W                 ( XIF_ID_W                                    ),
//         .XIF_ID_CNT               ( XIF_ID_CNT                                  ),
//         .VLSU_QUEUE_SZ            ( VLSU_QUEUE_SZ                               ),
//         .VLSU_FLAGS               ( VLSU_FLAGS                                  ),
//         .PORT_QUEUE_DEPTH         ( PORT_QUEUE_DEPTH                            ),
//         .DONT_CARE_ZERO           ( DONT_CARE_ZERO                              )
//     ) lsu_extension (
//         .clk_i                    ( clk_i                                       ),
//         .async_rst_ni             ( async_rst_ni                                ),
//         .sync_rst_ni              ( sync_rst_ni                                 ),
//         .vreg_pend_rd_i           ( vreg_pend_rd_i                              ),
//         .state_req_red_i          ( state_req_red                               ),
//         .state_rdata_valid_o      ( state_rdata_valid                           ),
//         .state_req_ready_o        ( state_req_ready                             ),
//         .rdata_buf_o              ( rdata_buf                                   ),
//         .rmask_buf_o              ( rmask_buf                                   ),
//         .state_rdata_o            ( state_rdata                                 ),
//         .instr_state_i            ( instr_state_i                               ),
//         .trans_complete_valid_o   ( trans_complete_valid_o                      ),
//         .trans_complete_ready_i   ( trans_complete_ready_i                      ),
//         .trans_complete_id_o      ( trans_complete_id_o                         ),
//         .trans_complete_exc_o     ( trans_complete_exc_o                        ),
//         .trans_complete_exccode_o ( trans_complete_exccode_o                    ),
//         .obi_bus                  ( obi_bus                                     ),
//         .fsm_load_o               ( fsm_load                                    ),
//         .fsm_store_o              ( fsm_store                                   )
//     );


//     // load data conversion:
//     logic [VMEM_W/8-1:0] rdata_unit_vl_mask [MEM_PORTS-1:0];
//     logic [VMEM_W/8-1:0] rdata_unit_vdmsk [MEM_PORTS-1:0];
//     logic [MEM_PORTS-1:0] rdata_stri_vdmsk;

//     always_comb begin
//         for(int i = 0; i < MEM_PORTS; i++) begin
//             rdata_unit_vl_mask[i] = '1;
//             rdata_unit_vdmsk[i]   = '1;
//             rdata_stri_vdmsk[i]   = '1;
//         end
//     end

//     always_comb begin
//         pipe_out_ctrl_o              = DONT_CARE_ZERO ? '0 : 'x;
//         pipe_out_ctrl_o.first_cycle  = state_rdata.first_cycle;
//         // only assert last_cycle once at the end of the field
//         // since it is used to dequeue the unit queue
//         //pipe_out_ctrl_o.last_cycle   = state_rdata.last_cycle & (state_rdata.field_init_count == 0 | (state_rdata.field_counter[0] == state_rdata.field_init_count));
//         pipe_out_ctrl_o.last_cycle   = state_rdata.field_init_count == 0 ? state_rdata.last_cycle : state_rdata.field_done;
//         pipe_out_ctrl_o.id           = state_rdata.id;
//         pipe_out_ctrl_o.mode.lsu     = state_rdata.mode;
//         pipe_out_ctrl_o.eew          = state_rdata.mode.eew;
//         pipe_out_ctrl_o.vl_part      = state_rdata.vl_part;
//         pipe_out_ctrl_o.vl_part_0    = state_rdata.vl_part_0;
//         pipe_out_ctrl_o.last_vl_part = state_rdata.last_vl_part & state_rdata.res_store; //only pass last_vl_part if storing to vreg
//         pipe_out_ctrl_o.vreg_idx     = state_rdata.vreg_idx;
//         pipe_out_ctrl_o.res_vaddr    = state_rdata.res_vaddr;
//         pipe_out_ctrl_o.res_store    = state_rdata.res_store & ~state_rdata.exc;
//         pipe_out_ctrl_o.res_shift    = state_rdata.res_shift;
//         pipe_out_ctrl_o.field_counter = state_rdata.field_counter;
//         pipe_out_ctrl_o.field_init_count = state_rdata.field_init_count;
//     end
//     assign pipe_out_pend_clr_o = state_rdata.res_store;
    
//     always_comb begin
//         pipe_out_valid_o = state_rdata.mem_req_valid; //TODO:
//         pipe_out_res_o = '{default: 0};

//         for(int i = 0; i < MEM_PORTS; i++) begin
//             pipe_out_res_o[i][VMEM_W-1:0] = rdata_buf[i];
//             pipe_out_mask_o[i] = (state_rdata.mode.stride == LSU_UNITSTRIDE) ? rdata_unit_vdmsk[i] : {(VMEM_W/8){rdata_stri_vdmsk[i]}};
//         end

//         if(state_rdata.field_init_count == 0) begin

//             for(int i = 0; i < MEM_PORTS; i++) begin

//                 if(i > 0) begin
//                     pipe_out_valid_o[i] = 0;
//                 end

//                 if(state_rdata.mode.stride != LSU_UNITSTRIDE) begin
//                     unique case (state_rdata.mode.eew)
//                         VSEW_8: begin
//                             pipe_out_res_o[0][8*i +: 8] = rdata_buf[i][7:0];
//                             pipe_out_mask_o[0][i] = {(1){rdata_stri_vdmsk[i]}};
//                         end
//                         VSEW_16: begin
//                             pipe_out_res_o[0][16*i +: 16] = rdata_buf[i][15:0];
//                             pipe_out_mask_o[0][2*i +: 2] = {(2){rdata_stri_vdmsk[i]}};
//                         end
//                         VSEW_32: begin
//                             pipe_out_res_o[0][32*i +: 32] = rdata_buf[i][31:0];
//                             pipe_out_mask_o[0][4*i +: 4] = {(4){rdata_stri_vdmsk[i]}};
//                         end
//                         default: ;    
//                     endcase
//                 end else begin
//                     pipe_out_res_o[0][VMEM_W*i +: VMEM_W] = rdata_buf[i];
//                     pipe_out_mask_o[0][VMEM_W/8*i +: VMEM_W/8] = rdata_unit_vdmsk[i];
//                 end
//             end
//         end

//         if(~state_rdata_valid) begin
//             pipe_out_valid_o = '0;
//         end
//     end


// `ifdef VPROC_SVA
// `include "vproc_lsu_sva.svh"
// `endif

endmodule
