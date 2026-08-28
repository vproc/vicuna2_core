module vproc_redminmax_tree_tb;

    localparam int unsigned ELEM_W    = 32;
    localparam int unsigned N         = 4;
    localparam int unsigned RAND_ITER = 2000;

    // Corner values used both for directed cases and as the random value pool.
    localparam int unsigned NCORNER   = 5;

    logic [N-1:0][ELEM_W-1:0] elem;
    logic                     is_max;
    logic                     is_signed;
    logic [ELEM_W-1:0]        res;

    int unsigned checks = 0;
    int unsigned errors = 0;

    vproc_redminmax_tree #(
        .ELEM_W ( ELEM_W ),
        .N      ( N      )
    ) dut (
        .elem_i      ( elem      ),
        .is_max_i    ( is_max    ),
        .is_signed_i ( is_signed ),
        .res_o       ( res       )
    );

    ////////////////////////////////////////////////////////////////////////////
    // Reference model
    ////////////////////////////////////////////////////////////////////////////

    function automatic logic [ELEM_W-1:0] ref_minmax(
        input logic [N-1:0][ELEM_W-1:0] v,
        input logic                     max,
        input logic                     sgn
    );
        logic [ELEM_W-1:0] acc;
        logic              take;

        acc = v[0];
        for (int i = 1; i < N; i++) begin
            if (sgn) begin
                take = max ? ($signed(v[i])   > $signed(acc))
                           : ($signed(v[i])   < $signed(acc));
            end else begin
                take = max ? ($unsigned(v[i]) > $unsigned(acc))
                           : ($unsigned(v[i]) < $unsigned(acc));
            end
            if (take) begin
                acc = v[i];
            end
        end
        return acc;
    endfunction

    ////////////////////////////////////////////////////////////////////////////
    // Stimulus helpers
    ////////////////////////////////////////////////////////////////////////////

    // Value pool that straddles every interesting boundary of the signed /
    // unsigned interpretation.
    function automatic logic [ELEM_W-1:0] corner_val(input int unsigned k);
        case (k)
            0:       return '0;                                 // 0
            1:       return {ELEM_W{1'b1}};                     // -1 / UMAX
            2:       return {1'b0, {(ELEM_W-1){1'b1}}};         // SMAX
            3:       return {1'b1, {(ELEM_W-1){1'b0}}};         // SMIN
            default: return {{(ELEM_W-1){1'b0}}, 1'b1};         // 1
        endcase
    endfunction

    function automatic logic [ELEM_W-1:0] rand_word();
        logic [ELEM_W-1:0] w;
        w = '0;
        for (int b = 0; b < ELEM_W; b += 32) begin
            w |= ELEM_W'($urandom) << b;
        end
        return w;
    endfunction

    // Mixed distribution: corners to hit the boundaries, small values to make
    // ties and near-misses frequent, full-range words for everything else.
    function automatic logic [ELEM_W-1:0] rand_elem();
        int unsigned sel;
        sel = $urandom_range(0, 3);
        case (sel)
            0:       return corner_val($urandom_range(0, NCORNER - 1));
            1:       return ELEM_W'($urandom_range(0, 7));
            default: return rand_word();
        endcase
    endfunction

    function automatic string vec2str(input logic [N-1:0][ELEM_W-1:0] v);
        string s;
        s = "";
        for (int i = 0; i < N; i++) begin
            s = {s, $sformatf("[%0d]=%0h ", i, v[i])};
        end
        return s;
    endfunction

    ////////////////////////////////////////////////////////////////////////////
    // Checkers
    ////////////////////////////////////////////////////////////////////////////

    task automatic check(input logic [N-1:0][ELEM_W-1:0] v,
                         input logic                     max,
                         input logic                     sgn,
                         input string                    label);
        logic [ELEM_W-1:0] exp;

        elem      = v;
        is_max    = max;
        is_signed = sgn;
        #1;                                 // let the combinational DUT settle

        exp    = ref_minmax(v, max, sgn);
        checks = checks + 1;

        // !== so that an X on res counts as a failure rather than matching.
        if (res !== exp) begin
            errors = errors + 1;
            if (errors <= 20) begin         // keep the log readable
                $display("FAIL [%s] %s%s: %s-> res=%0h exp=%0h",
                         label,
                         sgn ? "signed "  : "unsigned ",
                         max ? "max"      : "min",
                         vec2str(v), res, exp);
            end
        end
    endtask

    // Every stimulus is worth running in all four operating modes.
    task automatic check_all(input logic [N-1:0][ELEM_W-1:0] v,
                             input string                    label);
        for (int m = 0; m < 2; m++) begin
            for (int s = 0; s < 2; s++) begin
                check(v, m[0], s[0], label);
            end
        end
    endtask

    ////////////////////////////////////////////////////////////////////////////
    // Test sequence
    ////////////////////////////////////////////////////////////////////////////

    initial begin
        logic [N-1:0][ELEM_W-1:0] v;
        int unsigned              combos;
        int unsigned              t;

        $display("=== vproc_redminmax_tree_tb: ELEM_W=%0d N=%0d ===", ELEM_W, N);

        // --- Directed cases -------------------------------------------------

        for (int i = 0; i < N; i++) v[i] = '0;
        check_all(v, "all-zero");

        for (int i = 0; i < N; i++) v[i] = ELEM_W'(32'h5A5A_5A5A);
        check_all(v, "all-equal");

        // Ramps: the winner sits at a known end, so an off-by-one in the tree
        // pairing shows up immediately.
        for (int i = 0; i < N; i++) v[i] = ELEM_W'(i + 1);
        check_all(v, "ramp-up");

        for (int i = 0; i < N; i++) v[i] = ELEM_W'(N - i);
        check_all(v, "ramp-down");

        for (int i = 0; i < N; i++) v[i] = corner_val(4);
        v[0] = corner_val(2);
        check_all(v, "winner-at-0");

        for (int i = 0; i < N; i++) v[i] = corner_val(4);
        v[N-1] = corner_val(2);
        check_all(v, "winner-at-last");

        // Signed vs unsigned distinguishers: all-ones is UMAX unsigned but -1
        // signed, SMIN is the smallest signed value but nearly the largest
        // unsigned one. Anything wrong with the width extension fails here.
        for (int i = 0; i < N; i++) v[i] = (i % 2 == 0) ? corner_val(1) : corner_val(4);
        check_all(v, "ones-vs-one");

        for (int i = 0; i < N; i++) v[i] = (i % 2 == 0) ? corner_val(3) : corner_val(2);
        check_all(v, "smin-vs-smax");

        for (int i = 0; i < N; i++) v[i] = corner_val(2);
        v[N/2] = corner_val(3);
        check_all(v, "lone-smin");

        for (int i = 0; i < N; i++) v[i] = corner_val(3);
        v[N/2] = corner_val(0);
        check_all(v, "lone-zero");

        // --- Exhaustive over the corner pool --------------------------------
        // NCORNER**N stimuli, i.e. every arrangement of the boundary values.
        // Cheap for the N we care about; skipped if the count explodes.
        combos = NCORNER ** N;
        if (combos <= 4096) begin
            for (int unsigned c = 0; c < combos; c++) begin
                t = c;
                for (int i = 0; i < N; i++) begin
                    v[i] = corner_val(t % NCORNER);
                    t    = t / NCORNER;
                end
                check_all(v, "corner-combo");
            end
        end else begin
            $display("NOTE: skipping exhaustive corner sweep (%0d combos)", combos);
        end
 
        // --- Constrained random ---------------------------------------------
        // $urandom is seeded deterministically, so a failure reproduces.
        for (int unsigned it = 0; it < RAND_ITER; it++) begin
            for (int i = 0; i < N; i++) begin
                v[i] = rand_elem();
            end
            check_all(v, "random");
        end

        // --- Summary ---------------------------------------------------------

        $display("=== %0d checks, %0d failures ===", checks, errors);
        if (errors != 0) begin
            $fatal(1, "TESTBENCH FAILED");
        end
        $display("TESTBENCH PASSED");
        $finish;
    end

endmodule
