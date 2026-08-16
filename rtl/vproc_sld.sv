// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_sld #(
        parameter int unsigned        OP_W           = 64,   // SLD unit operand width in bits
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
        SLIDEUP_ZEROS   = 3'b010,
        SLIDEDOWN_ZEROS = 3'b011,
        CLEANUP         = 3'b100
    } slide_state;

    typedef struct packed {
        METADATA_T                      ctrl;
        logic [$clog2((2*OP_W)/8)-1:0]  input_idx;
        logic                           valid;
    } slide_meta_t;

    slide_state state_d, state_q;
    slide_meta_t metadata_d, metadata_q;

    logic [2*OP_W - 1:0] slide_buffer_d, slide_buffer_q;  //main buffer for data

    logic [OP_W/8 - 1:0] mask_buffer_d, mask_buffer_q;  // buffer for mask

    always_ff @(posedge clk_i) begin
        if (~sync_rst_ni) begin
            state_q <= READY;
            slide_buffer_q <= '0;
            mask_buffer_q <= '0;
            metadata_q <= slide_meta_t'(DONT_CARE_ZERO ? '0 : 'x);;
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
    //      SLIDEUP_ZEROS   - Slideup requires the insertion of zeros at the start, before processing input data
    //      SLIDEDOWN_ZEROS - Slidedown requires the insertion of zeroes at the end, after processing input data
    //      CLEANUP         - Slideup operations might leave unprocessed data in the shift registers in UNPACK.  Need to clear them before returning to IDLE
    //
    //      Because the mask is applied directly (without any shifting), it is always consumed at a constant rate, allowing it to be used to synchronize state transitions
    //////////////////

    always_comb begin
        state_d = state_q;
        metadata_d = metadata_q;
        metadata_d.ctrl = pipe_in_ctrl_i;
        metadata_d.valid = pipe_in_valid_i & pipe_in_mask_valid_i;
        unique case (state_q)
            READY: begin
                if (pipe_in_ctrl_i.first_cycle & (pipe_in_valid_i & pipe_in_mask_valid_i) & pipe_out_ready_i) begin
                    //on first cycle, select next state based on operation performed
                    unique case ({pipe_in_ctrl_i.mode.sld.dir, pipe_in_ctrl_i.mode.sld.slide1})
                        {SLD_UP, 1'b0}:;    //TODO
                        {SLD_UP, 1'b1}: begin
                                state_d = SLIDING;
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: metadata_d.input_idx = 4;
                                    VSEW_16: metadata_d.input_idx = 2;
                                    VSEW_8 : metadata_d.input_idx = 1;
                                endcase
                        end
                        {SLD_DOWN, 1'b0}:;  //TODO:
                        {SLD_DOWN, 1'b1}:;  //TODO:
                    endcase
                end
            end
            SLIDING: begin
                if (pipe_in_ctrl_i.last_cycle & (pipe_in_valid_i & pipe_in_mask_valid_i)) begin  //On last cycle of mask input, leave sliding state.  All relevant data has been loaded
                    state_d = (pipe_in_ctrl_i.mode.sld.dir == SLD_UP) ? CLEANUP : READY; //Slideup operations need to enter cleanup state
                end
            end
            CLEANUP: begin
                if (!pipe_in_valid_i) begin  //if all register data has been cleared, return to READY
                    state_d = READY;
                end
            end
            SLIDEUP_ZEROS:;
            SLIDEDOWN_ZEROS:;
        endcase
    end

    /////////////
    // Buffer assignments
    ////////////
    //main buffer assignment
    always_comb begin
        slide_buffer_d = slide_buffer_q;
        if (pipe_in_valid_i & pipe_in_ready_o) begin  //Only update on accepting new data
            unique case (state_q)
                READY: begin
                    //Initialize buffer based on shift type and SEW
                    unique case ({pipe_in_ctrl_i.mode.sld.dir, pipe_in_ctrl_i.mode.sld.slide1})
                        {SLD_UP, 1'b0}:;    //TODO
                        {SLD_UP, 1'b1}: begin
                                unique case (pipe_in_ctrl_i.eew)            //Select writing index in buffer based on SEW of slide
                                    VSEW_32: slide_buffer_d[2*OP_W-1 : 0] = {{(OP_W-32){1'b0}}, pipe_in_op_i, pipe_in_ctrl_i.op_xval[1][31:0]};
                                    VSEW_16: slide_buffer_d[2*OP_W-1 : 0] = {{(OP_W-16){1'b0}}, pipe_in_op_i, pipe_in_ctrl_i.op_xval[1][15:0]};
                                    VSEW_8 : slide_buffer_d[2*OP_W-1 : 0] = {{(OP_W-8){1'b0}}, pipe_in_op_i, pipe_in_ctrl_i.op_xval[1][7:0]};
                                endcase
                        end
                        {SLD_DOWN, 1'b0}:;  //TODO:
                        {SLD_DOWN, 1'b1}:;  //TODO:
                    endcase

                end
                SLIDING: begin
                    // when sliding, copy bytes from upper part of buffer or from input depending on the byte index of the slide
                    for (int i = 0; i < (OP_W*2/8); i++) begin
                        slide_buffer_d[i*8 +: 8] = (i < metadata_q.input_idx) ? slide_buffer_d[(OP_W + i*8) +: 8] : pipe_in_op_i[(i - metadata_q.input_idx)*8 +: 8];
                    end
                end
                SLIDEUP_ZEROS:;     //TODO:
                SLIDEDOWN_ZEROS:;   //TODO:
                CLEANUP:;
            endcase
        end
    end

    //mask buffer assignment
    //no modifications to the mask buffer necessary, pass directly through
    always_comb begin
        mask_buffer_d = mask_buffer_q;
        if (pipe_in_mask_valid_i & pipe_in_valid_i) begin
            mask_buffer_d = pipe_in_mask_i;
        end  
    end

    /////////
    //  Input/Output Handshakes
    /////////

    //operand ready when both input are valid in IDLE or SLIDING state OR when in CLEANUP state
    assign pipe_in_ready_o      = (pipe_in_valid_i & pipe_in_mask_valid_i & (state_q == SLIDING | state_q == READY)) | state_q == CLEANUP;
    //mask ready whenever all input are valid
    assign pipe_in_mask_ready_o = (pipe_in_valid_i & pipe_in_mask_valid_i);


    assign pipe_out_valid_o = metadata_q.valid;
    assign pipe_out_res_o = slide_buffer_q[OP_W-1:0];
    assign pipe_out_ctrl_o = metadata_q.ctrl;
    assign pipe_out_mask_o = mask_buffer_q;

endmodule
