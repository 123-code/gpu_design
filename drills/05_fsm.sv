// DRILL 05 — FSM: "101" sequence detector (~25 lines)
//
// Sample serial input `din` every clock. Drive `seen` high for one cycle
// when the last three samples were 1,0,1. Overlap counts: in 10101 the
// pattern hits twice (…101.. and ….101).
// Moore machine, registered output: `seen` is high in the cycle AFTER the
// edge that sampled the final 1. rst is synchronous, active high.
//
// This is THE classic interview FSM. The shape to internalize:
//   - an enum for states
//   - one always_ff that moves state <= next
//   - one always_comb (or case in the ff block) computing next
//
// Run:  make drill D=05_fsm

module seq_detect (
    input  logic clk,
    input  logic rst,
    input  logic din,
    output logic seen
);

    // TODO: states IDLE, GOT1, GOT10 — draw the arrows on paper first,
    // including where each state goes on BOTH din=0 and din=1
typedef enum logic [1:0] {
    IDLE,   
    GOT1,   
    GOT10,  
    GOT101   
} state_t;      

state_t current_state,next_state; 

always_ff @(posedge clk) begin
    if(rst ==1'b1) begin
        current_state <= IDLE;
    end
    else begin
        current_state <= next_state;
    end
end
 
always_comb begin
   next_state = current_state;

    case(current_state) 
        IDLE: begin
            if(din == 1'b1) begin
                next_state = GOT1;
            end else begin
                next_state = IDLE;
            end 
        end
        GOT1: begin
            if(din == 1'b0) begin 
                next_state = GOT10;
            end else begin
                if(din == 1'b1) begin
                    next_state = GOT1;
                end
            end
        end

        GOT10:
        begin
            if(din == 1'b1) begin
                next_state = GOT101;
            end else begin 
                if(din == 1'b0) begin 
                    next_state = IDLE;
                end
            end
        end
 
        GOT101: begin
            if(din == 1'b1) begin
                next_state = GOT1; 
            end else begin
                if(din == 1'b0) begin
                    next_state = GOT10; 
                end 
            end
        end 

        endcase


    end

assign seen = (current_state ==GOT101);
endmodule
