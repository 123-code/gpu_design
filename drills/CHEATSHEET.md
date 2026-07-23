# The only Verilog you need (one page)

Everything below is the complete syntax surface for a whiteboard screen.
There is no more.

## 1. A module is ports + processes

```systemverilog
module thing (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] a,      // 8-bit bus, a[7] is the MSB
    output logic [7:0] y
);
    ...
endmodule
```

`logic` is the only type you need. `[7:0]` = 8 bits.

## 2. Registers: `always_ff` + `<=`

Anything that must remember a value across clock cycles:

```systemverilog
always_ff @(posedge clk) begin
    if (rst)     q <= '0;          // '0 = all zeros, any width
    else if (en) q <= q + 1'b1;
end
```

- Inside `always_ff`, ALWAYS use `<=` (nonblocking).
- Everything in the block updates simultaneously at the clock edge. So
  `a <= b; b <= a;` legally swaps — right-hand sides are all read first.
- This block IS a row of flip-flops. Say that out loud in the interview.

## 3. Wires/combinational: `always_comb` + `=`

Anything computed instantly from current inputs, no memory:

```systemverilog
always_comb begin
    case (op)
        2'b00:   y = a + b;
        2'b01:   y = a - b;
        default: y = '0;       // EVERY path must set y, or you've
    endcase                    // inferred a latch (classic gotcha)
end

assign zero = (y == '0);       // one-liner version of the same idea
```

- Inside `always_comb`, ALWAYS use `=` (blocking).
- The one rule interviewers fish for: **`<=` in clocked blocks, `=` in
  combinational blocks, never mix.** That answer alone passes the question.

## 4. Literals

`8'd255` (decimal) · `8'hFF` (hex) · `2'b01` (binary) · `'0` / `'1` (all
bits). Width'base'value.

## 5. Concatenation and slicing

```systemverilog
q <= {q[6:0], din};   // shift left, din enters at bit 0
{hi, lo} = word;      // split works too
```

## 6. FSM template (memorize this shape)

```systemverilog
typedef enum logic [1:0] {IDLE, BUSY, DONE} state_t;
state_t state;

always_ff @(posedge clk) begin
    if (rst) state <= IDLE;
    else begin
        case (state)
            IDLE: if (start)   state <= BUSY;
            BUSY: if (finished) state <= DONE;
            DONE: state <= IDLE;
            default: state <= IDLE;
        endcase
    end
end
```

## 7. Small memory

```systemverilog
logic [7:0] mem [0:3];         // four 8-bit words
mem[wptr] <= wdata;            // write (clocked)
assign rdata = mem[rptr];      // read (combinational)
```

## 8. Talking points that cost nothing and score points

- "I reset synchronously here; async assert / sync deassert is the other
  common style — on my GPU a reset-path restructure lifted Fmax 79.5 to 100."
- Latch inference: incomplete if/case in combinational logic = accidental
  memory. Fix: default assignment at the top of the block.
- Crossing clock domains: never sample an async signal raw; 2-flop
  synchronizer for single bits, FIFO or handshake for buses.
- If you blank on syntax at a whiteboard: **narrate the hardware instead** —
  "this is a register bank, this mux feeds it, enable gated here" — and write
  pseudo-RTL. Interviewers pass people who see the hardware and fumble a
  semicolon; they fail people who type fluent Verilog that implies impossible
  hardware.
