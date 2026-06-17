module vproc_custom_vfu #(
        parameter int unsigned          OP_W             = 64,
        parameter bit                   BUF_OPERANDS     = 1'b1, // insert pipeline stage after operand extraction
        parameter bit                   BUF_INTERMEDIATE = 1'b1, // insert pipeline stage for for intermediate results
        parameter bit                   BUF_RESULTS      = 1'b1, // insert pipeline stage after computing result
        parameter type                  CTRL_T           = logic,
        parameter bit                   DONT_CARE_ZERO   = 1'b0, // initialize don't care values to zero
        parameter bit                   ZKT_ACTIVE       = 1'b0  // flag to enforce data independent runtime
    )(
        input  logic                    clk_i,
        input  logic                    async_rst_ni,
        input  logic                    sync_rst_ni,

        input  logic                    pipe_in_valid_i,
        output logic                    pipe_in_ready_o,
        input  CTRL_T                   pipe_in_ctrl_i,
        input  logic [OP_W  -1:0]       pipe_in_op1_i,
        input  logic [OP_W  -1:0]       pipe_in_op2_i,
        input  logic [OP_W  -1:0]       pipe_in_op3_i,
        input  logic [OP_W/8-1:0]       pipe_in_mask_i,

        output logic                    pipe_out_valid_o,
        input  logic                    pipe_out_ready_i,
        output CTRL_T                   pipe_out_ctrl_o,
        output logic [OP_W  -1:0]       pipe_out_res_o,
        output logic [OP_W/8-1:0]       pipe_out_mask_o
    ); /*verilator public_module*/

        /*Current Vicuna pipeline expects at least one pipeline stage inside the functional unit (at least one cycle latency)*/
        localparam PIPELINE_STAGES = 1;
        logic [OP_W  -1:0] data[PIPELINE_STAGES];
        CTRL_T ctrl[PIPELINE_STAGES];
        logic [OP_W/8-1:0] mask[PIPELINE_STAGES];
        // Handshake vars
        logic valid[PIPELINE_STAGES];
        /* verilator lint_off UNOPTFLAT */
        logic ready[PIPELINE_STAGES];

        always_ff @(posedge clk_i) begin
            begin
                ctrl[0] <= pipe_in_ctrl_i;
                data[0] <= pipe_in_op3_i;
                mask[0] <= pipe_in_mask_i;
                valid[0] <= pipe_in_valid_i;
            end
        end

    always_comb begin
        pipe_out_valid_o = valid[0];
        pipe_in_ready_o = 1'b1; //pipe in always ready (TODO: Investigate this handshake, ready needs to be high to initiate any transfer (i.e. before output ready is raised))
        pipe_out_ctrl_o = ctrl[0];
         //Based on metadata bits, perform different operations.  (These are dummy ops)
        pipe_out_res_o =  ctrl[0].mode.custom.unused[0] ? '1 : data[0];
        if (ctrl[0].mode.custom.unused[1]) begin
            pipe_out_res_o =   32'h55555555;
        end
        pipe_out_mask_o = '1; //Mask

    end
 






endmodule;
