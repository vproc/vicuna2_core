// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// This module handles all csr accesses within Vicuna.  This includes the standard vector CSRs (vtype, etc) as well as the custom performance counters for TODO: functional unit utilization

module vproc_csr import vproc_pkg::*; #(
        parameter int unsigned          VLEN                     = 128,
        parameter int unsigned          CFG_VL_W                 = $clog2(VLEN),
        parameter type                  DEC_DATA_CSR_T           = logic,
        parameter int unsigned          XIF_ID_W                 = 4
)(
    input  logic                     clk_i,
    input  logic                     async_rst_ni,
    input  logic                     sync_rst_ni,

    //Interface to expose csrs to DECODE

    output logic [CFG_VL_W-1:0]     vl_o,    //TODO: currently passing old vl bytes
    output logic                    vl_0_o,
    output logic [CFG_VL_W:0]       vlmax_o, //TODO: currently passing old vlmax number of elements
    output cfg_lmul                 lmul_o,
    output cfg_vsew                 sew_o,
    output logic                    illegal_cfg_o,
    output cfg_vxrm                 vxrm_o,

    //TODO: Expose other relevant CSRs

    //Interface with CSR dispatch queue
    input  DEC_DATA_CSR_T            dec_data_i,
    input  logic                     valid_i,
    output logic                     ready_o,

    //Interface with Result Module
    output  logic                    result_csr_valid_o,
    input   logic                    result_csr_ready_i,
    output  logic [XIF_ID_W-1:0]     result_csr_id_o,
    output  logic [4:0]              result_csr_addr_o,
    output  logic [31:0]             result_csr_data_o,
    output  logic                    result_csr_we_o,

    //Interface to update VCSR for fixed point ops

    input   logic                    vx_saturate_i,

    //Interface to update custom performance counter CSRs

    input   logic [vproc_pkg::UNIT_CNT - 1 : 0] unit_busy_i

);

assign ready_o = result_csr_ready_i;   //TODO: Will need to generate CSR stalls when vxsat accessed while fixed point operations are pending 

////////////
// Standard VCSRs
////////////

//Standard Vector CSRs, declared as 32 bits for simplicity

logic[31:0] vstart, vcsr, vtype, vl, vlenb; //VXSAT and VXRM are contained within VCSR
logic[31:0] vstart_d, vcsr_d, vtype_d, vl_d;

always_ff @(posedge clk_i) begin
    if (~sync_rst_ni) begin
        vstart <= '0;
        vcsr <= '0;
        vtype <= '0;
        vl <= '0;
    end else begin
        vstart <= vstart_d;
        vcsr <= vcsr_d;
        vtype <= vtype_d;
        vl <= vl_d;
    end
end

assign vlenb = VLEN/8; //Static value for vlenb

always_comb begin //vcsr special handling, since VXSAT bit can be set by a functional unit in parallel to a csr write
    vcsr_d = vcsr;
    vcsr_d[0] = vcsr[0] | vx_saturate_i;
    if (valid_i & ready_o & (dec_data_i.cfg.csr == CSR_VXRM)) begin
        vcsr_d[2:1] = dec_data_i.cfg.w ? dec_data_i.val[1:0] : dec_data_i.cfg.s ? vcsr[2:1] | dec_data_i.val[1:0] : vcsr[2:1] & ~dec_data_i.val[1:0];
    end else if (valid_i & ready_o & (dec_data_i.cfg.csr == CSR_VXSAT)) begin
        vcsr_d[0] = dec_data_i.cfg.w ? dec_data_i.val[0] : dec_data_i.cfg.s ? vcsr[0] | dec_data_i.val[0] : vcsr[0] & ~dec_data_i.val[0];
    end 
    //TODO additional condition for writes to vcsr specifically? could override the vxrm/vxsat
end

logic[31:0] vlmax;
logic       illegal_vsetvl;
always_comb begin
    illegal_vsetvl = 1'b0;
    vlmax = '0;
    case ({dec_data_i.cfg.lmul, dec_data_i.cfg.vsew})
        //TODO:For small VLEN, some of these low end cases might be illegal
        {LMUL_F8, VSEW_8}:  vlmax = (VLEN/8)/8;
        {LMUL_F8, VSEW_16}: vlmax = (VLEN/8)/16;
        {LMUL_F8, VSEW_32}: vlmax = (VLEN/8)/32;
        {LMUL_F4, VSEW_8}:  vlmax = (VLEN/4)/8;
        {LMUL_F4, VSEW_16}: vlmax = (VLEN/4)/16;
        {LMUL_F4, VSEW_32}: vlmax = (VLEN/4)/32;
        {LMUL_F2, VSEW_8}:  vlmax = (VLEN/2)/8;
        {LMUL_F2, VSEW_16}: vlmax = (VLEN/2)/16;
        {LMUL_F2, VSEW_32}: vlmax = (VLEN/2)/32;
        {LMUL_1, VSEW_8}:   vlmax = (VLEN)/8;
        {LMUL_1, VSEW_16}:  vlmax = (VLEN)/16;
        {LMUL_1, VSEW_32}:  vlmax = (VLEN)/32;
        {LMUL_2, VSEW_8}:   vlmax = (VLEN*2)/8;
        {LMUL_2, VSEW_16}:  vlmax = (VLEN*2)/16;
        {LMUL_2, VSEW_32}:  vlmax = (VLEN*2)/32;
        {LMUL_4, VSEW_8}:   vlmax = (VLEN*4)/8;
        {LMUL_4, VSEW_16}:  vlmax = (VLEN*4)/16;
        {LMUL_4, VSEW_32}:  vlmax = (VLEN*4)/32;
        {LMUL_8, VSEW_8}:   vlmax = (VLEN*8)/8;
        {LMUL_8, VSEW_16}:  vlmax = (VLEN*8)/16;
        {LMUL_8, VSEW_32}:  vlmax = (VLEN*8)/32;
        default:            illegal_vsetvl = 1'b1;
    endcase
end

always_comb begin //vtype and vl handled differently, both set explicitly by vsetvl* instructions and these are always writes
    vtype_d = vtype;
    vl_d = vl;
    if (valid_i & ready_o & (dec_data_i.cfg.csr == CSR_VSETVL)) begin
        //Vtype setting: contains sew, lmul, t/m settings, and vill
        vtype_d[2:0] = {1'b0, dec_data_i.cfg.vsew};
        vtype_d[5:3] = dec_data_i.cfg.lmul;
        vtype_d[7:6] = dec_data_i.cfg.agnostic;

        vtype_d[31]  = illegal_vsetvl; //TODO: reject offloading when this bit is set in decode
        //VL setting
        if (dec_data_i.cfg.keep_vl) begin
            //Keep current vl
            vl_d = vl;
        end else if (dec_data_i.cfg.vlmax) begin
            //set to vlmax
            vl_d = vlmax;
        end else begin
            //set to input value or vlmax
            vl_d = dec_data_i.val < vlmax ? dec_data_i.val : vlmax;
        end
    end
end

always_comb begin //vstart has special handling, can be set explicity(TODO) or by hardware trap (NOT IMPLEMENTED), and reset to 0 upon completion of execution(NOT IMPLEMENTED)
    vstart_d = vstart; //TODO: VSTART handling here, and in pipeline
end

////////////
//  Expose relevant values from vtype to decode
////////////
//Translate vl to # bytes - 1 for pipeline
//TODO: Upgrade pipeline so this is not necessary
always_comb begin
    case ({vtype[1:0]})
        VSEW_8:       vl_o = vl - 1;
        VSEW_16:      vl_o = (vl << 1) - 1;
        VSEW_32:      vl_o = (vl << 2) - 1;
        VSEW_INVALID: vl_o = '0;
    endcase
end

//TODO: Upgrade pipeline so this signal is not necessary
assign vl_0_o = (vl == 0);

always_comb begin
    vlmax_o = '0;
    case ({vtype[5:3], vtype[1:0]})
        //TODO:For small VLEN, some of these low end cases might be illegal
        {LMUL_F8, VSEW_8}:  vlmax_o = (VLEN/8)/8;
        {LMUL_F8, VSEW_16}: vlmax_o = (VLEN/8)/16;
        {LMUL_F8, VSEW_32}: vlmax_o = (VLEN/8)/32;
        {LMUL_F4, VSEW_8}:  vlmax_o = (VLEN/4)/8;
        {LMUL_F4, VSEW_16}: vlmax_o = (VLEN/4)/16;
        {LMUL_F4, VSEW_32}: vlmax_o = (VLEN/4)/32;
        {LMUL_F2, VSEW_8}:  vlmax_o = (VLEN/2)/8;
        {LMUL_F2, VSEW_16}: vlmax_o = (VLEN/2)/16;
        {LMUL_F2, VSEW_32}: vlmax_o = (VLEN/2)/32;
        {LMUL_1, VSEW_8}:   vlmax_o = (VLEN)/8;
        {LMUL_1, VSEW_16}:  vlmax_o = (VLEN)/16;
        {LMUL_1, VSEW_32}:  vlmax_o = (VLEN)/32;
        {LMUL_2, VSEW_8}:   vlmax_o = (VLEN*2)/8;
        {LMUL_2, VSEW_16}:  vlmax_o = (VLEN*2)/16;
        {LMUL_2, VSEW_32}:  vlmax_o = (VLEN*2)/32;
        {LMUL_4, VSEW_8}:   vlmax_o = (VLEN*4)/8;
        {LMUL_4, VSEW_16}:  vlmax_o = (VLEN*4)/16;
        {LMUL_4, VSEW_32}:  vlmax_o = (VLEN*4)/32;
        {LMUL_8, VSEW_8}:   vlmax_o = (VLEN*8)/8;
        {LMUL_8, VSEW_16}:  vlmax_o = (VLEN*8)/16;
        {LMUL_8, VSEW_32}:  vlmax_o = (VLEN*8)/32;
        default;
    endcase
end

assign lmul_o = vtype[5:3];
assign sew_o = vtype[1:0];
assign illegal_cfg_o = vtype[31];
assign vxrm_o = vcsr[2:1];

////////////
//  Custom CSR Performance Counters
////////////

//Custom counters for utilization.  Read only, updated each cycle if the respective functional unit is busy.  Order based on functional unit declarations in vproc_pkg.  Indexed based on provided scalar val
//TODO: Optionally declare these to reduce overhead
logic [vproc_pkg::UNIT_CNT : 0][31:0] util_cntr; //UNIT_CNT + 1 counters for all units + CFG 

generate
    for (genvar i = 0; i < UNIT_CNT ; i ++) begin
        always_ff @(posedge clk_i) begin
            if (~sync_rst_ni) begin
                util_cntr[i] <= '0;
            end else begin
                util_cntr[i] <= unit_busy_i[i] ? util_cntr[i] + 1 : util_cntr[i];
            end
        end
    end
endgenerate

// CFG unit handled separately.  Counted as busy if valid cfg data is available, even if stalled
always_ff @(posedge clk_i) begin
    if (~sync_rst_ni) begin
        util_cntr[UNIT_CNT] <= '0;
    end else begin
        util_cntr[UNIT_CNT] <= valid_i ? util_cntr[UNIT_CNT] + 1 : util_cntr[UNIT_CNT];
    end
end

////////////
//  Output Interface to Result
////////////

assign result_csr_valid_o = valid_i & ready_o; //valid output on successful operation accept
assign result_csr_id_o = dec_data_i.id;
assign result_csr_addr_o = dec_data_i.dest_addr;

always_comb begin
    case(dec_data_i.cfg.csr)
        CSR_VSETVL: result_csr_data_o = vl_d; //vsetvl result is the new value of vl
        CSR_VXRM:   result_csr_data_o = {{(30){1'b0}}, vcsr[2:1]};
        CSR_VXSAT:  result_csr_data_o = {{(31){1'b0}}, vcsr[0]};
        CSR_VPERF:  result_csr_data_o = util_cntr[dec_data_i.val];
        CSR_VL:     result_csr_data_o = vl;
        default: result_csr_data_o = '0;
    endcase
end

endmodule
