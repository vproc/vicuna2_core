// Copyright 2024 TU Munich
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_fpu #(
        parameter int unsigned        FPU_OP_W       = 64,   // DIV unit operand width in bits.  Operates on 32 bit wide operands (SEW8 and SEW16 should be extended in regunpack)
        parameter type                CTRL_T         = logic,
        `ifdef RISCV_ZVFH
        parameter fpnew_pkg::fpu_features_t       FPU_FEATURES       = vproc_pkg::RV32ZVFH,           //TODO:Need to pass these all the way to the top level for easy adjustments
        `else
        parameter fpnew_pkg::fpu_features_t       FPU_FEATURES       = fpnew_pkg::RV32F,           //TODO:Need to pass these all the way to the top level for easy adjustments
        `endif
        
        parameter fpnew_pkg::fpu_implementation_t FPU_IMPLEMENTATION = fpnew_pkg::DEFAULT_NOREGS   //TODO:Need to pass these all the way to the top level for easy adjustments 
            )(
        input  logic                  clk_i,
        input  logic                  async_rst_ni,
        input  logic                  sync_rst_ni,

        input  logic                  pipe_in_valid_i,
        output logic                  pipe_in_ready_o,
        input  CTRL_T                 pipe_in_ctrl_i,
        input  logic [FPU_OP_W  -1:0] pipe_in_op1_i,
        input  logic [FPU_OP_W  -1:0] pipe_in_op2_i,
        input  logic [FPU_OP_W  -1:0] pipe_in_op3_i,
        input  logic [FPU_OP_W/8-1:0] pipe_in_mask_i,

        output logic                  pipe_out_valid_o,
        input  logic                  pipe_out_ready_i,
        output CTRL_T                 pipe_out_ctrl_o,
        output logic [FPU_OP_W  -1:0] pipe_out_res_o,
        output logic [FPU_OP_W/8-1:0] pipe_out_mask_o


    );

    import vproc_pkg::*;
    import fpnew_pkg::*;

    //Struct for tag data to pass through FPU
    typedef struct packed {
        CTRL_T     ctrl;
        logic      last_cycle;
    } fpu_tag; 

    ///////////////////////////////////////////////////////////////////////////
    //Input buffer defines
    ///////////////////////////////////////////////////////////////////////////

    logic [FPU_OP_W  -1:0] pipe_in_op1_i_d, pipe_in_op2_i_d, pipe_in_op3_i_d;
    logic [FPU_OP_W  -1:0] pipe_in_op1_i_q, pipe_in_op2_i_q, pipe_in_op3_i_q;
    CTRL_T                unit_ctrl_d, unit_ctrl_q;

    logic                 data_valid_i_d, data_valid_i_q;

    ///////////////////////////////////////////////////////////////////////////
    //Control logic for Reductions Ops Defines
    ///////////////////////////////////////////////////////////////////////////

    //store the intermediate result of the reduction operation here
    logic [31:0] reduction_buffer_d, reduction_buffer_q;

    logic last_cycle; 
    

    ///////////////////////////////////////////////////////////////////////////
    // FPU ARITHMETIC defines
    // Each FPU unit handles one 32 bit result.
    // Signals for connections to the FPU
    ///////////////////////////////////////////////////////////////////////////
    logic [FPU_OP_W/ 32 - 1:0] pipe_in_ready_fpu;
    logic [FPU_OP_W/ 32 - 1:0] pipe_out_valid_fpu;

    fpu_tag unit_in_fpu_tag;
    assign unit_in_fpu_tag.ctrl = unit_ctrl_q;
    assign unit_in_fpu_tag.last_cycle = last_cycle;

    fpu_tag [FPU_OP_W/ 32 - 1:0] unit_out_fpu_tag;


    logic [FPU_OP_W  -1:0] operand_0_fpu, operand_1_fpu, operand_2_fpu;

   

    ///////////////////////////////////////////////////////////////////////////
    //Input Connections - Connect to buffers
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin                                                
            unit_ctrl_d     = pipe_in_ctrl_i;
            data_valid_i_d  = pipe_in_valid_i;
            pipe_in_op1_i_d = pipe_in_op1_i;
            pipe_in_op2_i_d = pipe_in_op2_i;
            pipe_in_op3_i_d = pipe_in_op3_i;

    end


    ///////////////////////////////////////////////////////////////////////////
    //Output Connections
    ///////////////////////////////////////////////////////////////////////////

    always_comb begin
        pipe_in_ready_o = &pipe_in_ready_fpu;  //only pass ready signal when all data has been processed
        pipe_out_valid_o = &pipe_out_valid_fpu & (~unit_out_fpu_tag[0].ctrl.mode.fpu.op_reduction | unit_out_fpu_tag[0].last_cycle); //only pass data valid signal when entire reduction operation is complete
        pipe_out_ctrl_o = unit_out_fpu_tag[0].ctrl; //only passing from the lowest FPU, all tag data should be the same
        reduction_buffer_d = pipe_out_res_o[31:0]; //reduction operation only uses the lowest FPU
    end

    ///////////////////////////////////////////////////////////////////////////
    //Determine the input and output formats and vectorial operation based on SEW
    ///////////////////////////////////////////////////////////////////////////

    fp_format_e src_fmt, dst_fmt;
    int_format_e int_fmt;

    logic vectorial_op;
    always_comb begin
        unique case ({unit_ctrl_q.eew, unit_ctrl_q.mode.fpu.src_1_narrow, unit_ctrl_q.mode.fpu.src_2_narrow})
            //Single Width SEW32
            {VSEW_32, 1'b0, 1'b0} : begin
                src_fmt = FP32;
                dst_fmt = FP32;
                int_fmt = INT32;
                vectorial_op = 0;
            end
            //Single Width SEW16
            {VSEW_16, 1'b0, 1'b0} : begin
                src_fmt = FP16;
                dst_fmt = FP16;
                int_fmt = INT16;
                vectorial_op = 1;
            end
            //Widening From SEW16
            {VSEW_32, 1'b1, 1'b1} : begin
                src_fmt = FP16;
                dst_fmt = FP32;
                int_fmt = INT32;
                vectorial_op = 0;
            end

            default : begin
                src_fmt = FP32;
                dst_fmt = FP32;
                int_fmt = INT32;
                vectorial_op = 0;
            end
        endcase

    end

    ///////////////////////////////////////////////////////////////////////////
    //Input buffers
    ///////////////////////////////////////////////////////////////////////////

    always_ff @(posedge clk_i) begin

        pipe_in_op1_i_q <= pipe_in_op1_i_d;
        pipe_in_op2_i_q <= pipe_in_op2_i_d;
        pipe_in_op3_i_q <= pipe_in_op3_i_d;
        unit_ctrl_q <= unit_ctrl_d;
        data_valid_i_q <= data_valid_i_d;
        reduction_buffer_q <= reduction_buffer_d;
            
    end

    ///////////////////////////////////////////////////////////////////////////
    //Control logic for Reductions Ops
    ///////////////////////////////////////////////////////////////////////////
    always_comb begin
        last_cycle = 0;
        if ((unit_ctrl_q.last_cycle) | (unit_ctrl_q.last_vl_part & unit_ctrl_d.vl_part_0)) begin
            last_cycle = 1'b1;
        end else begin
            last_cycle = 1'b0;
        end
        
    end

    ///////////////////////////////////////////////////////////////////////////
    // Mask out generation
    ///////////////////////////////////////////////////////////////////////////

    // result byte mask
    logic [FPU_OP_W/8-1:0] vl_mask;

    assign vl_mask        = ~pipe_out_ctrl_o.vl_part_0 ? ({(FPU_OP_W/8){1'b1}} >> (~pipe_out_ctrl_o.vl_part)) : '0;
    assign pipe_out_mask_o = (pipe_out_ctrl_o.mode.fpu.masked ? pipe_in_mask_i : {(FPU_OP_W/8){1'b1}}) & vl_mask; //TODO: may need to buffer or pass the input operand mask as metadata for masked operations

    ///////////////////////////////////////////////////////////////////////////
    //Input connections to FPU
    ///////////////////////////////////////////////////////////////////////////

    //Operand order/mapping depends on op selected
    //each opgroup has uses different input operands for FPU.  Pipeline always provides rd as operand 3 and other operands as 1 and 2.
    //FPNEW Operands are numbered 0, 1, 2

    always_comb begin
        operand_0_fpu = '0;
        operand_1_fpu = '0;
        operand_2_fpu = '0;


        if (unit_ctrl_q.mode.fpu.op_reduction == 1'b1 & unit_ctrl_q.mode.fpu.op == ADD) begin
            if(unit_ctrl_q.first_cycle == 1'b1) begin
                operand_0_fpu = '0;//This operand is unused by these operations;
                operand_1_fpu = {'0, pipe_in_op1_i_q[31:0]};//First cycle of reduction operation uses vs1[0]  //TODO: MAKE THESE GENERIC
                operand_2_fpu = {'0, pipe_in_op2_i_q[31:0]};

            end else begin
                operand_0_fpu = '0;//This operand is unused by these operations;
                operand_1_fpu = {'0, reduction_buffer_q[31:0]};//all other cycles use previous result
                operand_2_fpu = {'0, pipe_in_op2_i_q[31:0]};

            end           

        end else if (unit_ctrl_q.mode.fpu.op_reduction == 1'b1 & unit_ctrl_q.mode.fpu.op == MINMAX) begin

            if(unit_ctrl_q.first_cycle == 1'b1) begin
                operand_0_fpu = {'0, pipe_in_op2_i_q[31:0]};
                operand_1_fpu = {'0, pipe_in_op1_i_q[31:0]};//First cycle of reduction operation uses vs1[0]  //TODO: MAKE THESE GENERIC
                operand_2_fpu = '0;//This operand is unused by these operations
            end else begin
                operand_0_fpu = {'0, pipe_in_op2_i_q[31:0]};
                operand_1_fpu = {'0, reduction_buffer_q[31:0]};//all other cycles use previous result
                operand_2_fpu = '0;//This operand is unused by these operations;
            end     

        end else if (unit_ctrl_q.mode.fpu.op == ADD) begin

            if (unit_ctrl_q.mode.fpu.op_rev == 1'b1) begin
                //Reverse input operands
                operand_0_fpu = 32'b0;//This operand is unused by these operations;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = pipe_in_op2_i_q;
            end else begin
                operand_0_fpu = 32'b0;//This operand is unused by these operations;
                operand_1_fpu = pipe_in_op2_i_q;
                operand_2_fpu = pipe_in_op1_i_q;
            end
        
         end else if (unit_ctrl_q.mode.fpu.op == DIV) begin

            if (unit_ctrl_q.mode.fpu.op_rev == 1'b1) begin
                //Reverse input operands
                operand_0_fpu = pipe_in_op1_i_q;
                operand_1_fpu = pipe_in_op2_i_q;
                operand_2_fpu = 32'b0;//This operand is unused by these operations
            end else begin
                operand_0_fpu = pipe_in_op2_i_q;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = 32'b0;//This operand is unused by these operations
            end

        end else if (unit_ctrl_q.mode.fpu.op == MINMAX | unit_ctrl_q.mode.fpu.op == MUL | unit_ctrl_q.mode.fpu.op == SGNJ ) begin
            
            operand_0_fpu = pipe_in_op2_i_q;
            operand_1_fpu = pipe_in_op1_i_q;
            operand_2_fpu = 32'b0;//This operand is unused by these operations

        end else if (unit_ctrl_q.mode.fpu.op == FMADD | unit_ctrl_q.mode.fpu.op == FNMSUB) begin

            if (unit_ctrl_q.mode.fpu.op_rev == 1'b1) begin
                //Reverse input operands
                operand_0_fpu = pipe_in_op3_i_q;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = pipe_in_op2_i_q;
            end else begin
                operand_0_fpu = pipe_in_op2_i_q;
                operand_1_fpu = pipe_in_op1_i_q;
                operand_2_fpu = pipe_in_op3_i_q;
            end


        end else if (unit_ctrl_q.mode.fpu.op == CLASSIFY | unit_ctrl_q.mode.fpu.op == F2I | unit_ctrl_q.mode.fpu.op == I2F) begin

            operand_0_fpu = pipe_in_op2_i_q;
            operand_1_fpu = 32'b0;//This operand is unused by these operations
            operand_2_fpu = 32'b0;//This operand is unused by these operations

        end

    end

    ///////////////////////////////////////////////////////////////////////////
    // FPU ARITHMETIC
    // Each FPU unit handles one 32 bit result.
    
    generate
        for (genvar g = 0; g < FPU_OP_W/ 32; g++) begin
              fpnew_top #(
                    //.DivSqrtSel    (fpnew_pkg::THMULTI),                //TODO: Wire this to T-Head unit
                    .Features      (FPU_FEATURES),        //TODO:Pass in from top level ideally (or define as part of package? if so cant swap them)
                    .Implementation(FPU_IMPLEMENTATION),  //TODO:Pass in from top level ideally (or define as part of package? if so cant swap them)
                    .TagType       (fpu_tag)              // Type for metadata to pass through with instruction.  allows for pipelined operation
                    //Missing 2 config parameters :TrueSIMDClass and EnableSIMDMask - may be necessary for FP16 SIMD OPERATION
                ) fpnew_i (
                    .clk_i         (clk_i),                               
                    .rst_ni        (async_rst_ni),          
                    .operands_i    ({operand_2_fpu[32*g +: 32], operand_1_fpu[32*g +: 32], operand_0_fpu[32*g +: 32]}),  
                    .rnd_mode_i    (unit_ctrl_q.mode.fpu.rnd_mode ), //TODO:Needs to be read from the CSR (can do this at decoder?)
                    .op_i          (unit_ctrl_q.mode.fpu.op ),       
                    .op_mod_i      (unit_ctrl_q.mode.fpu.op_mod ),       
                    .src_fmt_i     (src_fmt),                              
                    .dst_fmt_i     (dst_fmt),                           
                    .int_fmt_i     (int_fmt),                            
                    .vectorial_op_i(vectorial_op),                        
                    .tag_i         (unit_in_fpu_tag),                       
                    .simd_mask_i   (2'b11),                                 //TODO: In SIMD mode, select the active lanes to not pollute the output status flags.  Derive from input mask
                    .in_valid_i    (data_valid_i_q),                        //DIRECT CONNECT to pipe_in_valid_i
                    .in_ready_o    (pipe_in_ready_fpu[g]),                   
                    .flush_i       (~sync_rst_ni),                          
                    .result_o      (pipe_out_res_o[32*g +: 32]),            
                    .status_o      (),                                      //TODO: RISCV FFLAGS status regs/ vector float instructions need to update the CSR
                    .tag_o         (unit_out_fpu_tag[g]),              
                    .out_valid_o   (pipe_out_valid_fpu[g]),                  
                    .out_ready_i   ((&pipe_out_valid_fpu)),                 //output only ready when pipeline is ready(TODO: Why does this signal not get raised for ops that arent DIV?) and all units are finished operating.  Causes units to hold their outputs
                    .busy_o        ()                                       //TODO: Can be monitored for usage? Should be unneeded
                );

            
        end
    endgenerate
endmodule
