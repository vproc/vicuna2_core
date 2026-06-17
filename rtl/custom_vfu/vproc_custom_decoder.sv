module vproc_custom_decoder #(
        parameter int unsigned          VREG_W             = 128,
        parameter int unsigned          CFG_VL_W           = 7,    // width of VL CSR register
        parameter int unsigned          XIF_MEM_W          = 0,    // width of XIF mem iface
        parameter bit                   DONT_CARE_ZERO     = 1'b0
    )(
        input  logic [31:0]             instr_i,

        input  vproc_pkg::cfg_vsew      vsew_i,       // current SEW (single element width)
        input  vproc_pkg::cfg_lmul      lmul_i,       // current register size multiplier


        output logic                    valid_o,
        output vproc_pkg::op_mode       mode_o,
        output vproc_pkg::op_regs       rs1_o,        // source register rs1/vs1
        output vproc_pkg::op_regs       rs2_o,        // source register rs2/vs2
        output vproc_pkg::op_regd       rd_o          // destination register rd/vd
    );

    always_comb begin
        valid_o = 1'b0;

        mode_o.unused = DONT_CARE_ZERO ? '0 : 'x;

        rs1_o.vreg    = DONT_CARE_ZERO ? 1'b0 : 1'bx;
        rs1_o.xreg    = 1'b0;
        rs1_o.r.xval  = DONT_CARE_ZERO ? '0 : 'x;
        rs1_o.r.vaddr = DONT_CARE_ZERO ? '0 : 'x;

        rs2_o.vreg    = DONT_CARE_ZERO ? 1'b0 : 1'bx;
        rs2_o.xreg    = 1'b0;
        rs2_o.r.xval  = DONT_CARE_ZERO ? '0 : 'x;
        rs2_o.r.vaddr = DONT_CARE_ZERO ? '0 : 'x;

        rd_o.vreg     = DONT_CARE_ZERO ? 1'b0 : 1'bx;
        rd_o.addr     = DONT_CARE_ZERO ? 1'b0 : 1'bx;

        //define custom op here:
        unique case (instr_i[6:0])
        //////////////////////////////////
        //define custom op here:
            7'h7F: begin

                valid_o = 1'b1;


                rs1_o.vreg    = 1'b1; // rs1 is a vector register
                rs1_o.xreg    = 1'b0;
                rs1_o.r.vaddr = instr_i[19:15];
                rs2_o.vreg    = 1'b1; // rs2 is a vector register
                rs2_o.r.vaddr = instr_i[24:20];
                rd_o.vreg         = 1'b1;
                rd_o.addr = instr_i[11:7];
                mode_o.unused[0] = instr_i[31] ? 1'b0 : 1'b1; //set metadata bits based on instruction encoding
                mode_o.unused[1] = 1'b0;
            end
            7'h5F: begin

                valid_o = 1'b1;


                rs1_o.vreg    = 1'b1; // rs1 is a vector register
                rs1_o.xreg    = 1'b0;
                rs1_o.r.vaddr = instr_i[19:15];
                rs2_o.vreg    = 1'b1; // rs2 is a vector register
                rs2_o.r.vaddr = instr_i[24:20];
                rd_o.vreg         = 1'b1;
                rd_o.addr = instr_i[11:7];
                mode_o.unused[0] = 1'b0;
                mode_o.unused[1] = 1'b1;
            end
        //////////////////////////////////
            default: begin
                valid_o = 1'b0;
            end

        endcase
    end



 

endmodule