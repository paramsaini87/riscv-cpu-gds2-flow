// tb_rv32i_cpu.v — RV32I ISA Compliance Testbench
// Instantiates rv32i_cpu with unified word-addressable memory.
// Loads test program via $readmemh, monitors TOHOST for pass/fail.
// Usage: iverilog -o sim -DTEST_HEX=\"test.hex\" tb_rv32i_cpu.v ../src/rv32i_cpu.v && ./sim

`timescale 1ns / 1ps

module tb_rv32i_cpu;

    // Clock and reset
    reg clk;
    reg rst_n;

    // CPU ↔ memory wires
    wire [31:0] imem_addr, dmem_addr, dmem_wdata, imem_rdata, dmem_rdata;
    wire  [3:0] dmem_wstrb;
    wire        imem_req, dmem_req, imem_ready, dmem_ready;

    // Unified memory — 64KB (16K x 32-bit words)
    reg [31:0] mem [0:16383];

    // TOHOST address: 0x1000 → word index 0x400
    localparam TOHOST_WORD = 14'h400;

    // Clock: 10ns period (100 MHz)
    initial clk = 0;
    always #5 clk = ~clk;

    // Instruction memory — configurable latency
    // IMEM_LATENCY=0: combinational (always ready)
    // IMEM_LATENCY=N: N-cycle wait after request
`ifdef IMEM_LATENCY
    reg [3:0] imem_wait_cnt;
    reg       imem_ready_r;
    assign imem_rdata = mem[imem_addr[15:2]];
    assign imem_ready = imem_ready_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            imem_wait_cnt <= 0;
            imem_ready_r  <= 0;
        end else if (imem_req && !imem_ready_r) begin
            if (imem_wait_cnt >= `IMEM_LATENCY - 1) begin
                imem_ready_r  <= 1;
                imem_wait_cnt <= 0;
            end else
                imem_wait_cnt <= imem_wait_cnt + 1;
        end else begin
            imem_ready_r <= 0;
            imem_wait_cnt <= 0;
        end
    end
`else
    assign imem_rdata = mem[imem_addr[15:2]];
    assign imem_ready = 1'b1;
`endif

    // Data memory — configurable latency
`ifdef DMEM_LATENCY
    reg [3:0] dmem_wait_cnt;
    reg       dmem_ready_r;
    assign dmem_rdata = mem[dmem_addr[15:2]];
    assign dmem_ready = dmem_ready_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dmem_wait_cnt <= 0;
            dmem_ready_r  <= 0;
        end else if (dmem_req && !dmem_ready_r) begin
            if (dmem_wait_cnt >= `DMEM_LATENCY - 1) begin
                dmem_ready_r  <= 1;
                dmem_wait_cnt <= 0;
            end else
                dmem_wait_cnt <= dmem_wait_cnt + 1;
        end else begin
            dmem_ready_r <= 0;
            dmem_wait_cnt <= 0;
        end
    end
    // Data memory — write on ready
    always @(posedge clk) begin
        if (dmem_req && dmem_ready_r && |dmem_wstrb) begin
            if (dmem_wstrb[0]) mem[dmem_addr[15:2]][ 7: 0] <= dmem_wdata[ 7: 0];
            if (dmem_wstrb[1]) mem[dmem_addr[15:2]][15: 8] <= dmem_wdata[15: 8];
            if (dmem_wstrb[2]) mem[dmem_addr[15:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[15:2]][31:24] <= dmem_wdata[31:24];
        end
    end
`else
    assign dmem_rdata = mem[dmem_addr[15:2]];
    assign dmem_ready = 1'b1;

    // Data memory — write: byte-level via dmem_wstrb
    always @(posedge clk) begin
        if (dmem_req && |dmem_wstrb) begin
            if (dmem_wstrb[0]) mem[dmem_addr[15:2]][ 7: 0] <= dmem_wdata[ 7: 0];
            if (dmem_wstrb[1]) mem[dmem_addr[15:2]][15: 8] <= dmem_wdata[15: 8];
            if (dmem_wstrb[2]) mem[dmem_addr[15:2]][23:16] <= dmem_wdata[23:16];
            if (dmem_wstrb[3]) mem[dmem_addr[15:2]][31:24] <= dmem_wdata[31:24];
        end
    end
`endif

    // DUT instantiation
    rv32i_cpu #(
        .RESET_ADDR(32'h0000_0000)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .imem_addr  (imem_addr),
        .imem_req   (imem_req),
        .imem_rdata (imem_rdata),
        .imem_ready (imem_ready),
        .dmem_addr  (dmem_addr),
        .dmem_wdata (dmem_wdata),
        .dmem_wstrb (dmem_wstrb),
        .dmem_req   (dmem_req),
        .dmem_rdata (dmem_rdata),
        .dmem_ready (dmem_ready)
    );

    // Cycle counter
    integer cycle_count;

    // Test result detection
    reg test_done;
    reg test_pass;
    reg [31:0] tohost_val;

    // VCD dump for waveform viewing
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_rv32i_cpu);
    end

    // Load test program
    initial begin
`ifdef TEST_HEX
        $readmemh(`TEST_HEX, mem);
`else
        $display("ERROR: No TEST_HEX defined. Use -DTEST_HEX=\\\"file.hex\\\"");
        $finish;
`endif
    end

    // Reset sequence + main simulation loop
    initial begin
        rst_n = 0;
        test_done = 0;
        test_pass = 0;
        cycle_count = 0;
        tohost_val = 0;

        // Hold reset for 5 cycles
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Run until TOHOST write or timeout
        while (!test_done && cycle_count < 50000) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            // Detect write to TOHOST (0x1000)
            if (dmem_req && |dmem_wstrb && dmem_addr[15:2] == TOHOST_WORD) begin
                tohost_val = 0;
                if (dmem_wstrb[0]) tohost_val[ 7: 0] = dmem_wdata[ 7: 0];
                if (dmem_wstrb[1]) tohost_val[15: 8] = dmem_wdata[15: 8];
                if (dmem_wstrb[2]) tohost_val[23:16] = dmem_wdata[23:16];
                if (dmem_wstrb[3]) tohost_val[31:24] = dmem_wdata[31:24];
                test_done = 1;
                test_pass = (tohost_val == 32'd1);
            end
        end

        // Report result
        if (!test_done) begin
            $display("TIMEOUT after %0d cycles", cycle_count);
            dump_regs();
            $finish(1);
        end else if (test_pass) begin
            $display("PASS (%0d cycles)", cycle_count);
            $finish(0);
        end else begin
            $display("FAIL: tohost = %0d (%0d cycles)", tohost_val, cycle_count);
            dump_regs();
            $finish(1);
        end
    end

    // Register dump on failure/timeout
    task dump_regs;
        integer i;
        begin
            $display("--- Register File ---");
            for (i = 0; i < 32; i = i + 1)
                $display("  x%-2d = 0x%08h", i, dut.regfile[i]);
            $display("--- Pipeline State ---");
            $display("  PC          = 0x%08h", dut.pc);
            $display("  IF/ID instr = 0x%08h", dut.ifid_instr);
            $display("  imem_addr   = 0x%08h", imem_addr);
            $display("  dmem_addr   = 0x%08h", dmem_addr);
        end
    endtask

endmodule
