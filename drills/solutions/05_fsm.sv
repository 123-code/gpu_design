module seq_detect (
    input  logic clk,
    input  logic rst,
    input  logic din,
    output logic seen
);
    typedef enum logic [1:0] {IDLE, GOT1, GOT10} state_t;
    state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            seen  <= 1'b0;
        end else begin
            seen <= (state == GOT10) && din;  // this edge completes 1,0,1
            case (state)
                IDLE:    if (din) state <= GOT1;
                GOT1:    if (!din) state <= GOT10;
                GOT10:   if (din) state <= GOT1;  // hit! last bit is a 1 -> overlap
                         else     state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
