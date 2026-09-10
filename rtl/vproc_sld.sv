// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_sld #(
        parameter int unsigned        OP_W           = 64,   // SLD unit operand width in bits
        parameter int unsigned        VLEN              = 128,
        parameter type                METADATA_T         = logic,
        parameter bit                 DONT_CARE_ZERO = 1'b0  // initialize don't care values to zero
    )(
        input  logic                  clk_i,
        input  logic                  async_rst_ni,
        input  logic                  sync_rst_ni,

        input  logic                  pipe_in_valid_i,
        output logic                  pipe_in_ready_o,
        input  METADATA_T             pipe_in_ctrl_i,
        input  logic [OP_W  -1:0]     pipe_in_op_i,
        input  logic [OP_W/8-1:0]     pipe_in_mask_i,
        input  logic                  pipe_in_mask_valid_i,
        output logic                  pipe_in_mask_ready_o,

        output logic                  pipe_out_valid_o,
        input  logic                  pipe_out_ready_i,
        output METADATA_T             pipe_out_ctrl_o,
        output logic [OP_W  -1:0]     pipe_out_res_o,
        output logic [OP_W/8-1:0]     pipe_out_mask_o
    );

    import vproc_pkg::*;

    ////////////////////
    // States, Structs, and Buffers
    ////////////////////

    typedef enum logic[2:0] {
        READY           = 3'b000,
        SLIDING         = 3'b001,
        SLIDEUP_SETUP   = 3'b010,
        CLEANUP         = 3'b100,
        SLIDEDOWN_SETUP = 3'b101
    } slide_state;

    typedef struct packed {
        METADATA_T                          ctrl;
        logic [$clog2((2*OP_W)/8)-1:0]      input_idx; //byte index to load input from pipeline into slidebuffer
        logic [$clog2(32)-1:0] setup_cycles; //Maximum setup cycles is total cycles to go through all data in an LMUL8 vector
        logic [(8*VLEN)/8-1:0] insertion_idx;  // when to begin inserting entires for slidedown or 0's or mask in slideup
        logic                               valid;
        logic                               input_consumed;
    } slide_meta_t;

    slide_state state_d, state_q;
    slide_meta_t metadata_d, metadata_q;

    logic [2*OP_W - 1:0] slide_buffer_d, slide_buffer_q;  //main buffer for data


    //Buffers for masks.  Extra buffer needed for slide down, since at least two inputs are required to assemble the first valid output
    logic [OP_W/8 - 1:0] mask_buffer_d, mask_buffer_q;

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            state_q <= READY;
            slide_buffer_q <= '0;
            mask_buffer_q <= '0;
            metadata_q <= slide_meta_t'(DONT_CARE_ZERO ? '0 : 'x);
        end else begin
            state_q <= state_d;
            slide_buffer_q <= slide_buffer_d;
            mask_buffer_q <= mask_buffer_d;
            metadata_q <= metadata_d;
        end
    end

    //////////////////
    // State transitions
    //
    // Five states:
    //      READY           - Ready for input
    //      SLIDING         - Input values are being processed directly to the output.  Input idx has been calculated
    //      SLIDEUP_SETUP   - Slideup requires the insertion of zeros at the start, before processing input data
    //      SLIDEDOWN_SETUP - Slidedown requires one or more cycles to load the initial data (depends on how many slides take place)
    //      CLEANUP         - Slideup operations might leave unprocessed data in the shift registers in UNPACK.  Need to clear them before returning to IDLE
    //
    //      Because the mask is applied directly (without any shifting), it is always consumed at a constant rate, allowing it to be used to synchronize state transitions
    //////////////////

    always_comb begin
        state_d = state_q;
        metadata_d = metadata_q;
        metadata_d.valid = metadata_q.valid;
        unique case (state_q)
            READY: begin
                metadata_d.valid = 1'b0;
                if (pipe_in_ctrl_i.first_cycle & (pipe_in_valid_i & pipe_in_mask_valid_i) & pipe_out_ready_i) begin
                    metadata_d.ctrl = pipe_in_ctrl_i;
                    //on first cycle, select next state based on operation performed
                    metadata_d.valid = pipe_in_valid_i & pipe_in_mask_valid_i;
                    unique case ({pipe_in_ctrl_i.mode.sld.dir, pipe_in_ctrl_i.mode.sld.slide1})
                        {SLD_UP, 1'b0}: begin
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: begin
                                        metadata_d.input_idx        = ((pipe_in_ctrl_i.op_xval[1][31:0] << 2) & {{(32-$clog2(OP_W/8)){1'b0}}, {($clog2(OP_W/8)){1'b1}}});  //Input index based on lower bits of xval accomplished with mask
                                        metadata_d.insertion_idx    = (pipe_in_ctrl_i.op_xval[1][31:0] << 2);                                                             //Slideup inserts 0s in the byte mask below this index
                                        metadata_d.setup_cycles     = ((pipe_in_ctrl_i.op_xval[1][31:0] << 2) >> $clog2(OP_W/8)) - 1;
                                        state_d = (((pipe_in_ctrl_i.op_xval[1][31:0] << 2)) >> $clog2(OP_W/8) == '0) ? SLIDING: SLIDEUP_SETUP;                                                               //num cycles in setup is xval(bytes)/(OP_W/8), determined via upper bits
                                    end
                                    VSEW_16: begin
                                        metadata_d.input_idx        = ((pipe_in_ctrl_i.op_xval[1][31:0] << 1) & {{(32-$clog2(OP_W/8)){1'b0}}, {($clog2(OP_W/8)){1'b1}}});
                                        metadata_d.insertion_idx    = (pipe_in_ctrl_i.op_xval[1][31:0] << 1);
                                        metadata_d.setup_cycles     = ((pipe_in_ctrl_i.op_xval[1][31:0] << 1) >> $clog2(OP_W/8)) - 1;
                                        state_d = (((pipe_in_ctrl_i.op_xval[1][31:0] << 1)) >> $clog2(OP_W/8) == '0) ? SLIDING: SLIDEUP_SETUP;
                                    end
                                    VSEW_8 : begin
                                        metadata_d.input_idx        = ((pipe_in_ctrl_i.op_xval[1][31:0]) & {{(32-$clog2(OP_W/8)){1'b0}}, {($clog2(OP_W/8)){1'b1}}});
                                        metadata_d.insertion_idx    = (pipe_in_ctrl_i.op_xval[1][31:0]);
                                        metadata_d.setup_cycles     = ((pipe_in_ctrl_i.op_xval[1][31:0]) >> $clog2(OP_W/8)) - 1;
                                        state_d = ((pipe_in_ctrl_i.op_xval[1][31:0]) >> $clog2(OP_W/8) == '0) ? SLIDING: SLIDEUP_SETUP;
                                    end
                                endcase
                        end
                        {SLD_UP, 1'b1}: begin
                                state_d = SLIDING;
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: metadata_d.input_idx = 4;
                                    VSEW_16: metadata_d.input_idx = 2;
                                    VSEW_8 : metadata_d.input_idx = 1;
                                endcase
                        end
                        {SLD_DOWN, 1'b0}: begin
                                state_d = SLIDEDOWN_SETUP;
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: begin
                                        metadata_d.input_idx        = OP_W/8 - ((pipe_in_ctrl_i.op_xval[1][31:0] << 2) & {{(32-$clog2(OP_W/8)){1'b0}}, {($clog2(OP_W/8)){1'b1}}});  //input index is xval(bytes)%(OP_W/8), accomplished via bit mask of lower bits
                                        metadata_d.insertion_idx    = (pipe_in_ctrl_i.op_xval[1][31:0] << 2) > (pipe_in_ctrl_i.vlmax << 2) ? '0 : (pipe_in_ctrl_i.vlmax << 2) - (pipe_in_ctrl_i.op_xval[1][31:0] << 2);//slidedown inserts 0s based on xreg val * 4, vl_max given in elements
                                        metadata_d.setup_cycles     = (pipe_in_ctrl_i.op_xval[1][31:0] << 2) >> $clog2(OP_W/8);                                             //num cycles in setup is xval(bytes)/(OP_W/8), determined via upper bits
                                    end
                                    VSEW_16: begin
                                        metadata_d.input_idx        = OP_W/8 - ((pipe_in_ctrl_i.op_xval[1][31:0] << 1) & {{(32-$clog2(OP_W/8)){1'b0}}, {($clog2(OP_W/8)){1'b1}}});
                                        metadata_d.insertion_idx    = (pipe_in_ctrl_i.op_xval[1][31:0] << 1) > (pipe_in_ctrl_i.vlmax << 1) ? '0 : (pipe_in_ctrl_i.vlmax << 1) - (pipe_in_ctrl_i.op_xval[1][31:0] << 1); 
                                        metadata_d.setup_cycles     = (pipe_in_ctrl_i.op_xval[1][31:0] << 1) >> $clog2(OP_W/8);
                                    end
                                    VSEW_8 : begin
                                        metadata_d.input_idx        = OP_W/8  - ((pipe_in_ctrl_i.op_xval[1][31:0]) & {{(32-$clog2(OP_W/8)){1'b0}}, {($clog2(OP_W/8)){1'b1}}});
                                        metadata_d.insertion_idx    = pipe_in_ctrl_i.op_xval[1][31:0] > pipe_in_ctrl_i.vlmax ? '0 : pipe_in_ctrl_i.vlmax - pipe_in_ctrl_i.op_xval[1][31:0];
                                        metadata_d.setup_cycles     = (pipe_in_ctrl_i.op_xval[1][31:0]) >> $clog2(OP_W/8);
                                    end
                                endcase
                        end
                        {SLD_DOWN, 1'b1}: begin
                                state_d = SLIDEDOWN_SETUP;
                                metadata_d.setup_cycles = 0;                    // Only 1 cycle in setup for slide1down
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: begin
                                        metadata_d.input_idx        = OP_W/8 - 4;
                                        metadata_d.insertion_idx    = pipe_in_ctrl_i.vl - 3; //slide1down inserts at last index in vl, vl given in bytes -1
                                    end
                                    VSEW_16: begin
                                        metadata_d.input_idx        = OP_W/8 - 2;
                                        metadata_d.insertion_idx    = pipe_in_ctrl_i.vl - 1;
                                    end
                                    VSEW_8 : begin
                                        metadata_d.input_idx        = OP_W/8 - 1;
                                        metadata_d.insertion_idx    = pipe_in_ctrl_i.vl;
                                    end
                                endcase
                        end
                    endcase
                end
            end
            SLIDEDOWN_SETUP: begin
                if (metadata_q.setup_cycles == 0 | !pipe_in_valid_i) begin  //Leave this state if the setup is complete or no more valid input data: Might be an issue here with hazard stalls?
                    state_d = SLIDING;
                end else begin
                    metadata_d.setup_cycles = metadata_q.setup_cycles - 1;  
                end 
            end
            SLIDING: begin
                if (pipe_out_ready_i) begin
                    metadata_d.ctrl = pipe_in_ctrl_i;
                    if (pipe_in_ctrl_i.last_cycle & (pipe_in_mask_valid_i)) begin  //On last cycle of mask input, leave sliding state.  All relevant data has been loaded
                        state_d = (pipe_in_ctrl_i.mode.sld.dir == SLD_UP) ? CLEANUP : READY; //Slideup operations need to enter cleanup state to clear any remaining data in unpack registers
                    end
                    metadata_d.insertion_idx = metadata_q.insertion_idx < OP_W/8 ? '0 : metadata_q.insertion_idx - OP_W/8;    //Reduce index by amount processed each cycle, minimum 0
                end
            end
            SLIDEUP_SETUP: begin
                if (pipe_out_ready_i) begin
                    metadata_d.valid = pipe_in_mask_valid_i; //If mask is consumed, mark invalid
                    metadata_d.ctrl = pipe_in_ctrl_i;
                    if (pipe_in_ctrl_i.last_cycle & (pipe_in_mask_valid_i)) begin
                        state_d = CLEANUP;
                    end else if (metadata_q.setup_cycles == 0) begin  //Leave this state if the setup is complete
                        state_d = SLIDING;
                    end else begin
                        metadata_d.setup_cycles = metadata_q.setup_cycles - 1;  
                    end
                    metadata_d.insertion_idx = metadata_q.insertion_idx < OP_W/8 ? '0 : metadata_q.insertion_idx - OP_W/8;    //Reduce index by amount processed each cycle, minimum 0
                end
            end
            CLEANUP: begin
                metadata_d.valid = 1'b0;
                if (!pipe_in_valid_i) begin  //if all register data has been cleared, return to READY
                    state_d = READY;
                end
            end
        endcase
    end

    /////////////
    // Buffer assignments
    ////////////
    //main buffer assignment
    always_comb begin
        slide_buffer_d = slide_buffer_q;
        if ((pipe_in_valid_i & pipe_in_ready_o) | pipe_in_mask_valid_i & pipe_in_mask_ready_o | (state_q == SLIDEDOWN_SETUP)) begin  //Only update on accepting new data (from input data OR mask), with extra case if input data runs out while in slidedown setup
            unique case (state_q)
                READY: begin
                    //Initialize buffer based on shift type and SEW
                    unique case ({pipe_in_ctrl_i.mode.sld.dir, pipe_in_ctrl_i.mode.sld.slide1})
                        {SLD_UP, 1'b1}: begin
                                unique case (pipe_in_ctrl_i.eew)
                                    VSEW_32: slide_buffer_d[2*OP_W-1 : 0] = {{(OP_W-32){1'b0}}, pipe_in_op_i, pipe_in_ctrl_i.op_xval[1][31:0]};
                                    VSEW_16: slide_buffer_d[2*OP_W-1 : 0] = {{(OP_W-16){1'b0}}, pipe_in_op_i, pipe_in_ctrl_i.op_xval[1][15:0]};
                                    VSEW_8 : slide_buffer_d[2*OP_W-1 : 0] = {{(OP_W-8){1'b0}}, pipe_in_op_i, pipe_in_ctrl_i.op_xval[1][7:0]};
                                endcase
                        end
                        {SLD_DOWN, 1'b1}: begin
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: slide_buffer_d[2*OP_W-1 : 0] = {{(32){1'b0}}, pipe_in_op_i, {(OP_W-32){1'b0}}};
                                    VSEW_16: slide_buffer_d[2*OP_W-1 : 0] = {{(16){1'b0}}, pipe_in_op_i, {(OP_W-16){1'b0}}};
                                    VSEW_8 : slide_buffer_d[2*OP_W-1 : 0] = {{(8){1'b0}}, pipe_in_op_i, {(OP_W-8){1'b0}}};
                                endcase
                        end
                        {SLD_UP, 1'b0},
                        {SLD_DOWN, 1'b0}: begin
                            for (int i = 0; i < (OP_W*2/8); i++) begin
                                slide_buffer_d[i*8 +: 8] = (i < metadata_d.input_idx) ? slide_buffer_q[(OP_W + i*8) +: 8] : pipe_in_op_i[(i - metadata_d.input_idx)*8 +: 8]; //Initial cycle index computed from above
                            end
                        end
                    endcase

                end
                SLIDEDOWN_SETUP,
                SLIDING: begin
                    // when sliding, copy bytes from upper part of buffer or from input depending on the byte index of the slide
                    // SLIDEDOWN_SETUP performs the same operation, but without allowing the mask to advance or signalling valid
                    if ((pipe_out_ready_i && state_q == SLIDING) | state_q == SLIDEDOWN_SETUP) begin //If output not ready, don't advance slide
                        for (int i = 0; i < (OP_W*2/8); i++) begin
                            slide_buffer_d[i*8 +: 8] = (i < metadata_q.input_idx) ? slide_buffer_q[(OP_W + i*8) +: 8] : pipe_in_op_i[(i - metadata_q.input_idx)*8 +: 8];
                        end
                        //For slidedown, insert xval depending on insertion_idx
                        case ({pipe_in_ctrl_i.mode.sld.dir, pipe_in_ctrl_i.mode.sld.slide1})
                            {SLD_DOWN, 1'b1}: begin
                                    if (metadata_d.insertion_idx < OP_W/8) begin
                                        unique case (metadata_q.ctrl.eew)            //Select writing index in buffer based on SEW of slide
                                            VSEW_32: slide_buffer_d[metadata_d.insertion_idx * 8 +: 32] = metadata_q.ctrl.op_xval[1][31:0];
                                            VSEW_16: slide_buffer_d[metadata_d.insertion_idx * 8 +: 16] = metadata_q.ctrl.op_xval[1][15:0];
                                            VSEW_8 : slide_buffer_d[metadata_d.insertion_idx * 8 +: 8]  = metadata_q.ctrl.op_xval[1][7:0];
                                        endcase
                                    end
                            end
                        endcase
                    end
                end
                SLIDEUP_SETUP:;     //Slide buffer does not change in slideup setup
                CLEANUP:;           //Slide buffer does not change in cleanup
            endcase
        end
    end

    //mask buffer assignment
    //no modifications to the mask buffer necessary, pass directly through
    always_comb begin
        mask_buffer_d = mask_buffer_q;
        if (pipe_in_mask_valid_i & !(state_q == SLIDEDOWN_SETUP) & pipe_out_ready_i) begin
            mask_buffer_d = pipe_in_mask_i;
        end  
    end
    /////////
    //  Input/Output Handshakes
    /////////

    //operand ready when both input are valid in IDLE or SLIDING state OR when in CLEANUP state
    assign pipe_in_ready_o      = ((pipe_in_valid_i & pipe_in_mask_valid_i & (state_q == SLIDING | state_q == READY | state_q == SLIDEDOWN_SETUP)) | state_q == CLEANUP) & pipe_out_ready_i;
    //mask ready whenever all input are valid and not setting up initial buffer for slidedown
    assign pipe_in_mask_ready_o = (( pipe_in_mask_valid_i) & !(state_q == SLIDEDOWN_SETUP) & (!(!pipe_in_valid_i & state_q == READY))) & pipe_out_ready_i;
    assign pipe_out_valid_o = metadata_q.valid & !(state_q == SLIDEDOWN_SETUP);
    assign pipe_out_ctrl_o = metadata_q.ctrl;

    //For slideup/slide down, write zeros when necessary
    always_comb begin
        pipe_out_res_o = slide_buffer_q[OP_W-1:0];
        pipe_out_mask_o = mask_buffer_q[OP_W/8-1:0];
        case ({metadata_q.ctrl.mode.sld.dir, metadata_q.ctrl.mode.sld.slide1})
            {SLD_DOWN, 1'b0}: begin
                for (int i = 0; i < OP_W/8; i++) begin
                    pipe_out_res_o[8*i +: 8] = i < metadata_q.insertion_idx ? slide_buffer_q[8*i +: 8] : '0; //Write zeroes in slidedown region
                end
            end
            {SLD_UP, 1'b0}: begin
                for (int i = 0; i < OP_W/8; i++) begin
                    pipe_out_mask_o[i] = i < metadata_q.insertion_idx ? 1'b0 : mask_buffer_q[i]; //Don't overwrite values in slideup region (by clearing mask bits)
                end
            end
        endcase
    end

endmodule
