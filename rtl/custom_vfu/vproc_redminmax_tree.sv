

module vproc_redminmax_tree #(
    parameter int unsigned ELEM_W  = 32,    // elem width in bits
    parameter int unsigned N    = 4         // number of elements to reduce
)(
    input  logic [N-1:0][ELEM_W-1:0]    elem_i,
    input  logic                        is_max_i,     // 0 = min, 1 = max
    input  logic                        is_signed_i,  // 0 = unsigned
    output logic [ELEM_W-1:0]           res_o
);

    function automatic logic [ELEM_W-1:0] minmax(input logic [ELEM_W-1:0] a, input logic [ELEM_W-1:0] b);

        logic [ELEM_W:0] a_ext, b_ext;
        // widen by 1 bit and sign extend to only use 1 comparator
        // this allows us to only use signed type in the comparison
        a_ext = {is_signed_i & a[ELEM_W-1], a}; 
        b_ext = {is_signed_i & b[ELEM_W-1], b};
        
        if (is_max_i) begin
            return ($signed(a_ext) > $signed(b_ext)) ? a : b;
        end else begin
            return ($signed(a_ext) < $signed(b_ext)) ? a : b;
        end

    endfunction;

    localparam int unsigned LEVELS = $clog2(N); // ceiling log2

    logic [ELEM_W-1:0] level [LEVELS+1][N];

    always_comb begin
        for (int i = 0; i < N; i++) begin
            level[0][i] = elem_i[i];
        end
        for (int l = 0; l < LEVELS; l++) begin
            for (int n = 0; n < (N >> (l+1)); n++) begin // number of comparisons per level
                level[l+1][n] = minmax(level[l][2*n], level[l][2*n+1]); //compare neighbours
            end
        end
    end

    assign res_o = level[LEVELS][0];

    initial begin
        assert (2**LEVELS == N) else $fatal(1, "N must be a power of two");
    end
endmodule