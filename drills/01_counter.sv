module counter(
    input wire clk,
    input wire rst, 
    input wire en,
    output reg [7:0] count
);
always@(posedge clk) begin
    if(rst == 1'b1) begin
        count <= 8'b0;
    end
    else if (en == 1'b1) begin
        count <= count + 1;
    end
end
endmodule