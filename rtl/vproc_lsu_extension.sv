module vproc_lsu_extension import vproc_pkg::*; #(
        parameter int unsigned        MAX_OP_W        = 32,
        parameter int unsigned        VMEM_W          = 32,   // width in bits of the vector memory interface
        parameter int unsigned        VREG_W          = 128,   // width in bits of a vector register
        parameter int unsigned        MEM_PORTS       = 1,
        parameter bit                 BUF_RDATA       = 1'b1, // insert pipeline stage after memory read
        parameter type                LSU_STATE_RED_T = logic,
        parameter int unsigned        XIF_ID_W        = 3,    // width in bits of instruction IDs
        parameter int unsigned        XIF_ID_CNT      = 8,    // total count of instruction IDs
        parameter int unsigned           VLSU_QUEUE_SZ = 4,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS    = '0,
        parameter int unsigned        PORT_QUEUE_DEPTH = 2,  // must be power of 2, greater equal 2
        parameter int unsigned        SCRATCH_DEPTH    = 2,  // must be power of 2, greater equal 2
        parameter int unsigned        HIT_DEPTH        = 1,
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
        output logic [VMEM_W   -1:0] rdata_buf_o [MEM_PORTS-1:0],
        output logic [VMEM_W/8 -1:0] rmask_buf_o [MEM_PORTS-1:0],

        input  instr_state [XIF_ID_CNT-1:0] instr_state_i,

        output logic                  trans_complete_valid_o,
        input  logic                  trans_complete_ready_i,
        output logic [XIF_ID_W-1:0]   trans_complete_id_o,
        output logic                  trans_complete_exc_o,
        output logic [5:0]            trans_complete_exccode_o,

        OBI_BUS.Manager              obi_bus [MEM_PORTS-1:0],

        output logic                  fsm_load_o,
        output logic                  fsm_store_o
    );

    assign fsm_load_o = scratch_state_q.fsm_state != IDLE & ~scratch_state_q.store;
    assign fsm_store_o = scratch_state_q.fsm_state != IDLE & scratch_state_q.store;

    function automatic logic [MEM_PORTS-1:0] rotate_left(input logic [MEM_PORTS-1:0] port_in);
        // By using shift operators instead of indexed part-selects, 
        // we bypass the negative index elaboration error completely.
        // 
        // For MEM_PORTS > 1: It shifts left by 1 and brings the MSB to the LSB.
        // For MEM_PORTS = 1: (port_in << 1) becomes 0, and (port_in >> 0) remains port_in. 
        //                    The bitwise OR safely returns the original 1-bit value.
        
        return (port_in << 1) | (port_in >> (MEM_PORTS - 1));
    endfunction

    /////////////////////////////////scratch memory//////////////////////////////// 
    typedef logic [$clog2(MEM_PORTS)-1 : 0] port_select_t;
    typedef logic [$clog2(PORT_QUEUE_DEPTH) : 0] portq_elem_cnt_t;
    typedef logic [$clog2(VLSU_QUEUE_SZ + (MEM_PORTS*PORT_QUEUE_DEPTH)) : 0] outstanding_mem_req_cnt_t;

    /////////////////////////////////scratch state////////////////////////////////
    port_select_t [MEM_PORTS-1:0] port_pending_select;
    logic [MEM_PORTS-1:0][$clog2(VMEM_W/8)-1:0] port_pending_data_off;

    typedef enum logic [2:0] {
        IDLE                            = 3'b000,
        LOAD                            = 3'b001,
        LOAD_MISALIGNMENT               = 3'b010,
        STORE                           = 3'b011,
        STORE_MISALIGNMENT              = 3'b100,
        LAST_CYCLE_LOAD                 = 3'b110,
        LAST_CYCLE_STORE                = 3'b111
    } scratch_fsm_state_t;

    typedef struct packed {
        scratch_fsm_state_t fsm_state;
        outstanding_mem_req_cnt_t outstanding_mem_req_cnt;
        cfg_vsew current_eew;
        logic [MEM_PORTS-1:0] misalignment_request_in;
        logic [MEM_PORTS-1:0] misalignment_request_out;
        logic [MEM_PORTS-1:0][VMEM_W-1 : 0] misalignment_data;
        logic store;
        logic [XIF_ID_W-1:0] id;
    } scratch_state_t;

    scratch_state_t scratch_state_q, scratch_state_d;

    /////////////////////////////////input queue////////////////////////////////
    logic               input_queue_valid_out;
    logic               input_queue_ready_in;
    logic               input_queue_ready_out;
    LSU_STATE_RED_T     state_req_red;

    /////////////////////////////////Store queue////////////////////////////////
    logic [MEM_PORTS-1:0]   mem_req_queue_ready_in;
    logic [MEM_PORTS-1:0]   mem_req_queue_ready_out;
    logic [MEM_PORTS-1:0]   mem_req_queue_valid_in;
    logic [MEM_PORTS-1:0]   mem_req_queue_valid_out;

    typedef struct packed {
        logic                        first_cycle;
        logic                        store;
        logic [31:0]                 addr;
        logic [VMEM_W  -1:0]         wdata;
        logic [VMEM_W/8-1:0]         wmask;
    } mem_req_queue_data_t;

    mem_req_queue_data_t [MEM_PORTS-1:0] mem_req_queue_data_in;
    mem_req_queue_data_t [MEM_PORTS-1:0] mem_req_queue_data_out;


    /////////////////////////////////Output queue////////////////////////////////
    logic               output_queue_valid_out;
    logic               output_queue_ready_out;
    logic               output_queue_ready_in;

    port_select_t   [MEM_PORTS-1:0]                       port_queue_pending_select_out;
    logic           [MEM_PORTS-1:0][$clog2(VMEM_W/8)-1:0] port_queue_pending_data_off;
    logic       [MEM_PORTS-1:0][VMEM_W-1 : 0]           scratch_queue_data_out;

    LSU_STATE_RED_T     deq_state;

    // load data, offset and mask buffers:
    logic [VMEM_W   -1:0] rdata_buf_q [MEM_PORTS-1:0];
    logic [VMEM_W   -1:0] rdata_buf_d [MEM_PORTS-1:0];
    logic [VMEM_W/8 -1:0] rmask_buf_q [MEM_PORTS-1:0]; 
    logic [VMEM_W/8 -1:0] rmask_buf_d [MEM_PORTS-1:0];

    logic [MEM_PORTS-1:0] misalignment_request_out;

    typedef struct packed {
        port_select_t   [MEM_PORTS-1:0]                         port_pending_select;
        logic           [MEM_PORTS-1:0][$clog2(VMEM_W/8)-1:0]   port_pending_data_off;
        LSU_STATE_RED_T                                         state_req_red;
        logic           [MEM_PORTS-1:0]                         misalignment_request;
    } output_queue_data_t;

    output_queue_data_t output_queue_data_in, output_queue_data_out;

    /////////////////////////////////Port queue////////////////////////////////
    logic [MEM_PORTS-1 : 0] port_queue_ready_out;
    logic [MEM_PORTS-1 : 0] port_queue_valid_out;
    logic [MEM_PORTS-1 : 0] port_queue_ready_in;
    logic [VMEM_W   -1:0]   port_queue_rdata_out [MEM_PORTS-1 : 0]; 
    logic [MEM_PORTS-1 : 0] port_queue_mem_err_out;

    typedef struct packed {
        portq_elem_cnt_t [MEM_PORTS-1:0] portq_elem_cnt;
    } port_state_t;

    port_state_t port_state_q, port_state_d;


    /////////////////////////////////Memory request////////////////////////////////
    logic           mem_req_switch;

    /////////////////////////////////General signals////////////////////////////////
    logic                   state_req_stall;
    logic                   pending_req_stall; 
    logic                   state_rdata_valid_q, state_rdata_valid_d;
    logic [MEM_PORTS-1:0]   misalignment_request;
    logic                   misalignment_request_any;
    logic                   all_ports_finished;
    logic                   misalignment_request_finished;
    logic                   misalignment_request_out_any;
    logic                   state_req_red_end_of_field;
    logic                   deq_state_end_of_field;

    logic                   state_req_ready;

    LSU_STATE_RED_T         state_rdata_q, state_rdata_d;

    // memory request caused an exception:
    logic mem_exc_q, mem_exc_d;

    // memory request caused an error (exception or bus error):
    logic       mem_err_q,     mem_err_d, mem_any_err_q, mem_any_err_d;
    logic [5:0] mem_exccode_q, mem_exccode_d;

    logic [VMEM_W-1:0] rdata_next [MEM_PORTS-1:0];


    logic [$bits(obi_bus[0].req)-1:0]       obi_bus_req [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].gnt)-1:0]       obi_bus_gnt [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].addr)-1:0]      obi_bus_addr [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].we)-1:0]        obi_bus_we [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].be)-1:0]        obi_bus_be [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].wdata)-1:0]     obi_bus_wdata [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].rvalid)-1:0]    obi_bus_rvalid [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].rdata)-1:0]     obi_bus_rdata [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].err)-1:0]       obi_bus_err [MEM_PORTS-1:0];
    logic [$bits(obi_bus[0].aid)-1:0]       obi_bus_aid [MEM_PORTS-1:0];
    generate
        for(genvar i = 0; i < MEM_PORTS; i++) begin
            assign obi_bus[i].req    = obi_bus_req[i];
            assign obi_bus_gnt[i]    = obi_bus[i].gnt;
            assign obi_bus[i].addr   = obi_bus_addr[i];
            assign obi_bus[i].we     = obi_bus_we[i];
            assign obi_bus[i].be     = obi_bus_be[i];
            assign obi_bus[i].wdata  = obi_bus_wdata[i];
            assign obi_bus_rvalid[i] = obi_bus[i].rvalid;
            assign obi_bus_rdata[i]  = obi_bus[i].rdata;
            assign obi_bus_err[i]    = obi_bus[i].err;
            assign obi_bus[i].aid    = obi_bus_aid[i];
        end
    endgenerate


    always_ff @(posedge clk_i or negedge async_rst_ni) begin
        if (~async_rst_ni) begin
            scratch_state_q.fsm_state <= IDLE;
        end
        else if (~sync_rst_ni) begin
            scratch_state_q.fsm_state <= IDLE;
        end
        else begin
            scratch_state_q <= scratch_state_d;
            port_state_q <= port_state_d;
            mem_err_q     <= mem_err_d;
            mem_any_err_q <= mem_any_err_d;
            mem_exccode_q <= mem_exccode_d;
        end
    end

    assign state_req_ready = ~state_req_stall & input_queue_ready_out;

    generate
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
                    rmask_buf_q   <= rmask_buf_d;
                end
            end
        end else begin
            always_comb begin
                state_rdata_valid_q = state_rdata_valid_d;
                state_rdata_q       = state_rdata_d;
                rdata_buf_q         = rdata_buf_d;
                rmask_buf_q         = rmask_buf_d;
            end
        end
    endgenerate

    // Stall vreg writes until pending reads of the destination register are
    // complete and while the instruction is speculative; for the LSU stalling
    // has to happen at the request stage, since later stalling is not possible
    // Also stall if incoming instruction is speculative OR a current instruction has not finished
    assign state_req_stall = (~state_req_red_i.mode.store & state_req_red_i.res_store & vreg_pend_rd_i[state_req_red_i.res_vaddr]) |
                             (instr_state_i[state_req_red_i.id] == INSTR_SPECULATIVE);          

    // memory request (keep requesting next access while addressing is not complete)
    always_comb begin
        port_state_d = port_state_q;

        if(scratch_state_q.fsm_state == IDLE) begin
            port_state_d.portq_elem_cnt = '0;
        end

        for(int i = 0; i < MEM_PORTS; i++) begin
            obi_bus_req[i]   = mem_req_queue_valid_out[i] & (~mem_exc_q | mem_req_queue_data_out[i].first_cycle) & 
                               port_queue_ready_out[i];
            obi_bus_addr[i]  = mem_req_queue_data_out[i].addr;
            obi_bus_we[i]    = mem_req_queue_data_out[i].store;
            obi_bus_be[i]    = mem_req_queue_data_out[i].wmask;
            obi_bus_wdata[i] = mem_req_queue_data_out[i].wdata;
            obi_bus_aid[i]   = i; // TODO: USE_XIF_MEM needs id from state_red_req

            if(obi_bus_gnt[i] & port_queue_ready_in[i]) begin
                port_state_d.portq_elem_cnt[i] = port_state_q.portq_elem_cnt[i];
            end else if (obi_bus_gnt[i]) begin
                port_state_d.portq_elem_cnt[i] = port_state_q.portq_elem_cnt[i] + 1;
            end else if (port_queue_ready_in[i]) begin
                port_state_d.portq_elem_cnt[i] = port_state_q.portq_elem_cnt[i] - 1;
            end
        end
    end


    // monitor the memory response for exceptions
    always_comb begin
        mem_exc_d = mem_exc_q;
        if (state_req_red.first_cycle | ~mem_exc_q) begin
            // reset the exception flag in the first cycle, unless there is an
            // exception
            mem_exc_d = '0;// TODO xif_mem_if.mem_valid & xif_mem_if.mem_ready & xif_mem_if.mem_resp.exc;
        end
    end

    // input queue
    vproc_queue #(
        .WIDTH        ( $bits(LSU_STATE_RED_T)                                        ),
        .DEPTH        ( VLSU_QUEUE_SZ                                                 ),
        .FLOW         ( 1'b1                                                          )
    ) input_queue (
        .clk_i        ( clk_i                                                         ),
        .async_rst_ni ( async_rst_ni                                                  ),
        .sync_rst_ni  ( sync_rst_ni                                                   ),
        .enq_ready_o  ( input_queue_ready_out                                         ),
        .enq_valid_i  ( state_req_red_i.state_req_valid_q & ~state_req_stall          ),
        .enq_data_i   ( state_req_red_i                                               ),
        .deq_ready_i  ( input_queue_ready_in & ~pending_req_stall & ~misalignment_request_any),
        .deq_valid_o  ( input_queue_valid_out                                         ),
        .deq_data_o   ( state_req_red                                                 ),
        .flags_any_o  (                                                               ),
        .flags_all_o  (                                                               )
    );

    // memory request queue
    generate
        for (genvar i = 0; i < MEM_PORTS; i++) begin
            vproc_queue #(
                .WIDTH        ( $bits(LSU_STATE_RED_T)                                                                  ),
                .DEPTH        ( VLSU_QUEUE_SZ                                                                           ),
                .FLOW         ( 1'b1                                                                                    )
            ) mem_req_queue (
                .clk_i        ( clk_i                                                                                   ),
                .async_rst_ni ( async_rst_ni                                                                            ),
                .sync_rst_ni  ( sync_rst_ni                                                                             ),
                .enq_ready_o  ( mem_req_queue_ready_out[i]                                                              ),
                .enq_valid_i  ( mem_req_queue_valid_in[i]                                                               ),
                .enq_data_i   ( mem_req_queue_data_in[i]                                                                ),
                .deq_ready_i  ( mem_req_queue_ready_in[i]                                                               ),
                .deq_valid_o  ( mem_req_queue_valid_out[i]                                                              ),
                .deq_data_o   ( mem_req_queue_data_out[i]                                                               ),
                .flags_any_o  (                                                                                         ),
                .flags_all_o  (                                                                                         )
            );
            assign mem_req_queue_ready_in[i] = obi_bus_gnt[i] | (mem_exc_q & ~mem_req_queue_data_out[i].first_cycle);
        end
    endgenerate


    // Port queue
    generate
        for (genvar i = 0; i < MEM_PORTS; i++) begin
            vproc_queue #(
                .WIDTH        ( $bits(LSU_STATE_RED_T)                                        ),
                .DEPTH        ( PORT_QUEUE_DEPTH                                              ),
                .FLOW         ( 1'b1                                                          )
            ) port_queue (
                .clk_i        ( clk_i                                                         ),
                .async_rst_ni ( async_rst_ni                                                  ),
                .sync_rst_ni  ( sync_rst_ni                                                   ),
                .enq_ready_o  (                                                               ),
                .enq_valid_i  ( obi_bus_rvalid[i]                                             ),
                .enq_data_i   ( {obi_bus_rdata[i], obi_bus_err[i]}                            ),
                .deq_ready_i  ( port_queue_ready_in[i]                                        ),
                .deq_valid_o  ( port_queue_valid_out[i]                                       ),
                .deq_data_o   ( {port_queue_rdata_out[i], port_queue_mem_err_out[i]}          ),
                .flags_any_o  (                                                               ),
                .flags_all_o  (                                                               )
            );

            assign port_queue_ready_out[i] = port_state_q.portq_elem_cnt[i] != PORT_QUEUE_DEPTH;
        end
    endgenerate

    assign misalignment_request_any = |misalignment_request;
    assign misalignment_request_out_any = |misalignment_request_out;

    always_comb begin
        state_req_red_end_of_field = 0;

        for(int i = 0; i < MEM_PORTS; i++) begin
            if(state_req_red.field_init_count == state_req_red.field_counter[i] 
               & state_req_red.mem_req_valid[i]) begin

                state_req_red_end_of_field = 1;

            end
        end
    end

    always_comb begin
        logic [$clog2(VMEM_W/8):0] eew_in_bytes;
        logic [MEM_PORTS-1:0] port_read_hit;
        logic [MEM_PORTS-1:0] port_write_hit;
        logic [MEM_PORTS-1:0] port_hit;
        logic [$clog2(MEM_PORTS):0] port_hit_index;
        logic [MEM_PORTS-1:0][VMEM_W-1:0] port_wdata;
        logic [MEM_PORTS-1:0][VMEM_W/8-1:0] port_wmask;

        logic [MEM_PORTS-1:0][31:0] end_of_addr;

        scratch_state_d = scratch_state_q;

        port_read_hit = '0;
        port_write_hit = '0;
        port_hit = '0;
        port_hit_index = '0;
        port_pending_select = '0;
        port_wdata = '0;
        port_wmask = '0;

        mem_req_switch = 0;
        mem_req_queue_valid_in = '0;

        pending_req_stall = 0;

        misalignment_request = '0;
        all_ports_finished = 0;
        misalignment_request_finished = 0;

        end_of_addr = '0;

        for(int i = 0; i < MEM_PORTS; i++) begin
            port_queue_ready_in[i] = 0;
        end

        mem_any_err_d = mem_any_err_q;

        rdata_next = '{default: '0};

        unique case (scratch_state_q.current_eew)
            VSEW_8:
                eew_in_bytes = 1;
            VSEW_16:
                eew_in_bytes = 2;
            VSEW_32: 
                eew_in_bytes = 4;
            default: 
                eew_in_bytes = VMEM_W/8;
        endcase

        unique case (scratch_state_q.fsm_state)
        
            IDLE: begin
                pending_req_stall = 1;

                scratch_state_d.id = state_req_red.id;
                scratch_state_d.store = state_req_red.mode.store;
                
                scratch_state_d.outstanding_mem_req_cnt = 0;

                scratch_state_d.misalignment_request_in = '0;
                scratch_state_d.misalignment_request_out = '0;

                // Reset error for new memory request
                mem_any_err_d = 0;

                scratch_state_d.current_eew = state_req_red.mode.eew;
                if(state_req_red.mode.stride == LSU_UNITSTRIDE) begin
                    scratch_state_d.current_eew = VSEW_INVALID;
                end

                unique case (scratch_state_d.current_eew)
                    VSEW_8:
                        eew_in_bytes = 1;
                    VSEW_16:
                        eew_in_bytes = 2;
                    VSEW_32: 
                        eew_in_bytes = 4;
                    default: 
                        eew_in_bytes = VMEM_W/8;
                endcase

                if(input_queue_ready_in & input_queue_valid_out & state_req_red.first_cycle) begin
                    

                    if(state_req_red.mode.store) begin
                        scratch_state_d.fsm_state = STORE;
                        pending_req_stall = 0;
                        mem_req_switch = 1;

                        for(int i = 0; i < MEM_PORTS; i++) begin
                            end_of_addr[i] = state_req_red.req_addr_q[i] + eew_in_bytes - 1;

                            if (input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed[i] & state_req_red.mem_req_valid[i]) begin

                                for(int j = 0; j < i; j++) begin

                                    if(
                                        state_req_red.mem_req_valid[j] &
                                        state_req_red.req_addr_q[j][31:$clog2(VMEM_W/8)] == state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)]
                                    ) begin
                                        
                                        port_read_hit[i] = 1;
                                        port_hit_index = j; 
                                        port_pending_select[i] = port_pending_select[j];
                                    end
                                end

                                if(port_read_hit[i]) begin
                                    if(state_req_red.req_addr_q[port_hit_index][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                        misalignment_request[i] = 1;
                                        scratch_state_d.misalignment_request_in[i] = 1;
                                    end
                                end

                                port_pending_data_off[i] = state_req_red.req_addr_q[i][$clog2(VMEM_W/8)-1:0];

                                if(~port_read_hit[i]) begin
                                    if(mem_req_queue_ready_out[i]) begin
                                            port_write_hit[i] = 1;
                                            port_pending_select[i] = i;
                                            mem_req_queue_valid_in[i] = 1;
                                            port_wmask[i] = '0;

                                            if(state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                                misalignment_request[i] = 1;
                                                scratch_state_d.misalignment_request_in[i] = 1;
                                            end

                                    end else begin
                                        pending_req_stall = 1;
                                    end
                                end

                                if(~pending_req_stall & misalignment_request_any) begin
                                    scratch_state_d.fsm_state = STORE_MISALIGNMENT;
                                end

                                port_hit[i] = port_read_hit[i] | port_write_hit[i];

                                port_wdata[i] = state_req_red.wdata_buf_q[i] << VMEM_W'(port_pending_data_off[i] << 3);
                                port_wmask[i] = state_req_red.wmask_buf_q[i] << port_pending_data_off[i]; 

                                if(port_hit[i]) begin

                                    for (int j = 0; j < VMEM_W / 8 ; j++) begin
                                        if(port_wmask[i][j]) begin
                                            port_wdata[port_pending_select[i]][8*j +: 8] = port_wdata[i][8*j +: 8];
                                            port_wmask[port_pending_select[i]][j] = 1;
                                        end
                                    end
                                end
                            end
                        end

                        if(pending_req_stall) begin
                            mem_req_queue_valid_in = '0;
                        end


                    end else begin
                        scratch_state_d.fsm_state = LOAD;
                        pending_req_stall = 0;

                        for(int i = 0; i < MEM_PORTS; i++) begin
                            end_of_addr[i] = state_req_red.req_addr_q[i] + eew_in_bytes - 1;

                            // Load
                            if(input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed[i] & state_req_red.mem_req_valid[i]) begin

                                for(int j = 0; j < i; j++) begin

                                    if(
                                        state_req_red.mem_req_valid[j] &
                                        state_req_red.req_addr_q[j][31:$clog2(VMEM_W/8)] == state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)]
                                    ) begin
                                        
                                        port_read_hit[i] = 1; 
                                        port_hit_index = j;
                                        port_pending_select[i] = port_pending_select[j];
                                        port_pending_data_off[i] = state_req_red.req_addr_q[i][$clog2(VMEM_W/8)-1:0];
                                    end
                                end

                                if(port_read_hit[i]) begin
                                    if(state_req_red.req_addr_q[port_hit_index][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                        misalignment_request[i] = 1;
                                        scratch_state_d.misalignment_request_in[i] = 1;
                                    end
                                end

                                if(~port_read_hit[i]) begin
                                    if(mem_req_queue_ready_out[i]) begin
                                        mem_req_queue_valid_in[i] = 1;
                                        port_pending_select[i] = i;
                                        port_pending_data_off[i] = state_req_red.req_addr_q[i][$clog2(VMEM_W/8)-1:0];

                                        if(state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                            misalignment_request[i] = 1;
                                            scratch_state_d.misalignment_request_in[i] = 1;
                                        end
                                    end else begin
                                        pending_req_stall = 1;
                                    end
                                end

                                if(~pending_req_stall & misalignment_request_any) begin
                                    scratch_state_d.fsm_state = LOAD_MISALIGNMENT;
                                end
                            end

                        end

                        if(pending_req_stall) begin
                            mem_req_queue_valid_in = '0;
                        end

                        if(~pending_req_stall & misalignment_request_any) begin
                            scratch_state_d.fsm_state = LOAD_MISALIGNMENT;
                        end

                    end
                end
            end    

            LOAD: begin

                for(int i = 0; i < MEM_PORTS; i++) begin
                    end_of_addr[i] = state_req_red.req_addr_q[i] + eew_in_bytes - 1;

                    // Load
                    if(input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed[i] & state_req_red.mem_req_valid[i]) begin

                        for(int j = 0; j < i; j++) begin

                            if(
                                state_req_red.mem_req_valid[j] &
                                state_req_red.req_addr_q[j][31:$clog2(VMEM_W/8)] == state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)]
                            ) begin
                                
                                port_read_hit[i] = 1;
                                port_hit_index = j; 
                                port_pending_select[i] = port_pending_select[j];
                                port_pending_data_off[i] = state_req_red.req_addr_q[i][$clog2(VMEM_W/8)-1:0];
                            end
                        end

                        if(port_read_hit[i]) begin
                            if(state_req_red.req_addr_q[port_hit_index][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                misalignment_request[i] = 1;
                                scratch_state_d.misalignment_request_in[i] = 1;
                            end
                        end

                        if(~port_read_hit[i]) begin
                            if(mem_req_queue_ready_out[i]) begin
                                mem_req_queue_valid_in[i] = 1;
                                port_pending_select[i] = i;
                                port_pending_data_off[i] = state_req_red.req_addr_q[i][$clog2(VMEM_W/8)-1:0];

                                if(state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                    misalignment_request[i] = 1;
                                    scratch_state_d.misalignment_request_in[i] = 1;
                                end
                            end else begin
                                pending_req_stall = 1;
                            end
                        end

                        if(~pending_req_stall & misalignment_request_any) begin
                            scratch_state_d.fsm_state = LOAD_MISALIGNMENT;
                        end
                    end

                end

                if(pending_req_stall) begin
                    mem_req_queue_valid_in = '0;
                end

                // End of load
                if(
                    input_queue_ready_in &
                    input_queue_valid_out &
                    state_req_red.last_cycle & 
                    (state_req_red.field_init_count == '0 | state_req_red_end_of_field) &
                    ~pending_req_stall &
                    ~misalignment_request_any
                ) begin
                    scratch_state_d.fsm_state = LAST_CYCLE_LOAD;
                end

            end

            LOAD_MISALIGNMENT: begin

                for(int i = 0; i < MEM_PORTS; i++) begin
                    end_of_addr[i] = state_req_red.req_addr_q[i] + eew_in_bytes;

                    // Load
                    if(input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed[i] & scratch_state_q.misalignment_request_in[i]) begin

                        for(int j = 0; j < i; j++) begin

                                if(
                                    state_req_red.mem_req_valid[j] &
                                    scratch_state_q.misalignment_request_in[j] &
                                    end_of_addr[j][31:$clog2(VMEM_W/8)] == end_of_addr[i][31:$clog2(VMEM_W/8)]
                                ) begin
                                    
                                    port_read_hit[i] = 1; 
                                    port_pending_select[i] = port_pending_select[j];
                                    port_pending_data_off[i] = eew_in_bytes - end_of_addr[i][$clog2(VMEM_W/8)-1:0];
                                end
                        end

                        if(~port_read_hit[i]) begin
                            if(mem_req_queue_ready_out[i]) begin
                                mem_req_queue_valid_in[i] = 1;
                                port_pending_select[i] = i;
                                port_pending_data_off[i] = eew_in_bytes - end_of_addr[i][$clog2(VMEM_W/8)-1:0];
                            end else begin
                                pending_req_stall = 1;
                            end
                        end


                        if(~pending_req_stall) begin
                            scratch_state_d.fsm_state = LOAD;
                            scratch_state_d.misalignment_request_in = '0;
                        end
                    end
                end

                if(pending_req_stall) begin
                    mem_req_queue_valid_in = '0;
                end

                // End of load
                if(
                    input_queue_ready_in &
                    input_queue_valid_out &
                    state_req_red.last_cycle & 
                    (state_req_red.field_init_count == '0 | state_req_red_end_of_field) &
                    ~pending_req_stall
                ) begin
                    scratch_state_d.fsm_state = LAST_CYCLE_LOAD;
                end

            end

            STORE: begin
                mem_req_switch = 1;

                for(int i = 0; i < MEM_PORTS; i++) begin
                    end_of_addr[i] = state_req_red.req_addr_q[i] + eew_in_bytes - 1;

                    if (input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed[i] & state_req_red.mem_req_valid[i]) begin

                        for(int j = 0; j < i; j++) begin

                            if(
                                state_req_red.mem_req_valid[j] &
                                state_req_red.req_addr_q[j][31:$clog2(VMEM_W/8)] == state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)]
                            ) begin
                                
                                port_read_hit[i] = 1;
                                port_hit_index = j; 
                                port_pending_select[i] = port_pending_select[j];
                            end
                        end

                        if(port_read_hit[i]) begin
                            if(state_req_red.req_addr_q[port_hit_index][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                misalignment_request[i] = 1;
                                scratch_state_d.misalignment_request_in[i] = 1;
                            end
                        end

                        port_pending_data_off[i] = state_req_red.req_addr_q[i][$clog2(VMEM_W/8)-1:0];

                        if(~port_read_hit[i]) begin
                            if(mem_req_queue_ready_out[i]) begin
                                    port_write_hit[i] = 1;
                                    port_pending_select[i] = i;
                                    mem_req_queue_valid_in[i] = 1;
                                    port_wmask[i] = '0;

                                    if(state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)] != end_of_addr[i][31:$clog2(VMEM_W/8)]) begin
                                        misalignment_request[i] = 1;
                                        scratch_state_d.misalignment_request_in[i] = 1;
                                    end

                                end else begin
                                    pending_req_stall = 1;
                                end
                        end

                        if(~pending_req_stall & misalignment_request_any) begin
                            scratch_state_d.fsm_state = STORE_MISALIGNMENT;
                        end

                        port_hit[i] = port_read_hit[i] | port_write_hit[i];

                        port_wdata[i] = state_req_red.wdata_buf_q[i] << VMEM_W'(port_pending_data_off[i] << 3);
                        port_wmask[i] = state_req_red.wmask_buf_q[i] << port_pending_data_off[i]; 

                        if(port_hit[i]) begin

                            for (int j = 0; j < VMEM_W / 8 ; j++) begin
                                if(port_wmask[i][j]) begin
                                    port_wdata[port_pending_select[i]][8*j +: 8] = port_wdata[i][8*j +: 8];
                                    port_wmask[port_pending_select[i]][j] = 1;
                                end
                            end
                        end
                    end
                end

                if(pending_req_stall) begin
                    mem_req_queue_valid_in = '0;
                end

                // End of store
                if(
                    input_queue_ready_in &
                    input_queue_valid_out &
                    state_req_red.last_cycle & 
                    (state_req_red.field_init_count == '0 | state_req_red_end_of_field) &
                    ~pending_req_stall &
                    ~misalignment_request_any
                ) begin
                    scratch_state_d.fsm_state = LAST_CYCLE_STORE;
                end


            end


            STORE_MISALIGNMENT: begin
                mem_req_switch = 1;

                for(int i = 0; i < MEM_PORTS; i++) begin
                    end_of_addr[i] = state_req_red.req_addr_q[i] + eew_in_bytes;

                    if (input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed[i] & scratch_state_q.misalignment_request_in[i]) begin
                        
                        for(int j = 0; j < i; j++) begin

                            if(
                                state_req_red.mem_req_valid[j] &
                                scratch_state_q.misalignment_request_in[j] &
                                end_of_addr[j][31:$clog2(VMEM_W/8)] == end_of_addr[i][31:$clog2(VMEM_W/8)]
                            ) begin
                                
                                port_read_hit[i] = 1; 
                                port_pending_select[i] = port_pending_select[j];
                            end
                        end

                        port_pending_data_off[i] = eew_in_bytes - end_of_addr[i][$clog2(VMEM_W/8)-1:0];

                        if(~port_read_hit[i]) begin
                            if(mem_req_queue_ready_out[i]) begin
                                    port_write_hit[i] = 1;
                                    port_pending_select[i] = i;
                                    mem_req_queue_valid_in[i] = 1;
                                    port_wmask[i] = '0;
                                end else begin
                                    pending_req_stall = 1;
                                end
                        end

                        port_hit[i] = port_read_hit[i] | port_write_hit[i];

                        port_wdata[i] = state_req_red.wdata_buf_q[i] >> VMEM_W'(port_pending_data_off[i] << 3);
                        port_wmask[i] = state_req_red.wmask_buf_q[i] >> port_pending_data_off[i]; 

                        if(port_hit[i]) begin

                            for (int j = 0; j < VMEM_W / 8 ; j++) begin
                                if(port_wmask[i][j]) begin
                                    port_wdata[port_pending_select[i]][8*j +: 8] = port_wdata[i][8*j +: 8];
                                    port_wmask[port_pending_select[i]][j] = 1;
                                end
                            end
                        end

                        if(~pending_req_stall) begin
                            scratch_state_d.fsm_state = STORE;
                            scratch_state_d.misalignment_request_in = '0;
                        end
                    end
                end

                if(pending_req_stall) begin
                    mem_req_queue_valid_in = '0;
                end

                // End of store
                if(
                    input_queue_ready_in &
                    input_queue_valid_out &
                    state_req_red.last_cycle & 
                    (state_req_red.field_init_count == '0 | state_req_red_end_of_field) &
                    ~pending_req_stall
                ) begin
                    scratch_state_d.fsm_state = LAST_CYCLE_STORE;
                end


            end

            LAST_CYCLE_LOAD: begin
                pending_req_stall = 1;
                if(scratch_state_q.outstanding_mem_req_cnt == '0 & ~output_queue_valid_out) begin
                    scratch_state_d.fsm_state = IDLE;
                end
            end

            LAST_CYCLE_STORE: begin
                pending_req_stall = 1;
                if(scratch_state_q.outstanding_mem_req_cnt == '0) begin
                    scratch_state_d.fsm_state = IDLE;
                end
            end

        endcase

        // handling of pending loads/stores
        unique case (scratch_state_q.fsm_state)
            LOAD,
            LOAD_MISALIGNMENT,
            LAST_CYCLE_LOAD: begin
                // PENDING_LOAD_STALL - deal with pending loads
                logic misalignment_request_combine_any;
                port_select_t [MEM_PORTS-1:0] selected_port;

                misalignment_request_combine_any = |scratch_state_q.misalignment_request_out;
                selected_port = port_queue_pending_select_out;

                // put together the data
                for(int i = 0; i < MEM_PORTS; i++) begin
                    if(scratch_state_q.misalignment_request_out[i]) begin
                        rdata_next[i] = (port_queue_rdata_out[selected_port[i]] << VMEM_W'(port_queue_pending_data_off[i] << 3)) | scratch_state_q.misalignment_data[i];
                    end else begin
                        if(misalignment_request_combine_any) begin
                            rdata_next[i] = scratch_state_q.misalignment_data[i];
                        end else begin
                            rdata_next[i] = port_queue_rdata_out[selected_port[i]] >> VMEM_W'(port_queue_pending_data_off[i] << 3);
                        end
                    end
                end

                if (output_queue_valid_out) begin
                    all_ports_finished = ~misalignment_request_out_any;
                    misalignment_request_finished = misalignment_request_out_any;

                    // check if requests are finished
                    for(int i = 0; i < MEM_PORTS; i++) begin
                        if(~port_queue_valid_out[selected_port[i]] & deq_state.mem_req_valid[i] & misalignment_request_out[i]) begin
                            misalignment_request_finished = 0;
                        end
                    end

                    for(int i = 0; i < MEM_PORTS; i++) begin
                        if(~port_queue_valid_out[selected_port[i]] & deq_state.mem_req_valid[i] & ~deq_state.suppressed[i]) begin
                            if(misalignment_request_combine_any) begin
                                if(scratch_state_q.misalignment_request_out[i]) begin
                                    all_ports_finished = 0;
                                end
                            end else begin
                                all_ports_finished = 0;
                            end
                        end
                    end

                    // send out valid signals to ports
                    for(int i = 0; i < MEM_PORTS; i++) begin
                        if(port_queue_valid_out[selected_port[i]] & deq_state.mem_req_valid[i] & misalignment_request_out[i]) begin
                            port_queue_ready_in[selected_port[i]] = 1;
                            scratch_state_d.misalignment_request_out[i] = 1;
                        end
                        scratch_state_d.misalignment_data[i] = rdata_next[i];
                    end

                    for(int i = 0; i < MEM_PORTS; i++) begin
                        if(port_queue_valid_out[selected_port[i]] & deq_state.mem_req_valid[i]) begin
                            port_queue_ready_in[selected_port[i]] = 1;
                        end
                    end

                    // block valid signals if requests are not all finished
                    if(~misalignment_request_finished & misalignment_request_out_any) begin
                        port_queue_ready_in = '0;
                        scratch_state_d.misalignment_request_out = '0;
                    end

                    if(~all_ports_finished & ~misalignment_request_out_any) begin
                        port_queue_ready_in = '0;
                    end else if(all_ports_finished) begin
                        scratch_state_d.misalignment_request_out = '0;
                    end
                end
            end

            STORE,
            STORE_MISALIGNMENT,
            LAST_CYCLE_STORE: begin
                // PENDING_STORE_STALL - deal with pending stores

                for(int i = 0; i < MEM_PORTS; i++) begin
                    if(port_queue_valid_out[i]) begin
                        port_queue_ready_in[i] = 1;
                    end
                end

            end

            default: ;


        endcase

        // Input port configuration
        for(int i = 0; i < MEM_PORTS; i++) begin
            if(mem_req_queue_valid_in[i]) begin
                scratch_state_d.outstanding_mem_req_cnt = scratch_state_d.outstanding_mem_req_cnt + 1; // read from d since it could have been incremented before
            end
        end

        for(int i = 0; i < MEM_PORTS; i++) begin
            if(mem_req_switch) begin
                mem_req_queue_data_in[i].first_cycle = state_req_red.first_cycle;
                mem_req_queue_data_in[i].store = 1;
                if(scratch_state_q.fsm_state == STORE_MISALIGNMENT) begin
                    mem_req_queue_data_in[i].addr = {end_of_addr[i][31:$clog2(VMEM_W/8)], {$clog2(VMEM_W/8){1'b0}}};
                end else begin
                    mem_req_queue_data_in[i].addr = {state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)], {$clog2(VMEM_W/8){1'b0}}};
                end
                mem_req_queue_data_in[i].wmask = port_wmask[i];
                mem_req_queue_data_in[i].wdata = port_wdata[i];
            end else begin
                mem_req_queue_data_in[i].first_cycle = state_req_red.first_cycle;
                mem_req_queue_data_in[i].store = 0;
                if(scratch_state_q.fsm_state == LOAD_MISALIGNMENT) begin
                    mem_req_queue_data_in[i].addr = {end_of_addr[i][31:$clog2(VMEM_W/8)], {$clog2(VMEM_W/8){1'b0}}};
                end else begin
                    mem_req_queue_data_in[i].addr = {state_req_red.req_addr_q[i][31:$clog2(VMEM_W/8)], {$clog2(VMEM_W/8){1'b0}}};
                end
                mem_req_queue_data_in[i].wmask = state_req_red.wmask_buf_q[i];
                mem_req_queue_data_in[i].wdata = state_req_red.wdata_buf_q[i];
                
            end
        end

        // Output port configuration
        for(int i = 0; i < MEM_PORTS; i++) begin
            if(port_queue_ready_in[i]) begin
                mem_any_err_d |= port_queue_mem_err_out[i];
                scratch_state_d.outstanding_mem_req_cnt = scratch_state_d.outstanding_mem_req_cnt - 1; // read from d since it could have been incremented before
            end
        end


    end


    // output queue -> queue after sending memory request
    assign output_queue_data_in.port_pending_select             = port_pending_select;
    assign output_queue_data_in.port_pending_data_off           = port_pending_data_off;
    assign output_queue_data_in.state_req_red                   = state_req_red;
    assign output_queue_data_in.misalignment_request            = misalignment_request;

    // flow turned off since otherwise requests will be handled before the scratch was able to process them 
    vproc_queue_dyn_flow #(
        .WIDTH        ( $bits(output_queue_data_t)                                                                                      ),
        .DEPTH        ( VLSU_QUEUE_SZ                                                                                                   )
        //.FLOW         ( 1'b0                                                                                                            )
    ) output_queue (
        .clk_i        ( clk_i                                                                                                           ),
        .async_rst_ni ( async_rst_ni                                                                                                    ),
        .sync_rst_ni  ( sync_rst_ni                                                                                                     ),
        .flow_i       ( scratch_state_d.store                                                                                           ),
        .enq_ready_o  ( output_queue_ready_out                                                                                          ),
        .enq_valid_i  ( input_queue_ready_in & input_queue_valid_out & ~pending_req_stall                                               ),
        .enq_data_i   ( output_queue_data_in                                                                                            ),
        .deq_ready_i  ( output_queue_ready_in                                                                                           ),
        .deq_valid_o  ( output_queue_valid_out                                                                                          ),
        .deq_data_o   ( output_queue_data_out                                                                                           ),
        .flags_any_o  (                                                                                                                 ),
        .flags_all_o  (                                                                                                                 )
    );

    assign port_queue_pending_select_out       = output_queue_data_out.port_pending_select;
    assign port_queue_pending_data_off         = output_queue_data_out.port_pending_data_off;
    assign misalignment_request_out            = output_queue_data_out.misalignment_request;

    always_comb begin
        deq_state = output_queue_data_out.state_req_red;
        deq_state_end_of_field = 0;

        for(int i = 0; i < MEM_PORTS; i++) begin
            if(deq_state.field_init_count == deq_state.field_counter[i] 
               & deq_state.mem_req_valid[i]) begin

                deq_state_end_of_field = 1;

            end
        end

    end


    always_comb begin
        rdata_buf_d = rdata_next;

        for(int i = 0; i < MEM_PORTS; i++) begin
            rmask_buf_d[i] = output_queue_data_out.state_req_red.vmsk_tmp_q[i];
        end

    end


    // Ready signals
    assign output_queue_ready_in = output_queue_valid_out & 
                                    ((~deq_state.mode.store & all_ports_finished | misalignment_request_finished) | deq_state.mode.store | mem_err_d);

    assign input_queue_ready_in  = output_queue_ready_out;

    // Valid signals
    assign state_rdata_valid_d = output_queue_valid_out & output_queue_ready_in & ~misalignment_request_out_any;

    // monitor the memory result for bus errors and the queue for exceptions
    always_comb begin
        mem_err_d     = mem_err_q;
        mem_exccode_d = mem_exccode_q;
        if (output_queue_valid_out & (deq_state.first_cycle | ~mem_err_q)) begin
            // reset the error flag in the first cycle, unless there is a bus
            // error or an exception occured during the request
            mem_err_d     = mem_err_q | (mem_any_err_q); // TODO deq_state.exc
            mem_exccode_d = mem_err_q ? mem_exccode_q : ( // TODO deq_state.exc
                // bus error translates to a load/store access fault exception
                deq_state.mode.store ? 6'h07 : 6'h05
            );
        end
    end

    // LSU transaction complete queue, result indicates potential exceptions
    logic trans_complete_valid, trans_complete_ready;
    assign trans_complete_valid = ((~scratch_state_q.store & state_rdata_valid_d & deq_state.last_cycle & 
                                 (deq_state.field_init_count == '0 | deq_state_end_of_field)) &
                                  (instr_state_i[scratch_state_q.id] == INSTR_COMMITTED)) |
                                  (scratch_state_q.store & state_rdata_valid_d & deq_state.last_cycle & 
                                 (deq_state.field_init_count == '0 | deq_state_end_of_field));

    /*assign trans_complete_valid = ((~scratch_state_q.store & scratch_state_q.fsm_state == LAST_CYCLE_LOAD & scratch_state_d.fsm_state == IDLE) &
                                  (instr_state_i[scratch_state_q.id] == INSTR_COMMITTED)) |
                                  (scratch_state_q.store & scratch_state_q.fsm_state == LAST_CYCLE_STORE & scratch_state_d.fsm_state == IDLE);*/

    vproc_queue #(
        .WIDTH        ( XIF_ID_W + 7                                                          ),
        .DEPTH        ( 2                                                                     )
    ) trans_complete_queue (
        .clk_i        ( clk_i                                                                 ),
        .async_rst_ni ( async_rst_ni                                                          ),
        .sync_rst_ni  ( sync_rst_ni                                                           ),
        .enq_ready_o  ( trans_complete_ready                                                  ),
        .enq_valid_i  ( trans_complete_valid                                                  ),
        .enq_data_i   ( {scratch_state_q.id, mem_err_d, mem_exccode_d}                        ),
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

    assign state_rdata_valid_o = state_rdata_valid_q;
    assign state_req_ready_o = state_req_ready;
    assign state_rdata_o = state_rdata_q;

    assign rdata_buf_o = rdata_buf_q;
    assign rmask_buf_o = rmask_buf_q;

`ifdef VPROC_SVA
`include "vproc_lsu_extension_sva.svh"
`endif

endmodule
