module edge_detect (
    input  logic clk,
    input  logic rst,
    input  logic sig,
    output logic pulse
);
    logic prev;
    always_ff @(posedge clk) begin
        if (rst) begin
            prev  <= 1'b0;
            pulse <= 1'b0;
        end else begin
            pulse <= sig & ~prev;  // high iff this edge sees 0->1
            prev  <= sig;
        end
    end
endmodule
