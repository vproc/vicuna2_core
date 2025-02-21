// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_pending_wr #(
        parameter int unsigned          CFG_VL_W       = 7,       // width of VL CSR register
        parameter int unsigned          VREG_W         = 128,     // vector register width in bits
        parameter bit                   DONT_CARE_ZERO = 1'b0     // initialize don't care values to zero
    )(
        input  vproc_pkg::cfg_vsew      vsew_i,
        input  vproc_pkg::cfg_emul      emul_i,
        input  logic [CFG_VL_W-1:0]     vl_i,

        input  vproc_pkg::op_unit       unit_i,
        input  vproc_pkg::op_mode       mode_i,
        input  vproc_pkg::op_widenarrow widenarrow_i,

        input  vproc_pkg::op_regd       rd_i,

        output logic [31:0]             pending_wr_o
    );

    import vproc_pkg::*;

    logic [31:0] pend_vd;

    //Changes to control flow to improve performance.  Introduces timing anomalies
    //Here, only the vregs that will actually be used are marked with a pending write.  
    // Old Vicuna marks all vregs in a group with a pending write, regardless of if the current vector has elements in them or not
     `ifdef OLD_VICUNA
        always_comb begin
            pend_vd = DONT_CARE_ZERO ? '0 : 'x;
            if (unit_i == UNIT_LSU) begin
                unique case ({emul_i, mode_i.lsu.nfields})
                    {EMUL_1, 3'b000}: pend_vd = 32'h01 <<  rd_i.addr              ;
                    {EMUL_1, 3'b001}: pend_vd = 32'h03 <<  rd_i.addr              ;
                    {EMUL_1, 3'b010}: pend_vd = 32'h07 <<  rd_i.addr              ;
                    {EMUL_1, 3'b011}: pend_vd = 32'h0F <<  rd_i.addr              ;
                    {EMUL_1, 3'b100}: pend_vd = 32'h1F <<  rd_i.addr              ;
                    {EMUL_1, 3'b101}: pend_vd = 32'h3F <<  rd_i.addr              ;
                    {EMUL_1, 3'b110}: pend_vd = 32'h7F <<  rd_i.addr              ;
                    {EMUL_1, 3'b111}: pend_vd = 32'hFF <<  rd_i.addr              ;
                    {EMUL_2, 3'b000}: pend_vd = 32'h03 << {rd_i.addr[4:1], 1'b0  };
                    {EMUL_2, 3'b001}: pend_vd = 32'h0F << {rd_i.addr[4:1], 1'b0  };
                    {EMUL_2, 3'b010}: pend_vd = 32'h3F << {rd_i.addr[4:1], 1'b0  };
                    {EMUL_2, 3'b011}: pend_vd = 32'hFF << {rd_i.addr[4:1], 1'b0  };
                    {EMUL_4, 3'b000}: pend_vd = 32'h0F << {rd_i.addr[4:2], 2'b00 };
                    {EMUL_4, 3'b001}: pend_vd = 32'hFF << {rd_i.addr[4:2], 2'b00 };
                    {EMUL_8, 3'b000}: pend_vd = 32'hFF << {rd_i.addr[4:3], 3'b000};
                    default: ;
                endcase
            end else begin
                unique case ({emul_i, widenarrow_i == OP_NARROWING})
                    {EMUL_1, 1'b0},
                    {EMUL_2, 1'b1}: begin
                        pend_vd = rd_i.vreg ? (32'h00000001 <<  rd_i.addr              ) : 32'b0;
                    end
                    {EMUL_2, 1'b0},
                    {EMUL_4, 1'b1}: begin
                        pend_vd = rd_i.vreg ? (32'h00000003 << {rd_i.addr[4:1], 1'b0  }) : 32'b0;
                    end
                    {EMUL_4, 1'b0},
                    {EMUL_8, 1'b1}: begin
                        pend_vd = rd_i.vreg ? (32'h0000000F << {rd_i.addr[4:2], 2'b00 }) : 32'b0;
                    end
                    {EMUL_8, 1'b0}: begin
                        pend_vd = rd_i.vreg ? (32'h000000FF << {rd_i.addr[4:3], 3'b000}) : 32'b0;
                    end
                    default: ;
                endcase
            end
        end

    `else
        always_comb begin
        //only generate pending write if the register is actually used based on VL.  
        logic [3:0] vregs_used;
        pend_vd = DONT_CARE_ZERO ? '0 : 'x;
        vregs_used = ((vl_i) >> $clog2(VREG_W/8)); //returns (# vregs needed for VL - 1) as VL is (# bytes in vector - 1)
        //TODO: lsu.nfields is needed for segmented loads/stores.  may have issues with early stopping due to this.
        if (unit_i == UNIT_LSU) begin
            unique case ({emul_i, mode_i.lsu.nfields, vregs_used})
                {EMUL_1, 3'b000, 4'h0}: pend_vd = 32'h01 <<  rd_i.addr              ; //EMUL_1 always uses 1 vreg
                {EMUL_1, 3'b001, 4'h0}: pend_vd = 32'h03 <<  rd_i.addr              ;
                {EMUL_1, 3'b010, 4'h0}: pend_vd = 32'h07 <<  rd_i.addr              ;
                {EMUL_1, 3'b011, 4'h0}: pend_vd = 32'h0F <<  rd_i.addr              ;
                {EMUL_1, 3'b100, 4'h0}: pend_vd = 32'h1F <<  rd_i.addr              ;
                {EMUL_1, 3'b101, 4'h0}: pend_vd = 32'h3F <<  rd_i.addr              ;
                {EMUL_1, 3'b110, 4'h0}: pend_vd = 32'h7F <<  rd_i.addr              ;
                {EMUL_1, 3'b111, 4'h0}: pend_vd = 32'hFF <<  rd_i.addr              ;

                {EMUL_2, 3'b000, 4'h0}: pend_vd = 32'h01 << {rd_i.addr[4:1], 1'b0  }; //Only mark the vregs actually used by each group with a pending write
                {EMUL_2, 3'b001, 4'h0}: pend_vd = 32'h05 << {rd_i.addr[4:1], 1'b0  };
                {EMUL_2, 3'b010, 4'h0}: pend_vd = 32'h15 << {rd_i.addr[4:1], 1'b0  };
                {EMUL_2, 3'b011, 4'h0}: pend_vd = 32'h55 << {rd_i.addr[4:1], 1'b0  };
                {EMUL_2, 3'b000, 4'h1}: pend_vd = 32'h03 << {rd_i.addr[4:1], 1'b0  };
                {EMUL_2, 3'b001, 4'h1}: pend_vd = 32'h0F << {rd_i.addr[4:1], 1'b0  };
                {EMUL_2, 3'b010, 4'h1}: pend_vd = 32'h3F << {rd_i.addr[4:1], 1'b0  };
                {EMUL_2, 3'b011, 4'h1}: pend_vd = 32'hFF << {rd_i.addr[4:1], 1'b0  };

                {EMUL_4, 3'b000, 4'h0}: pend_vd = 32'h01 << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b001, 4'h0}: pend_vd = 32'h11 << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b000, 4'h1}: pend_vd = 32'h03 << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b001, 4'h1}: pend_vd = 32'h33 << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b000, 4'h2}: pend_vd = 32'h07 << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b001, 4'h2}: pend_vd = 32'h77 << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b000, 4'h3}: pend_vd = 32'h0F << {rd_i.addr[4:2], 2'b00 };
                {EMUL_4, 3'b001, 4'h3}: pend_vd = 32'hFF << {rd_i.addr[4:2], 2'b00 };

                {EMUL_8, 3'b000, 4'h0}: pend_vd = 32'h01 << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h1}: pend_vd = 32'h03 << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h2}: pend_vd = 32'h07 << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h3}: pend_vd = 32'h0F << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h4}: pend_vd = 32'h1F << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h5}: pend_vd = 32'h3F << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h6}: pend_vd = 32'h7F << {rd_i.addr[4:3], 3'b000};
                {EMUL_8, 3'b000, 4'h7}: pend_vd = 32'hFF << {rd_i.addr[4:3], 3'b000};
                default: ;
            endcase
        end else begin
            unique case ({emul_i, widenarrow_i == OP_NARROWING, vregs_used})
                {EMUL_1, 1'b0, 4'h0},          //single width EMUL_1, 1 vreg used
                {EMUL_2, 1'b0, 4'h0},          //single width EMUL_2, 1 vreg used
                {EMUL_2, 1'b1, 4'h0},          //narrowing EMUL_2, 1 vreg used
                {EMUL_2, 1'b1, 4'h1},          //narrowing EMUL_2, 2 vregs used
                {EMUL_4, 1'b0, 4'h0},          //single width EMUL_4, 1 vreg used
                {EMUL_4, 1'b1, 4'h1},          //narrowing EMUL_4, 2 vregs used
                {EMUL_8, 1'b0, 4'h0},          //single width EMUL_8, 1 vreg used
                {EMUL_8, 1'b1, 4'h1}: begin    //narrowing EMUL_8, 2 vregs used
                    pend_vd = rd_i.vreg ? (32'h00000001 <<  rd_i.addr              ) : 32'b0; //Mark one register with a pending write
                end
                {EMUL_2, 1'b0, 4'h1},          //single width EMUL_2, 2 vregs used
                {EMUL_4, 1'b0, 4'h1},          //single width EMUL_4, 2 vregs used
                {EMUL_4, 1'b1, 4'h2},          //narrowing EMUL_4, 3 vregs used
                {EMUL_4, 1'b1, 4'h3},          //narrowing EMUL_4, 4 vregs used
                {EMUL_8, 1'b0, 4'h1},          //single width EMUL_8, 2 vregs used
                {EMUL_8, 1'b1, 4'h2},          //narrowing EMUL_8, 3 vregs used
                {EMUL_8, 1'b1, 4'h3}: begin    //narrowing EMUL_8, 4 vregs used
                    pend_vd = rd_i.vreg ? (32'h00000003 << {rd_i.addr[4:1], 1'b0  }) : 32'b0; //Mark two registers with a pending write
                end
                {EMUL_4, 1'b0, 4'h2},          //single width EMUL_4, 3 vregs used
                {EMUL_8, 1'b0, 4'h2},          //single width EMUL_8, 3 vregs used
                {EMUL_8, 1'b1, 4'h4},          //narrowing EMUL_8, 5 vregs used
                {EMUL_8, 1'b1, 4'h5}: begin    //narrowing EMUL_8, 6 vregs used
                    pend_vd = rd_i.vreg ? (32'h00000007 << {rd_i.addr[4:1], 1'b0  }) : 32'b0; //Mark three registers with a pending write
                end
                {EMUL_4, 1'b0, 4'h3},          //single width EMUL_4, 4 vregs used
                {EMUL_8, 1'b0, 4'h3},          //single width EMUL_8, 4 vregs used
                {EMUL_8, 1'b1, 4'h6},          //narrowing EMUL_8, 7 vregs used
                {EMUL_8, 1'b1, 4'h7}: begin   //narrowing EMUL_8, 8 vregs used
                    pend_vd = rd_i.vreg ? (32'h0000000F << {rd_i.addr[4:2], 2'b00 }) : 32'b0; //Mark four registers with a pending write
                end
                {EMUL_8, 1'b0, 4'h4}: begin    //single width EMUL_8, 5 vregs used
                    pend_vd = rd_i.vreg ? (32'h0000001F << {rd_i.addr[4:3], 3'b000}) : 32'b0; //mark five registers with a pending write
                end
                {EMUL_8, 1'b0, 4'h5}: begin    //single width EMUL_8, 6 vregs used
                    pend_vd = rd_i.vreg ? (32'h0000003F << {rd_i.addr[4:3], 3'b000}) : 32'b0; //mark five registers with a pending write
                end
                {EMUL_8, 1'b0, 4'h6}: begin    //single width EMUL_8, 7 vregs used
                    pend_vd = rd_i.vreg ? (32'h0000007F << {rd_i.addr[4:3], 3'b000}) : 32'b0; //mark five registers with a pending write
                end
                {EMUL_8, 1'b0, 4'h7}: begin    //single width EMUL_8, 8 vregs used
                    pend_vd = rd_i.vreg ? (32'h000000FF << {rd_i.addr[4:3], 3'b000}) : 32'b0; //mark eight registers with a pending write
                end
                default: pend_vd = 32'h00000001 <<  rd_i.addr;
            endcase
        end
    end
    `endif


    always_comb begin
        pending_wr_o = pend_vd;
        unique case (unit_i)
            UNIT_LSU: begin
                if (mode_i.lsu.store) begin
                    pending_wr_o  = '0;
                end
            end
            UNIT_ALU: begin
                if (mode_i.alu.cmp) begin
                    pending_wr_o = rd_i.vreg ? (32'h1 << rd_i.addr) : 32'b0;
                end
            end
            UNIT_ELEM: begin
                if (mode_i.elem.xreg) begin
                    pending_wr_o = '0;
                end
            end
            default: ;
        endcase
    end

endmodule
