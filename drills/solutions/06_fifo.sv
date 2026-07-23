module fifo (
    input  logic       clk,
    input  logic       rst,
    input  logic       wr_en,
    input  logic [7:0] wdata,
    input  logic       rd_en,
    output logic [7:0] rdata,
    output logic       full,
    output logic       empty
);
    logic [7:0] mem [0:3];
    logic [1:0] wptr, rptr;
    logic [2:0] count;  // 0..4 needs 3 bits — a classic off-by-one trap

    assign rdata = mem[rptr];        // first-word fall-through
    assign full  = (count == 3'd4);
    assign empty = (count == 3'd0);

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always_ff @(posedge clk) begin
        if (rst) begin
            wptr  <= '0;
            rptr  <= '0;
            count <= '0;
        end else begin
            if (do_wr) begin
                mem[wptr] <= wdata;
                wptr      <= wptr + 1'b1;
            end
            if (do_rd) rptr <= rptr + 1'b1;
            count <= count + do_wr - do_rd;  // push+pop same cycle nets to 0
        end
    end
endmodule
