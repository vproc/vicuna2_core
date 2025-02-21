// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

    // Assert that the instruction ID is always valid
    assert property (
        @(posedge clk_i)
        state_valid_q |-> instr_state_i[state_q.id] != INSTR_INVALID
    ) else begin
        $error("Instruction %d is invalid", state_q.id);
    end

    // Assert that local pending writes are only added in the first cycle of an instruction
    // Assert that new vregs are added to the pending reads only in the first cycle of an instruction or when local pending writes are cleared
    generate
        for (genvar g = 0; g < 32; g++) begin
            assert property (
                @(posedge clk_i)
                $rose(state_q.pend_vreg_wr[g]) |-> state_q.first_cycle
            ) else begin
                $error("local pending write for vreg %d added midway", g);
            end
            assert property (
                @(posedge clk_i)
                $rose(vreg_pend_rd_o[g]) |-> (state_q.first_cycle | $fell(state_q.pend_vreg_wr[g]))
            ) else begin
                $error("pending read for vreg %d added midway", g);
            end
        end
    endgenerate

    // Assert that a vreg is still in the pending writes while being written
    assert property (
        @(posedge clk_i)
        vreg_wr_valid_o |-> vreg_pend_wr_i[vreg_wr_addr_o]
    ) else begin
        $error("writing to a vreg which is not in the global pending writes");
    end
    assert property (
        @(posedge clk_i)
        vreg_wr_valid_o |-> (~vreg_pend_rd_i[vreg_wr_addr_o])
    ) else begin
        $error("writing to a vreg for which there are pending reads");
    end
