//Arbiter for register file access.  For timing predictability, ensure oldest instruction always receives access.
module vproc_vreg_arbiter
    #( 
        parameter int unsigned                        ID_W         = 5,  // log2(number of possible instruction IDs in the system)
        parameter int unsigned                        REQUESTORS   = 2,  // # of possible requestors per arbiter (number of pipelines)

        parameter int unsigned                        NUM_PORTS_RD = 3, //TODO: +1 for mask reg?
        parameter int unsigned                        NUM_PORTS_WR = 1
    )(

        input  logic                            clk_i,
        input  logic                            rst_ni,

        //add new entries when instruction is dispatched (max one per cycle)
        input  logic                            set_i,
        input  logic[ID_W-1:0]                  set_id_i,

        //clear entry when instruction is completed (max one per cycle)
        input  logic                            clear_i,
        input  logic[ID_W-1:0]                  clear_id_i,

        //Read Arbiter Interface
        input  logic[REQUESTORS-1:0][NUM_PORTS_RD-1:0]            rd_req_i,
        input  logic[REQUESTORS-1:0][ID_W-1:0]                 rd_req_id_i,
        output logic[REQUESTORS-1:0][NUM_PORTS_RD-1:0]            rd_gnt_o,

        //Write Arbiter Interface
        input  logic[REQUESTORS-1:0][NUM_PORTS_WR-1:0]            wr_req_i,
        input  logic[REQUESTORS-1:0][ID_W-1:0]                 wr_req_id_i,
        output logic[REQUESTORS-1:0][NUM_PORTS_WR-1:0]            wr_gnt_o,

        //On successful write, generate vector to clear pending writes
        input logic[REQUESTORS-1:0][NUM_PORTS_WR-1:0][4:0]       wr_addr_i,
        output logic[31:0]                                   pend_wr_clr_o


    );

    //Buffer to keep track of ages of current instructions.  One entry for each possible instruction, max value of each entry is total number of instructions -1;
    logic[ID_W**2-1:0][ID_W-1:0] state_d, state_q;

    //keep track of total number of outstanding instructions
    logic[ID_W-1:0] outstanding_d, outstanding_q;

    //keep track of how many instructions have completed that are not the oldest (in case of out of order completion to keep age counts constant)
    logic[ID_W-1:0] completed_d, completed_q;

    always_ff @(posedge clk_i) begin
        if (~rst_ni) begin
            state_q <= '0;
            outstanding_q <= '0;
            completed_q <= '0;
        end else begin
            state_q <= state_d;
            outstanding_q <= outstanding_d;
            completed_q <= completed_d;
        end
    end

    //Outstanding and Completed counter logic
    always_comb begin
        if (set_i & clear_i) begin
            outstanding_d = outstanding_q - completed_q;
        end else if (set_i) begin
            outstanding_d = outstanding_q + 1;
        end else if (clear_i) begin
            outstanding_d = outstanding_q - 1 - completed_q;
        end else begin
            outstanding_d = outstanding_q;
        end
    end

    always_comb begin
        if (!(state_q[clear_id_i] == '0) & clear_i) begin //If cleared instruction was not the oldest one, increment
            completed_d = completed_q + 1;
        end else begin
            completed_d = completed_q;
        end
    end

    //Update the counters for each ID on set and clear
    generate
        for (genvar i = 0; i < ID_W**2; i++) begin  //This condition is fine when ID_W is manually set, not inferred?
            always_comb begin
            if ((i == set_id_i) & set_i) begin //Setting a new value takes precedence for a cell.
                state_d[i] = outstanding_q;
            end else if (clear_i) begin
                state_d[i] = state_q[i] - completed_q - 1;
            end else begin
                state_d[i] = state_q[i];
            end
        end
    end
    endgenerate

    /////////
    // Arbiters
    // Always raises the gnt signal for the oldest instruction requesting access
    // Two arbiters required.  One for the register read interface and one for the register write interface
    /////////

    //Read arbiter
    generate
    for (genvar port = 0; port < NUM_PORTS_RD; port++) begin //For all read ports
        for (genvar requestor = 0; requestor < REQUESTORS; requestor++) begin //Comparison for each port
            logic [REQUESTORS-1:0] gnt_vector;
            assign rd_gnt_o[requestor][port] = &gnt_vector;
            for (genvar others = 0; others < REQUESTORS; others++) begin //Comparison for each port
                always_comb begin
                    if(others == requestor) begin
                        gnt_vector[others] = rd_req_i[requestor][port]; //own value in gnt_vector is the request signal (others and requestor index are the same here)
                    end else begin
                        gnt_vector[others] = (state_q[rd_req_id_i[requestor]] < state_q[rd_req_id_i[others]]) | !rd_req_i[others][port]; //grant to this interface if the instruction is older OR other request is not valid
                    end
                end
            end
        end
    end
    endgenerate

    //Write arbiter
    generate
    for (genvar port = 0; port < NUM_PORTS_WR; port++) begin //For all write ports
        for (genvar requestor = 0; requestor < REQUESTORS; requestor++) begin //Comparison for each port
            logic [REQUESTORS-1:0] gnt_vector;
            assign wr_gnt_o[requestor][port] = &gnt_vector;
            for (genvar others = 0; others < REQUESTORS; others++) begin //Comparison for each port
                always_comb begin
                    if(others == requestor) begin
                        gnt_vector[others] = wr_req_i[requestor][port]; //own value in gnt_vector is the request signal (others and requestor index are the same here)
                    end else begin
                        gnt_vector[others] = (state_q[wr_req_id_i[requestor]] < state_q[wr_req_id_i[others]]) | !wr_req_i[others][port]; //grant to this interface if the instruction is older OR other request is not valid
                    end
                end
            end
        end
    end
    endgenerate

    //Generate pending wr clear bits
    generate
    for (genvar vreg = 0; vreg < 32; vreg++) begin //For all write ports
        logic[NUM_PORTS_WR-1:0] write_across_ports;
        assign pend_wr_clr_o[vreg] = |write_across_ports;
        for (genvar port = 0; port < NUM_PORTS_WR; port++) begin
            logic[REQUESTORS-1:0] write_across_requestors;
            assign write_across_ports[port] = |write_across_requestors;
            for (genvar requestor = 0; requestor < REQUESTORS; requestor++) begin
                assign write_across_requestors[requestor] = wr_gnt_o[requestor][port] & (wr_addr_i[requestor][port] == vreg); //Mark if successful write on a port.
            end
        end
    end
    endgenerate

endmodule
