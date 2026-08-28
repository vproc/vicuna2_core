// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1


module vproc_pipeline import vproc_pkg::*, obi_pkg::*; #(
        parameter int unsigned          VREG_W              = 128,  // width in bits of vector registers
        parameter int unsigned          CFG_VL_W            = 7,    // width of VL reg in bits (= log2(VREG_W))
        parameter int unsigned          XIF_ID_W            = 3,    // width in bits of instruction IDs
        parameter int unsigned          XIF_ID_CNT          = 8,    // total count of instruction IDs
        parameter bit [UNIT_CNT-1:0]    UNITS               = '0,
        parameter int unsigned          MAX_VPORT_W         = 128,  // max port width
        parameter int unsigned          MAX_VADDR_W         = 5,    // max addr width
        parameter int unsigned          VPORT_CNT           = 1,
        //parameter int unsigned          VPORT_W [VPORT_CNT] = '{0},
        parameter int unsigned          VADDR_W [VPORT_CNT] = '{0},
        parameter bit [VPORT_CNT-1:0]   VPORT_BUFFER        = '0,   // buffer port
        parameter int unsigned          MAX_OP_W            = 64,
        parameter int unsigned          MEM_W               = 0,
        parameter int unsigned          OP_CNT              = 1,
        parameter int unsigned          OP_W    [OP_CNT   ] = '{0}, // op widths
        // parameter int unsigned          OP_STAGE[OP_CNT   ] = '{0}, // op load stage
        // parameter int unsigned          OP_SRC  [OP_CNT   ] = '{0}, // op port index
        parameter int unsigned          OP_DYN_ADDR_SRC     = 0,    // dyn addr src idx
        parameter bit [OP_CNT-1:0]      OP_DYN_ADDR         = '0,   // dynamic addr
        parameter bit [OP_CNT-1:0]      OP_MASK             = '0,   // op is a mask
        parameter bit [OP_CNT-1:0]      OP_XREG             = '0,   // op may be XREG
        parameter bit [OP_CNT-1:0]      OP_NARROW           = '0,   // op may be narrow
        parameter bit [OP_CNT-1:0]      OP_ALLOW_ELEMWISE   = '0,   // op may be 1 elem
        parameter bit [OP_CNT-1:0]      OP_ALWAYS_ELEMWISE  = '0,   // op is 1 elem
        parameter bit [OP_CNT-1:0]      OP_ALT_COUNTER      = '0,
        parameter bit [OP_CNT-1:0]      OP_ALWAYS_VREG      = '0,
        parameter bit [OP_CNT-1:0]      OP_FIELD            = '0,    // op incremented for each field
        parameter bit [OP_CNT-1:0]      OP_INDEX_FIELD      = 0, 
        parameter int unsigned          UNPACK_STAGES       = 0,
        parameter int unsigned          MAX_RES_W           = 64,
        parameter int unsigned          RES_CNT             = 1,
        parameter int unsigned          RES_W   [RES_CNT  ] = '{0},
        parameter bit [RES_CNT-1:0]     RES_MASK            = '0,   // result is a mask
        parameter bit [RES_CNT-1:0]     RES_NARROW          = '0,   // result may be narrow
        parameter bit [RES_CNT-1:0]     RES_ALLOW_ELEMWISE  = '0,   // result may be 1 elem
        parameter bit [RES_CNT-1:0]     RES_ALWAYS_ELEMWISE = '0,   // result is 1 elem
        parameter bit [RES_CNT-1:0]     RES_ALWAYS_VREG     = '0,   // result is 1 elem
        parameter bit                   FIELD_COUNT_USED    = 1'b0,
        parameter int unsigned           VLSU_QUEUE_SZ      = 4,
        parameter bit [VLSU_FLAGS_W-1:0] VLSU_FLAGS         = '0,
        parameter mul_type               MUL_TYPE           = MUL_GENERIC,
        parameter type                  INIT_STATE_T        = logic,
        parameter int unsigned          MEM_PORTS           = 1,
        parameter obi_cfg_t             OBI_CFG             = ObiDefaultConfig,
        parameter int unsigned          PORT_QUEUE_DEPTH    = 1,
        parameter bit                   DONT_CARE_ZERO      = 1'b0  // initialize don't care values to zero
    )(
        input  logic                    clk_i,
        input  logic                    async_rst_ni,
        input  logic                    sync_rst_ni,

        input  logic                    pipe_in_valid_i,
        output logic                    pipe_in_ready_o,
        input  INIT_STATE_T             pipe_in_state_i,

        input  logic [31:0]             vreg_pend_wr_i,
        output logic [31:0]             vreg_pend_rd_o,
        input  logic [31:0]             vreg_pend_rd_i,

        input  instr_state [XIF_ID_CNT-1:0] instr_state_i,
        output logic                    instr_done_valid_o,
        output logic [XIF_ID_W-1:0]     instr_done_id_o,

        // connections to register file
        output logic [VPORT_CNT-1:0][MAX_VADDR_W-1:0] vreg_rd_addr_o,       // vreg read address
        input  logic [VPORT_CNT-1:0][MAX_VPORT_W-1:0] vreg_rd_data_i,       // vreg read data
        input  logic [VPORT_CNT-1:0]                  vreg_rd_gnt_i,        // gnt signal for read ports
        output logic [VPORT_CNT-1:0]                  vreg_rd_req_o,        // req signal for read ports
        input  logic                [MAX_VPORT_W -1:0] vreg_rd_v0_i,         // vreg v0 read data

        output logic [XIF_ID_W-1:0]                   vreg_rd_id_o,         // instruction id for read port arbitration

        output logic                    vreg_wr_req_o,
        input  logic                    vreg_wr_gnt_i,
        output logic [4:0]              vreg_wr_addr_o,
        output logic [VREG_W/8-1:0]     vreg_wr_be_o,
        output logic [VREG_W  -1:0]     vreg_wr_data_o,
        output logic [XIF_ID_W-1:0]     vreg_wr_id_o,

        input  logic   [31:0]           pend_wr_clear_i,

        output logic                    vreg_wr_clr_o, //Deprecated signals
        output logic [1:0]              vreg_wr_clr_cnt_o,

        output logic                    pending_load_o,
        output logic                    pending_store_o,

        OBI_BUS.Manager                 obi_bus [MEM_PORTS-1:0],

        output logic                    trans_complete_valid_o,
        input  logic                    trans_complete_ready_i,
        output logic [XIF_ID_W-1:0]     trans_complete_id_o,
        output logic                    trans_complete_exc_o,
        output logic [5:0]              trans_complete_exccode_o,

        `ifdef RISCV_ZVE32F
        output logic                    freg_res,
        `endif 

        output logic                    xreg_valid_o,
        input  logic                    xreg_ready_i,
        output logic [XIF_ID_W-1:0]     xreg_id_o,
        output logic [4:0]              xreg_addr_o,
        output logic [31:0]             xreg_data_o
    );

    if ((MAX_OP_W & (MAX_OP_W - 1)) != 0 || MAX_OP_W < 32 || MAX_OP_W >= VREG_W) begin
        $fatal(1, "The vector pipeline operand width MAX_OP_W must be at least 32, less than ",
                  "the vector register width VREG_W and a power of two.  ",
                  "The current value of %d is invalid.", MAX_OP_W);
    end


    ///////////
    // Metadata struct to be passed through the vector pipeline for all instructions
    // TODO: Most of this info comes from or is available during decode.  Rework decode + pipeline wrapper to simplify this
    ///////////

    typedef struct packed {
        logic                            first_cycle;
        logic                            last_cycle;

        logic        [XIF_ID_W     -1:0] id;
        op_unit                          unit;
        op_mode                          mode;
        cfg_vsew                         eew;            // effective element width
        cfg_emul                         emul;           // effective MUL factor
        cfg_vxrm                         vxrm;
        logic        [CFG_VL_W     -1:0] vl;
        logic        [CFG_VL_W       :0] vlmax;
        logic                            vl_0;

        logic        [OP_CNT -1:0][31:0] op_xval; //Why twice?  This is the better one

        logic        [RES_CNT-1:0]       res_narrow;
        logic                            res_narrow_frac;
        logic                     [4 :0] res_vaddr;
        logic                     [31:0] pend_vreg_wr;   // pending vector register writes

        decode_metadata                decode_metadata; //All above relevant signals should be absorbed into this one and passed from decode

    } metadata_t;

    metadata_t metadata_i;

    always_comb begin
        metadata_i.first_cycle             = 1'b1; // These should be set in vregunpack
        metadata_i.last_cycle              = 1'b1; // These should be set in vregunpack

        metadata_i.id                      = pipe_in_state_i.id;
        metadata_i.mode                    = pipe_in_state_i.mode;

        metadata_i.eew                     = pipe_in_state_i.eew;
        metadata_i.unit                    = pipe_in_state_i.unit;

        metadata_i.emul                    = pipe_in_state_i.emul;
        metadata_i.vxrm                    = pipe_in_state_i.vxrm;
        metadata_i.vl                      = pipe_in_state_i.vl;
        metadata_i.vlmax                   = pipe_in_state_i.vlmax;
        metadata_i.vl_0                    = pipe_in_state_i.vl_0;

        metadata_i.op_xval                 = pipe_in_state_i.op_xval;        //TODO: Something uses these values instead of values from decode_metadata

        metadata_i.res_narrow              = pipe_in_state_i.res_narrow;
        metadata_i.res_narrow_frac         = pipe_in_state_i.res_narrow_frac;
        metadata_i.res_vaddr               = pipe_in_state_i.res_vaddr;

        metadata_i.decode_metadata         = pipe_in_state_i.decode_metadata; //TODO: This should be the only struct passed
    end

    //////////
    //  VREGUNPACK unit instantiation and signal connections
    //////////

    //Handshake signals between unpack and unit_mux
    logic               [OP_CNT   -1:0] unpack_out_valid;
    logic               [OP_CNT   -1:0] unpack_out_ready;
    metadata_t                          unpack_out_ctrl;
    logic [OP_CNT   -1:0][MAX_OP_W-1:0] unpack_out_ops;
    logic                               unpack_out_mask_valid;
    logic                               unpack_out_mask_ready;
    logic              [MAX_OP_W/8-1:0] unpack_out_mask;

    logic                vfu_vreg_rd_req;
    logic                vfu_vreg_rd_gnt;
    logic [XIF_ID_W-1:0] vfu_vreg_rd_id;
    logic [4:0]          vfu_vreg_rd_addr;

  vproc_vregunpack #(
        .MAX_VPORT_W          ( MAX_VPORT_W                  ),
        .MAX_VADDR_W          ( MAX_VADDR_W                  ),
        .VPORT_CNT            ( VPORT_CNT                    ),
        //.VPORT_W              ( VPORT_W                      ),
        .VADDR_W              ( VADDR_W                      ),
        .VPORT_BUFFER         ( VPORT_BUFFER                 ),
        .VPORT_V0_W           ( VREG_W                       ),
        .MAX_OP_W             ( MAX_OP_W                     ),
        .MEM_W                ( MEM_W                        ),
        .MEM_PORTS            ( MEM_PORTS                    ),
        .OP_W                 ( OP_W                         ),
        .CFG_VL_W             ( CFG_VL_W                     ),
        .OP_DYN_ADDR_SRC      ( OP_DYN_ADDR_SRC              ),
        .OP_DYN_ADDR          ( OP_DYN_ADDR                  ),
        .OP_MASK              ( OP_MASK                      ),
        .OP_XREG              ( OP_XREG                      ),
        .OP_NARROW            ( OP_NARROW                    ),
        .OP_ALLOW_ELEMWISE    ( OP_ALLOW_ELEMWISE            ),
        .OP_ALWAYS_ELEMWISE   ( OP_ALWAYS_ELEMWISE           ),
        .FLAGS_T              ( unpack_flags                 ),
        .METADATA_T           ( metadata_t                   ),
        .CTRL_DATA_W          ( $bits(metadata_t)            ),
        .FIELD_COUNT_USED     ( FIELD_COUNT_USED             ),
        .OP_FIELD             ( OP_FIELD                     ),
        .DONT_CARE_ZERO       ( DONT_CARE_ZERO               )
    ) unpack (
        .clk_i                      ( clk_i                        ),
        .async_rst_ni               ( async_rst_ni                 ),
        .sync_rst_ni                ( sync_rst_ni                  ),

        .vreg_rd_addr_o             ( vreg_rd_addr_o               ),
        .vreg_rd_data_i             ( vreg_rd_data_i               ),
        .vreg_rd_gnt_i              ( vreg_rd_gnt_i                ),
        .vreg_rd_req_o              ( vreg_rd_req_o                ),
        .vreg_rd_v0_i               ( vreg_rd_v0_i                 ),
        .vreg_rd_id_o               ( vreg_rd_id_o                 ),

        .vfu_vreg_rd_req_i          (vfu_vreg_rd_req               ),
        .vfu_vreg_rd_gnt_o          (vfu_vreg_rd_gnt               ),
        .vfu_vreg_rd_addr_i         (vfu_vreg_rd_addr              ),
        .vfu_vreg_rd_id_i           (vfu_vreg_rd_id                ),

        .pipe_in_valid_i            ( pipe_in_valid_i              ),
        .pipe_in_ready_o            ( pipe_in_ready_o              ),
        .pipe_in_ctrl_i             ( metadata_i                   ),
        .pipe_in_unit_i             ( metadata_i.unit              ), //TODO: Passing metadata already, all other not necessary
        .pipe_in_eew_i              ( metadata_i.eew               ),
        .pipe_in_op_xval_i          ( metadata_i.op_xval           ),
        .pend_wr_map_i              ( vreg_pend_wr_i               ),
        .pend_wr_clear_i            ( pend_wr_clear_i              ),
        // .pipe_in_mem_req_valid_i    ( unpack_ctrl.mem_req_valid    ),
        // .pipe_in_field_counter_i    ( unpack_ctrl.field_counter    ),
        .pipe_out_valid_o           ( unpack_out_valid             ),
        .pipe_out_ready_i           ( unpack_out_ready             ),
        .pipe_out_ctrl_o            ( unpack_out_ctrl              ),
        .pipe_out_op_data_o         ( unpack_out_ops               ),
        .pipe_out_mask_data_o       ( unpack_out_mask              ),
        .pipe_out_mask_ready_i      ( unpack_out_mask_ready        ),
        .pipe_out_mask_valid_o      ( unpack_out_mask_valid        ),
        //.pending_vreg_reads_o       ( unpack_pend_rd             ),
        .stage_valid_any_o          (                              ),
        .ctrl_flags_any_o           ( unpack_ctrl_flags            ),
        .ctrl_flags_all_o           (                              )
    );

    ////////////
    //  Vector Functional Unit Mux Instantiation and Signal Connections
    ////////////

    // Handshake signals between unit mux and vregpack
    // TODO: These should all be passed in a single struct
    logic                                   mux_out_valid;
    logic                                   mux_out_ready;
    logic      [XIF_ID_W              -1:0] mux_out_instr_id;
    vproc_pkg::cfg_vsew                     mux_out_eew;
    logic      [4:0]                        mux_out_vaddr;
    logic                                   mux_out_res_vaddr;
    logic      [RES_CNT-1:0]                mux_out_res_store;
    logic      [RES_CNT-1:0]                mux_out_res_valid;
    pack_flags [RES_CNT-1:0]                mux_out_res_flags;
    logic      [RES_CNT-1:0][MAX_RES_W-1:0] mux_out_res_data;
    logic      [RES_CNT-1:0][MAX_RES_W-1:0] mux_out_res_mask;
    logic                                   mux_out_pend_clear;
    logic      [1:0]                        mux_out_pend_clear_cnt;
    logic                                   mux_out_instr_done;


    // TODO: Define metadata struct between UNPACK and UNITMUX
    

    vproc_unit_mux #(
        .UNITS                     ( UNITS                    ),
        .XIF_ID_W                  ( XIF_ID_W                 ),
        .XIF_ID_CNT                ( XIF_ID_CNT               ),
        .VREG_W                    ( VREG_W                   ),
        .OP_CNT                    ( OP_CNT                   ),
        .MAX_OP_W                  ( MAX_OP_W                 ),
        .MEM_W                     ( MEM_W                    ),
        .RES_CNT                   ( RES_CNT                  ),
        .MAX_RES_W                 ( MAX_RES_W                ),
        .VLSU_QUEUE_SZ             ( VLSU_QUEUE_SZ            ),
        .VLSU_FLAGS                ( VLSU_FLAGS               ),
        .MUL_TYPE                  ( MUL_TYPE                 ),
        .CTRL_T                    ( metadata_t               ),
        // .COUNTER_T                 ( counter_t                ),
        // .COUNTER_W                 ( COUNTER_W                ),
        .MEM_PORTS                 ( MEM_PORTS                ),
        .OBI_CFG                   ( OBI_CFG                  ),
        .PORT_QUEUE_DEPTH          ( PORT_QUEUE_DEPTH         ),
        .DONT_CARE_ZERO            ( DONT_CARE_ZERO           )
    ) unit_mux (
        .clk_i                     ( clk_i                    ),
        .async_rst_ni              ( async_rst_ni             ),
        .sync_rst_ni               ( sync_rst_ni              ),

        .pipe_in_valid_i           ( unpack_out_valid         ),
        .pipe_in_ready_o           ( unpack_out_ready         ),
        .pipe_in_ctrl_i            ( unpack_out_ctrl          ),
        .pipe_in_op_data_i         ( unpack_out_ops           ),
        .pipe_in_mask_valid_i      ( unpack_out_mask_valid    ),
        .pipe_in_mask_ready_o      ( unpack_out_mask_ready    ),
        .pipe_in_mask_data_i       ( unpack_out_mask          ),

        .pipe_out_valid_o          ( mux_out_valid            ),
        .pipe_out_ready_i          ( mux_out_ready            ),
        .pipe_out_instr_id_o       ( mux_out_instr_id         ),
        .pipe_out_eew_o            ( mux_out_eew              ),
        .pipe_out_vaddr_o          ( mux_out_vaddr            ),
        .pipe_out_res_store_o      ( mux_out_res_store        ),
        .pipe_out_res_valid_o      ( mux_out_res_valid        ),
        .pipe_out_res_flags_o      ( mux_out_res_flags        ),
        .pipe_out_res_data_o       ( mux_out_res_data         ),
        .pipe_out_res_mask_o       ( mux_out_res_mask         ),
        .pipe_out_pend_clear_o     ( mux_out_pend_clear       ),
        .pipe_out_pend_clear_cnt_o ( mux_out_pend_clear_cnt   ),
        .pipe_out_instr_done_o     ( mux_out_instr_done       ),
        .pending_load_o            ( lsu_pending_load         ),
        .pending_store_o           ( lsu_pending_store        ),
        .vreg_pend_rd_i            ( vreg_pend_rd_i           ),
        .instr_state_i             ( instr_state_i            ),
        .obi_bus                   ( obi_bus                  ),
        .trans_complete_valid_o    ( trans_complete_valid_o   ),
        .trans_complete_ready_i    ( trans_complete_ready_i   ),
        .trans_complete_id_o       ( trans_complete_id_o      ),
        .trans_complete_exc_o      ( trans_complete_exc_o     ),
        .trans_complete_exccode_o  ( trans_complete_exccode_o ),
        `ifdef RISCV_ZVE32F
        .freg_res                  ( freg_res                 ),
        `endif 
        .xreg_valid_o              ( xreg_valid_o             ),
        .xreg_ready_i              ( xreg_ready_i             ),
        .xreg_id_o                 ( xreg_id_o                ),
        .xreg_addr_o               ( xreg_addr_o              ),
        .xreg_data_o               ( xreg_data_o              ),
        
        .vreg_rd_req_o             (vfu_vreg_rd_req           ),
        .vreg_rd_gnt_i             (vfu_vreg_rd_gnt           ),
        .vreg_rd_addr_o            (vfu_vreg_rd_addr          ),
        .vreg_rd_id_o              (vfu_vreg_rd_id            ),
        .vreg_rd_data_i            (vreg_rd_data_i[0]         )
    );

    ////////////
    // VREGPACK Instantiation and Signal Connections
    ////////////

    //TODO: Define metadata struct between unit mux and regpack

    vproc_vregpack #(
        .VPORT_W                     ( VREG_W                  ),
        .VADDR_W                     ( 5                       ),
        .MAX_RES_W                   ( MAX_RES_W               ),
        .MEM_W                       ( MEM_W                   ),
        .MEM_PORTS                   ( MEM_PORTS               ),
        .RES_CNT                     ( RES_CNT                 ),
        .RES_W                       ( RES_W                   ),
        .RES_MASK                    ( RES_MASK                ),
        .RES_NARROW                  ( RES_NARROW              ),
        .RES_ALLOW_ELEMWISE          ( RES_ALLOW_ELEMWISE      ),
        .RES_ALWAYS_ELEMWISE         ( RES_ALWAYS_ELEMWISE     ),
        .FLAGS_T                     ( pack_flags              ),
        .INSTR_ID_W                  ( XIF_ID_W                ),
        .INSTR_ID_CNT                ( XIF_ID_CNT              ),
        .DONT_CARE_ZERO              ( DONT_CARE_ZERO          ),
        .FIELD_COUNT_USED            ( FIELD_COUNT_USED        )
    ) pack (
        .clk_i                       ( clk_i                   ),
        .async_rst_ni                ( async_rst_ni            ),
        .sync_rst_ni                 ( sync_rst_ni             ),
        .pipe_in_valid_i             ( mux_out_valid          ),
        .pipe_in_ready_o             ( mux_out_ready          ),
        .pipe_in_instr_id_i          ( mux_out_instr_id       ),
        .pipe_in_eew_i               ( mux_out_eew            ),
        .pipe_in_vaddr_i             ( mux_out_vaddr          ),
        .pipe_in_res_store_i         ( mux_out_res_store      ),
        .pipe_in_res_valid_i         ( mux_out_res_valid      ),
        .pipe_in_res_flags_i         ( mux_out_res_flags      ),
        .pipe_in_res_data_i          ( mux_out_res_data       ),
        .pipe_in_res_mask_i          ( mux_out_res_mask       ),
        .pipe_in_pend_clr_i          ( mux_out_pend_clear     ),
        .pipe_in_pend_clr_cnt_i      ( mux_out_pend_clear_cnt ),
        .pipe_in_instr_done_i        ( mux_out_instr_done     ),
        .vreg_wr_req_o               ( vreg_wr_req_o          ),
        .vreg_wr_gnt_i               ( vreg_wr_gnt_i          ),
        .vreg_wr_addr_o              ( vreg_wr_addr_o          ),
        .vreg_wr_be_o                ( vreg_wr_be_o            ),
        .vreg_wr_data_o              ( vreg_wr_data_o          ),
        .vreg_wr_id_o                ( vreg_wr_id_o            ),
        .vreg_wr_clr_o               ( vreg_wr_clr_o           ),
        .vreg_wr_clr_cnt_o           ( vreg_wr_clr_cnt_o       ),
        .pending_vreg_reads_i        ( vreg_pend_rd_i          ),
        .instr_state_i               ( instr_state_i           ),
        .instr_done_valid_o          ( instr_done_valid_o      ),
        .instr_done_id_o             ( instr_done_id_o         )
    );

endmodule
