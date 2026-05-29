`default_nettype none
`timescale 1ns/1ns

module tb;

    // 1. Virtual Wires to connect to the GPU
    reg clk;
    reg reset;
    reg enable;

    // 2. Instantiate the Top-Level GPU
    gpu uut (
        .clk(clk),
        .reset(reset),
        .enable(enable)
    );

    // 3. The Virtual Metronome
    // A 27 MHz clock has a period of ~37ns. Toggling every 18.5ns gives us that frequency.
    always #18.5 clk = ~clk; 

    // 4. The Simulation Sequence
    initial begin
        // Tell Icarus to record the voltage of every single wire to a file
        $dumpfile("gpu_waveform.vcd");
        $dumpvars(0, tb);

        // Turn on the power, but hold the reset button down
        clk = 0;
        enable = 0;
        reset = 1;

        // Wait 100 nanoseconds, then release reset and hit enable!
        #100;
        reset = 0;
        enable = 1;

        // The multiplier loop (5 * 3) takes a few dozen clock cycles.
        // Let it run for 5000 nanoseconds to ensure it finishes.
        #5000;

        // Self-check: thread 0 should have computed R3 = 5 * 3 = 15, and the
        // core should have halted (reached the DONE state) on its own RET.
        begin : check
            reg [7:0] r3;
            reg core_done;
            r3 = uut.compute_core_0.thread_block[0].thread_regs.registers[3];
            core_done = uut.core_0_done;
            $display("R3 (accumulator) = %0d (expected 15)", r3);
            $display("core_0_done       = %0b (expected 1)", core_done);
            if (r3 === 8'd15 && core_done === 1'b1)
                $display("RESULT: PASS - kernel computed 5*3=15 and halted");
            else
                $display("RESULT: FAIL");
        end

        $display("Simulation Finished Successfully!");
        $finish;
    end

endmodule