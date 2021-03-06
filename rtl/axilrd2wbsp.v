////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	axilrd2wbsp.v (AXI lite to wishbone slave, read channel)
//
// Project:	Pipelined Wishbone to AXI converter
//
// Purpose:	Bridge an AXI lite read channel pair to a single wishbone read
//		channel.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2018, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory, run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	axilrd2wbsp(i_clk, i_axi_reset_n,
	// AXI read address channel signals
	o_axi_arready, i_axi_araddr, i_axi_arcache, i_axi_arprot, i_axi_arvalid,
	// AXI read data channel signals   
	o_axi_rresp, o_axi_rvalid, o_axi_rdata, i_axi_rready,
	// We'll share the clock and the reset
	o_wb_cyc, o_wb_stb, o_wb_addr,
		i_wb_ack, i_wb_stall, i_wb_data, i_wb_err
`ifdef	FORMAL
	, f_first, f_mid, f_last
`endif
	);
	localparam C_AXI_DATA_WIDTH	= 32;// Width of the AXI R&W data
	parameter C_AXI_ADDR_WIDTH	= 28;	// AXI Address width
	localparam AW			= C_AXI_ADDR_WIDTH-2;// WB Address width
	parameter LGFIFO                =  3;

	input	wire			i_clk;	// Bus clock
	input	wire			i_axi_reset_n;	// Bus reset

// AXI read address channel signals
	output	wire			o_axi_arready;	// Read address ready
	input	wire	[C_AXI_ADDR_WIDTH-1:0]	i_axi_araddr;	// Read address
	input	wire	[3:0]		i_axi_arcache;	// Read Cache type
	input	wire	[2:0]		i_axi_arprot;	// Read Protection type
	input	wire			i_axi_arvalid;	// Read address valid
  
// AXI read data channel signals   
	output	reg [1:0]		o_axi_rresp;   // Read response
	output	reg			o_axi_rvalid;  // Read reponse valid
	output	wire [C_AXI_DATA_WIDTH-1:0] o_axi_rdata;    // Read data
	input	wire			i_axi_rready;  // Read Response ready

	// We'll share the clock and the reset
	output	reg				o_wb_cyc;
	output	reg				o_wb_stb;
	output	wire [(AW-1):0]			o_wb_addr;
	input	wire				i_wb_ack;
	input	wire				i_wb_stall;
	input	[(C_AXI_DATA_WIDTH-1):0]	i_wb_data;
	input	wire				i_wb_err;
`ifdef	FORMAL
	// Output connections only used in formal mode
	output	wire	[LGFIFO:0]		f_first;
	output	wire	[LGFIFO:0]		f_mid;
	output	wire	[LGFIFO:0]		f_last;
`endif

	localparam	DW = C_AXI_DATA_WIDTH;

	wire	w_reset;
	assign	w_reset = (!i_axi_reset_n);

	localparam	FLEN=(1<<LGFIFO);

	reg	[DW-1:0]	dfifo		[0:(FLEN-1)];
	reg			fifo_full, fifo_empty;

	reg	[LGFIFO:0]	r_first, r_mid, r_last, r_next;
	wire	[LGFIFO:0]	w_first_plus_one;
	wire	[LGFIFO:0]	next_first, next_last, next_mid, fifo_fill;
	reg			wb_pending, last_ack;
	reg	[LGFIFO:0]	wb_outstanding;


	initial	o_wb_cyc = 1'b0;
	initial	o_wb_stb = 1'b0;
	always @(posedge i_clk)
	if ((w_reset)||((o_wb_cyc)&&(i_wb_err))||(err_state))
	begin
		o_wb_stb <= 1'b0;
	end else if ((i_axi_arvalid)&&(o_axi_arready))
	begin
		o_wb_stb <= 1'b1;
	end else if (o_wb_cyc)
	begin
		if (!i_wb_stall)
			o_wb_stb <= 1'b0;
	end

	always @(*)
		o_wb_cyc = (wb_pending)||(o_wb_stb);

	always @(posedge i_clk)
	if (o_axi_arready)
		o_wb_addr <= i_axi_araddr[AW+1:2];

	initial	wb_pending     = 0;
	initial	wb_outstanding = 0;
	initial	last_ack    = 1;
	always @(posedge i_clk)
	if ((w_reset)||(!o_wb_cyc)||(i_wb_err)||(err_state))
	begin
		wb_pending     <= 1'b0;
		wb_outstanding <= 0;
		last_ack       <= 1;
	end else case({ (o_wb_stb)&&(!i_wb_stall), i_wb_ack })
	2'b01: begin
		wb_outstanding <= wb_outstanding - 1'b1;
		wb_pending <= (wb_outstanding >= 2);
		last_ack <= (wb_outstanding <= 2);
		end
	2'b10: begin
		wb_outstanding <= wb_outstanding + 1'b1;
		wb_pending <= 1'b1;
		last_ack <= (wb_outstanding == 0);
		end
	default: begin end
	endcase

	assign	next_first = r_first + 1'b1;
	assign	next_last  = r_last + 1'b1;
	assign	next_mid   = r_mid + 1'b1;
	assign	fifo_fill  = (r_first - r_last);

	initial	fifo_full  = 1'b0;
	initial	fifo_empty = 1'b1;
	always @(posedge i_clk)
	if (w_reset)
	begin
		fifo_full  <= 1'b0;
		fifo_empty <= 1'b1;
	end else case({ (o_axi_rvalid)&&(i_axi_rready),
				(i_axi_arvalid)&&(o_axi_arready) })
	2'b01: begin
		fifo_full  <= (next_first[LGFIFO-1:0] == r_last[LGFIFO-1:0])
					&&(next_first[LGFIFO]!=r_last[LGFIFO]);
		fifo_empty <= 1'b0;
		end
	2'b10: begin
		fifo_full <= 1'b0;
		fifo_empty <= 1'b0;
		end
	default: begin end
	endcase

	initial	r_first = 0;
	always @(posedge i_clk)
	if (w_reset)
		r_first <= 0;
	else if ((i_axi_arvalid)&&(o_axi_arready))
		r_first <= r_first + 1'b1;

	initial	r_mid = 0;
	always @(posedge i_clk)
	if (w_reset)
		r_mid <= 0;
	else if ((o_wb_cyc)&&((i_wb_ack)||(i_wb_err)))
		r_mid <= r_mid + 1'b1;
	else if ((err_state)&&(r_mid != r_first))
		r_mid <= r_mid + 1'b1;

	initial	r_last = 0;
	always @(posedge i_clk)
	if (w_reset)
		r_last <= 0;
	else if ((o_axi_rvalid)&&(i_axi_rready))
		r_last <= r_last + 1'b1;

	always @(posedge i_clk)
	if ((o_wb_cyc)&&((i_wb_ack)||(i_wb_err)))
		dfifo[r_mid[(LGFIFO-1):0]] <= i_wb_data;

	reg	[LGFIFO:0]	err_loc;
	always @(posedge i_clk)
	if ((o_wb_cyc)&&(i_wb_err))
		err_loc <= r_mid;

	wire	[DW-1:0]	read_data;

	assign	read_data = dfifo[r_last[LGFIFO-1:0]];
	assign	o_axi_rdata = read_data[DW-1:0];
	initial	o_axi_rresp = 2'b00;
	always @(posedge i_clk)
	if (w_reset)
		o_axi_rresp <= 0;
	else if ((!o_axi_rvalid)||(i_axi_rready))
	begin
		if ((!err_state)&&((!o_wb_cyc)||(!i_wb_err)))
			o_axi_rresp <= 2'b00;
		else if ((!err_state)&&(o_wb_cyc)&&(i_wb_err))
		begin
			if (o_axi_rvalid)
				o_axi_rresp <= (r_mid == next_last) ? 2'b10 : 2'b00;
			else
				o_axi_rresp <= (r_mid == r_last) ? 2'b10 : 2'b00;
		end else if (err_state)
		begin
			if (next_last == err_loc)
				o_axi_rresp <= 2'b10;
			else if (o_axi_rresp[1])
				o_axi_rresp <= 2'b11;
		end else
			o_axi_rresp <= 0;
	end


	reg	err_state;	
	initial err_state  = 0;
	always @(posedge i_clk)
	if (w_reset)
		err_state <= 0;
	else if (r_first == r_last)
		err_state <= 0;
	else if ((o_wb_cyc)&&(i_wb_err))
		err_state <= 1'b1;

	initial	o_axi_rvalid = 1'b0;
	always @(posedge i_clk)
	if (w_reset)
		o_axi_rvalid <= 0;
	else if ((o_wb_cyc)&&((i_wb_ack)||(i_wb_err)))
		o_axi_rvalid <= 1'b1;
	else if ((o_axi_rvalid)&&(i_axi_rready))
	begin
		if (err_state)
			o_axi_rvalid <= (next_last != r_first);
		else
			o_axi_rvalid <= (next_last != r_mid);
	end

	assign o_axi_arready = (!fifo_full)&&(!err_state)
				&&((!o_wb_stb)||(!i_wb_stall));

	// Make Verilator happy
	// verilator lint_off UNUSED
	// verilator lint_on  UNUSED

`ifdef	FORMAL
`endif
endmodule
