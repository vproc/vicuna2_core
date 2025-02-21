// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Modifications 2024 TUM by J Parker Jones
////////////////////////////////////////////////////////////////////////////////
// Engineer:       Matthias Baer - baermatt@student.ethz.ch                   //
//                                                                            //
// Additional contributions by:                                               //
//                 Igor Loi - igor.loi@unibo.it                               //
//                 Andreas Traber - atraber@student.ethz.ch                   //
//                 Michael Gautschi - gautschi@iis.ee.ethz.ch                 //
//                 Davide Schiavone - pschiavo@iis.ee.ethz.ch                 //
//                 Halfdan Bechmann - halfdan.bechmann@silabs.com             //
//                 Arjan Bink - arjan.bink@silabs.com                         //
//                 Kristine D�svik  - kristine.dosvik@silabs.com              //
//                                                                            //
// Design Name:    ALU                                                        //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Arithmetic logic unit of the pipelined processor           //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////
//
////////////////////////////////////////////////////////////////////////////////
// Shifter based on https://github.com/riscv/riscv-bitmanip/blob/main-history///
// verilog/rvb_shifter/rvb_shifter.v                                          //
//                                                                            //
// Copyright (C) 2019  Claire Wolf <claire@symbioticeda.com>                  //
//                                                                            //
// Permission to use, copy, modify, and/or distribute this software for any   //
// purpose with or without fee is hereby granted, provided that the above     //
// copyright notice and this permission notice appear in all copies.          //
//                                                                            //
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES   //
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF           //
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR    //
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES     //
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN      //
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF    //
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.             //
////////////////////////////////////////////////////////////////////////////////

module vproc_div_shift_clz import cv32e40x_pkg::*;
(
  input  logic [31:0]       muldiv_operand_b_i,

  // Divider interface towards CLZ
  input logic               div_clz_en_i,
  input logic [31:0]        div_clz_data_rev_i,
  output logic [5:0]        div_clz_result_o,

  // Divider interface towards shifter
  input logic               div_shift_en_i,
  input logic [5:0]         div_shift_amt_i,
  output logic [31:0]       div_op_b_shifted_o
);
  ////////////////////////////////////////
  //  ____  _   _ ___ _____ _____       //
  // / ___|| | | |_ _|  ___|_   _|      //
  // \___ \| |_| || || |_    | |        //
  //  ___) |  _  || ||  _|   | |        //
  // |____/|_| |_|___|_|     |_|        //
  //                                    //
  ////////////////////////////////////////

  // Shifter is used for:
  // - DIV_DIVU, DIV_DIVU, DIV_REM, DIV_REMU

  logic [5:0]  shifter_shamt;           // Shift amount
  logic [31:0] shifter_aa, shifter_bb;
  logic [63:0] shifter_tmp;

  always_comb begin
      shifter_shamt =  {1'b0, div_shift_amt_i[4:0]};    // DIV(U), REM(U) always use shift left - will always use this one
  end

  always_comb begin
    shifter_aa = muldiv_operand_b_i;
    shifter_bb = 32'h0;
  end

  always_comb begin
    shifter_tmp = {shifter_bb, shifter_aa};
    shifter_tmp = shifter_shamt[5] ? {shifter_tmp[31:0], shifter_tmp[63:32]} : shifter_tmp;
    shifter_tmp = shifter_shamt[4] ? {shifter_tmp[47:0], shifter_tmp[63:48]} : shifter_tmp;
    shifter_tmp = shifter_shamt[3] ? {shifter_tmp[55:0], shifter_tmp[63:56]} : shifter_tmp;
    shifter_tmp = shifter_shamt[2] ? {shifter_tmp[59:0], shifter_tmp[63:60]} : shifter_tmp;
    shifter_tmp = shifter_shamt[1] ? {shifter_tmp[61:0], shifter_tmp[63:62]} : shifter_tmp;
    shifter_tmp = shifter_shamt[0] ? {shifter_tmp[62:0], shifter_tmp[63:63]} : shifter_tmp;
  end

  assign div_op_b_shifted_o = shifter_tmp[31:0]; //output set


  /////////////////////////////////////////////////////////////////////
  //   ____  _ _      ____                  _      ___               //
  //  | __ )(_) |_   / ___|___  _   _ _ __ | |_   / _ \ _ __  ___    //
  //  |  _ \| | __| | |   / _ \| | | | '_ \| __| | | | | '_ \/ __|   //
  //  | |_) | | |_  | |__| (_) | |_| | | | | |_  | |_| | |_) \__ \_  //
  //  |____/|_|\__|  \____\___/ \__,_|_| |_|\__|  \___/| .__/|___(_) //
  //                                                   |_|           //
  /////////////////////////////////////////////////////////////////////

  logic [31:0] clz_data_in;
  logic [4:0]  ff1_result; // holds the index of the first '1'
  logic        ff_no_one;  // if no ones are found

  assign clz_data_in = div_clz_data_rev_i;

  cv32e40x_ff_one ff_one_i
  (
    .in_i        ( clz_data_in ),
    .first_one_o ( ff1_result ),
    .no_ones_o   ( ff_no_one  )
  );

  // Divider assumes CLZ returning 32 when there are no zeros (as per CLZ spec)
  assign div_clz_result_o = ff_no_one ? 6'd32 : ff1_result;



endmodule
