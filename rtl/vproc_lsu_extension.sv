module vproc_lsu_extension import vproc_pkg::*, obi_pkg::*; #(
        parameter int unsigned        VMEM_W          = 32,   // width in bits of the vector memory interface
        parameter int unsigned        VREG_W          = 128,   // width in bits of a vector register
        parameter int unsigned        MEM_PORTS       = 1,
        parameter bit [OBI_CFG.IdWidth-1:0] OBI_ID    = '1,
        parameter bit                 BUF_REQUEST     = 1'b1, // insert pipeline stage before issuing request
        parameter bit                 BUF_RDATA       = 1'b1, // insert pipeline stage after memory read
        parameter type                LSU_STATE_RED_T = logic,
        parameter int unsigned        XIF_ID_W        = 3,    // width in bits of instruction IDs
        parameter int unsigned        XIF_ID_CNT      = 8,    // total count of instruction IDs
        parameter int unsigned           VLSU_QUEUE_SZ = 4,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS    = '0,
        parameter int unsigned        SCRATCH_DEPTH    = 1, // power of 2
        parameter int unsigned        HIT_DEPTH        = 1, // power of 2
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
        vproc_xif.coproc_mem_result   xif_memres_if,

        obi_intf.Manager              obi_intf [MEM_PORTS-1:0]
    );

    /////////////////////////////////scratch memory//////////////////////////////// 
    typedef logic [$clog2(SCRATCH_DEPTH)-1 : 0] elem_cnt_t;
    typedef logic [$clog2(PORT_QUEUE_DEPTH)-1 : 0] portq_elem_cnt_t;
    typedef logic [$clog2(VREG_W)-1 : 0] outstanding_mem_req_t;

    typedef enum logic [1:0] {
        VALID,
        PENDING,
        NOT_VALID
    } scratch_state_t;

    typedef struct packed {
        logic [31:0] address;
        logic [$clog2(VMEM_W/8)-1:0] wmask;
        logic [VMEM_W-1:0] data;
    } scratch_line_t;

    typedef scratch_state_t [SCRATCH_DEPTH-1 : 0] scratch_memory_state_t;
    typedef scratch_line_t [SCRATCH_DEPTH-1 : 0] scratch_memory_t;

    scratch_memory_state_t scratch_memory_state_q, scratch_memory_state_d;
    scratch_memory_t scratch_memory_q, scratch_memory_d;

    /////////////////////////////////scratch state////////////////////////////////
    logic scratch_hit;
    logic scratch_pending;

    elem_cnt_t scratch_pending_index;
    logic scratch_pending_req_cleared;
    logic [VMEM_W-1 : 0] scratch_pending_output;
    logic [$clog2(VMEM_W/8)-1:0] scratch_pending_data_off;

    logic [VMEM_W-1:0] scratch_hit_data;

    typedef enum logic [2:0] {
        IDLE,
        LOAD,
        PENDING_LOAD_STALL,
        STORE_SCRATCH,
        PENDING_STORE_STALL,
        STORE_MEMORY
    } scratch_fsm_state_t;

    struct packed {
        scratch_fsm_state_t fsm_state;
        scratch_fsm_state_t pending_store_state_cb;
        scratch_fsm_state_t pending_load_state_cb;
        elem_cnt_t write_index;
        elem_cnt_t [MEM_PORTS-1:0] port_write_index;
        portq_elem_cnt_t [MEM_PORTS-1:0] portq_elem_cnt;
        logic [MEM_PORTS-1:0] current_input_port;
        logic [MEM_PORTS-1:0] current_output_port;
        outstanding_mem_req_t outstanding_mem_req_cnt;
    } scratch_state_t;

    scratch_state_t scratch_state_q, scratch_state_d;

    /////////////////////////////////input queue////////////////////////////////
    logic               input_queue_valid_out;
    logic               input_queue_ready_in;
    logic               input_queue_ready_out;
    LSU_STATE_RED_T     state_req_red;

    /////////////////////////////////Store queue////////////////////////////////
    logic               mem_req_queue_ready_out;
    logic               mem_req_queue_valid_in;
    logic               mem_req_queue_valid_out;

    struct packed {
        logic                        store;
        logic [31:0]                 req_addr_q;
        logic [VMEM_W  -1:0]         wdata_buf_q;
        logic [VMEM_W/8-1:0]         wmask_buf_q;
    } mem_req_queue_data_out_t;

    mem_req_data_out_t mem_req_data_in, mem_req_data_out;


    /////////////////////////////////Output queue////////////////////////////////
    logic               output_queue_valid_out;
    logic               output_queue_ready_out;
    logic               output_queue_ready_in;

    logic                           scratch_queue_pending_out;
    elem_cnt_t                      scratch_queue_pending_index_out;
    logic [$clog2(VMEM_W/8)-1:0]    scratch_queue_pending_data_off_out;
    logic [VMEM_W-1 : 0]            scratch_queue_data_out;

    LSU_STATE_RED_T     deq_state;

    // load data, offset and mask buffers:
    logic [       VMEM_W   -1:0] rdata_buf_q, rdata_buf_d;
    logic [$clog2(VMEM_W/8)-1:0] rdata_off_q, rdata_off_d;
    logic [       VMEM_W/8 -1:0] rmask_buf_q, rmask_buf_d;

    struct packed {
        logic [VMEM_W-1 : 0]         scratch_hit_data;
        logic                        scratch_pending;
        elem_cnt_t                   scratch_pending_index;
        logic [$clog2(VMEM_W/8)-1:0] scratch_pending_data_off;
        logic [$clog2(VMEM_W/8)-1:0] rdata_off;
        logic [       VMEM_W/8 -1:0] rmask_buf;
        LSU_STATE_RED_T              state_req_red;
    } output_queue_data_t;

    output_queue_data_t output_queue_data_in, output_queue_data_out;

    /////////////////////////////////Port queue////////////////////////////////
    logic [MEM_PORTS-1 : 0] port_queue_ready_out;
    logic [MEM_PORTS-1 : 0] port_queue_valid_out;
    logic [MEM_PORTS-1 : 0] port_queue_ready_in;
    logic [VMEM_W   -1:0]   port_queue_rdata_out [MEM_PORTS-1 : 0]; 
    logic [MEM_PORTS-1 : 0] port_queue_mem_err_out;


    /////////////////////////////////Memory request////////////////////////////////
    logic           mem_req_switch;

    /////////////////////////////////General signals////////////////////////////////
    logic            state_req_stall;
    logic            pending_req_stall; 
    logic            state_rdata_valid_q, state_rdata_valid_d;

    logic            state_req_ready;

    LSU_STATE_RED_T  state_rdata_q, state_rdata_d;

    // memory request caused an exception:
    logic mem_exc_q, mem_exc_d;

    // memory request caused an error (exception or bus error):
    logic       mem_err_q,     mem_err_d, mem_any_err_q, mem_any_err_d;
    logic [5:0] mem_exccode_q, mem_exccode_d;


    generate
        if (BUF_REQUEST) begin
            always_ff @(posedge clk_i) begin : vproc_lsu_stage_req
                if (state_req_ready & state_req_red.state_req_valid_d) begin
                    mem_exc_q   <= mem_exc_d;
                end
            end
            always_comb begin
                state_req_ready = ~state_req_red.state_req_valid_q;
                for(int i = 0; i < MEM_PORTS; i++) begin
                    if(scratch_state_q.current_input_port[i]) begin
                        state_req_ready = (obi_intf[i].req & obi_intf[i].gnt) | (~state_req_stall & ~obi_intf[i].req);
                    end
                end
            end
        end else begin
            always_ff @(posedge clk_i) begin
                // always need a flip-flop for the exception flag
                mem_exc_q <= mem_exc_d;
            end
            always_comb begin
                state_req_ready = 0;
                for(int i = 0; i < MEM_PORTS; i++) begin
                    if(scratch_state_q.current_input_port[i]) begin
                        state_req_ready = (obi_intf[i].req & obi_intf[i].gnt) | (~state_req_stall & ~obi_intf[i].req);
                    end
                end
            end
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

                    scratch_state_q <= scratch_state_d;
                    scratch_memory_state_q <= scratch_memory_state_d;
                    scratch_memory_q <= scratch_memory_d;
                end
            end
            always_ff @(posedge clk_i) begin : vproc_lsu_stage_rdata
                if (state_rdata_valid_d) begin
                    state_rdata_q <= state_rdata_d;
                    rdata_buf_q   <= rdata_buf_d;
                    rdata_off_q   <= rdata_off_d;
                    rmask_buf_q   <= rmask_buf_d;
                    mem_err_q     <= mem_err_d;
                    mem_any_err_q <= mem_any_err_d;
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
                mem_any_err_q <= mem_any_err_d;
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
                             ~input_queue_ready_out | ~output_queue_ready_out;

    assign pending_req_stall = scratch_state_q.fsm_state != LOAD | scratch_state_q.fsm_state != STORE_SCRATCH |
                               scratch_state_d.fsm_state != PENDING_LOAD_STALL | scratch_state_d.fsm_state != PENDING_STORE_STALL;             

    // memory request (keep requesting next access while addressing is not complete)
    logic current_input_port_gnt;
    always_comb begin
        current_input_port_gnt = 0;

        for(int i = 0; i < MEM_PORTS; i++) begin
            obi_intf[i].req = mem_req_queue_valid_out & (~mem_exc_q | state_req_red.first_cycle);
            obi_intf[i].mem_req.id = OBI_ID;
            obi_intf[i].mem_req.addr = VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE] ? {mem_req_queue_data_out.addr[31:$clog2(VMEM_W/8)], {$clog2(VMEM_W/8){1'b0}}} : mem_req_queue_data_out.addr;
            obi_intf[i].mem_req.we = mem_req_queue_data_out.store;
            obi_intf[i].mem_req.be = mem_req_queue_data_out.wmask_buf_q;
            obi_intf[i].mem_req.wdata = mem_req_queue_data_out.wdata_buf_q;


            if(scratch_state_q.current_input_port[i]) begin
                current_input_port_gnt = obi_intf[i].gnt;
            end else begin
                obi_intf[i].req = 0;
            end
        end
    end

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
        .deq_ready_i  ( input_queue_ready_in & ~pending_req_stall                     ),
        .deq_valid_o  ( input_queue_valid_out                                         ),
        .deq_data_o   ( state_req_red                                                 ),
        .flags_any_o  (                                                               ),
        .flags_all_o  (                                                               )
    );

    // memory request queue
    vproc_queue #(
        .WIDTH        ( $bits(LSU_STATE_RED_T)                                        ),
        .DEPTH        ( VLSU_QUEUE_SZ                                                 ),
        .FLOW         ( 1'b1                                                          )
    ) mem_req_queue (
        .clk_i        ( clk_i                                                         ),
        .async_rst_ni ( async_rst_ni                                                  ),
        .sync_rst_ni  ( sync_rst_ni                                                   ),
        .enq_ready_o  ( mem_req_queue_ready_out                                       ),
        .enq_valid_i  ( mem_req_queue_valid_in                                        ),
        .enq_data_i   ( mem_req_queue_data_in                                         ),
        .deq_ready_i  ( current_input_port_gnt                                        ),
        .deq_valid_o  ( mem_req_queue_valid_out                                       ),
        .deq_data_o   ( mem_req_queue_data_out                                        ),
        .flags_any_o  (                                                               ),
        .flags_all_o  (                                                               )
    );


    // Port queue
    generate
        for (genvar i = 0; i < MEM_PORTS; i++) begin
            vproc_queue #(
                .WIDTH        ( $bits(LSU_STATE_RED_T)                                        ),
                .DEPTH        ( VLSU_QUEUE_SZ                                                 ),
                .FLOW         ( 1'b1                                                          )
            ) port_queue (
                .clk_i        ( clk_i                                                         ),
                .async_rst_ni ( async_rst_ni                                                  ),
                .sync_rst_ni  ( sync_rst_ni                                                   ),
                .enq_ready_o  (                                                               ),
                .enq_valid_i  ( obi_intf[i].rvalid                                            ),
                .enq_data_i   ( {obi_intf[i].rdata, obi_intf[i].err}                          ),
                .deq_ready_i  ( port_queue_ready_in[i]                                        ),
                .deq_valid_o  ( port_queue_valid_out[i]                                       ),
                .deq_data_o   ( {port_queue_rdata_out, port_queue_mem_err_out[i]}             ),
                .flags_any_o  (                                                               ),
                .flags_all_o  (                                                               )
            );

            assign port_queue_ready_out[i] = scratch_state_q.portq_elem_cnt[i] != '1;
        end
    endgenerate
    

    always_comb begin
        logic [2:0] eew_in_bytes;

        logic [$clog2(VMEM_W/8)-1:0] scratch_data_off;
        logic [$clog2(VMEM_W/8)-1:0] scratch_load_offset;

        logic [$clog2(VMEM_W/8)-1:0] scratch_wmask;
        logic [$clog2(VMEM_W/8)-1:0] scratch_store_offset;

        elem_cnt_t selected_index;

        scratch_state_d = scratch_state_q;
        scratch_state_d.store_index = '0;

        scratch_memory_state_d = scratch_memory_state_q;
        scratch_memory_d = scratch_memory_q;

        scratch_hit = 0;
        scratch_hit_data = '0;

        scratch_pending_output = '0;
        scratch_pending_req_cleared = 0;

        scratch_data_off = state_req_red.req_addr_q[$clog2(VMEM_W/8)-1:0];
        scratch_load_offset = '0;

        scratch_wmask = '0;
        scratch_write_offset = '0;
        scratch_store_offset = '0;

        mem_req_switch = 0;
        mem_req_queue_valid_in = 0;

        selected_index = '0;
        
        // if request is granted, select next port
        if(current_input_port_gnt) begin
            scratch_state_d.current_input_port = {scratch_state_q.current_input_port[MEM_PORTS-2:1], cratch_state_q.current_input_port[MEM_PORTS-1]};
        end

        for(int i = 0; i < MEM_PORTS; i++) begin
            port_queue_ready_in[i] = 0;
        end

        mem_any_err_d = mem_any_err_q;

        eew_in_bytes = 1;
        unique case (state_req_red.mode.eew)
            VSEW_8:
                eew_in_bytes = 1;
            VSEW_16:
                eew_in_bytes = 2;
            VSEW_32: 
                eew_in_bytes = 4;
        endcase

        unique case (scratch_state_q.fsm_state)
        
            IDLE: begin
                scratch_state_d.write_index = 0;
                scratch_state_d.portq_elem_cnt = '0;
                scratch_state_d.outstanding_mem_req_cnt = 0;

                for(int i = 0; i < SCRATCH_DEPTH; i++) begin
                    scratch_memory_state_d[i] = NOT_VALID;
                end

                if(input_queue_ready_in & input_queue_valid_out & state_req_red.first_cycle) begin
                    // Reset error for new memory request
                    mem_any_err_d = 0;

                    if(state_req_red.mode.store) begin
                        scratch_state_d.fsm_state = STORE_SCRATCH;
                    end else begin
                        scratch_state_d.fsm_state = LOAD;
                    end
                end
            end    

            LOAD: begin
                if(input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed) begin

                    for(int i = 0; i < HIT_DEPTH; i++) begin
                        selected_index = scratch_state_q.write_index - 1 - i;

                        if(
                            (
                                scratch_memory_state_q[selected_index] == VALID ||
                                scratch_memory_state_q[selected_index] == PENDING
                            ) &
                            scratch_memory_q.[selected_index].address <= state_req_red.req_addr_q &
                            scratch_memory_q.[selected_index].address + VMEM_W/8 >= state_req_red.req_addr_q + eew_in_bytes
                        ) begin
                            
                            scratch_hit = 1;

                            scratch_data_off = state_req_red.req_addr_q[$clog2(VMEM_W/8)-1:0];
                            scratch_load_offset = state_req_red.req_addr_q - scratch_memory_q.[selected_index].address;
                            scratch_data_off += scratch_load_offset;   

                            unique case (state_req_red.mode.eew)
                                VSEW_8:
                                    scratch_hit_data[7 :0] = scratch_memory_q.[selected_index].data[{3'b000, scratch_data_off                                  } * 8 +: 8 ];
                                VSEW_16: 
                                    scratch_hit_data[15:0] = scratch_memory_q.[selected_index].data[{3'b000, scratch_data_off & ({$clog2(VMEM_W/8){1'b1}} << 1)} * 8 +: 16];
                                VSEW_32: 
                                    scratch_hit_data[31:0] = scratch_memory_q.[selected_index].data[{3'b000, scratch_data_off & ({$clog2(VMEM_W/8){1'b1}} << 2)} * 8 +: 32];
                                default: ;
                            endcase
                            if (VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE]) begin
                                scratch_hit_data = scratch_memory_q.[selected_index].data;
                            end

                            if (scratch_memory_state_q[selected_index] == PENDING) begin
                                scratch_memory_d.[selected_index].pending_req_cnt++;
                                scratch_pending = 1;
                                scratch_pending_index = selected_index;
                                scratch_pending_data_off = scratch_data_off;
                            end

                        end
                    end

                    if(~scratch_hit) begin
                        if(
                            (
                                scratch_memory_state_q[scratch_state_d.write_index] == PENDING ||
                                scratch_memory_state_q[scratch_state_d.write_index] == VALID
                            ) &
                            scratch_memory_q[scratch_state_d.write_index].pending_req_cnt > 0
                        ) begin
                            scratch_state_d.fsm_state = PENDING_LOAD_STALL;
                            scratch_state_d.pending_load_state_cb = LOAD;
                        end else begin
                            if(mem_req_queue_ready_out) begin
                                mem_req_queue_valid_in = 1;
                                scratch_memory_state_d[scratch_state_q.write_index] = PENDING;
                                scratch_memory_d[scratch_state_q.write_index].address = state_req_red.req_addr_q;
                                scratch_memory_d[scratch_state_q.write_index].pending_req_cnt = 1;
                                scratch_state_d.write_index = scratch_state_q.write_index + 1;
                                scratch_state_d.outstanding_mem_req_cnt = scratch_state_q.outstanding_mem_req_cnt + 1;
                                for(int i = 0; i < MEM_PORTS; i++) begin
                                    if(scratch_state_q.current_input_port[i]) begin
                                        scratch_state_d.port_write_index[i] = scratch_state_q.write_index;
                                        scratch_state_d.portq_elem_cnt[i] = scratch_state_q.portq_elem_cnt[i] + 1;
                                    end
                                end
                            end else begin
                                scratch_state_d.fsm_state = PENDING_LOAD_STALL;
                                scratch_state_d.pending_load_state_cb = LOAD;
                            end
                        end
                        
                    end

                end else begin
                    // if queues are not ready, check if pending loads can be cleared
                    // take over valid memory result into scratch
                    for(int i = 0; i < MEM_PORTS; i++) begin
                        if(scratch_state_q.current_output_port[i]) begin
                            if(port_queue_valid_out[i]) begin
                                scratch_state_d.fsm_state = PENDING_LOAD_STALL;
                                scratch_state_d.pending_load_state_cb = LOAD;
                            end
                        end
                    end
                end

                // End of load
                if(
                    input_queue_ready_in &
                    input_queue_valid_out &
                    state_req_red.last_cycle & 
                    (state_req_red.field_init_count == 0 | state_req_red.field_init_count == state_req_red.field_counter) &
                    ~pending_req_stall
                ) begin
                    scratch_state_d.fsm_state = LAST_CYCLE_LOAD;
                end

            end

            PENDING_LOAD_STALL: begin
                // deal with pending loads

                for(int i = 0; i < MEM_PORTS; i++) begin

                    if(scratch_state_q.current_output_port[i] & port_queue_valid_out[i]) begin

                        scratch_memory_state_d[scratch_state_q.port_write_index[i]] = VALID;
                        scratch_memory_d[scratch_state_q.port_write_index[i]].data = port_queue_rdata_out[i];
                        mem_any_err_d |= port_queue_mem_err_out[i];
                        scratch_state_d.portq_elem_cnt[i] = scratch_state_q.portq_elem_cnt[i] - 1;
                        scratch_state_d.outstanding_mem_req_cnt = scratch_state_q.outstanding_mem_req_cnt - 1;
                        port_queue_ready_in[i] = 1;
                        scratch_state_d.current_output_port = {scratch_state_q.current_output_port[MEM_PORTS-2:1], cratch_state_q.current_output_port[MEM_PORTS-1]};
                    end
                end

                if (output_queue_valid_out & scratch_queue_pending_out) begin
                    if(scratch_memory_state_q[scratch_queue_pending_index_out] == VALID) begin
                        scratch_memory_d.[scratch_queue_pending_index_out].pending_req_cnt--;
                        scratch_pending_req_cleared = 1;

                        unique case (state_req_red.mode.eew)
                            VSEW_8:
                                scratch_pending_output[7 :0] = scratch_memory_q.[scratch_queue_pending_index_out].data[{3'b000, scratch_queue_pending_data_off_out                                  } * 8 +: 8 ];
                            VSEW_16: 
                                scratch_pending_output[15:0] = scratch_memory_q.[scratch_queue_pending_index_out].data[{3'b000, scratch_queue_pending_data_off_out & ({$clog2(VMEM_W/8){1'b1}} << 1)} * 8 +: 16];
                            VSEW_32: 
                                scratch_pending_output[31:0] = scratch_memory_q.[scratch_queue_pending_index_out].data[{3'b000, scratch_queue_pending_data_off_out & ({$clog2(VMEM_W/8){1'b1}} << 2)} * 8 +: 32];
                            default: ;
                        endcase
                        if (VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE]) begin
                            scratch_pending_output = scratch_memory_q.[scratch_queue_pending_index_out].data;
                        end
                    end
                end

                unique case(scratch_state_q.pending_load_state_cb)
                    LOAD: begin 
                        if(output_queue_ready_out) begin
                            scratch_state_d.fsm_state = scratch_state_q.pending_load_state_cb;
                        end
                    end
                    IDLE: begin
                        if(scratch_state_q.outstanding_mem_req_cnt == '0) begin
                            scratch_state_d.fsm_state = scratch_state_q.pending_load_state_cb;
                        end
                    end
                    default: ;
                endcase 

                
            end

            STORE_SCRATCH: begin
                mem_req_switch = 1;
                if (input_queue_ready_in & input_queue_valid_out & ~state_req_red.suppressed) begin
                    
                    for(int i = 0; i < HIT_DEPTH; i++) begin
                        if(
                            scratch_memory_state_q[scratch_state_q.write_index - 1 - i] == VALID &
                            scratch_memory_q.[scratch_state_q.write_index - 1 - i].address <= state_req_red.req_addr_q &
                            scratch_memory_q.[scratch_state_q.write_index - 1 - i].address + VMEM_W/8 >= state_req_red.req_addr_q + eew_in_bytes
                        ) begin
                            scratch_hit = 1;
                            selected_index = scratch_state_q.write_index - 1 - i;
                        end
                    end

                    scratch_store_offset = state_req_red.req_addr_q - scratch_memory_q.[selected_index].address;

                    if(~scratch_hit) begin
                        selected_index = scratch_state_q.write_index;

                        if(scratch_memory_state_q[selected_index] == NOT_VALID) begin
                            scratch_hit = 1;
                            scratch_memory_state_d[selected_index] = VALID;
                            scratch_memory_d.[selected_index].address = state_req_red.req_addr_q;
                            scratch_store_offset = '0;
                        else
                            if(mem_req_queue_ready_out) begin
                                scratch_hit = 1;
                                mem_req_queue_valid_in = 1;
                                scratch_memory_d.[selected_index].address = state_req_red.req_addr_q;
                                scratch_state_d.write_index = scratch_state_q.write_index + 1;
                                scratch_state_d.outstanding_mem_req_cnt = scratch_state_q.outstanding_mem_req_cnt + 1;
                                for(int i = 0; i < MEM_PORTS; i++) begin
                                    if(scratch_state_q.current_input_port[i]) begin
                                        scratch_state_d.portq_elem_cnt[i] = scratch_state_q.portq_elem_cnt[i] + 1;
                                    end
                                end
                            end else begin
                                scratch_state_d.fsm_state = PENDING_STORE_STALL;
                                scratch_state_d.pending_store_state_cb = STORE_SCRATCH;
                            end
                        end
                    end

                    // shifted in case of ~VLSU_FLAGS[VLSU_ALIGNED_UNITSTRIDE], otherwise offset is 0
                    scratch_wmask = state_req_red.wmask_buf_q << scratch_store_offset; 

                    if(scratch_hit) begin

                        unique case (state_req_red.mode.eew)
                            VSEW_8: begin
                                for (int j = 0; j < VMEM_W / 8 ; j++) begin
                                    if(scratch_wmask[j]) begin
                                        scratch_memory_d.[selected_index].data[8*j +: 8] = state_req_red.wdata_buf_q[8*j +: 8];
                                        scratch_memory_d.wmask[j] = 1;
                                    end
                                end
                            end
                            VSEW_16: begin
                                for (int j = 0; j < VMEM_W / 16 ; j++) begin
                                    if(scratch_wmask[j]) begin
                                        scratch_memory_d.[selected_index].data[16*j +: 16] = state_req_red.wdata_buf_q[16*j +: 16];
                                        scratch_memory_d.wmask[j] = 1;
                                    end
                                end
                            end
                            VSEW_32: begin
                                for (int j = 0; j < VMEM_W / 32 ; j++) begin
                                    if(scratch_wmask[j]) begin
                                        scratch_memory_d.[selected_index].data[32*j +: 32] = state_req_red.wdata_buf_q[32*j W+: 32];
                                        scratch_memory_d.wmask[j] = 1;
                                    end
                                end
                            end
                            default: ;
                        endcase

                    end

                end else begin
                    // if queues are not ready, check if pending stores can be cleared
                    // take over valid error result
                    for(int i = 0; i < MEM_PORTS; i++) begin
                        if(scratch_state_q.current_output_port[i]) begin
                            if(port_queue_valid_out[i]) begin
                                scratch_state_d.fsm_state = PENDING_STORE_STALL;
                                scratch_state_d.pending_store_state_cb = STORE_SCRATCH;
                            end
                        end
                    end
                end

                // End of store
                if(
                    input_queue_ready_in &
                    input_queue_valid_out &
                    state_req_red.last_cycle & 
                    (state_req_red.field_init_count == 0 | state_req_red.field_init_count == state_req_red.field_counter) &
                    ~pending_req_stall
                ) begin
                    scratch_state_d.fsm_state = LAST_CYCLE_STORE;
                end


            end

            PENDING_STORE_STALL: begin
                // deal with pending stores

                for(int i = 0; i < MEM_PORTS; i++) begin
                    if(scratch_state_q.current_output_port[i]) begin
                        if(port_queue_valid_out[i]) begin
                            mem_any_err_d |= port_queue_mem_err_out[i];
                            scratch_state_d.portq_elem_cnt[i] = scratch_state_q.portq_elem_cnt[i] - 1;
                            scratch_state_d.outstanding_mem_req_cnt = scratch_state_q.outstanding_mem_req_cnt - 1;
                            port_queue_ready_in[i] = 1;
                            scratch_state_d.current_output_port = {scratch_state_q.current_output_port[MEM_PORTS-2:1], cratch_state_q.current_output_port[MEM_PORTS-1]};
                        end

                        unique case(scratch_state_q.pending_store_state_cb)
                            STORE_SCRATCH, STORE_MEMORY: begin 
                                if(port_queue_ready_out[i]) begin
                                    scratch_state_d.fsm_state = scratch_state_q.pending_store_state_cb;
                                end
                            end
                            IDLE: begin
                                if(scratch_state_q.outstanding_mem_req_cnt == '0) begin
                                    scratch_state_d.fsm_state = scratch_state_q.pending_store_state_cb;
                                end
                            end
                            default: ;
                        endcase 
                    end
                end

            end

            STORE_MEMORY: begin
                mem_req_switch = 1;

                if(scratch_memory_state_q[scratch_state_q.write_index] == VALID) begin

                    if(mem_req_queue_ready_out) begin
                        for(int i = 0; i < MEM_PORTS; i++) begin
                            if(scratch_state_q.current_input_port[i]) begin
                                if(port_queue_ready_out[i]) begin
                                    mem_req_queue_valid_in = 1;
                                    mem_req_queue_data_in.store = 1;
                                    mem_req_queue_data_in.req_addr_q = scratch_memory_q.[scratch_state_q.write_index].address;
                                    mem_req_queue_data_in.wdata_buf_q = scratch_memory_q.[scratch_state_q.write_index].data;
                                    mem_req_queue_data_in.wmask_buf_q = scratch_memory_q.[scratch_state_q.write_index].wmask;
                                    scratch_state_d.write_index = scratch_state_q.write_index + 1;
                                    scratch_state_d.outstanding_mem_req_cnt = scratch_state_q.outstanding_mem_req_cnt + 1;
                                    if(scratch_state_q.write_index == '0) begin
                                        scratch_state_d.fsm_state = PENDING_STORE_STALL;
                                        scratch_state_d.pending_store_state_cb = IDLE;
                                    end
                                end else begin
                                    scratch_state_d.fsm_state = PENDING_STORE_STALL;
                                    scratch_state_d.pending_store_state_cb = STORE_MEMORY;
                                end
                            end
                        end
                        
                    end

                end else begin
                    scratch_state_d.write_index = scratch_state_q.write_index - 1;
                    if(scratch_state_q.write_index == '0) begin
                        scratch_state_d.fsm_state = PENDING_STORE_STALL;
                        scratch_state_d.pending_store_state_cb = IDLE;
                    end
                end


            end

            LAST_CYCLE_LOAD: begin
                // state to circumvent pending stall
                scratch_state_d.fsm_state = PENDING_LOAD_STALL;
                scratch_state_d.pending_load_state_cb = IDLE;
            end

            LAST_CYCLE_STORE: begin
                // state to circumvent pending stall (not needed -> symmetry)
                scratch_state_d.fsm_state = STORE_MEMORY;
                scratch_state_d.write_index = '0;
            end

        endcase


        if(mem_req_switch) begin
            mem_req_queue_data_in.store = 1;
            mem_req_queue_data_in.req_addr_q = scratch_memory_q.[scratch_state_q.write_index].address;
            mem_req_queue_data_in.wmask_buf_q = scratch_memory_q.[scratch_state_q.write_index].wmask;
            mem_req_queue_data_in.wdata_buf_q = scratch_memory_q.[scratch_state_q.write_index].data;
        end else begin
            mem_req_queue_data_in.store = 0;
            mem_req_queue_data_in.req_addr_q = state_req_red.req_addr_q;
            mem_req_queue_data_in.wmask_buf_q = state_req_red.wmask_buf_q;
            mem_req_queue_data_in.wdata_buf_q = state_req_red.wdata_buf_q;
        end

    end


    // output queue -> queue after sending memory request
    output_queue_data_t output_queue_data_in, output_queue_data_out;

    assign output_queue_data_in.scratch_hit_data           = scratch_hit_data;
    assign output_queue_data_in.scratch_pending            = scratch_pending;
    assign output_queue_data_in.scratch_pending_index      = scratch_pending_index;
    assign output_queue_data_in.scratch_pending_data_off   = scratch_pending_data_off;
    assign output_queue_data_in.rdata_off                  = state_req_red.req_addr_q[$clog2(VMEM_W/8)-1:0];
    assign output_queue_data_in.rmask_buf                  = state_req_red.vmsk_tmp_q;
    assign output_queue_data_in.state_req_red              = state_req_red;

    vproc_queue #(
        .WIDTH        ( $bits(output_queue_data_t)                                                                                      ),
        .DEPTH        ( VLSU_QUEUE_SZ                                                                                                   ),
        .FLOW         ( 1'b1                                                                                                            )
    ) output_queue (
        .clk_i        ( clk_i                                                                                                           ),
        .async_rst_ni ( async_rst_ni                                                                                                    ),
        .sync_rst_ni  ( sync_rst_ni                                                                                                     ),
        .enq_ready_o  ( output_queue_ready_out                                                                                          ),
        .enq_valid_i  ( state_req_red.state_req_valid_q & state_req_ready & input_queue_valid_out & ~pending_req_stall                  ),
        .enq_data_i   ( output_queue_data_in                                                                                            ),
        .deq_ready_i  ( output_queue_ready_in                                                                                           ),
        .deq_valid_o  ( output_queue_valid_out                                                                                          ),
        .deq_data_o   ( output_queue_data_out                                                                                           ),
        .flags_any_o  (                                                                                                                 ),
        .flags_all_o  (                                                                                                                 )
    );

    assign scratch_queue_data_out              = output_queue_data_out.scratch_hit_data;
    assign scratch_queue_pending_out           = output_queue_data_out.scratch_pending;
    assign scratch_queue_pending_index_out     = output_queue_data_out.scratch_queue_pending_index;
    assign scratch_queue_pending_data_off_out  = output_queue_data_out.scratch_pending_data_off;
    assign rdata_off_d                         = output_queue_data_out.rdata_off;
    assign rmask_buf_d                         = output_queue_data_out.rmask_buf;
    assign deq_state                           = output_queue_data_out.state_req_red;



    // Ready signals
    assign output_queue_ready_in = output_queue_valid_out & 
                                    (~deq_state.last_cycle | deq_state.field_counter != deq_state.field_init_count | scratch_state_q.fsm_state == IDLE) &
                                    (scratch_queue_pending_out & scratch_pending_req_cleared) |
                                    deq_state.suppressed | mem_err_d;

    always_comb begin
        input_queue_ready_in = state_req_ready & output_queue_ready_out;

        for(int i = 0; i < MEM_PORTS; i++) begin
            if(scratch_state_q.current_input_port[i]) begin
                input_queue_ready_in &= port_queue_ready_out[i];
            end
        end
    end

    // Valid signals
    assign state_rdata_valid_d = output_queue_valid_out & output_queue_ready_in;

    // monitor the memory result for bus errors and the queue for exceptions
    always_comb begin
        mem_err_d     = mem_err_q;
        mem_exccode_d = mem_exccode_q;
        if (output_queue_valid_out & (deq_state.first_cycle | ~mem_err_q)) begin
            // reset the error flag in the first cycle, unless there is a bus
            // error or an exception occured during the request
            mem_err_d     = deq_state.exc | (mem_any_err_q);
            mem_exccode_d = deq_state.exc ? deq_state.exccode : (
                // bus error translates to a load/store access fault exception
                deq_state.mode.store ? 6'h07 : 6'h05
            );
        end
    end

    // LSU transaction complete queue, result indicates potential exceptions
    logic trans_complete_valid, trans_complete_ready;
    assign trans_complete_valid = output_queue_valid_out & output_queue_ready_in & deq_state.last_cycle &
                                  (deq_state.field_init_count == 0 | (deq_state.field_counter == deq_state.field_init_count)) &
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
    assign rdata_buf_d = output_queue_ready_in & scratch_queue_pending_out ? scratch_pending_output : scratch_queue_data_out;

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