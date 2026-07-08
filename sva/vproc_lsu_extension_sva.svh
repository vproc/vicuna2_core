// Copyright TU Wien
// Licensed under the Solderpad Hardware License v2.1, see LICENSE.txt for details
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

    
    // Assert that there are no outstanding memory request in the idle state
    assert property (
        @(posedge clk_i)
        (scratch_state_q.fsm_state == IDLE) |-> scratch_state_q.outstanding_mem_req_cnt == 0
    ) else begin
        $error("outstanding memory requests not resolved");
    end

    // Assert that the transaction complete queue is always ready
    assert property (
        @(posedge clk_i)
        trans_complete_valid |-> trans_complete_ready
    ) else begin
        $error("transaction complete queue is full");
    end
